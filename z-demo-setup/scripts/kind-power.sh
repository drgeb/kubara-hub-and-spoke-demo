#!/usr/bin/env bash
# kind-power.sh - stop/start/inspect every demo kind cluster without deleting it.
#
# Usage: kind-power.sh stop|start|status [-c|--config <file>]
#
#   status one line per cluster: node containers running, node Ready,
#          cilium-ingress LoadBalancer IP (read-only)
#   stop   docker-stop each cluster's node containers and its
#          cloud-provider-kind LoadBalancer containers
#   start  start them again (hub first), wait for every cilium-ingress
#          LoadBalancer IP and for ClusterMesh to reconnect
#
# Clusters come from the demo config (kind-demo.yaml) - the same list
# build-mesh.sh, delete-kind-demo.sh and test-teardown.sh use - so all six
# clusters are covered. Clusters with no containers are skipped, not fatal.
# The dnsmasq refresh after a start is left to the caller (`just
# kind-restart`), because it needs sudo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/kind-demo-common.sh"

ACTION="${1:-}"
[ "$#" -gt 0 ] && shift
CONFIG_FILE="$DEMO_DEFAULT_CONFIG"
while [ "$#" -gt 0 ]; do
    case "$1" in
        -c|--config) CONFIG_FILE="${2:?missing value for $1}"; shift 2 ;;
        --config=*) CONFIG_FILE="${1#*=}"; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$ACTION" in
    stop|start|status) ;;
    *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

demo_load_config "$CONFIG_FILE"
demo_require_cmd docker

KCFG="${DEMO_REPO_ROOT}/.local/kind.kubeconfig"
LB_WAIT_SECONDS="${KIND_POWER_LB_WAIT_SECONDS:-300}"
MESH_WAIT="${KIND_POWER_MESH_WAIT:-5m}"

# Cluster names in config order, hub first (spokes' ClusterMesh agents and
# Argo CD both depend on the hub). bash 3.2: plain indexed array.
CLUSTERS=("$DEMO_HUB_CLUSTER_NAME")
while IFS='|' read -r name _cfg; do
    [ -n "$name" ] || continue
    [ "$name" = "$DEMO_HUB_CLUSTER_NAME" ] && continue
    CLUSTERS+=("$name")
done < <(demo_parse_clusters)

# Container IDs for one cluster: kind nodes + cpk LB containers. Prints
# nothing (not an error) when the cluster has none.
cluster_containers() {
    docker ps -aq --filter "label=io.x-k8s.kind.cluster=$1"
    docker ps -aq --filter "label=io.x-k8s.cloud-provider-kind.cluster=$1"
}

power() {
    local verb="$1" name ids
    for name in "${CLUSTERS[@]}"; do
        ids="$(cluster_containers "$name" | tr '\n' ' ')"
        if [ -z "${ids// /}" ]; then
            printf '    %-16s no containers, skipped\n' "$name"
            continue
        fi
        PRESENT+=("$name")
        # shellcheck disable=SC2086
        if docker "$verb" $ids >/dev/null; then
            printf '    %-16s %s (%d containers)\n' "$name" "$([ "$verb" = stop ] && echo stopped || echo started)" "$(echo $ids | wc -w)"
        else
            printf '    %-16s FAILED to %s\n' "$name" "$verb" >&2
            failures=$((failures + 1))
        fi
    done
}

wait_for_lb_ips() {
    [ "${#PRESENT[@]}" -gt 0 ] || return 0
    local deadline=$((SECONDS + LB_WAIT_SECONDS)) missing name ip
    printf '==> Waiting up to %ss for cilium-ingress LoadBalancer IPs\n' "$LB_WAIT_SECONDS"
    while :; do
        missing=""
        for name in "${PRESENT[@]}"; do
            ip="$(kubectl --kubeconfig "$KCFG" --context "kind-${name}" -n kube-system \
                get svc cilium-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
            [ -n "$ip" ] || missing="${missing} ${name}"
        done
        if [ -z "$missing" ]; then
            echo "    all ${#PRESENT[@]} LoadBalancer IPs assigned"
            return 0
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "WARN: no LoadBalancer IP yet for:${missing} (is cloud-provider-kind running? just start-cloud-provider-kind)" >&2
            return 1
        fi
        sleep 5
    done
}

