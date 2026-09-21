#!/usr/bin/env bash
# Test every app entry point that the Justfile's `open-*` recipes open.
# For each entry: HTTP GET (follow redirects), PASS on 2xx/3xx.
# Port-forward based entries (open-portal) are tested via a short-lived
# kubectl port-forward.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KC="${ROOT_DIR}/.local/kind.kubeconfig"
KC_ARG=""
if [[ -f "$KC" ]] && kubectl --kubeconfig "$KC" config get-contexts -o name 2>/dev/null | grep -Fxq "kind-hub"; then
    KC_ARG="--kubeconfig $KC --context kind-hub"
else
    KC_ARG=""
fi

PASS=0
FAIL=0
FAILED=()
PORTAL_PID=""

cleanup() {
    if [[ -n "$PORTAL_PID" ]] && kill -0 "$PORTAL_PID" 2>/dev/null; then
        kill "$PORTAL_PID" 2>/dev/null || true
        wait "$PORTAL_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

test_url() {
    local name="$1"
    local url="$2"
    local code
    code="$(curl -skL -o /dev/null -w '%{http_code}' \
        --connect-timeout 8 --max-time 25 "$url" 2>/dev/null || echo 000)"
    local ok=0
    [[ "$code" =~ ^[23][0-9][0-9]$ ]] && ok=1
    if (( ok )); then
        PASS=$((PASS + 1))
        printf '  PASS  %-18s %-4s %s\n' "$name" "$code" "$url"
    else
        FAIL=$((FAIL + 1))
        FAILED+=("$name ($code)")
        printf '  FAIL  %-18s %-4s %s\n' "$name" "$code" "$url"
    fi
}

test_portal() {
    local name="$1"
    printf '  ...  %-18s port-forward argocd-server 8080:443\n' "$name"

    PORTAL_PID=""
    # shellcheck disable=SC2086
    kubectl $KC_ARG port-forward svc/argocd-server -n argocd 8080:443 >/dev/null 2>&1 &
    PORTAL_PID=$!

    sleep 4

    local code
    code="$(curl -skL -o /dev/null -w '%{http_code}' \
        --connect-timeout 5 --max-time 15 https://localhost:8080 2>/dev/null || echo 000)"

    if [[ -n "$PORTAL_PID" ]] && kill -0 "$PORTAL_PID" 2>/dev/null; then
        kill "$PORTAL_PID" 2>/dev/null || true
        wait "$PORTAL_PID" 2>/dev/null || true
        PORTAL_PID=""
    fi

    local ok=0
    [[ "$code" =~ ^[23][0-9][0-9]$ ]] && ok=1
    if (( ok )); then
        PASS=$((PASS + 1))
        printf '  PASS  %-18s %-4s %s\n' "$name" "$code" "https://localhost:8080"
    else
        FAIL=$((FAIL + 1))
        FAILED+=("$name ($code)")
        printf '  FAIL  %-18s %-4s %s\n' "$name" "$code" "https://localhost:8080"
    fi
}

command -v curl >/dev/null 2>&1 || { echo "curl is not installed" >&2; exit 1; }

echo "==> Testing app entry points (following redirects, TLS verification off)"

echo
echo "hub"
test_url argocd        https://argocd.hub.kubara.test/
test_url homer         https://homer.hub.kubara.test/
test_url grafana       https://grafana.hub.kubara.test/
test_url prometheus    https://prometheus.hub.kubara.test/
test_url alertmanager  https://alertmanager.hub.kubara.test/
test_url openbao       https://openbao.hub.kubara.test/

echo
echo "platform-engineering (kubara-spoke-1)"
test_url forgejo       https://forgejo.spoke-1.kubara.test/
test_url harbor        https://harbor.spoke-1.kubara.test/
test_url kargo         https://kargo.spoke-1.kubara.test/
test_url nexus         https://nexus.spoke-1.kubara.test/
test_url keycloak      https://keycloak.spoke-1.kubara.test/

echo
echo "dev"
test_url uptime-kuma   https://uptime-kuma.spoke-2.kubara.test/
# test_url go-hello      http://go-hello.dev.kubara.test/

# for env in dev staging prod; do
    # test_url "ebank-$env"        "http://ebank-simple-${env}.dev.kubara.test/"
    # test_url "kargo-simple-$env" "http://guestbook-simple-${env}.dev.kubara.test/"
# done

echo
echo "port-forward based"
test_portal portal-argocd

echo
echo "==> Summary: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then
    printf 'Failed: %s\n' "${FAILED[*]}" >&2
    exit 1
fi
echo "ALL app entry points reachable"