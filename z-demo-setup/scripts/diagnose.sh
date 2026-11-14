#!/usr/bin/env bash
# diagnose.sh - snapshot why the kubara demo mesh is unhealthy.
#
# Collects host, network/DNS, per-cluster and Argo CD state into
#   .local/diagnostics/<timestamp>/
# and prints a categorised summary with the most likely cause.
#
# Kubernetes events expire after ~1h, so this runs automatically when
# `just bring-up` fails (capture evidence at the moment of failure); run it
# by hand any time with `just diagnose`.
#
# Usage: diagnose.sh [--out DIR] [--config FILE]
# Exit:  0 = no ERROR findings, 1 = ERROR findings, 2 = usage error.
# Read-only: never changes cluster or host state, never needs sudo.

set -uo pipefail   # no -e: every probe is best-effort, one failure must not stop the snapshot

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/kind-demo-common.sh"

ROOT_DIR="$DEMO_REPO_ROOT"
KCFG="${ROOT_DIR}/.local/kind.kubeconfig"
CONFIG_FILE="$DEMO_DEFAULT_CONFIG"
OUT=""
DNSMASQ_CONF="${ROOT_DIR}/dnsmasq/config/dnsmasq.conf"
ANALYZER="${SCRIPT_DIR}/lib/diagnose_cluster.py"
REQ_TIMEOUT="10s"

# Same domain->context rows as `refresh-lb-hosts` in dnsmasq/Justfile.
DNS_ROWS=(
    "hub.kubara.test kind-hub"
    "spoke-1.kubara.test kind-kubara-spoke-1"
    "spoke-2.kubara.test kind-kubara-spoke-2"
    "dev.kubara.test kind-kubara-dev"
    "staging.kubara.test kind-kubara-staging"
    "prod.kubara.test kind-kubara-prod"
)

while [ "$#" -gt 0 ]; do
    case "$1" in
        --out) OUT="${2:?--out needs a directory}"; shift 2 ;;
        -c|--config) CONFIG_FILE="${2:?--config needs a file}"; shift 2 ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$OUT" ] || OUT="${ROOT_DIR}/.local/diagnostics/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
FINDINGS="${OUT}/findings.psv"     # SEVERITY|CATEGORY|object|message (+ cluster prefix)
: >"$FINDINGS"

demo_load_config "$CONFIG_FILE"

# ── helpers ──────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_DIM=$'\033[2m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
    C_RED=""; C_YEL=""; C_GRN=""; C_DIM=""; C_B=""; C_0=""
fi

section() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }
ok()      { printf '  %sok%s    %s\n' "$C_GRN" "$C_0" "$*"; }

# finding SEVERITY CATEGORY SCOPE OBJECT MESSAGE
finding() {
    local sev="$1" cat="$2" scope="$3" obj="$4" msg="$5" color
    printf '%s|%s|%s|%s|%s\n' "$sev" "$cat" "$scope" "$obj" "$msg" >>"$FINDINGS"
    case "$sev" in
        ERROR) color="$C_RED" ;;
        WARN)  color="$C_YEL" ;;
        *)     color="$C_DIM" ;;
    esac
    printf '  %s%-5s%s %-13s %s %s%s%s\n' "$color" "$sev" "$C_0" "$cat" "$msg" "$C_DIM" "${obj:+[$obj]}" "$C_0"
}

kc() { local ctx="$1"; shift; kubectl --kubeconfig "$KCFG" --context "$ctx" --request-timeout="$REQ_TIMEOUT" "$@"; }

