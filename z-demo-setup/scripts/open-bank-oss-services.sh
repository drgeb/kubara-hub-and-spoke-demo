#!/usr/bin/env bash
# open-bank-oss-services.sh - deploy OpenBank domain services (beyond the
# product catalog) to kubara-dev through Harbor -> Kargo -> Argo CD.
#
# Usage: open-bank-oss-services.sh <step> [service]
#        (Justfile.open-bank-oss wraps every step as openbank-svc-*)
#
#   keycloak         realm `openbank` + confidential client `openbank-services`
#                    on the mesh Keycloak; client secret -> Secret openbank/openbank-oidc
#   chart            commit the generic chart to openbank-gitops charts/openbank-service
#   temporal         demo Temporal dev server (charts/openbank-temporal) + its test
#   build   <svc>    Gradle fast-jar of the service module
#   image   <svc>    bake + push harbor/openbank/<svc>-service:kubara-<utc>-<sha>
#   db      <svc>    role/database on kubara-dev postgres + Secret openbank/<svc>-database
#   gitops  <svc>    stages/dev/<svc>/values.yaml (+ image.yaml seed, then Kargo's)
#   argocd  <svc>    hub Argo CD Application openbank-<svc>-dev
#   kargo   <svc>    Kargo Warehouse <svc>-service + Stage <svc>-dev (auto-promotion)
#   test    <svc>    Argo healthy, pod ready (DB + Kafka health), Flyway ran,
#                    Kafka consumer group, ingress 401 without / non-401 with a token
#   deploy  <svc>    build image db gitops argocd kargo test
#   status           every service's Kargo stage, Argo app and pods
#   list             the services this script knows
#
# Services: see `list` (OPENBANK_SERVICES in open-bank-oss.sh). They use the
# shared PostgreSQL, Kafka, OIDC, a per-service Redis where needed, and the demo
# Temporal (`temporal` step) for workflow services. ClickHouse, OpenBao/Vault
# and OPA are not deployed; the services' defaults keep those paths off.
#
# Upstream deploys each service with raw manifests on CNPG, Argo Rollouts,
# Kafka mTLS, an OPA sidecar and ExternalSecrets. Here one generic chart
# (z-demo-setup/open-bank-oss/service-chart) wires a service to the shared
# postgres, kubara's plain Kafka listener and the mesh Keycloak; authz is
# advisory (no OPA sidecar). No IP addresses anywhere (AGENTS.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Shared config + helpers (CA, Harbor push, gitops git, kc, log/die, ...).
# shellcheck source=open-bank-oss.sh
source "${SCRIPT_DIR}/open-bank-oss.sh"

SERVICE_CHART="${SETUP}/service-chart"
SERVICE_OVERLAY="${SETUP}/kubara-image/service-application.yaml"
OIDC_SECRET="openbank-oidc"
OIDC_REALM="openbank"
OIDC_CLIENT="openbank-services"
# Realm roles OpenBank's @RolesAllowed checks use; granted to the client's
# service account (the identity the smoke tests call with).
OIDC_ROLES="ROLE_OPERATOR ROLE_API ROLE_ADMIN"

