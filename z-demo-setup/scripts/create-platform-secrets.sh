#!/usr/bin/env bash
set -Eeuo pipefail

# Create Kubernetes Secrets for platform services across the spoke clusters
# (kubara-spoke-1, kubara-spoke-2, kubara-dev, kubara-staging, kubara-prod)
# from environment variables (loaded from .env via direnv). Publishes the same
# secrets to OpenBao (Vault) on a best-effort basis — warns if OpenBao is
# unreachable (chicken-and-egg during initial bootstrap). Creating secrets with
# kubectl apply is idempotent, so the script is safe to re-run on recreated
# clusters and during subsequent build-mesh bring-ups.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ── Cluster / context ────────────────────────────────────────────────────────
SPOKE1_CONTEXT="kind-kubara-spoke-1"
SPOKE2_CONTEXT="kind-kubara-spoke-2"
DEV_CONTEXT="kind-kubara-dev"
STAGING_CONTEXT="kind-kubara-staging"
PROD_CONTEXT="kind-kubara-prod"
HUB_CONTEXT="kind-hub"

# Standalone backing-cluster postgres deployments (db "app", user "app").
# Each of these has a bitnami postgresql Deployment in the postgresql
# namespace wired to auth.existingSecret=postgresql, so every cluster that
# runs the chart needs the secret seeded before its pod initializes.
POSTGRES_ONLY_CONTEXTS=("$SPOKE2_CONTEXT" "$DEV_CONTEXT" "$STAGING_CONTEXT" "$PROD_CONTEXT")

OPENBAO_NAMESPACE="openbao"
OPENBAO_MOUNT="kv"
HUB_NAME="hub"
HUB_STAGE="local"
CLUSTER_NAME="kubara-spoke-1"
CLUSTER_STAGE="dev"
CLUSTER2_NAME="kubara-spoke-2"
CLUSTER2_STAGE="prod"
CLUSTER3_NAME="kubara-dev"
CLUSTER3_STAGE="dev"
CLUSTER4_NAME="kubara-staging"
CLUSTER4_STAGE="staging"
CLUSTER5_NAME="kubara-prod"
CLUSTER5_STAGE="prod"

# ── Helpers ──────────────────────────────────────────────────────────────────
log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARN: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

require_var() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        die "${name} is not set — run 'direnv allow' to load .env"
    fi
}

is_cluster_reachable() {
    local context="$1"
    kubectl --context "$context" get --raw='/readyz' >/dev/null 2>&1
}

ensure_namespace() {
    local context="$1" namespace="$2"
    kubectl --context "$context" get namespace "$namespace" >/dev/null 2>&1 ||
        kubectl --context "$context" create namespace "$namespace" \
            --dry-run=client -o yaml |
            kubectl --context "$context" apply -f -
}

create_secret() {
    local context="$1" namespace="$2" name="$3"
    shift 3
    ensure_namespace "$context" "$namespace"
    # "$@" contains --from-literal=key=value pairs
    kubectl --context "$context" -n "$namespace" \
        create secret generic "$name" "$@" \
        --dry-run=client -o yaml |
        kubectl --context "$context" -n "$namespace" apply -f -
    echo "    ${namespace}/${name}"
}

# ── Validate environment ────────────────────────────────────────────────────
log "Validating required environment variables"

for var in \
    KARGO_ADMIN_PASSWORD \
    KARGO_ADMIN_TOKEN_SIGNING_KEY \
    FORGEJO_ADMIN_USER \
    FORGEJO_ADMIN_PASSWORD \
    APP_POSTGRES_PASSWORD \
    HARBOR_ADMIN_PASSWORD \
    KEYCLOAK_ADMIN_PASSWORD \
    KEYCLOAK_DB_PASSWORD \
    OPENPROJECT_ADMIN_PASSWORD \
    OPENPROJECT_SECRET_KEY_BASE \
    POSTGRES_PASSWORD \
    OPENPROJECT_DB_PASSWORD \
    APICURIO_DB_PASSWORD; do
    require_var "$var"
done

command -v htpasswd >/dev/null 2>&1 || die "htpasswd is required (brew install httpd)"
command -v jq      >/dev/null 2>&1 || die "jq is required"
command -v curl    >/dev/null 2>&1 || die "curl is required"
command -v kubectl >/dev/null 2>&1 || die "kubectl is required"