# ── 1. host ──────────────────────────────────────────────────────────────────
check_host() {
    section "Host"
    if ! docker info >"$OUT/docker-info.txt" 2>&1; then
        finding ERROR HOST host docker "Docker daemon not reachable"
        return
    fi
    ok "docker: $(docker info --format '{{.NCPU}} CPUs, {{.MemTotal}} bytes RAM' 2>/dev/null)"
    docker system df >"$OUT/docker-df.txt" 2>&1

    # Pull-through image caches (registry-cache.sh). Missing/detached caches
    # mean every rebuild pulls ~150 images from the internet again.
    "${SCRIPT_DIR}/registry-cache.sh" status >"$OUT/registry-cache.txt" 2>&1
    local bad_caches
    bad_caches="$(awk 'NR>1 && ($2 != "running" || $3 != "attached") {print $1"("$2","$3")"}' "$OUT/registry-cache.txt" | tr '\n' ' ')"
    if [ "${KUBARA_REGISTRY_CACHE:-1}" = "0" ]; then
        printf '  %sinfo%s  registry cache disabled (KUBARA_REGISTRY_CACHE=0)\n' "$C_DIM" "$C_0"
    elif [ -n "$bad_caches" ]; then
        finding WARN CACHE host registry-cache "not running/attached: ${bad_caches}(just registry-cache up)"
    else
        ok "registry caches running + attached ($(awk 'NR>1 {printf "%s ", $4}' "$OUT/registry-cache.txt"))"
    fi

    if pgrep -f cloud-provider-kind >/dev/null 2>&1; then
        ok "cloud-provider-kind running (pid $(pgrep -f cloud-provider-kind | head -1))"
    else
        finding ERROR LB host cloud-provider-kind "not running: LoadBalancer IPs will never be assigned (just start-cloud-provider-kind)"
    fi
    [ -f "${ROOT_DIR}/.cloud-provider-kind.log" ] && tail -n 200 "${ROOT_DIR}/.cloud-provider-kind.log" >"$OUT/cloud-provider-kind.log.tail" 2>/dev/null

    if demo_docker_network_exists "$DEMO_MESH_DOCKER_NETWORK"; then
        ok "docker network ${DEMO_MESH_DOCKER_NETWORK} exists"
        docker network inspect "$DEMO_MESH_DOCKER_NETWORK" >"$OUT/docker-network-mesh.json" 2>&1
    else
        finding ERROR NETWORK host "$DEMO_MESH_DOCKER_NETWORK" "docker network missing"
    fi

    [ -f "$KCFG" ] || finding ERROR KUBECONFIG host "$KCFG" "kubeconfig missing (just refresh-kind-kubeconfig)"
}

# ── 2. DNS / LoadBalancer map ────────────────────────────────────────────────
check_dns() {
    section "DNS / LoadBalancer map"
    local dnsmasq_up=1
    if ! dig +short +time=1 +tries=1 @127.0.0.1 hub.kubara.test >/dev/null 2>&1 \
        || [ -z "$(dig +short +time=1 +tries=1 @127.0.0.1 hub.kubara.test 2>/dev/null)" ]; then
        dnsmasq_up=0
        finding ERROR DNS host dnsmasq "not answering on 127.0.0.1: every *.kubara.test URL fails (just refresh-dns-lb-hosts)"
    else
        ok "dnsmasq answering on 127.0.0.1"
    fi
    [ -f /etc/resolver/kubara.test ] || finding ERROR DNS host /etc/resolver/kubara.test "resolver file missing (just -f dnsmasq/Justfile install-resolver)"

    local row dom ctx live conf answer
    for row in "${DNS_ROWS[@]}"; do
        dom="${row%% *}"; ctx="${row#* }"
        live="$(kc "$ctx" get svc/cilium-ingress -n kube-system \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
        conf="$(sed -n "s|^address=/${dom}/||p" "$DNSMASQ_CONF" 2>/dev/null | head -1)"
        answer=""
        [ "$dnsmasq_up" = 1 ] && answer="$(dig +short +time=1 +tries=1 @127.0.0.1 "x.${dom}" 2>/dev/null | head -1)"
        if [ -z "$live" ]; then
            finding ERROR LB "$ctx" cilium-ingress "${dom}: no LoadBalancer IP assigned"
        elif [ "$live" != "$conf" ]; then
            finding ERROR DNS "$ctx" dnsmasq.conf "${dom}: map says '${conf:-none}' but live LB is ${live} (just refresh-dns-lb-hosts)"
        elif [ "$dnsmasq_up" = 1 ] && [ "$answer" != "$live" ]; then
            finding ERROR DNS "$ctx" dnsmasq "${dom}: dnsmasq answers '${answer:-nothing}', live LB is ${live} (stale dnsmasq: restart it)"
        else
            ok "${dom} -> ${live}"
        fi
    done
}