# ── service registry (bash 3.2: no associative arrays) ───────────────────────
# Sets SVC_* for one service; dies on an unknown name.
svc_def() {
    SVC="${1:-}"
    [ -n "$SVC" ] || die "missing service name; one of: ${OPENBANK_SERVICES}"
    SVC_REDIS=false
    SVC_MGMT_PORT=8085          # openbank-libs-runtime default; some modules override
    SVC_SECRET_KEYS=""          # env vars generated once into Secret <svc>-app
    SVC_M2M_CLIENT=""           # the module's named "m2m" OIDC client id, if any
    SVC_TLS_MOUNTS=""           # <name>:<mountPath> mTLS client keypairs loaded at startup
    SVC_ENV=""                  # extra KEY=value env vars (no spaces in values)
    SVC_AUTH_PATH=""            # path for the no-token 401 check (default SVC_TEST_PATH)
    SVC_TEMPORAL=false          # point the service at the demo Temporal (openbank-temporal)
    case "$SVC" in
        engagement)
            SVC_MODULE=openbank-engagement-service; SVC_PORT=8153
            SVC_DB=openbank_engagement; SVC_TEST_PATH=/api/v1/game/admin/catalog
            SVC_ENV="CONSENT_SERVICE_URL=http://consent-service:8106" ;;
        incentive)
            SVC_MODULE=openbank-incentive-service; SVC_PORT=8156; SVC_MGMT_PORT=8087
            SVC_DB=openbank_incentive; SVC_TEST_PATH=/api/v1/incentives/offers
            SVC_SECRET_KEYS="PROMO_CODE_PEPPER" ;;   # >= 32 chars, promo-code hashing
        account)
            SVC_MODULE=openbank-account-service; SVC_PORT=8100
            SVC_DB=openbank_accounts; SVC_TEST_PATH=/api/v1/accounts/approvals
            SVC_REDIS=true; SVC_M2M_CLIENT=openbank-account
            # East-west mTLS to sca-service / party-service (named TLS configs
            # sca-authority / party-authority read these files at startup).
            SVC_TLS_MOUNTS="sca-tls:/mnt/sca-tls party-tls:/mnt/party-tls"
            # Plain HTTP in-cluster: the demo images are built without a TLS listener.
            SVC_ENV="PARTY_SERVICE_URL=http://party-service:8111 SCA_SERVICE_URL=http://sca-service:8110" ;;
        party)
            SVC_MODULE=openbank-party-service; SVC_PORT=8111
            SVC_DB=openbank_parties; SVC_TEST_PATH=/api/v1/parties/approvals
            SVC_REDIS=true; SVC_M2M_CLIENT=openbank-party ;;
        campaign)
            # Temporal (openbank.temporal.enabled) and the ClickHouse analytics
            # reads default off/lazy upstream, so neither is deployed here.
            SVC_MODULE=openbank-campaign-service; SVC_PORT=8128
            SVC_DB=openbank_campaigns; SVC_TEST_PATH=/api/v1/segments
            # /segments is gated only by @Authorize (OPA, advisory here), so the
            # 401 check uses a @RolesAllowed endpoint instead.
            SVC_AUTH_PATH=/api/v1/campaigns/interactions/00000000-0000-0000-0000-000000000000
            SVC_REDIS=true; SVC_M2M_CLIENT=openbank-campaign
            # %prod's named TLS config "referral-service" reads ca.crt at startup.
            SVC_TLS_MOUNTS="campaign-tls:/mnt/campaign-tls"
            # No Temporal server: the worker registrar connects to it at startup.
            SVC_ENV="CAMPAIGN_WORKER_ENABLED=false INCENTIVE_SERVICE_URL=http://incentive-service:8156 CONSENT_SERVICE_URL=http://consent-service:8106 REFERRAL_SERVICE_URL=http://referral-service:8155" ;;
        billing)
            # OpenBao is only used when product-shadow verification.mode=openbao
            # (default: disabled), so it is not deployed here.
            SVC_MODULE=openbank-billing-service; SVC_PORT=8132
            SVC_DB=openbank_billing; SVC_TEST_PATH=/api/v1/fees/approvals
            SVC_REDIS=true; SVC_M2M_CLIENT=openbank-billing
            SVC_ENV="ACCOUNT_SERVICE_URL=http://account-service:8100 LEDGER_SERVICE_URL=http://ledger-service:8101 BALANCE_SERVICE_URL=http://balance-service:8103" ;;
        consent)
            SVC_MODULE=openbank-consent-service; SVC_PORT=8106
            SVC_DB=openbank_consents; SVC_TEST_PATH=/api/v1/consents/approvals
            SVC_REDIS=true ;;
        ledger)
            SVC_MODULE=openbank-ledger-service; SVC_PORT=8101
            SVC_DB=openbank_ledger; SVC_TEST_PATH=/api/v1/journals/approvals
            SVC_REDIS=true ;;
        balance)
            SVC_MODULE=openbank-balance-service; SVC_PORT=8103
            SVC_DB=openbank_balances; SVC_TEST_PATH=/api/v1/balances/approvals
            SVC_REDIS=true ;;
        sca)
            SVC_MODULE=openbank-sca-service; SVC_PORT=8110
            SVC_DB=openbank_sca; SVC_TEST_PATH=/api/v1/sca/approvals
            SVC_REDIS=true
            # %prod's named TLS config party-authority reads this pair at startup.
            SVC_TLS_MOUNTS="party-tls:/mnt/party-tls"
            SVC_ENV="PARTY_SERVICE_URL=http://party-service:8111" ;;
        referral)
            SVC_MODULE=openbank-referral-service; SVC_PORT=8155; SVC_MGMT_PORT=8086
            SVC_DB=openbank_referral; SVC_TEST_PATH=/api/v1/referrals/programs ;;
        transaction)
            SVC_MODULE=openbank-transaction-service; SVC_PORT=8102
            SVC_DB=openbank_transactions; SVC_TEST_PATH=/api/v1/transactions/approvals
            SVC_REDIS=true; SVC_M2M_CLIENT=openbank-transaction; SVC_TEMPORAL=true
            SVC_TLS_MOUNTS="fx-tls:/mnt/fx-tls"
            # The payment worker refuses to poll unversioned (Temporal worker
            # deployment versioning): build id = the image's full source SHA,
            # baked in as OPENBANK_BUILD_SHA by push_image, expanded by Quarkus.
            SVC_ENV='BALANCE_SERVICE_URL=http://balance-service:8103 LEDGER_SERVICE_URL=http://ledger-service:8101 OPENBANK_TRANSACTION_WORKER_VERSIONING_ENABLED=true OPENBANK_TRANSACTION_WORKER_VERSIONING_DEPLOYMENT_NAME=transaction-service OPENBANK_TRANSACTION_WORKER_VERSIONING_BUILD_ID=${OPENBANK_BUILD_SHA}' ;;
        sepa-payment)
            SVC_MODULE=openbank-sepa-payment; SVC_PORT=8115
            SVC_DB=openbank_sepa_payments; SVC_TEST_PATH=/api/v1/sepa-payments/approvals
            SVC_REDIS=true; SVC_M2M_CLIENT=openbank-sepa-payment; SVC_TEMPORAL=true
            SVC_TLS_MOUNTS="aml-tls:/mnt/aml-tls document-tls:/mnt/document-tls"
            SVC_ENV="ACCOUNT_SERVICE_URL=http://account-service:8100 TRANSACTION_SERVICE_URL=http://transaction-service:8102" ;;
        clearing)
            SVC_MODULE=openbank-clearing-service; SVC_PORT=8124
            SVC_DB=openbank_clearing; SVC_TEST_PATH=/api/v1/clearing/approvals
            SVC_REDIS=true; SVC_M2M_CLIENT=openbank-clearing
            SVC_TLS_MOUNTS="ledger-tls:/mnt/ledger-tls"
            SVC_ENV="LEDGER_SERVICE_URL=http://ledger-service:8101" ;;
        settlement)
            SVC_MODULE=openbank-settlement-service; SVC_PORT=8138
            SVC_DB=openbank_settlement; SVC_TEST_PATH=/api/v1/settlements/approvals
            SVC_M2M_CLIENT=openbank-settlement; SVC_TEMPORAL=true
            SVC_ENV="BALANCE_SERVICE_URL=http://balance-service:8103 LEDGER_SERVICE_URL=http://ledger-service:8101" ;;
        swift)
            SVC_MODULE=openbank-swift-service; SVC_PORT=8122
            SVC_DB=openbank_swift; SVC_TEST_PATH=/api/v1/swift/approvals
            SVC_REDIS=true; SVC_M2M_CLIENT=openbank-swift
            SVC_TLS_MOUNTS="aml-tls:/mnt/aml-tls"
            SVC_ENV="TRANSACTION_SERVICE_URL=http://transaction-service:8102" ;;
        *) die "unknown service '${SVC}'; one of: ${OPENBANK_SERVICES}" ;;
    esac
    SVC_NAME="${SVC}-service"                    # k8s name + Harbor repo
    SVC_IMAGE="${HARBOR}/${HARBOR_PROJECT}/${SVC_NAME}"
    SVC_DB_USER="$SVC_DB"
    SVC_DB_SECRET="${SVC}-database"
    SVC_APP_SECRET="${SVC}-app"
    SVC_M2M_SECRET=""
    [ -z "$SVC_M2M_CLIENT" ] || SVC_M2M_SECRET="${SVC}-oidc-m2m"
    SVC_STAGE="${SVC}-dev"                       # Kargo Stage
    SVC_APP="openbank-${SVC}-dev"                # Argo CD Application
    SVC_HOST="${SVC}.${DEV_DNS}"
    SVC_TAG_FILE="${STATE}/last-tag-${SVC}"
}

