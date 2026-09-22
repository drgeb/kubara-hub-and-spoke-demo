#!/usr/bin/env bash
# Create the Uptime Kuma admin account from .env (UPTIME_KUMA_ADMIN_USER /
# UPTIME_KUMA_PASSWORD). Uptime Kuma has no env-based first-run setup, so seed
# its SQLite `user` table with a bcrypt hash. Idempotent: no-op if a user
# already exists. Safe to re-run after a demo rebuild (empty PVC).
# Pass --reset to remove any existing user and reseed from .env.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KC="${ROOT_DIR}/.local/kind.kubeconfig"
CONTEXT="kind-kubara-spoke-2"
NS="uptime-kuma"

RESET=false
[ "${1:-}" = "--reset" ] && RESET=true

: "${UPTIME_KUMA_ADMIN_USER:?set in .env - run 'direnv allow'}"
: "${UPTIME_KUMA_PASSWORD:?set in .env - run 'direnv allow'}"

command -v htpasswd >/dev/null 2>&1 || { echo "htpasswd is required (macOS: /usr/sbin/htpasswd)" >&2; exit 1; }

echo ">> Waiting for uptime-kuma pod on ${CONTEXT} to be Ready..."
kubectl --kubeconfig "$KC" --context "$CONTEXT" rollout status deploy/uptime-kuma -n "$NS" --timeout=180s >/dev/null 2>&1 || {
    echo "deploy/uptime-kuma not ready on ${CONTEXT}" >&2
    exit 1
}

POD="$(kubectl --kubeconfig "$KC" --context "$CONTEXT" -n "$NS" get pod -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' | awk '{print $1}')"
[ -n "$POD" ] || { echo "no running uptime-kuma pod found" >&2; exit 1; }

EXISTING="$(kubectl --kubeconfig "$KC" --context "$CONTEXT" -n "$NS" exec "$POD" -- sqlite3 -readonly /app/data/kuma.db "SELECT username FROM user;")"
if [ -n "$EXISTING" ]; then
    if [ "$RESET" = true ]; then
        echo ">> Removing existing Uptime Kuma user(s) (${EXISTING}) and reseeding from .env..."
        kubectl --kubeconfig "$KC" --context "$CONTEXT" -n "$NS" exec "$POD" -- \
            sqlite3 /app/data/kuma.db "DELETE FROM user;"
    else
        echo "Uptime Kuma admin already exists (username: ${EXISTING}); skipping. Use --reset to overwrite from .env."
        exit 0
    fi
fi

HASH="$(htpasswd -bnBC 10 "" "${UPTIME_KUMA_PASSWORD}" | tr -d ':\n')"
kubectl --kubeconfig "$KC" --context "$CONTEXT" -n "$NS" exec "$POD" -- \
    sqlite3 /app/data/kuma.db "INSERT INTO user (username, password, active, timezone) VALUES ('${UPTIME_KUMA_ADMIN_USER}', '${HASH}', 1, 'UTC');"

COUNT="$(kubectl --kubeconfig "$KC" --context "$CONTEXT" -n "$NS" exec "$POD" -- sqlite3 -readonly /app/data/kuma.db "SELECT COUNT(*) FROM user;")"
echo "Created Uptime Kuma admin '${UPTIME_KUMA_ADMIN_USER}' (users in db: ${COUNT})."
echo "Refresh https://uptime-kuma.spoke-2.kubara.test/ — log in with UPTIME_KUMA_ADMIN_USER / UPTIME_KUMA_PASSWORD."