# ── Create secrets on kubara-spoke-1 ────────────────────────────────────────
SKIP_KUBECTL=false

if is_cluster_reachable "$SPOKE1_CONTEXT"; then
    log "Creating platform secrets on ${SPOKE1_CONTEXT}"
else
    warn "Cluster ${SPOKE1_CONTEXT} is not reachable; skipping kubectl secret creation"
    SKIP_KUBECTL=true
fi

if [[ "$SKIP_KUBECTL" == false ]]; then
    # Backing database (bitnami postgresql chart) credentials used by the
    # `postgresql` Deployment in the postgresql namespace. The chart is
    # configured with auth.existingSecret=postgresql (see
    # catalogs/backing-services/platform-configs/helm/postgresql) so the
    # secret below is the single source for the superuser (POSTGRES_PASSWORD)
    # and app user (APP_POSTGRES_PASSWORD) passwords, never a committed value.
    create_secret "$SPOKE1_CONTEXT" postgresql postgresql \
        --from-literal=postgres-password="$POSTGRES_PASSWORD" \
        --from-literal=password="$APP_POSTGRES_PASSWORD"

    # Kargo — bcrypt hash of admin password
    BCRYPT_HASH=$(htpasswd -nbBC 10 "" "$KARGO_ADMIN_PASSWORD" | cut -d: -f2)

    create_secret "$SPOKE1_CONTEXT" kargo kargo-admin \
        --from-literal=ADMIN_ACCOUNT_PASSWORD_HASH="$BCRYPT_HASH" \
        --from-literal=ADMIN_ACCOUNT_TOKEN_SIGNING_KEY="$KARGO_ADMIN_TOKEN_SIGNING_KEY"

    # Forgejo
    create_secret "$SPOKE1_CONTEXT" forgejo forgejo-admin \
        --from-literal=username="$FORGEJO_ADMIN_USER" \
        --from-literal=password="$FORGEJO_ADMIN_PASSWORD"

    create_secret "$SPOKE1_CONTEXT" forgejo forgejo-credentials \
        --from-literal=password="$APP_POSTGRES_PASSWORD"

    # Harbor
    create_secret "$SPOKE1_CONTEXT" harbor harbor-credentials \
        --from-literal=HARBOR_ADMIN_PASSWORD="$HARBOR_ADMIN_PASSWORD"

    # Keycloak
    create_secret "$SPOKE1_CONTEXT" keycloak keycloak-credentials \
        --from-literal=admin-password="$KEYCLOAK_ADMIN_PASSWORD" \
        --from-literal=db-password="$KEYCLOAK_DB_PASSWORD"

    # OpenProject
    create_secret "$SPOKE1_CONTEXT" openproject openproject-secrets \
        --from-literal=admin-password="$OPENPROJECT_ADMIN_PASSWORD" \
        --from-literal=secret-key-base="$OPENPROJECT_SECRET_KEY_BASE"

    create_secret "$SPOKE1_CONTEXT" openproject openproject-postgresql \
        --from-literal=postgres-password="$POSTGRES_PASSWORD" \
        --from-literal=password="$OPENPROJECT_DB_PASSWORD"

    # Apicurio
    create_secret "$SPOKE1_CONTEXT" apicurio apicurio-credentials \
        --from-literal=password="$APICURIO_DB_PASSWORD"
fi

create_postgresql_secret() {
    local context="$1"
    if ! is_cluster_reachable "$context"; then
        warn "Cluster ${context} is not reachable; skipping postgresql secret"
        return 0
    fi
    log "Creating backing database secret on ${context}"
    create_secret "$context" postgresql postgresql \
        --from-literal=postgres-password="$POSTGRES_PASSWORD" \
        --from-literal=password="$APP_POSTGRES_PASSWORD"
}

for ctx in "${POSTGRES_ONLY_CONTEXTS[@]}"; do
    create_postgresql_secret "$ctx"
done