# Clone openbank-gitops, run <fn> <workdir> [args...], commit + push if changed.
#   gitops_edit <message> <fn> [args...]
gitops_edit() {
    local msg="$1" fn="$2"; shift 2
    local w="${STATE}/gitops-work"
    rm -rf "$w"
    gitops_git clone -q "$(gitops_url)" "$w"
    "$fn" "$w" "$@"
    (
        cd "$w"
        git add -A
        if git diff --cached --quiet; then
            info "already up to date in ${GITOPS_REPO}"
            exit 0
        fi
        git -c user.name="kubara demo" -c user.email="kubara-demo@${PE_DNS}" commit -q -m "$msg"
        gitops_git push -q origin main
        info "committed to ${GITOPS_REPO}: ${msg}"
    )
}

# ── keycloak ─────────────────────────────────────────────────────────────────
kc_admin() {   # kc_admin <curl args...> against the Keycloak admin API
    curl -sS --cacert "$CA" -H "Authorization: Bearer ${KC_TOKEN}" -H 'Content-Type: application/json' "$@"
}

# Ensure a confidential client with a service account holding <roles>; sets
# KC_CLIENT_SECRET.   kc_ensure_client <clientId> <roles...>
kc_ensure_client() {
    local client="$1"; shift
    local base="https://${KEYCLOAK}/admin/realms/${OIDC_REALM}" id role sa_id
    id="$(kc_admin "${base}/clients?clientId=${client}" \
        | python3 -c 'import json,sys; c=json.load(sys.stdin); print(c[0]["id"] if c else "")')"
    if [ -z "$id" ]; then
        kc_admin -f -o /dev/null -X POST "${base}/clients" -d "{
            \"clientId\":\"${client}\",\"enabled\":true,\"publicClient\":false,
            \"clientAuthenticatorType\":\"client-secret\",\"serviceAccountsEnabled\":true,
            \"standardFlowEnabled\":false,\"directAccessGrantsEnabled\":false}"
        id="$(kc_admin "${base}/clients?clientId=${client}" \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')"
        info "created client ${client}"
    else
        info "client ${client} exists"
    fi
    if [ "$#" -gt 0 ]; then
        sa_id="$(kc_admin "${base}/clients/${id}/service-account-user" \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
        kc_admin -f -o /dev/null -X POST "${base}/users/${sa_id}/role-mappings/realm" -d "$(
            for role in "$@"; do kc_admin "${base}/roles/${role}"; echo; done \
                | python3 -c 'import json,sys; print(json.dumps([json.loads(l) for l in sys.stdin if l.strip()]))')"
        info "  service account roles: $*"
    fi
    KC_CLIENT_SECRET="$(kc_admin "${base}/clients/${id}/client-secret" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])')"
    [ -n "$KC_CLIENT_SECRET" ] || die "could not read the ${client} client secret"
}

# Write a {client-id, client-secret} Secret into the openbank namespace on dev.
put_client_secret() {   # put_client_secret <secret-name> <client-id> <client-secret>
    kc "$DEV_CTX" -n "$NS" create secret generic "$1" \
        --from-literal=client-id="$2" --from-literal=client-secret="$3" \
        --dry-run=client -o yaml | kc "$DEV_CTX" apply -f - >/dev/null
    info "secret ${NS}/$1 applied (client secret never leaves the clusters)"
}

