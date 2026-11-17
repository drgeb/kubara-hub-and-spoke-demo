#!/usr/bin/env bash
set -Eeuo pipefail

# Bring the local DNS + cloud-provider-kind layer up to match the current mesh.
# Idempotent: re-runnable; every step is a no-op when already in the desired state.
#
# Order matters after a Docker restart: cloud-provider-kind recreates every
# LoadBalancer container (new IPs on kubara-mesh) and only then rewrites each
# Service's .status.loadBalancer. Refreshing DNS before that copies stale IPs
# (seen: two clusters reporting the same IP, ingresses not answering). So:
#   1. start cloud-provider-kind
#   2. WAIT until every required LB's status IP is a live, matching container
#      (restart cloud-provider-kind once if it does not converge)
#   3. rewrite the dnsmasq map, 4. ensure dnsmasq serves it
#   5. VERIFY: each zone resolves to its live IP and its ingress answers
#
# No IPs are hard-coded here (AGENTS.md): everything is read live.
#
# Tunables (env): LB_WAIT_SECS (default 300), VERIFY_WAIT_SECS (default 180).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# sudo shim: notify (cmux/macOS) before the password prompt.
PATH="${ROOT}/z-demo-setup/bin:${PATH}"; export PATH

KCFG="${ROOT}/.local/kind.kubeconfig"
LB_WAIT_SECS="${LB_WAIT_SECS:-300}"
VERIFY_WAIT_SECS="${VERIFY_WAIT_SECS:-180}"

# Required LoadBalancers: "<dns zone> <kind cluster> <namespace>/<service>".
# The zone rows mirror dnsmasq/Justfile refresh-lb-hosts; forgejo-ssh has no
# HTTP ingress, so it is only checked for a live LB (zone "-").
REQUIRED=(
    "hub.kubara.test hub kube-system/cilium-ingress"
    "platform-engineering.kubara.test kubara-platform-engineering kube-system/cilium-ingress"
    "poc.kubara.test kubara-poc kube-system/cilium-ingress"
    "dev.kubara.test kubara-dev kube-system/cilium-ingress"
    "staging.kubara.test kubara-staging kube-system/cilium-ingress"
    "prod.kubara.test kubara-prod kube-system/cilium-ingress"
    "forgejo-ssh.me kubara-platform-engineering forgejo/forgejo-ssh"
)

log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$KCFG" ] || die "kubeconfig not found: ${KCFG} (build the mesh first)"

# IP recorded in the Service status (what refresh-lb-hosts will copy).
status_ip() {   # status_ip <cluster> <ns/svc>
    kubectl --kubeconfig "$KCFG" --context "kind-$1" -n "${2%%/*}" get svc "${2#*/}" \
        --request-timeout=10s -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
}

# IP of the running cloud-provider-kind container that serves that Service.
container_ip() {   # container_ip <cluster> <ns/svc>
    local id
    id="$(docker ps -q --filter "label=io.x-k8s.cloud-provider-kind.loadbalancer.name=$1/$2" 2>/dev/null | head -1)"
    [ -n "$id" ] || return 0
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$id" 2>/dev/null || true
}

# One pass over REQUIRED: prints problems, returns 0 only when every LB has a
# status IP equal to its live container IP and no two LBs share an IP.
check_lbs() {
    local row zone cluster svc sip cip seen="" bad=0
    for row in "${REQUIRED[@]}"; do
        read -r zone cluster svc <<<"$row"
        sip="$(status_ip "$cluster" "$svc")"
        cip="$(container_ip "$cluster" "$svc")"
        if [ -z "$sip" ]; then
            echo "${cluster} ${svc}: no LoadBalancer IP in status yet"; bad=1
        elif [ -z "$cip" ]; then
            echo "${cluster} ${svc}: status ${sip} but no running LB container"; bad=1
        elif [ "$sip" != "$cip" ]; then
            echo "${cluster} ${svc}: status ${sip} is stale (container is ${cip})"; bad=1
        else
            case " $seen " in
                *" $sip "*) echo "${cluster} ${svc}: ${sip} also claimed by another LB"; bad=1 ;;
            esac
            seen="${seen} ${sip}"
        fi
    done
    return "$bad"
}