# ── 3. per cluster ───────────────────────────────────────────────────────────
check_cluster() {
    local name="$1" ctx="kind-$1" dir="$OUT/clusters/$1"
    mkdir -p "$dir"
    section "Cluster ${name}"

    if ! demo_cluster_exists "$name"; then
        finding ERROR CLUSTER "$ctx" "$name" "kind cluster does not exist"
        return
    fi
    if ! kc "$ctx" get --raw /readyz >/dev/null 2>&1; then
        finding ERROR CLUSTER "$ctx" apiserver "API server not reachable"
        docker logs --tail 100 "${name}-control-plane" >"$dir/node-container.log" 2>&1
        return
    fi

    # CNI first: without the Cilium agent no pod can get a network, and every
    # other finding on this cluster is a downstream symptom.
    local ds_ready ds_want
    ds_want="$(kc "$ctx" -n kube-system get ds cilium -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)"
    ds_ready="$(kc "$ctx" -n kube-system get ds cilium -o jsonpath='{.status.numberReady}' 2>/dev/null)"
    if [ -z "$ds_want" ]; then
        finding ERROR CNI "$ctx" daemonset/cilium "Cilium agent DaemonSet is missing: no pod networking (check Argo CD *-cilium apps for a cascade delete)"
    elif [ "${ds_ready:-0}" != "$ds_want" ]; then
        finding ERROR CNI "$ctx" daemonset/cilium "Cilium agent ${ds_ready:-0}/${ds_want} ready"
    else
        ok "Cilium agent ${ds_ready}/${ds_want} ready"
    fi

    kc "$ctx" get pods -A -o json >"$dir/pods.json" 2>/dev/null
    kc "$ctx" get events -A -o json >"$dir/events.json" 2>/dev/null
    kc "$ctx" get nodes -o json >"$dir/nodes.json" 2>/dev/null
    kc "$ctx" get pods -A -o wide >"$dir/pods.txt" 2>&1
    kc "$ctx" get events -A --sort-by=.lastTimestamp >"$dir/events.txt" 2>&1
    kc "$ctx" get svc -A >"$dir/services.txt" 2>&1
    kc "$ctx" top pods -A >"$dir/top-pods.txt" 2>&1
    helm --kubeconfig "$KCFG" --kube-context "$ctx" list -A -a >"$dir/helm-releases.txt" 2>&1
    docker exec "${name}-control-plane" df -h /var >"$dir/node-disk.txt" 2>&1
    docker exec "${name}-control-plane" crictl images >"$dir/node-images.txt" 2>&1

    # Node disk: kubelet evicts pods / refuses pulls above ~85%.
    local use
    use="$(awk 'NR==2 {gsub("%","",$5); print $5}' "$dir/node-disk.txt" 2>/dev/null)"
    if [ -n "$use" ] && [ "$use" -ge 85 ] 2>/dev/null; then
        finding ERROR DISK "$ctx" node "Docker VM disk ${use}% full (docker system prune / raise Docker Desktop disk)"
    fi

    # Failed / stuck helm releases (liquibase and friends are installed by helm).
    local rel
    while read -r rel; do
        [ -n "$rel" ] && finding ERROR HELM "$ctx" "$rel" "helm release not deployed"
    done < <(helm --kubeconfig "$KCFG" --kube-context "$ctx" list -A -a -o json 2>/dev/null \
        | python3 -c 'import json,sys
for r in json.load(sys.stdin) or []:
    if r.get("status") != "deployed": print("%s/%s (%s)" % (r["namespace"], r["name"], r.get("status")))' 2>/dev/null)

    # Pod / event / node analysis.
    local sev cat obj msg n=0
    while IFS='|' read -r sev cat obj msg; do
        [ -n "$sev" ] || continue
        finding "$sev" "$cat" "$ctx" "$obj" "$msg"
        n=$((n + 1))
        # Capture describe + logs for every broken pod while the evidence exists.
        case "$cat" in
            IMAGE_PULL|CRASH|OOM|CONFIG|UNSCHEDULABLE|VOLUME|NOT_READY|STUCK|JOB_FAILED|IMAGE_SLOW)
                local ns="${obj%%/*}" pod="${obj#*/}" f
                f="$dir/pod-${ns}-${pod}"
                [ -f "$f.describe.txt" ] || {
                    kc "$ctx" describe pod -n "$ns" "$pod" >"$f.describe.txt" 2>&1
                    kc "$ctx" logs -n "$ns" "$pod" --all-containers --tail=200 >"$f.log" 2>&1
                    kc "$ctx" logs -n "$ns" "$pod" --all-containers --previous --tail=200 >"$f.previous.log" 2>/dev/null || rm -f "$f.previous.log"
                }
                ;;
        esac
    done < <(python3 "$ANALYZER" "$name" "$dir/pods.json" "$dir/events.json" "$dir/nodes.json")

    local total notready
    total="$(grep -c . "$dir/pods.txt" 2>/dev/null)"; total=$((total > 0 ? total - 1 : 0))
    notready="$(awk 'NR>1 && $4 != "Completed" {split($3,a,"/"); if (a[1] != a[2]) n++} END {print n+0}' "$dir/pods.txt" 2>/dev/null)"
    printf '  %sinfo%s  %s pods, %s not fully ready\n' "$C_DIM" "$C_0" "$total" "$notready"
}