cmd_keycloak() {
    need KEYCLOAK_ADMIN_USER KEYCLOAK_ADMIN_PASSWORD; need_ca
    local base="https://${KEYCLOAK}" code role s
    log "Keycloak ${KEYCLOAK}: realm ${OIDC_REALM}, client ${OIDC_CLIENT} + service m2m clients"
    KC_TOKEN="$(curl -fsS --cacert "$CA" "${base}/realms/master/protocol/openid-connect/token" \
        --data-urlencode grant_type=password --data-urlencode client_id=admin-cli \
        --data-urlencode "username=${KEYCLOAK_ADMIN_USER}" --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD}" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')" \
        || die "Keycloak admin login failed"

    code="$(kc_admin -o /dev/null -w '%{http_code}' "${base}/admin/realms/${OIDC_REALM}")"
    if [ "$code" = 404 ]; then
        kc_admin -f -o /dev/null -X POST "${base}/admin/realms" \
            -d "{\"realm\":\"${OIDC_REALM}\",\"enabled\":true}"
        info "created realm ${OIDC_REALM}"
    else
        info "realm ${OIDC_REALM} exists"
    fi
    # OpenBank endpoints are @RolesAllowed on ROLE_* realm roles (Quarkus reads
    # Keycloak's realm_access.roles).
    for role in $OIDC_ROLES; do
        code="$(kc_admin -o /dev/null -w '%{http_code}' "${base}/admin/realms/${OIDC_REALM}/roles/${role}")"
        [ "$code" = 200 ] || kc_admin -f -o /dev/null -X POST "${base}/admin/realms/${OIDC_REALM}/roles" -d "{\"name\":\"${role}\"}"
    done

    kc "$DEV_CTX" create namespace "$NS" --dry-run=client -o yaml | kc "$DEV_CTX" apply -f - >/dev/null
    # Shared client: services verify bearer tokens from this realm and use it
    # for client-credentials calls; the smoke tests call with its service
    # account, which gets the read-side roles to get past @RolesAllowed.
    # shellcheck disable=SC2086  # OIDC_ROLES is a word list
    kc_ensure_client "$OIDC_CLIENT" $OIDC_ROLES
    put_client_secret "$OIDC_SECRET" "$OIDC_CLIENT" "$KC_CLIENT_SECRET"

    # Per-service named "m2m" OIDC clients (upstream: own principal per service
    # for money-path calls, ROLE_API).
    for s in $OPENBANK_SERVICES; do
        svc_def "$s"
        [ -n "$SVC_M2M_CLIENT" ] || continue
        kc_ensure_client "$SVC_M2M_CLIENT" ROLE_API
        put_client_secret "$SVC_M2M_SECRET" "$SVC_M2M_CLIENT" "$KC_CLIENT_SECRET"
    done
}

# ── chart ────────────────────────────────────────────────────────────────────
_put_chart() { rm -rf "$1/charts/openbank-service"; mkdir -p "$1/charts"; cp -R "$SERVICE_CHART" "$1/charts/openbank-service"; }

cmd_chart() {
    need FORGEJO_ADMIN_USER FORGEJO_ADMIN_PASSWORD; need_ca
    helm lint "$SERVICE_CHART" --set name=lint --set image.repository=x --set image.tag=x \
        --set database.name=x --set database.existingSecret=x --set oidc.keycloakUrl=https://x >/dev/null \
        || die "helm lint failed for ${SERVICE_CHART}"
    log "Committing charts/openbank-service to ${GITOPS_REPO}"
    gitops_edit "openbank-service chart (kubara generic service chart)" _put_chart
}

# ── build / image ────────────────────────────────────────────────────────────
cmd_svc_build() { svc_def "$1"; build_module "$SVC_MODULE"; }

cmd_svc_image() {
    svc_def "$1"
    cmd_harbor
    push_image "$SVC_MODULE" "$SVC_NAME" "$SERVICE_OVERLAY" "$SVC_TAG_FILE"
}

# ── db ───────────────────────────────────────────────────────────────────────
cmd_svc_db() {
    svc_def "$1"
    need POSTGRES_PASSWORD
    local pw
    # Reuse the password already in the Secret so re-runs don't rotate it
    # under a running pod; generate one on first run (never stored in git/.env).
    pw="$(kc "$DEV_CTX" -n "$NS" get secret "$SVC_DB_SECRET" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    [ -n "$pw" ] || pw="$(openssl rand -hex 24)"
    log "Database ${SVC_DB} on ${DEV_CTX}"
    kc "$DEV_CTX" -n postgresql exec -i postgresql-0 -- env PGPASSWORD="$POSTGRES_PASSWORD" \
        psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U postgres -q <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${SVC_DB_USER}') THEN
    CREATE ROLE ${SVC_DB_USER} LOGIN PASSWORD '${pw}';
  ELSE
    ALTER ROLE ${SVC_DB_USER} WITH LOGIN PASSWORD '${pw}';
  END IF;
END \$\$;
SELECT 'CREATE DATABASE ${SVC_DB} OWNER ${SVC_DB_USER}'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${SVC_DB}')\gexec
-- Upstream migrations GRANT to / REVOKE from the role "openbank" (their shared
-- app user). Here each service has its own login role, so "openbank" only has
-- to exist: NOLOGIN, no password.
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'openbank') THEN
    CREATE ROLE openbank NOLOGIN;
  END IF;
