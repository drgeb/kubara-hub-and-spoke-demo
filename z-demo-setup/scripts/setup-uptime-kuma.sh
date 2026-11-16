#!/usr/bin/env bash
# Create the Uptime Kuma admin account from .env (UPTIME_KUMA_ADMIN_USER /
# UPTIME_KUMA_PASSWORD). Uptime Kuma has no env-based first-run setup, so seed
# its SQLite `user` table with a bcrypt hash. Idempotent: no-op if a user
# already exists. Safe to re-run after a demo rebuild (empty PVC).
# Pass --reset to remove any existing user and reseed from .env.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KC="${ROOT_DIR}/.local/kind.kubeconfig"
CONTEXT="kind-kubara-poc"
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

kx() { kubectl --kubeconfig "$KC" --context "$CONTEXT" -n "$NS" exec "$POD" -- "$@"; }

# Ready != migrated: the pod listens before kuma.db exists and its schema
# (the `user` table) is created. Uptime Kuma 2.x also never creates kuma.db
# while it sits in its "Setup Database" wizard (no data/db-config.json).
echo ">> Waiting for the Uptime Kuma database to be initialised..."
i=0
until kx sqlite3 -readonly /app/data/kuma.db "SELECT 1 FROM user LIMIT 1;" >/dev/null 2>&1; do
    if [ "$i" -ge 60 ]; then
        if ! kx test -f /app/data/db-config.json; then
            echo "Uptime Kuma is waiting in its 'Setup Database' wizard (no /app/data/db-config.json)." >&2
            echo "Its chart must set env UPTIME_KUMA_DB_TYPE=sqlite (platform-components/helm/uptime-kuma/values.yaml);" >&2
            echo "push that to main and let Argo CD roll the pod, then re-run this script." >&2
        else
            echo "kuma.db still has no 'user' table after 120s; check: kubectl logs -n ${NS} ${POD}" >&2
        fi
        exit 1
    fi
    i=$((i + 1)); sleep 2
done

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

# Uptime Kuma decides "needs setup" once at startup (empty user table) and
# caches it, so every request keeps redirecting to /setup until it restarts.
echo ">> Restarting Uptime Kuma so it picks up the new admin..."
kubectl --kubeconfig "$KC" --context "$CONTEXT" -n "$NS" rollout restart deploy/uptime-kuma >/dev/null
kubectl --kubeconfig "$KC" --context "$CONTEXT" -n "$NS" rollout status deploy/uptime-kuma --timeout=180s >/dev/null
echo "Refresh https://uptime-kuma.poc.kubara.test/ — log in with UPTIME_KUMA_ADMIN_USER / UPTIME_KUMA_PASSWORD."