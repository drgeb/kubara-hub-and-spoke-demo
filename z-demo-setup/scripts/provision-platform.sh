#!/usr/bin/env bash
set -Eeuo pipefail

# Idempotent platform provisioning for the kubara hub-and-spoke mesh.
#
# Phases:
#   A. seed    — create platform secrets on every spoke cluster
#                (create-platform-secrets.sh; kubectl apply so re-runs no-op)
#   B. wait    — wait for each cluster's `postgresql` StatefulSet to be Ready
#   C. liquibase — provision per-cluster PostgreSQL roles/databases via helm
#                upgrade --install (guarded SQL + liquibase changelog so
#                re-runs converge without changing already-applied state)
#
# Everything is safe to re-run on already-provisioned clusters. Invoked by
# z-demo-setup/scripts/build-mesh.sh after the spoke kubeconfigs are
# published to OpenBao, and manually via `just provision-platform`.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="${ROOT_DIR}/z-demo-setup/scripts"
ENV_FILE="${ROOT_DIR}/.env"
LOCAL_KUBECONFIG="${ROOT_DIR}/.local/kind.kubeconfig"
LIQUIBASE_DIR="${ROOT_DIR}/z-demo-setup/liquibase"

# ── Cluster / context ────────────────────────────────────────────────────────
HUB_CONTEXT="kind-hub"
SPOKE1_CONTEXT="kind-kubara-spoke-1"
SPOKE2_CONTEXT="kind-kubara-spoke-2"
DEV_CONTEXT="kind-kubara-dev"
STAGING_CONTEXT="kind-kubara-staging"
PROD_CONTEXT="kind-kubara-prod"

KIND_NAMES=(hub kubara-spoke-1 kubara-spoke-2 kubara-dev kubara-staging kubara-prod)

# Every cluster that runs the bitnami `postgresql` chart in the postgresql
# namespace. Keep in sync with the Argo CD postgresql Applications.
POSTGRES_CONTEXTS=("$SPOKE1_CONTEXT" "$SPOKE2_CONTEXT" "$DEV_CONTEXT" "$STAGING_CONTEXT" "$PROD_CONTEXT")

# ── Options ──────────────────────────────────────────────────────────────────
KUBECONFIG="${KUBECONFIG:-${LOCAL_KUBECONFIG}}"
REFRESH_LOCAL=false
REFRESH_ONLY=false

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --kubeconfig <path>         kubeconfig holding the kind contexts
                              (default: \$KUBECONFIG or .local/kind.kubeconfig)
  --refresh-local-kubeconfig  re-merge all kind cluster kubeconfigs into
                              .local/kind.kubeconfig for local tooling before
                              provisioning
  --refresh-only              only refresh .local/kind.kubeconfig and exit
  -h, --help                  show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kubeconfig)
            KUBECONFIG="$2"
            shift 2
            ;;
        --refresh-local-kubeconfig)
            REFRESH_LOCAL=true
            shift
            ;;
        --refresh-only)
            REFRESH_LOCAL=true
            REFRESH_ONLY=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────
log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARN: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is required"
}

require_var() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        die "${name} is not set — run 'direnv allow' to load .env"
    fi
}

load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        set -a
        # shellcheck disable=SC1090
        . "$ENV_FILE"
        set +a
    fi
    for var in \
        POSTGRES_PASSWORD \
        APP_POSTGRES_PASSWORD \
        OPENPROJECT_DB_PASSWORD \
        KEYCLOAK_DB_PASSWORD \
        APICURIO_DB_PASSWORD; do
        require_var "$var"
    done
}

is_cluster_reachable() {
    local context="$1"
    kubectl --kubeconfig "$KUBECONFIG" --context "$context" get --raw='/readyz' >/dev/null 2>&1
}

# Deterministic mapping: which liquibase services (roles/databases) does a
# cluster need? kubara-spoke-1 hosts the DB-backed platform apps; every other
# spoke only runs a standalone postgres (role/db "app"). Extend the case
# statement if future clusters host DB-backed applications.
services_for_cluster() {
    local context="$1"
    case "$context" in
        "$SPOKE1_CONTEXT") echo "openproject keycloak apicurio" ;;
        *)                 echo "app" ;;
    esac
}

password_var_for() {
    case "$1" in
        openproject) echo "OPENPROJECT_DB_PASSWORD" ;;
        keycloak)    echo "KEYCLOAK_DB_PASSWORD" ;;
        apicurio)    echo "APICURIO_DB_PASSWORD" ;;
        app)         echo "APP_POSTGRES_PASSWORD" ;;
        *)           die "no password variable known for service '$1'" ;;
    esac
}

password_secret_for() {
    case "$1" in
        openproject) echo "openproject-postgresql password" ;;
        keycloak)    echo "keycloak-credentials db-password" ;;
        apicurio)    echo "apicurio-credentials password" ;;
        app)         echo "postgresql password" ;;
        *)           die "no secret mapping known for service '$1'" ;;
    esac
}