END \$\$;
SQL
    kc "$DEV_CTX" create namespace "$NS" --dry-run=client -o yaml | kc "$DEV_CTX" apply -f - >/dev/null
    kc "$DEV_CTX" -n "$NS" create secret generic "$SVC_DB_SECRET" \
        --from-literal=username="$SVC_DB_USER" --from-literal=password="$pw" \
        --dry-run=client -o yaml | kc "$DEV_CTX" apply -f - >/dev/null
    info "role + database ready; secret ${NS}/${SVC_DB_SECRET} applied"

    [ -z "$SVC_TLS_MOUNTS" ] || svc_tls_secrets

    # Service-specific secrets: generated once, kept across re-runs.
    if [ -n "$SVC_SECRET_KEYS" ]; then
        local key val args=""
        for key in $SVC_SECRET_KEYS; do
            val="$(kc "$DEV_CTX" -n "$NS" get secret "$SVC_APP_SECRET" -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true)"
            [ -n "$val" ] || val="$(openssl rand -hex 32)"
            args="${args} --from-literal=${key}=${val}"
        done
        # shellcheck disable=SC2086  # args is a list of --from-literal flags
        kc "$DEV_CTX" -n "$NS" create secret generic "$SVC_APP_SECRET" $args \
            --dry-run=client -o yaml | kc "$DEV_CTX" apply -f - >/dev/null
        info "secret ${NS}/${SVC_APP_SECRET} applied (${SVC_SECRET_KEYS})"
    fi
}

# ── demo mTLS material ───────────────────────────────────────────────────────
# Upstream issues east-west client keypairs with cert-manager from an internal
# CA. kubara-dev has no such issuer, so a demo CA (Secret openbank/openbank-demo-ca,
# created once) signs one client keypair per mount: Secret <svc>-<name> with
# tls.crt, tls.key, ca.crt. Existing Secrets are kept across re-runs.
demo_ca() {
    local d="$1"
    if kc "$DEV_CTX" -n "$NS" get secret openbank-demo-ca >/dev/null 2>&1; then
        kc "$DEV_CTX" -n "$NS" get secret openbank-demo-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > "${d}/ca.crt"
        kc "$DEV_CTX" -n "$NS" get secret openbank-demo-ca -o jsonpath='{.data.tls\.key}' | base64 -d > "${d}/ca.key"
        return 0
    fi
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${d}/ca.key" 2>/dev/null
    openssl req -x509 -new -key "${d}/ca.key" -sha256 -days 3650 -subj "/CN=openbank-demo-ca" \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -out "${d}/ca.crt" 2>/dev/null
    kc "$DEV_CTX" -n "$NS" create secret tls openbank-demo-ca --cert="${d}/ca.crt" --key="${d}/ca.key" >/dev/null
    info "created demo CA openbank/openbank-demo-ca"
}

svc_tls_secrets() {
    local d="${STATE}/tls-work" m name secret
    rm -rf "$d"; mkdir -p "$d"; chmod 700 "$d"
    trap 'rm -rf "'"$d"'"' RETURN
    demo_ca "$d"
    for m in $SVC_TLS_MOUNTS; do
        name="${m%%:*}"; secret="${SVC}-${name}"
        if kc "$DEV_CTX" -n "$NS" get secret "$secret" >/dev/null 2>&1; then
            info "secret ${NS}/${secret} exists"; continue
        fi
        openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${d}/${name}.key" 2>/dev/null
        openssl req -new -key "${d}/${name}.key" -subj "/CN=${SVC_NAME}" -out "${d}/${name}.csr" 2>/dev/null
        printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\nsubjectAltName=DNS:%s.%s.svc\n' \
            "$SVC_NAME" "$NS" > "${d}/${name}.ext"
        openssl x509 -req -in "${d}/${name}.csr" -CA "${d}/ca.crt" -CAkey "${d}/ca.key" -CAcreateserial \
            -days 825 -sha256 -extfile "${d}/${name}.ext" -out "${d}/${name}.crt" 2>/dev/null
        kc "$DEV_CTX" -n "$NS" create secret generic "$secret" --from-file=tls.crt="${d}/${name}.crt" \
            --from-file=tls.key="${d}/${name}.key" --from-file=ca.crt="${d}/ca.crt" >/dev/null
        info "secret ${NS}/${secret} created (client keypair for ${m#*:})"
    done
}