wait_for_mesh() {
    if ! command -v cilium >/dev/null 2>&1; then
        echo "WARN: cilium CLI not found; skipping ClusterMesh check" >&2
        return 0
    fi
    printf '==> Waiting up to %s for ClusterMesh to reconnect (from %s)\n' "$MESH_WAIT" "kind-${DEMO_HUB_CLUSTER_NAME}"
    # Node IPs on kubara-mesh can change across a docker stop/start; this
    # shows whether the remote clusters found each other again.
    if cilium clustermesh status --kubeconfig "$KCFG" --context "kind-${DEMO_HUB_CLUSTER_NAME}" \
            --wait --wait-duration "$MESH_WAIT" >/dev/null 2>&1; then
        echo "    ClusterMesh connected"
    else
        echo "WARN: ClusterMesh not fully connected; run: cilium clustermesh status --kubeconfig ${KCFG#"${DEMO_REPO_ROOT}/"} --context kind-${DEMO_HUB_CLUSTER_NAME}" >&2
        return 1
    fi
}

status() {
    local name nodes running ready ip total=0 up=0
    printf '%-16s %-10s %-10s %-9s %s\n' CLUSTER NODES RUNNING READY LB-IP
    for name in "${CLUSTERS[@]}"; do
        total=$((total + 1))
        nodes="$(docker ps -aq --filter "label=io.x-k8s.kind.cluster=$name" | wc -l | tr -d ' ')"
        running="$(docker ps -q --filter "label=io.x-k8s.kind.cluster=$name" | wc -l | tr -d ' ')"
        if [ "$nodes" -eq 0 ]; then
            printf '%-16s %-10s %-10s %-9s %s\n' "$name" "-" "-" "-" "not created"
            continue
        fi
        ready="-"; ip="-"
        if [ "$running" -gt 0 ]; then
            ready="$(kubectl --kubeconfig "$KCFG" --context "kind-${name}" get nodes --request-timeout=5s \
                -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
                | awk '$1=="True"{r++} END{printf "%d/%d", r, NR}' || true)"
            ip="$(kubectl --kubeconfig "$KCFG" --context "kind-${name}" -n kube-system get svc cilium-ingress \
                --request-timeout=5s -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
            [ -n "$ready" ] || ready="?"
            [ -n "$ip" ] || ip="none"
        fi
        [ "$running" -eq "$nodes" ] && [ "${ready%%/*}" = "${ready#*/}" ] && [ "$ip" != none ] && up=$((up + 1))
        printf '%-16s %-10s %-10s %-9s %s\n' "$name" "$nodes" "$running" "$ready" "$ip"
    done
    printf '==> %d/%d clusters fully up (nodes running + Ready, LB IP assigned)\n' "$up" "$total"
}

failures=0
PRESENT=()   # clusters that actually had containers (skipped ones excluded)
if [ "$ACTION" = status ]; then
    status
    exit 0
elif [ "$ACTION" = stop ]; then
    echo "==> Stopping ${#CLUSTERS[@]} kind clusters (nodes + LoadBalancers)"
    power stop
else
    echo "==> Starting ${#CLUSTERS[@]} kind clusters (hub first)"
    power start
    if [ "$failures" -eq 0 ]; then
        wait_for_lb_ips || failures=$((failures + 1))
        wait_for_mesh || failures=$((failures + 1))
    fi
fi

if [ "$failures" -gt 0 ]; then
    echo "==> ${ACTION}: ${failures} problem(s); see messages above" >&2
    exit 1
fi
echo "==> ${ACTION}: done"