# Image pull secret (empty registry auth, images are public) referenced by
# several workloads via imagePullSecrets.name=image-pull-secret. Not managed
# by Argo CD and not covered by ExternalSecrets on the spokes, so it has to be
# bootstrapped here on freshly recreated clusters.
ensure_image_pull_secret() {
    local context="$1" namespace="$2"
    kubectl --context "$context" get namespace "$namespace" >/dev/null 2>&1 || return 0
    kubectl --context "$context" -n "$namespace" get secret image-pull-secret >/dev/null 2>&1 && return 0
    local tmp="/tmp/image-pull-secret.$$"
    printf '%s' '{"auths":{}}' > "$tmp"
    kubectl --context "$context" -n "$namespace" \
        create secret generic image-pull-secret \
        --from-file=.dockerconfigjson="$tmp" \
        --type=kubernetes.io/dockerconfigjson --dry-run=client -o yaml |
        kubectl --context "$context" -n "$namespace" apply -f - >/dev/null
    rm -f "$tmp"
    echo "    ${namespace}/image-pull-secret"
}

if is_cluster_reachable "$SPOKE1_CONTEXT"; then
    log "Ensuring image-pull-secret on ${SPOKE1_CONTEXT}"
    for ns in external-secrets forgejo kargo traefik; do
        ensure_image_pull_secret "$SPOKE1_CONTEXT" "$ns"
    done
fi

if is_cluster_reachable "$SPOKE2_CONTEXT"; then
    log "Ensuring image-pull-secret on ${SPOKE2_CONTEXT}"
    for ns in external-secrets traefik; do
        ensure_image_pull_secret "$SPOKE2_CONTEXT" "$ns"
    done
fi

for ctx in "$DEV_CONTEXT" "$STAGING_CONTEXT" "$PROD_CONTEXT"; do
    if is_cluster_reachable "$ctx"; then
        log "Ensuring image-pull-secret on ${ctx}"
        for ns in external-secrets traefik; do
            ensure_image_pull_secret "$ctx" "$ns"
        done
    fi
done

# ── Publish to OpenBao (best-effort) ────────────────────────────────────────
log "Publishing secrets to OpenBao (best-effort)"

ROOT_TOKEN=""
OPENBAO_ADDR=""

read_root_token() {
    ROOT_TOKEN="$(
        kubectl --context "$HUB_CONTEXT" -n "$OPENBAO_NAMESPACE" \
            exec openbao-0 -c openbao -- \
            sh -c \
            'tr -d "\n\r" < /openbao/data/local-bootstrap/init.json |
             sed -n '\''s/.*"root_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'\'''
    )" 2>/dev/null || true
}

get_openbao_addr() {
    local host
    host="$(
        kubectl --context "$HUB_CONTEXT" -n "$OPENBAO_NAMESPACE" \
            get ingress openbao \
            -o jsonpath='{.spec.rules[0].host}'
    )" 2>/dev/null || true
    if [[ -n "$host" ]]; then
        OPENBAO_ADDR="http://${host}"
    fi
}

verify_openbao() {
    curl -fsS --max-time 5 \
        --header "X-Vault-Token: ${ROOT_TOKEN}" \
        "${OPENBAO_ADDR}/v1/sys/health" >/dev/null 2>&1
}

publish_to_openbao() {
    local path="$1"
    local data_json="$2"
    local api_url="${OPENBAO_ADDR}/v1/${OPENBAO_MOUNT}/data/${path}"

    echo "$data_json" | curl -fsS \
        --header "X-Vault-Token: ${ROOT_TOKEN}" \
        --header 'Content-Type: application/json' \
        --request POST \
        --data-binary @- \
        "$api_url" >/dev/null

    curl -fsS --header "X-Vault-Token: ${ROOT_TOKEN}" "$api_url" |
        jq -e '.data.data | length > 0' >/dev/null

    echo "    ${path}"
}

if ! is_cluster_reachable "$HUB_CONTEXT"; then
    warn "Cluster ${HUB_CONTEXT} is not reachable; skipping OpenBao publish"