# ── gitops ───────────────────────────────────────────────────────────────────
# values.yaml is owned by this script (rewritten on every run); image.yaml is
# seeded once and then owned by Kargo (image.tag on every promotion).
_put_stage() {
    local w="$1" tag="$2" d="$1/stages/dev/${SVC}" app_secret="" named_clients=""
    [ -z "$SVC_M2M_CLIENT" ] || named_clients="m2m"
    [ -z "$SVC_SECRET_KEYS" ] || app_secret="$SVC_APP_SECRET"
    mkdir -p "$d"
    cat > "${d}/values.yaml" <<EOF
# kubara-dev values for the OpenBank ${SVC} service (chart: charts/openbank-service).
# Written by z-demo-setup/scripts/open-bank-oss-services.sh; image.tag is in image.yaml (Kargo).
name: ${SVC}
port: ${SVC_PORT}
managementPort: ${SVC_MGMT_PORT}
appSecret: "${app_secret}"
image:
  repository: ${SVC_IMAGE}
database:
  name: ${SVC_DB}
  existingSecret: ${SVC_DB_SECRET}
oidc:
  keycloakUrl: https://${KEYCLOAK}
  realm: ${OIDC_REALM}
  clientId: ${OIDC_CLIENT}
  existingSecret: ${OIDC_SECRET}
  m2mSecret: "${SVC_M2M_SECRET}"
  namedClients: [${named_clients}]
redis:
  enabled: ${SVC_REDIS}
temporal:
  enabled: ${SVC_TEMPORAL}
ingress:
  enabled: true
  host: ${SVC_HOST}
EOF
    if [ -n "$SVC_TLS_MOUNTS" ]; then
        local m
        echo "tlsMounts:" >> "${d}/values.yaml"
        for m in $SVC_TLS_MOUNTS; do
            printf '  - {name: %s, mountPath: %s, secretName: %s-%s}\n' "${m%%:*}" "${m#*:}" "$SVC" "${m%%:*}" >> "${d}/values.yaml"
        done
    fi
    if [ -n "$SVC_ENV" ]; then
        local e
        echo "extraEnv:" >> "${d}/values.yaml"
        for e in $SVC_ENV; do
            printf '  - {name: %s, value: "%s"}\n' "${e%%=*}" "${e#*=}" >> "${d}/values.yaml"
        done
    fi
    if [ ! -f "${d}/image.yaml" ]; then
        printf '# Owned by Kargo Stage %s (yaml-update image.tag on promotion).\nimage:\n  tag: %s\n' \
            "$SVC_STAGE" "$tag" > "${d}/image.yaml"
    fi
}

cmd_svc_gitops() {
    svc_def "$1"
    need FORGEJO_ADMIN_USER FORGEJO_ADMIN_PASSWORD; need_ca
    local tag
    tag="$(cat "$SVC_TAG_FILE" 2>/dev/null || true)"
    [ -n "$tag" ] || die "no ${SVC} image pushed yet; run: just openbank-svc-image ${SVC}"
    log "Committing stages/dev/${SVC} to ${GITOPS_REPO}"
    gitops_edit "${SVC}: dev stage values" _put_stage "$tag"
}

# ── temporal ─────────────────────────────────────────────────────────────────
# Single-pod Temporal dev server for the services' workflows (namespace temporal
# on kubara-dev), delivered like the services: chart in openbank-gitops, hub
# Argo CD Application. Services reach it at temporal.temporal.svc:7233.
TEMPORAL_CHART="${SETUP}/temporal-chart"
TEMPORAL_APP="openbank-temporal-dev"
TEMPORAL_NS="temporal"

_put_temporal() {
    rm -rf "$1/charts/openbank-temporal"; mkdir -p "$1/charts" "$1/stages/dev/temporal"
    cp -R "$TEMPORAL_CHART" "$1/charts/openbank-temporal"
    cat > "$1/stages/dev/temporal/values.yaml" <<EOF
# kubara-dev values for the demo Temporal (chart: charts/openbank-temporal).
ui:
  ingress:
    host: temporal.${DEV_DNS}
EOF
}

cmd_temporal() {
    need FORGEJO_ADMIN_USER FORGEJO_ADMIN_PASSWORD; need_ca
    helm lint "$TEMPORAL_CHART" --set ui.ingress.host=x >/dev/null || die "helm lint failed for ${TEMPORAL_CHART}"
    log "Committing charts/openbank-temporal to ${GITOPS_REPO}"
    gitops_edit "openbank-temporal: demo Temporal dev server" _put_temporal
    log "Argo CD on ${HUB_CTX}: Application ${TEMPORAL_APP}"
    kc "$HUB_CTX" -n argocd get appproject openbank >/dev/null 2>&1 \
        || die "AppProject openbank missing; run: just openbank-argocd"
    kc "$HUB_CTX" apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${TEMPORAL_APP}
  namespace: argocd
spec:
  project: openbank
  source:
    repoURL: $(gitops_url)
    targetRevision: main
    path: charts/openbank-temporal
    helm:
      releaseName: temporal
      valueFiles:
        - ../../stages/dev/temporal/values.yaml
  destination:
    name: ${ARGO_DEST_CLUSTER}
    namespace: ${TEMPORAL_NS}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
    kc "$HUB_CTX" -n argocd annotate application "$TEMPORAL_APP" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
    info "Application ${TEMPORAL_APP} -> ${ARGO_DEST_CLUSTER}/${TEMPORAL_NS}"
    cmd_temporal_test
}

cmd_temporal_test() {
    local i ns want missing=""
    log "Testing Temporal (${TEMPORAL_APP}) on ${DEV_CTX}"
    for i in $(seq 1 60); do
        kc "$DEV_CTX" -n "$TEMPORAL_NS" rollout status deploy/temporal --timeout=5s >/dev/null 2>&1 && break
        sleep 5
    done
    kc "$DEV_CTX" -n "$TEMPORAL_NS" rollout status deploy/temporal --timeout=5s >/dev/null 2>&1 \
        || die "deployment temporal not ready; see: kubectl -n ${TEMPORAL_NS} logs deploy/temporal"
    info "PASS deployment temporal ready"
    ns="$(kc "$DEV_CTX" -n "$TEMPORAL_NS" exec deploy/temporal -- \
        temporal operator namespace list --address localhost:7233 -o json 2>/dev/null \
        | python3 -c 'import json,sys; print(" ".join(n["namespaceInfo"]["name"] for n in json.load(sys.stdin)))' || true)"
    for want in $(kc "$DEV_CTX" -n "$TEMPORAL_NS" get deploy temporal -o jsonpath='{.spec.template.spec.containers[0].args}' \
            | grep -oE 'namespace=[a-z-]+' | cut -d= -f2); do
        case " $ns " in *" $want "*) ;; *) missing="${missing} ${want}" ;; esac
    done
    [ -z "$missing" ] || die "Temporal namespaces missing:${missing}"
    info "PASS Temporal namespaces registered: ${ns}"
    log "Temporal UI: http://temporal.${DEV_DNS}"
}

