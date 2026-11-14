#!/usr/bin/env bash
# test-teardown.sh - verify the host is back to its expected pre-bring-up
# state after `delete-kind-demo.sh`. Read-only; never deletes anything.
#
# Expected state (what delete-kind-demo.sh promises):
#   - no demo kind clusters, node containers or kubectl contexts
#   - no cloud-provider-kind LB containers, process or PID file
#   - docker networks kubara-mesh and kind removed
#   - .local kubeconfigs removed
#   - dnsmasq stopped, *.kubara.test no longer resolving
#   - registry caches KEPT (running or purged) but detached from every
#     demo network, so the next bring-up starts warm
#
# Usage: test-teardown.sh [-c|--config <file>]
# Exit: 0 all PASS (WARNs allowed), 1 any FAIL, 2 usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/kind-demo-common.sh"

CONFIG_FILE="$DEMO_DEFAULT_CONFIG"
while [ "$#" -gt 0 ]; do
    case "$1" in
        -c|--config) CONFIG_FILE="${2:?missing value for $1}"; shift 2 ;;
        --config=*) CONFIG_FILE="${1#*=}"; shift ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
demo_load_config "$CONFIG_FILE"

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; N=$'\033[0m'; else G=; R=; Y=; N=; fi
pass=0; fail=0; warns=0; failed_names=""
ok()   { pass=$((pass + 1));   printf '  %sPASS%s  %s\n' "$G" "$N" "$1"; }
bad()  { fail=$((fail + 1));   failed_names="${failed_names}\n  - $1"
         printf '  %sFAIL%s  %s\n' "$R" "$N" "$1"; [ -z "${2:-}" ] || printf '        %s\n' "$2"; }
warn() { warns=$((warns + 1)); printf '  %sWARN%s  %s\n' "$Y" "$N" "$1"; [ -z "${2:-}" ] || printf '        %s\n' "$2"; }
section() { printf '\n%s\n' "$1"; }
oneline() { tr '\n' ' ' | sed 's/ *$//'; }

printf '==> Verifying teardown (config: %s)\n' "${DEMO_CONFIG_FILE#"${DEMO_REPO_ROOT}/"}"

if ! docker info >/dev/null 2>&1; then
    bad "docker daemon reachable" "cannot inspect containers/networks; start Docker and re-run"
    printf '\n==> Summary: %d passed, %d failed\n' "$pass" "$fail"; exit 1
fi

# ── Clusters ─────────────────────────────────────────────────────────────────
section "kind clusters"
existing="$(kind get clusters 2>/dev/null || true)"
contexts="$(kubectl config get-contexts -o name 2>/dev/null || true)"
while IFS='|' read -r name _cfg; do
    [ -n "$name" ] || continue
    if printf '%s\n' "$existing" | grep -qx "$name"; then
        bad "cluster ${name} deleted" "still listed by 'kind get clusters'"
    else
        ok "cluster ${name} deleted"
    fi
    if printf '%s\n' "$contexts" | grep -qx "kind-${name}"; then
        warn "context kind-${name} still in your default kubeconfig" \
             "kubectl config delete-context kind-${name}"
    fi
done < <(demo_parse_clusters)

nodes="$(docker ps -a --filter label=io.x-k8s.kind.cluster --format '{{.Names}}' | oneline)"
[ -z "$nodes" ] && ok "no kind node containers" \
    || bad "no kind node containers" "left over: ${nodes}"

# ── cloud-provider-kind ──────────────────────────────────────────────────────
section "cloud-provider-kind"
lbs="$(docker ps -a --filter label=io.x-k8s.cloud-provider-kind.cluster --format '{{.Names}}' | oneline)"
[ -z "$lbs" ] && ok "no LoadBalancer containers" \
    || bad "no LoadBalancer containers" "left over: ${lbs}"
cpk="$(pgrep -f cloud-provider-kind 2>/dev/null | oneline || true)"
[ -z "$cpk" ] && ok "cloud-provider-kind not running" \
    || bad "cloud-provider-kind not running" "pids ${cpk} (stop: sudo kill ${cpk})"