# ── Phase refresh ────────────────────────────────────────────────────────────
refresh_local_kubeconfig() {
    require_cmd kind
    mkdir -p "$(dirname "$LOCAL_KUBECONFIG")"
    local tmp
    tmp="$(mktemp -d)"
    local -a parts=()
    local part
    for name in "${KIND_NAMES[@]}"; do
        part="${tmp}/$(echo "${name}" | tr '-' '_').kubeconfig"
        if kind get kubeconfig --name "$name" >"$part" 2>/dev/null; then
            parts+=("$part")
        else
            warn "kind cluster '${name}' not found; excluding from merged kubeconfig"
        fi
    done
    if [[ ${#parts[@]} -eq 0 ]]; then
        die "no kind clusters found; cannot refresh ${LOCAL_KUBECONFIG}"
    fi
    KUBECONFIG="$(IFS=:; echo "${parts[*]}")" \
        kubectl config view --flatten >"${LOCAL_KUBECONFIG}.tmp"
    mv "${LOCAL_KUBECONFIG}.tmp" "$LOCAL_KUBECONFIG"
    rm -rf "$tmp"
    log "Refreshed ${LOCAL_KUBECONFIG} (${#parts[@]} clusters)"
}

# ── Phase A: seed secrets ────────────────────────────────────────────────────
seed_platform_secrets() {
    log "Seeding platform secrets on all spoke clusters"
    KUBECONFIG="$KUBECONFIG" bash "${SCRIPTS_DIR}/create-platform-secrets.sh"
}

# ── Phase B: wait for postgres ───────────────────────────────────────────────
wait_for_postgres() {
    local context="$1"
    if ! is_cluster_reachable "$context"; then
        warn "${context} not reachable; skipping postgres readiness wait"
        return 0
    fi
    log "Waiting for postgresql StatefulSet on ${context}"
    local i=0
    # Increased max retries to 300 (15 minutes total wait for creation)
    while ! kubectl --kubeconfig "$KUBECONFIG" --context "$context" \
        get statefulset postgresql -n postgresql >/dev/null 2>&1; do
        if (( ++i >= 300 )); then
            die "postgresql StatefulSet never appeared on ${context}"
        fi
        sleep 3
    done

    # Increased rollout status timeout from 300s to 900s (15 minutes)
    kubectl --kubeconfig "$KUBECONFIG" --context "$context" \
        rollout status statefulset/postgresql -n postgresql --timeout 900s
}

wait_for_postgres_all() {
    local context
    for context in "${POSTGRES_CONTEXTS[@]}"; do
        wait_for_postgres "$context"
    done
}

# ── Phase C: liquibase provisioning ──────────────────────────────────────────
provision_liquibase_bootstrap() {
    local context="$1"
    local services="$2"
    local tmp_values svc pass_var pass_secret secret_name secret_key value
    tmp_values="$(mktemp)"
    chmod 600 "$tmp_values"

    # Generate a values file with exactly the services for this cluster so
    # helm replaces (not merges) the chart's default service list.
    printf 'services:\n' >"$tmp_values"
    for svc in $services; do
        pass_var="$(password_var_for "$svc")"
        read -r secret_name secret_key < <(echo "$(password_secret_for "$svc")")
        value="${!pass_var}"
        # single-quote for YAML; escape embedded single quotes
        value="${value//\'/\'\'}"
        {
            printf '  - name: %s\n' "$svc"
            printf '    database: %s\n' "$svc"
            printf '    password: %s\n' "'${value}'"
            printf '    passwordSecretName: %s\n' "$secret_name"
            printf '    passwordSecretKey: %s\n' "$secret_key"
        } >>"$tmp_values"
    done

    log "Provisioning liquibase bootstrap (${services}) on ${context}"
    helm upgrade --install liquibase-bootstrap "${LIQUIBASE_DIR}/bootstrap" \
        --namespace postgresql \
        --kubeconfig "$KUBECONFIG" \
        --kube-context "$context" \
        --wait --timeout 5m \
        -f "$tmp_values"
    rm -f "$tmp_values"
}

provision_liquibase_migrations() {
    local context="$1"
    local services="$2"
    local svc
    for svc in $services; do
        # Only clusters with DB-backed platform apps have per-service
        # migration charts (openproject/keycloak/apicurio).
        [[ "$context" == "$SPOKE1_CONTEXT" ]] || return 0
        log "Provisioning liquibase migration for ${svc} on ${context}"
        helm upgrade --install "liquibase-${svc}" "${LIQUIBASE_DIR}/${svc}" \
            --namespace "$svc" \
            --kubeconfig "$KUBECONFIG" \
            --kube-context "$context" \
            --wait --timeout 5m
    done
}

provision_liquibase() {
    local context services
    for context in "${POSTGRES_CONTEXTS[@]}"; do
        if ! is_cluster_reachable "$context"; then
            warn "${context} not reachable; skipping liquibase provisioning"
            continue
        fi
        services="$(services_for_cluster "$context")"
        provision_liquibase_bootstrap "$context" "$services"
        provision_liquibase_migrations "$context" "$services"
    done
}

# ── Main ─────────────────────────────────────────────────────────────────────
require_cmd kubectl
require_cmd helm

load_env

if [[ ! -f "$KUBECONFIG" ]]; then
    # A missing default config is only fatal for the kubectl/helm phases;
    # refresh first if requested.
    if [[ "$REFRESH_LOCAL" == true ]]; then
        refresh_local_kubeconfig
        KUBECONFIG="$LOCAL_KUBECONFIG"
    else
        die "kubeconfig not found: ${KUBECONFIG}"
    fi
fi

if [[ "$REFRESH_LOCAL" == true ]]; then
    refresh_local_kubeconfig
    if [[ "$REFRESH_ONLY" == true ]]; then
        log "Kubeconfig refreshed; exiting (refresh-only)"
        exit 0
    fi
fi

seed_platform_secrets
wait_for_postgres_all
provision_liquibase

log "Platform provisioning complete (idempotent; safe to re-run)"