# Poll check_lbs until it passes or <secs> elapse; prints the last problems.
wait_for_lbs() {   # wait_for_lbs <secs>
    local deadline=$(( $(date +%s) + $1 )) problems
    while :; do
        if problems="$(check_lbs)"; then return 0; fi
        [ "$(date +%s)" -lt "$deadline" ] || { printf '%s\n' "$problems" | sed 's/^/    /' >&2; return 1; }
        sleep 5
    done
}

# Resolve <host> through the macOS resolver (what browsers and curl use).
resolve() {
    dscacheutil -q host -a name "$1" 2>/dev/null | awk '/^ip_address:/{print $2; exit}'
}

sudo -v   # cache credentials for the sudo-gated steps below

# 1. Ensure cloud-provider-kind is running (no-op if already up). Starting it
#    prunes stale hub LB containers so LBs land on kubara-mesh.
log "cloud-provider-kind"
just start-cloud-provider-kind

# 2. Wait until every required LB is live and its status matches. A process
#    left over from before a Docker restart can sit on recreated containers
#    forever without fixing statuses; restart it once in that case.
log "Waiting for LoadBalancer IPs to match live containers (up to ${LB_WAIT_SECS}s)"
if ! wait_for_lbs "$LB_WAIT_SECS"; then
    warn "LoadBalancers did not converge; restarting cloud-provider-kind once"
    just stop-cloud-provider-kind
    just start-cloud-provider-kind
    wait_for_lbs "$LB_WAIT_SECS" \
        || die "LoadBalancers still inconsistent after a cloud-provider-kind restart (see .cloud-provider-kind.log)"
fi
info "all ${#REQUIRED[@]} LoadBalancers live with matching status"

# 3. Rewrite the dnsmasq map from the (now correct) LB IPs and restart dnsmasq.
#    Aborts (without touching the map) if any required LB IP is missing.
log "dnsmasq map"
just -f dnsmasq/Justfile refresh-lb-hosts

# 4. Ensure dnsmasq is serving the new map (no-op after step 3; covers cold starts).
just -f dnsmasq/Justfile start-dnsmasq

# 5. Verify end to end: each zone resolves to its live LB IP and the ingress
#    behind it answers HTTP (any status; 000 = no connection). Envoy in the LB
#    containers can take a little while to get its config, so retry.
log "Verifying DNS and ingress reachability (up to ${VERIFY_WAIT_SECS}s)"
deadline=$(( $(date +%s) + VERIFY_WAIT_SECS ))
while :; do
    failed=0; report=""
    for row in "${REQUIRED[@]}"; do
        read -r zone cluster svc <<<"$row"
        [ "$zone" != "-" ] || continue
        want="$(status_ip "$cluster" "$svc")"
        case "$zone" in
            *.kubara.test) host="probe.${zone}" ;;   # wildcard zone: any name works
            *)             host="$zone" ;;
        esac
        got="$(resolve "$host")"
        code="-"
        if [ "$svc" = kube-system/cilium-ingress ]; then
            code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${host}/" || true)"
            [ "$code" != 000 ] || failed=1
        fi
        [ "$got" = "$want" ] || failed=1
        report="${report}$(printf '    %-36s dns=%-15s lb=%-15s http=%s' "$host" "${got:-none}" "${want:-none}" "$code")"$'\n'
    done
    [ "$failed" = 1 ] || break
    if [ "$(date +%s)" -ge "$deadline" ]; then
        printf '%s' "$report"
        die "DNS/ingress verification failed (dns must equal lb; http 000 = ingress not answering)"
    fi
    sleep 5
done
printf '%s' "$report"

echo "DNS + LB layer is up to date"