# ── 4. ClusterMesh + Argo CD (hub) ───────────────────────────────────────────
check_hub() {
    section "Hub: ClusterMesh + Argo CD"
    local dir="$OUT/clusters/hub"
    mkdir -p "$dir"

    if command -v cilium >/dev/null 2>&1; then
        if cilium clustermesh status --kubeconfig "$KCFG" --context kind-hub >"$dir/clustermesh-status.txt" 2>&1 \
            && ! grep -q "❌" "$dir/clustermesh-status.txt"; then
            ok "ClusterMesh: all remote clusters connected"
        else
            finding ERROR MESH kind-hub clustermesh "not all clusters connected (see clusters/hub/clustermesh-status.txt)"
        fi
    fi

    if ! kc kind-hub get applications.argoproj.io -A -o json >"$dir/argocd-apps.json" 2>/dev/null; then
        finding WARN ARGOCD kind-hub applications "could not list Argo CD applications"
        return
    fi
    kc kind-hub get applications.argoproj.io -A >"$dir/argocd-apps.txt" 2>&1
    local line count=0
    while IFS='|' read -r sev name msg; do
        [ -n "$sev" ] || continue
        finding "$sev" ARGOCD kind-hub "$name" "$msg"
        count=$((count + 1))
    done < <(python3 - "$dir/argocd-apps.json" <<'PY'
import json, sys
for a in json.load(open(sys.argv[1])).get("items", []):
    st = a.get("status", {})
    sync = st.get("sync", {}).get("status", "?")
    health = st.get("health", {}).get("status", "?")
    if sync == "Synced" and health == "Healthy":
        continue
    op = st.get("operationState", {}) or {}
    conds = "; ".join(c.get("message", "")[:160] for c in st.get("conditions", []) or [])
    detail = conds or (op.get("message", "") or "")[:200]
    # Degraded / Missing / sync errors are failures; Progressing / OutOfSync are in-flight.
    sev = "ERROR" if health in ("Degraded", "Missing") or op.get("phase") in ("Error", "Failed") else "WARN"
    print("%s|%s|sync=%s health=%s %s" % (sev, a["metadata"]["name"], sync, health,
                                           " ".join(detail.split())))
PY
)
    [ "$count" = 0 ] && ok "all Argo CD applications Synced + Healthy"
}