# ── argocd ───────────────────────────────────────────────────────────────────
cmd_svc_argocd() {
    svc_def "$1"
    log "Argo CD on ${HUB_CTX}: Application ${SVC_APP}"
    kc "$HUB_CTX" -n argocd get appproject openbank >/dev/null 2>&1 \
        || die "AppProject openbank missing; run: just openbank-argocd"
    kc "$HUB_CTX" apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${SVC_APP}
  namespace: argocd
spec:
  project: openbank
  source:
    repoURL: $(gitops_url)
    targetRevision: main
    path: charts/openbank-service
    helm:
      releaseName: ${SVC_NAME}
      valueFiles:
        - ../../stages/dev/${SVC}/values.yaml
        - ../../stages/dev/${SVC}/image.yaml
  destination:
    name: ${ARGO_DEST_CLUSTER}
    namespace: ${NS}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
    kc "$HUB_CTX" -n argocd annotate application "$SVC_APP" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
    info "Application ${SVC_APP} -> ${ARGO_DEST_CLUSTER}/${NS}"
}

# ── kargo ────────────────────────────────────────────────────────────────────
cmd_svc_kargo() {
    svc_def "$1"
    need FORGEJO_ADMIN_USER
    kc "$PE_CTX" -n "$KARGO_PROJECT" get secret openbank-gitops-creds >/dev/null 2>&1 \
        || die "Kargo project ${KARGO_PROJECT} not set up; run: just openbank-kargo"
    log "Kargo on ${PE_CTX}: Warehouse ${SVC_NAME} -> Stage ${SVC_STAGE}"
    kargo_project_config
    kc "$PE_CTX" apply -f - >/dev/null <<EOF
apiVersion: kargo.akuity.io/v1alpha1
kind: Warehouse
metadata:
  name: ${SVC_NAME}
  namespace: ${KARGO_PROJECT}
spec:
  interval: 2m0s
  subscriptions:
    - image:
        repoURL: ${SVC_IMAGE}
        imageSelectionStrategy: Lexical
        discoveryLimit: 10
        # Harbor's certificate comes from the mesh's own kubara-local-ca.
        insecureSkipTLSVerify: true
---
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: ${SVC_STAGE}
  namespace: ${KARGO_PROJECT}
spec:
  requestedFreight:
    - origin:
        kind: Warehouse
        name: ${SVC_NAME}
      sources:
        direct: true
  promotionTemplate:
    spec:
      vars:
        - name: gitRepo
          value: $(gitops_url)
        - name: imageRepo
          value: ${SVC_IMAGE}
      steps:
        - uses: git-clone
          config:
            repoURL: \${{ vars.gitRepo }}
            insecureSkipTLSVerify: true
            checkout:
              - branch: main
                path: ./src
        - uses: yaml-update
          config:
            path: ./src/stages/dev/${SVC}/image.yaml
            updates:
              - key: image.tag
                value: \${{ imageFrom(vars.imageRepo).Tag }}
        - uses: git-commit
          config:
            path: ./src
            message: "promote ${SVC_STAGE}: ${SVC_NAME} \${{ imageFrom(vars.imageRepo).Tag }}"
        - uses: git-push
          config:
            path: ./src
EOF
    info "Stage ${SVC_STAGE}: auto-promotes new ${SVC_IMAGE} tags (git-only; Argo CD syncs)"
}

# ── test ─────────────────────────────────────────────────────────────────────
pass() { printf '    PASS %s\n' "$*"; }
fail() { printf '    FAIL %s\n' "$*" >&2; FAILED=$((FAILED + 1)); }