else
    read_root_token
    get_openbao_addr

    if [[ -z "$ROOT_TOKEN" ]]; then
        warn "Could not read OpenBao root token; skipping OpenBao publish"
    elif [[ -z "$OPENBAO_ADDR" ]]; then
        warn "Could not determine OpenBao ingress address; skipping OpenBao publish"
    elif ! verify_openbao; then
        warn "OpenBao not reachable at ${OPENBAO_ADDR}; skipping OpenBao publish"
    else
        echo "    OpenBao: ${OPENBAO_ADDR}"

        HUB_PREFIX="${HUB_NAME}/${HUB_STAGE}"
        publish_to_openbao "${HUB_PREFIX}/cluster_secrets/docker_config" \
            "$(jq -n --arg ds '{"auths":{}}' '{data: {"pull-secret": $ds}}')"

        PREFIX="platform/${CLUSTER_NAME}-${CLUSTER_STAGE}"
        PREFIX2="platform/${CLUSTER2_NAME}-${CLUSTER2_STAGE}"
        PREFIX3="platform/${CLUSTER3_NAME}-${CLUSTER3_STAGE}"
        PREFIX4="platform/${CLUSTER4_NAME}-${CLUSTER4_STAGE}"
        PREFIX5="platform/${CLUSTER5_NAME}-${CLUSTER5_STAGE}"

        publish_to_openbao "${PREFIX}/postgresql/postgresql" \
            "$(jq -n --arg pg "$POSTGRES_PASSWORD" --arg app "$APP_POSTGRES_PASSWORD" \
                '{data: {"postgres-password": $pg, password: $app}}')"

        publish_to_openbao "${PREFIX2}/postgresql/postgresql" \
            "$(jq -n --arg pg "$POSTGRES_PASSWORD" --arg app "$APP_POSTGRES_PASSWORD" \
                '{data: {"postgres-password": $pg, password: $app}}')"

        publish_to_openbao "${PREFIX3}/postgresql/postgresql" \
            "$(jq -n --arg pg "$POSTGRES_PASSWORD" --arg app "$APP_POSTGRES_PASSWORD" \
                '{data: {"postgres-password": $pg, password: $app}}')"

        publish_to_openbao "${PREFIX4}/postgresql/postgresql" \
            "$(jq -n --arg pg "$POSTGRES_PASSWORD" --arg app "$APP_POSTGRES_PASSWORD" \
                '{data: {"postgres-password": $pg, password: $app}}')"

        publish_to_openbao "${PREFIX5}/postgresql/postgresql" \
            "$(jq -n --arg pg "$POSTGRES_PASSWORD" --arg app "$APP_POSTGRES_PASSWORD" \
                '{data: {"postgres-password": $pg, password: $app}}')"

        publish_to_openbao "${PREFIX}/kargo/kargo-admin" \
            "$(jq -n --arg hash "$BCRYPT_HASH" --arg key "$KARGO_ADMIN_TOKEN_SIGNING_KEY" \
                '{data: {ADMIN_ACCOUNT_PASSWORD_HASH: $hash, ADMIN_ACCOUNT_TOKEN_SIGNING_KEY: $key}}')"

        publish_to_openbao "${PREFIX}/forgejo/forgejo-admin" \
            "$(jq -n --arg user "$FORGEJO_ADMIN_USER" --arg pass "$FORGEJO_ADMIN_PASSWORD" \
                '{data: {username: $user, password: $pass}}')"

        publish_to_openbao "${PREFIX}/forgejo/forgejo-credentials" \
            "$(jq -n --arg pass "$APP_POSTGRES_PASSWORD" \
                '{data: {password: $pass}}')"

        publish_to_openbao "${PREFIX}/harbor/harbor-credentials" \
            "$(jq -n --arg pass "$HARBOR_ADMIN_PASSWORD" \
                '{data: {HARBOR_ADMIN_PASSWORD: $pass}}')"

        publish_to_openbao "${PREFIX}/keycloak/keycloak-credentials" \
            "$(jq -n --arg admin "$KEYCLOAK_ADMIN_PASSWORD" --arg db "$KEYCLOAK_DB_PASSWORD" \
                '{data: {"admin-password": $admin, "db-password": $db}}')"

        publish_to_openbao "${PREFIX}/openproject/openproject-secrets" \
            "$(jq -n --arg admin "$OPENPROJECT_ADMIN_PASSWORD" --arg keybase "$OPENPROJECT_SECRET_KEY_BASE" \
                '{data: {"admin-password": $admin, "secret-key-base": $keybase}}')"

        publish_to_openbao "${PREFIX}/openproject/openproject-postgresql" \
            "$(jq -n --arg pgpass "$POSTGRES_PASSWORD" --arg pass "$OPENPROJECT_DB_PASSWORD" \
                '{data: {"postgres-password": $pgpass, password: $pass}}')"

        publish_to_openbao "${PREFIX}/apicurio/apicurio-credentials" \
            "$(jq -n --arg pass "$APICURIO_DB_PASSWORD" \
                '{data: {password: $pass}}')"
    fi
fi

unset ROOT_TOKEN

log "Platform secrets created successfully"