# ── 5. summary ───────────────────────────────────────────────────────────────
summarize() {
    section "Summary"
    local errors warns
    errors="$(grep -c '^ERROR|' "$FINDINGS")"
    warns="$(grep -c '^WARN|' "$FINDINGS")"
    printf '  %s errors, %s warnings   (bundle: %s)\n' "$errors" "$warns" "$OUT"

    # Tally by category, most frequent first.
    if [ "$((errors + warns))" -gt 0 ]; then
        printf '\n  by category:\n'
        grep -E '^(ERROR|WARN)\|' "$FINDINGS" | cut -d'|' -f2 | sort | uniq -c | sort -rn \
            | while read -r n cat; do printf '    %4s  %s\n' "$n" "$cat"; done
    fi

    has() { grep -qE "^(ERROR|WARN)\|$1\|" "$FINDINGS"; }
    printf '\n  %slikely cause%s\n' "$C_B" "$C_0"
    local said=0
    if has "CNI"; then
        echo "  - Cilium (the CNI) is missing or unhealthy. Pods cannot get networking, so Argo CD, ingress"
        echo "    and ClusterMesh failures on that cluster are downstream symptoms. Rebuild is the safe recovery."; said=1
    fi
    if has "HOST|CLUSTER|KUBECONFIG"; then
        echo "  - Infrastructure is down (Docker / kind / kubeconfig). Fix that first; everything else is downstream."; said=1
    fi
    if has "LB|NETWORK"; then
        echo "  - LoadBalancer layer: cloud-provider-kind or the kubara-mesh network. No LB IP -> no ingress -> no DNS target."; said=1
    fi
    if has "IMAGE_SLOW|IMAGE_PULL"; then
        echo "  - Image pulls are slow or failing. Fixed timeouts (helm --wait, rollout status) race the pulls."
        echo "    Slowest pulls: grep IMAGE_SLOW $FINDINGS | sort -t'|' -k5 | head"
        echo "    Check the pull-through caches: just registry-cache status (nodes built before the"
        echo "    containerd config patch bypass them; rebuild to use the cache)."; said=1
    fi
    if has "OOM|UNSCHEDULABLE|DISK|NODE"; then
        echo "  - Resource pressure (OOM / unschedulable / disk). Override limits in values-custom.yaml, not kubectl patch."; said=1
    fi
    if has "CRASH|CONFIG|JOB_FAILED|HELM"; then
        echo "  - Workload errors (crash / missing secret / failed job / failed helm). See pod-*.log and *.describe.txt in the bundle."; said=1
    fi
    if has "DNS"; then
        echo "  - DNS map is stale or dnsmasq is down: apps may be fine but unreachable by name (just refresh-dns-lb-hosts)."; said=1
    fi
    if has "MESH"; then
        echo "  - ClusterMesh not fully connected; cross-cluster services will fail."; said=1
    fi
    if has "ARGOCD" && [ "$said" = 0 ]; then
        echo "  - Only Argo CD apps are unsettled; if nothing else is wrong they may still be syncing. Re-run in a few minutes."; said=1
    fi
    [ "$said" = 0 ] && echo "  - Nothing wrong detected."

    [ "$errors" -eq 0 ]
}

# ── main ─────────────────────────────────────────────────────────────────────
main() {
    printf '%sdiagnose%s  %s  -> %s\n' "$C_B" "$C_0" "$(date '+%Y-%m-%d %H:%M:%S')" "$OUT"
    check_host
    check_dns
    local cluster_name
    while IFS='|' read -r cluster_name _rest; do
        [ -n "$cluster_name" ] && check_cluster "$cluster_name"
    done < <(demo_parse_clusters)
    demo_cluster_exists "$DEMO_HUB_CLUSTER_NAME" && check_hub
    summarize
}

# Keep a plain-text copy of the console report in the bundle.
main 2>&1 | tee >(sed $'s/\033\\[[0-9;]*m//g' >"$OUT/report.txt")
rc="${PIPESTATUS[0]}"
exit "$rc"