cmd_svc_test() {
    svc_def "$1"
    need_ca
    FAILED=0
    local i sync health ready code n groups token
    log "Testing ${SVC} (${SVC_APP}) on ${DEV_CTX}"

    # 1. Argo CD synced + healthy (up to 10 min: first pull, Flyway, Kafka join).
    for i in $(seq 1 120); do
        sync="$(kc "$HUB_CTX" -n argocd get application "$SVC_APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
        health="$(kc "$HUB_CTX" -n argocd get application "$SVC_APP" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
        [ "$sync" = Synced ] && [ "$health" = Healthy ] && break
        sleep 5
    done
    if [ "$sync" = Synced ] && [ "$health" = Healthy ]; then pass "Argo CD ${SVC_APP} Synced/Healthy"
    else fail "Argo CD ${SVC_APP} is ${sync:-?}/${health:-?}"; fi

    # 2. Pod ready: the readiness probe is /q/health/ready, which includes the
    #    datasource and Kafka health checks.
    ready="$(kc "$DEV_CTX" -n "$NS" get deploy "$SVC_NAME" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    if [ "${ready:-0}" -ge 1 ]; then pass "deployment ${SVC_NAME} ready (${ready}) - DB + Kafka health UP"
    else fail "deployment ${SVC_NAME} has no ready pod; see: kubectl -n ${NS} logs deploy/${SVC_NAME}"; fi

    # 3. Flyway migrated the service database.
    n="$(kc "$DEV_CTX" -n postgresql exec -i postgresql-0 -- env PGPASSWORD="${POSTGRES_PASSWORD:-}" \
        psql -h 127.0.0.1 -U postgres -d "$SVC_DB" -tAc \
        "SELECT count(*) FROM pg_tables WHERE tablename = 'flyway_schema_history'" 2>/dev/null | tr -d '[:space:]' || true)"
    if [ "${n:-0}" -ge 1 ]; then pass "Flyway history present in ${SVC_DB}"
    else fail "no flyway_schema_history in ${SVC_DB}"; fi

    # 4. The service joined Kafka (consumer group named after it), if it consumes.
    groups="$(kc "$DEV_CTX" -n kafka exec openbank-cluster-dual-role-0 -- \
        /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --list 2>/dev/null \
        | grep "^openbank-${SVC}-service" | tr '\n' ' ' || true)"
    if [ -n "$groups" ]; then pass "Kafka consumer group(s): ${groups}"
    else info "note: no Kafka consumer group openbank-${SVC}-service* (producer-only, or groups not committed yet)"; fi

    # 5. OIDC end to end through the ingress: no token -> 401; a token from the
    #    openbank realm (service account with the ROLE_* realm roles) -> 2xx.
    local auth_path="${SVC_AUTH_PATH:-$SVC_TEST_PATH}"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${SVC_HOST}${auth_path}" || true)"
    if [ "$code" = 401 ]; then pass "GET ${auth_path} without token -> 401"
    else fail "GET http://${SVC_HOST}${auth_path} without token -> ${code} (want 401)"; fi
    token="$(oidc_token || true)"
    if [ -z "$token" ]; then
        fail "no client-credentials token from realm ${OIDC_REALM}; run: just openbank-svc-keycloak"
    else
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
            -H "Authorization: Bearer ${token}" "http://${SVC_HOST}${SVC_TEST_PATH}" || true)"
        case "$code" in
            2??) pass "GET ${SVC_TEST_PATH} with token -> ${code}" ;;
            403) fail "GET ${SVC_TEST_PATH} with token -> 403 (token valid, role missing; re-run: just openbank-svc-keycloak)" ;;
            *)   fail "GET ${SVC_TEST_PATH} with token -> ${code}; see: kubectl -n ${NS} logs deploy/${SVC_NAME}" ;;
        esac
    fi

    [ "$FAILED" = 0 ] || die "${SVC}: ${FAILED} check(s) failed"
    log "${SVC}: all checks passed"
}

# Client-credentials token for openbank-services (secret read from the cluster).
oidc_token() {
    local secret
    secret="$(kc "$DEV_CTX" -n "$NS" get secret "$OIDC_SECRET" -o jsonpath='{.data.client-secret}' | base64 -d)"
    curl -fsS --cacert "$CA" "https://${KEYCLOAK}/realms/${OIDC_REALM}/protocol/openid-connect/token" \
        --data-urlencode grant_type=client_credentials --data-urlencode "client_id=${OIDC_CLIENT}" \
        --data-urlencode "client_secret=${secret}" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'
}

# ── deploy / status ──────────────────────────────────────────────────────────
cmd_svc_deploy() {
    local s="$1"
    cmd_svc_build "$s"; cmd_svc_image "$s"; cmd_svc_db "$s"; cmd_svc_gitops "$s"
    cmd_svc_argocd "$s"; cmd_svc_kargo "$s"; cmd_svc_test "$s"
}

cmd_svc_status() {
    local s
    log "Kargo stages (${PE_CTX})"
    kc "$PE_CTX" -n "$KARGO_PROJECT" get stages \
        -o custom-columns='STAGE:.metadata.name,FREIGHT:.status.freightSummary,HEALTH:.status.health.status' 2>&1 | sed 's/^/    /'
    log "Argo CD (${HUB_CTX})"
    for s in $OPENBANK_SERVICES; do
        svc_def "$s"
        kc "$HUB_CTX" -n argocd get application "$SVC_APP" --no-headers \
            -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null \
            | sed 's/^/    /' || printf '    %s (not deployed)\n' "$SVC_APP"
    done
    log "Pods (${DEV_CTX}, namespace ${NS})"
    kc "$DEV_CTX" -n "$NS" get pods -o wide 2>&1 | sed 's/^/    /'
}

case "${1:-}" in
    keycloak) cmd_keycloak ;;
    temporal) cmd_temporal ;;
    temporal-test) cmd_temporal_test ;;
    chart)    cmd_chart ;;
    build)    cmd_svc_build "${2:-}" ;;
    image)    cmd_svc_image "${2:-}" ;;
    db)       cmd_svc_db "${2:-}" ;;
    gitops)   cmd_svc_gitops "${2:-}" ;;
    argocd)   cmd_svc_argocd "${2:-}" ;;
    kargo)    cmd_svc_kargo "${2:-}" ;;
    test)     cmd_svc_test "${2:-}" ;;
    deploy)   cmd_svc_deploy "${2:-}" ;;
    status)   cmd_svc_status ;;
    list)     printf '%s\n' $OPENBANK_SERVICES ;;
    *) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