pidfiles=""
for f in "${DEMO_REPO_ROOT}/.cloud-provider-kind" "${SCRIPT_DIR}/.cloud-provider-kind"; do
    [ -e "$f" ] && pidfiles="${pidfiles} ${f#"${DEMO_REPO_ROOT}/"}"
done
[ -z "$pidfiles" ] && ok "no cloud-provider-kind PID file" \
    || warn "stale cloud-provider-kind PID file:${pidfiles}"

# ── Docker networks ──────────────────────────────────────────────────────────
section "docker networks"
for net in "$DEMO_MESH_DOCKER_NETWORK" "$DEMO_KIND_NETWORK"; do
    if demo_docker_network_exists "$net"; then
        attached="$(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$net" 2>/dev/null | sed 's/ *$//')"
        bad "network ${net} removed" "still exists; attached: ${attached:-none}"
    else
        ok "network ${net} removed"
    fi
done

# ── Registry caches (must be kept, but detached) ─────────────────────────────
section "registry caches (kept on purpose)"
caches="$(docker ps -a --filter label=io.kubara.demo.registry-cache=true --format '{{.Names}}' | sort)"
if [ -z "$caches" ]; then
    warn "no registry caches present" \
         "fine after 'just registry-cache purge'; next bring-up recreates them and pulls cold"
else
    while read -r c; do
        [ -n "$c" ] || continue
        state="$(docker inspect -f '{{.State.Status}}' "$c")"
        nets="$(docker inspect -f '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}} {{end}}' "$c" | sed 's/ *$//')"
        case " $nets " in
            *" ${DEMO_MESH_DOCKER_NETWORK} "*|*" ${DEMO_KIND_NETWORK} "*)
                bad "${c} detached from demo networks" "still on: ${nets}" ;;
            *)
                if [ "$state" = running ]; then ok "${c} kept, detached"
                else warn "${c} kept, detached, but ${state}" "bring-up restarts it"; fi ;;
        esac
    done <<<"$caches"
fi

# ── Local artifacts ──────────────────────────────────────────────────────────
section "local artifacts"
for p in .local/kind-demo .local/kind.kubeconfig .local/kind.kubeconfig.bak; do
    [ -e "${DEMO_REPO_ROOT}/${p}" ] && bad "${p} removed" "still present" || ok "${p} removed"
done

# ── DNS ──────────────────────────────────────────────────────────────────────
section "dnsmasq / DNS"
dpid="$(pgrep -x dnsmasq 2>/dev/null | oneline || true)"
[ -z "$dpid" ] && ok "dnsmasq not running" \
    || bad "dnsmasq not running" "pids ${dpid} (stop: just -f dnsmasq/Justfile stop-dnsmasq)"
[ -e "${DEMO_REPO_ROOT}/dnsmasq/.dnsmasq.pid" ] \
    && warn "stale dnsmasq/.dnsmasq.pid" || ok "no dnsmasq PID file"
if command -v dig >/dev/null 2>&1; then
    ans="$(dig +short +time=1 +tries=1 @127.0.0.1 argocd.hub.kubara.test 2>/dev/null | grep -E '^[0-9.]+$' | oneline || true)"
    [ -z "$ans" ] && ok "*.kubara.test no longer answered on 127.0.0.1" \
        || bad "*.kubara.test no longer answered on 127.0.0.1" "argocd.hub.kubara.test -> ${ans}"
fi
# /etc/resolver/kubara.test is installed once (sudo) and intentionally kept.
[ -f /etc/resolver/kubara.test ] && ok "/etc/resolver/kubara.test kept for next bring-up" \
    || warn "/etc/resolver/kubara.test missing" "bring-up's DNS step will need sudo to reinstall it"

# ── Summary ──────────────────────────────────────────────────────────────────
printf '\n==> Summary: %d passed, %d failed, %d warnings\n' "$pass" "$fail" "$warns"
if [ "$fail" -gt 0 ]; then
    printf 'Failed:%b\n' "$failed_names"
    exit 1
fi
echo "Host is clean; ready for: just bring-up"
