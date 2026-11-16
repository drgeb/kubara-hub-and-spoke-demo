#!/usr/bin/env bash
# open-bank-oss.sh - build the OpenBank product catalog from ../apps/open-bank-oss
# and deliver it to kubara-dev through Harbor -> Kargo -> Argo CD.
#
# Usage: open-bank-oss.sh <step>   (Justfile.open-bank-oss wraps every step)
#
#   ca            fetch kubara-local-ca (issuer of Harbor/Forgejo/Keycloak certs)
#   trust-nodes   containerd on every demo kind node trusts Harbor via that CA
#   harbor        create the public Harbor project `openbank` (idempotent)
#   build         Gradle fast-jar of openbank-product-catalog (host JDK, warm cache)
#   image         docker build + skopeo push: harbor/openbank/product-catalog:kubara-<utc>-<sha>
#   db            role/database product_catalog on kubara-dev postgres + Secret
#   gitops        Forgejo repo openbank-gitops: chart copy + stages/dev/values.yaml
#   argocd        hub Argo CD: repo (local CA) + Application -> kubara-dev
#   kafka         OpenBank topics on kubara-dev's Kafka (kubara kafka chart) via gitops
#   kargo         Kargo Project, git credentials, Warehouse and dev Stage
#   status        freight, stage, Argo app and pods
#   test          wait for the catalog to answer on its ingress
#
# Why this shape (see also Justfile.open-bank-oss):
# - Why the product catalog: the README's full platform is 74 Quarkus services
#   on Kafka/Temporal/CNPG/...; the catalog is the one module upstream ships
#   for standalone use (PostgreSQL + any OIDC issuer, own Helm chart).
# - Kargo runs on kubara-platform-engineering but Argo CD runs on the hub and no
#   remote Argo CD kubeconfig is configured, so promotion is git-only: Kargo
#   commits the new tag to stages/dev/values.yaml and the hub's Argo CD
#   (automated sync) rolls it out. No argocd-update step.
# - Every endpoint uses the mesh's local CA; it is fetched live, never pinned.
#   No IP addresses anywhere (AGENTS.md): only *.kubara.test names.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/kind-demo-common.sh"
ROOT="$DEMO_REPO_ROOT"
SETUP="${ROOT}/z-demo-setup/open-bank-oss"

# ── Configuration (Justfile.open-bank-oss passes these; defaults match) ──────
KCFG="${KCFG:-${ROOT}/.local/kind.kubeconfig}"
OBO_SRC="${OBO_SRC:-$(cd "${ROOT}/.." && pwd)/apps/open-bank-oss}"
OBO_MODULE="${OBO_MODULE:-openbank-product-catalog}"
PE_DNS="${PE_DNS:-platform-engineering.kubara.test}"
DEV_DNS="${DEV_DNS:-dev.kubara.test}"
PE_CTX="${PE_CTX:-kind-kubara-platform-engineering}"
DEV_CTX="${DEV_CTX:-kind-kubara-dev}"
HUB_CTX="${HUB_CTX:-kind-hub}"
ARGO_DEST_CLUSTER="${ARGO_DEST_CLUSTER:-kubara-dev}"

HARBOR="harbor.${PE_DNS}"
FORGEJO="forgejo.${PE_DNS}"
KEYCLOAK="keycloak.${PE_DNS}"
HARBOR_PROJECT="openbank"
IMAGE_REPO="${HARBOR}/${HARBOR_PROJECT}/product-catalog"
GITOPS_REPO="openbank-gitops"
NS="openbank"
DB_NAME="product_catalog"
DB_USER="product_catalog"
DB_SECRET="catalog-database"
APP_HOST="product-catalog.${DEV_DNS}"
ARGO_APP="openbank-product-catalog-dev"
KARGO_PROJECT="openbank"

# Pushes the image to Harbor from a container (see cmd_image).
SKOPEO_IMAGE="${SKOPEO_IMAGE:-quay.io/skopeo/stable:v1.16.1}"

STATE="${ROOT}/.local/open-bank-oss"
CA="${STATE}/kubara-ca.crt"
mkdir -p "$STATE"
chmod 700 "$STATE"

log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
kc()   { local ctx="$1"; shift; kubectl --kubeconfig "$KCFG" --context "$ctx" "$@"; }
need() { local v; for v in "$@"; do [ -n "${!v:-}" ] || die "$v is not set (add it to .env and run 'direnv allow')"; done; }
# Print the live kubara-local-ca PEM (empty if the secret cannot be read).
live_ca() {
    local data
    data="$(kc "$PE_CTX" -n cert-manager get secret kubara-local-ca -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
    [ -n "$data" ] || data="$(kc "$PE_CTX" -n cert-manager get secret kubara-local-ca -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)"
    [ -n "$data" ] && printf '%s' "$data" | base64 -d
    return 0
}

# Ensure $CA matches the live mesh CA. A mesh rebuild regenerates
# kubara-local-ca, and a stale cached copy fails every TLS call with
# "unable to get local issuer certificate", so re-fetch when they differ.
need_ca() {
    local live
    live="$(live_ca)"
    if [ -z "$live" ]; then
        [ -s "$CA" ] || die "CA not fetched and kubara-local-ca unreadable on ${PE_CTX}; is the mesh up?"
        info "warning: cannot read live kubara-local-ca on ${PE_CTX}; using cached ${CA}"
        return 0
    fi
    if [ -s "$CA" ] && [ "$live" = "$(cat "$CA")" ]; then
        return 0
    fi
    if [ -s "$CA" ]; then
        log "Cached CA is stale (mesh CA was regenerated); re-fetching"
        info "re-run 'just openbank-trust-nodes' and 'just openbank-argocd' if they ran with the old CA"
    fi
    cmd_ca
}

# ── ca ───────────────────────────────────────────────────────────────────────
cmd_ca() {
    log "Fetching kubara-local-ca from ${PE_CTX}"
    local data
    data="$(live_ca)"
    [ -n "$data" ] || die "cannot read kubara-local-ca on ${PE_CTX}"
    printf '%s\n' "$data" > "$CA"
    openssl x509 -in "$CA" -noout -subject -enddate | sed 's/^/    /'
    curl -fsS --cacert "$CA" -o /dev/null "https://${HARBOR}/api/v2.0/ping" \
        || die "CA does not validate https://${HARBOR} - is the mesh up?"
    info "validates https://${HARBOR}"
}

# ── trust-nodes ──────────────────────────────────────────────────────────────
cmd_trust_nodes() {
    need_ca
    log "Trusting ${HARBOR} in containerd on every demo kind node"
    local dir="/etc/containerd/certs.d/${HARBOR}" node n=0
    for node in $(docker ps --filter label=io.x-k8s.kind.cluster --format '{{.Names}}'); do
        if ! docker exec "$node" grep -q 'config_path *= *"/etc/containerd/certs.d"' /etc/containerd/config.toml 2>/dev/null; then
            printf 'WARN: %s has no containerd config_path; rebuild the mesh to pull from Harbor\n' "$node" >&2
            continue
        fi
        docker exec -i "$node" sh -c "mkdir -p '$dir' && cat > '$dir/ca.crt'" < "$CA"
        docker exec -i "$node" sh -c "cat > '$dir/hosts.toml'" <<EOF
# Written by z-demo-setup/scripts/open-bank-oss.sh: Harbor's certificate is
# issued by the mesh's kubara-local-ca.
server = "https://${HARBOR}"

[host."https://${HARBOR}"]
  capabilities = ["pull", "resolve"]
  ca = "${dir}/ca.crt"
EOF
        n=$((n + 1))
    done
    info "configured ${n} node(s); containerd reads certs.d per pull (no restart)"
}

# ── harbor ───────────────────────────────────────────────────────────────────
cmd_harbor() {
    need HARBOR_ADMIN_USER HARBOR_ADMIN_PASSWORD; need_ca
    local code
    code="$(curl -sS --cacert "$CA" -u "${HARBOR_ADMIN_USER}:${HARBOR_ADMIN_PASSWORD}" -o /dev/null \
        -w '%{http_code}' -I "https://${HARBOR}/api/v2.0/projects?project_name=${HARBOR_PROJECT}")"
    if [ "$code" = 200 ]; then
        info "Harbor project ${HARBOR_PROJECT} exists"
        return 0
    fi
    log "Creating public Harbor project ${HARBOR_PROJECT}"
    curl -fsS --cacert "$CA" -u "${HARBOR_ADMIN_USER}:${HARBOR_ADMIN_PASSWORD}" \
        -H 'Content-Type: application/json' -X POST "https://${HARBOR}/api/v2.0/projects" \
        -d "{\"project_name\":\"${HARBOR_PROJECT}\",\"metadata\":{\"public\":\"true\"}}"
    info "created (public: kind nodes and Kargo pull without credentials)"
}

# ── build ────────────────────────────────────────────────────────────────────
cmd_build() {
    [ -x "${OBO_SRC}/gradlew" ] || die "open-bank-oss checkout not found at ${OBO_SRC} (set OBO_SRC)"
    log "Gradle fast-jar: ${OBO_MODULE} (in ${OBO_SRC})"
    # Upstream's own laptop path (openbank-infra/scripts/build-push-service.sh):
    # build quarkus-app/ on the host, never the in-image Gradle build.
    # Quarkus' codegen task expects build/classes/java/main, which this
    # Kotlin-only module never creates; it fails whenever codegen re-runs
    # (e.g. when the -D flags below change).
    mkdir -p "${OBO_SRC}/${OBO_MODULE}/build/classes/java/main"
    # quarkus.http.ssl.client-auth is BUILD-time: the module's %prod config
    # bakes in `required` (east-west mTLS for the OpenBank fleet). The
    # standalone profile has no TLS listener (TLS ends at the ingress), so a
    # baked-in `required` aborts startup with "Cannot set
    # quarkus.http.insecure-requests without enabling SSL". Build it off.
    (cd "$OBO_SRC" && ./gradlew ":${OBO_MODULE}:quarkusBuild" -Dquarkus.package.jar.type=fast-jar \
        -Dquarkus.http.ssl.client-auth=none -x test --console=plain -q)
    [ -f "${OBO_SRC}/${OBO_MODULE}/build/quarkus-app/quarkus-run.jar" ] || die "fast-jar not produced"
    info "built ${OBO_MODULE}/build/quarkus-app"
}

# ── image ────────────────────────────────────────────────────────────────────
cmd_image() {
    need HARBOR_ADMIN_USER HARBOR_ADMIN_PASSWORD; need_ca
    local qa="${OBO_SRC}/${OBO_MODULE}/build/quarkus-app"
    [ -f "${qa}/quarkus-run.jar" ] || die "no fast-jar; run: just openbank-build"

    local sha tag ctx arch host
    sha="$(git -C "$OBO_SRC" rev-parse --short HEAD)"
    git -C "$OBO_SRC" diff --quiet HEAD -- "$OBO_MODULE" openbank-libs 2>/dev/null || sha="${sha}-dirty"
    # Sortable tag: Kargo's Warehouse picks the lexically newest one.
    tag="kubara-$(date -u +%Y%m%d%H%M%S)-${sha}"
    arch="$(docker version -f '{{.Server.Arch}}')"

    ctx="${STATE}/image-context"
    rm -rf "$ctx"; mkdir -p "${ctx}/kubara"
    cp -R "$qa" "${ctx}/quarkus-app"
    cp "${SETUP}/kubara-image/application.yaml" "$CA" "${ctx}/kubara/"
    # Gradle writes quarkus-app with 600 perms; the image runs as non-root.
    chmod -R a+r "$ctx"
    # Upstream runtime recipe unchanged, plus one appended layer (same approach
    # as upstream's build-push-service.sh: copy their Dockerfile, append).
    { cat "${OBO_SRC}/${OBO_MODULE}/Dockerfile"; printf '\n# kubara: trust the mesh CA for OIDC\nCOPY kubara/ /app/config/\n'; } \
        > "${ctx}/Dockerfile"

    log "Building ${IMAGE_REPO}:${tag} (linux/${arch})"
    docker build -q --platform "linux/${arch}" -t "${IMAGE_REPO}:${tag}" "$ctx" >/dev/null

    # Push from inside a container with skopeo. Harbor's certificate comes from
    # the mesh's kubara-local-ca: Docker Desktop's daemon does not trust it (and
    # changing its insecure-registry list restarts Docker and every kind
    # cluster), and docker/buildx fetch registry tokens on macOS, which ignores
    # custom CA files. Inside a Linux container the CA and a one-off auth file
    # are plain mounts.
    log "Pushing to ${HARBOR}"
    local push="${STATE}/push"
    rm -rf "$push"; mkdir -p "${push}/certs"; chmod 700 "$push"
    trap 'rm -rf "'"$push"'"' RETURN
    cp "$CA" "${push}/certs/ca.crt"
    printf '{"auths":{"%s":{"auth":"%s"}}}\n' "$HARBOR" \
        "$(printf '%s:%s' "$HARBOR_ADMIN_USER" "$HARBOR_ADMIN_PASSWORD" | base64 | tr -d '\n')" \
        > "${push}/auth.json"
    chmod 644 "${push}/auth.json"   # read by the container's user; dir stays 700
    docker save -o "${push}/image.tar" "${IMAGE_REPO}:${tag}"
    chmod 644 "${push}/image.tar"
    docker run --rm -v "${push}:/work:ro" "$SKOPEO_IMAGE" copy -q \
        --authfile /work/auth.json --dest-cert-dir /work/certs \
        "docker-archive:/work/image.tar" "docker://${IMAGE_REPO}:${tag}"

    curl -fsS --cacert "$CA" -o /dev/null \
        "https://${HARBOR}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/product-catalog/artifacts/${tag}" \
        || die "push not visible in Harbor"
    printf '%s\n' "$tag" > "${STATE}/last-tag"
    info "pushed ${IMAGE_REPO}:${tag}"
}

# ── db ───────────────────────────────────────────────────────────────────────
cmd_db() {
    need POSTGRES_PASSWORD OPENBANK_CATALOG_DB_PASSWORD
    log "Database ${DB_NAME} on ${DEV_CTX}"
    local pw="${OPENBANK_CATALOG_DB_PASSWORD//\'/\'\'}"
    kc "$DEV_CTX" -n postgresql exec -i postgresql-0 -- env PGPASSWORD="$POSTGRES_PASSWORD" \
        psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U postgres -q <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE ROLE ${DB_USER} LOGIN PASSWORD '${pw}';
  ELSE
    ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD '${pw}';
  END IF;
END \$\$;
SELECT 'CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')\gexec
SQL
    info "role + database ready"
    kc "$DEV_CTX" create namespace "$NS" --dry-run=client -o yaml | kc "$DEV_CTX" apply -f - >/dev/null
    kc "$DEV_CTX" -n "$NS" create secret generic "$DB_SECRET" \
        --from-literal=username="$DB_USER" --from-literal=password="$OPENBANK_CATALOG_DB_PASSWORD" \
        --dry-run=client -o yaml | kc "$DEV_CTX" apply -f - >/dev/null
    info "secret ${NS}/${DB_SECRET} applied"
}

# ── gitops ───────────────────────────────────────────────────────────────────
forgejo_api() {
    curl -sS --cacert "$CA" -u "${FORGEJO_ADMIN_USER}:${FORGEJO_ADMIN_PASSWORD}" \
        -H 'Content-Type: application/json' "$@"
}

cmd_gitops() {
    need FORGEJO_ADMIN_USER FORGEJO_ADMIN_PASSWORD; need_ca
    local owner="$FORGEJO_ADMIN_USER" code tag
    tag="$(cat "${STATE}/last-tag" 2>/dev/null || true)"
    [ -n "$tag" ] || die "no image pushed yet; run: just openbank-image"

    code="$(forgejo_api -o /dev/null -w '%{http_code}' "https://${FORGEJO}/api/v1/repos/${owner}/${GITOPS_REPO}")"
    if [ "$code" = 404 ]; then
        log "Creating Forgejo repo ${owner}/${GITOPS_REPO} (public: Argo CD reads it anonymously)"
        forgejo_api -f -o /dev/null -X POST "https://${FORGEJO}/api/v1/user/repos" \
            -d "{\"name\":\"${GITOPS_REPO}\",\"private\":false,\"default_branch\":\"main\"}"
    fi
    # Forgejo flags a repo with no commits as "empty": true (its branches
    # endpoint returns null, not []).
    if ! forgejo_api "https://${FORGEJO}/api/v1/repos/${owner}/${GITOPS_REPO}" \
            | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("empty") else 1)'; then
        info "${owner}/${GITOPS_REPO} already seeded; Kargo owns stages/*/values.yaml from here"
        return 0
    fi

    log "Seeding ${owner}/${GITOPS_REPO} (chart + dev stage at ${tag})"
    local w="${STATE}/gitops-seed"
    rm -rf "$w"; mkdir -p "${w}/charts" "${w}/stages/dev"
    cp -R "${OBO_SRC}/${OBO_MODULE}/helm/product-catalog" "${w}/charts/product-catalog"
    cp -R "${SETUP}/chart-additions/." "${w}/charts/product-catalog/"
    # Allow the additive `ingress` values block in the copy's strict schema.
    python3 - "${w}/charts/product-catalog/values.schema.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
s["properties"]["ingress"] = {
    "type": "object", "additionalProperties": False,
    "description": "kubara addition: optional Ingress (templates/ingress.yaml)",
    "properties": {"enabled": {"type": "boolean"}, "className": {"type": "string"},
                   "host": {"type": "string"}, "annotations": {"type": "object"}}}
json.dump(s, open(p, "w"), indent=2); open(p, "a").write("\n")
PY
    cat > "${w}/stages/dev/values.yaml" <<EOF
# kubara-dev stage of the OpenBank product catalog.
# Kargo's "dev" Stage rewrites image.tag on every promotion; edit the rest here.
replicaCount: 1
image:
  repository: ${IMAGE_REPO}
  tag: ${tag}
oidc:
  issuer: https://${KEYCLOAK}/realms/master
database:
  host: postgresql.postgresql.svc.cluster.local
  name: ${DB_NAME}
  existingSecret: ${DB_SECRET}
ingress:
  enabled: true
  className: cilium
  host: ${APP_HOST}
EOF
    cat > "${w}/README.md" <<EOF
# openbank-gitops

Desired state for the OpenBank product catalog in the kubara demo.

- \`charts/product-catalog/\`: upstream chart from open-bank-oss
  (\`${OBO_MODULE}/helm/product-catalog\`) plus the additive
  \`templates/ingress.yaml\` and an \`ingress\` schema entry.
- \`stages/<stage>/values.yaml\`: per-stage values. Kargo promotes freight by
  rewriting \`image.tag\`; the hub's Argo CD syncs each stage.

Seeded by \`just openbank-gitops\` (kubara-hub-and-spoke-demo).
EOF
    (
        cd "$w"
        git init -q -b main
        git add -A
        git -c user.name="kubara demo" -c user.email="kubara-demo@${PE_DNS}" commit -q -m "seed: product-catalog chart and dev stage (${tag})"
        gitops_git push -q "$(gitops_url)" main
    )
    info "pushed https://${FORGEJO}/${owner}/${GITOPS_REPO}"
}

gitops_url() { printf 'https://%s/%s/%s.git' "$FORGEJO" "$FORGEJO_ADMIN_USER" "$GITOPS_REPO"; }

# git against Forgejo: verify TLS with the mesh CA, credentials via askpass
# (never in a URL or argv).
gitops_git() {
    local askpass="${STATE}/git-askpass.sh"
    printf '#!/bin/sh\ncase "$1" in Username*) echo "$FORGEJO_ADMIN_USER";; *) echo "$FORGEJO_ADMIN_PASSWORD";; esac\n' > "$askpass"
    chmod 700 "$askpass"
    GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 git -c http.sslCAInfo="$CA" -c credential.helper= "$@"
}

# Commit files into the (already seeded) openbank-gitops repo. Kargo commits
# there too, so always start from a fresh clone of main. <repo-path> is
# replaced wholesale: files no longer passed are deleted from the repo.
#   gitops_commit <message> <repo-path> <local-file>...
gitops_commit() {
    local msg="$1" dest="$2"; shift 2
    local w="${STATE}/gitops-work"
    rm -rf "$w"
    gitops_git clone -q "$(gitops_url)" "$w"
    rm -rf "${w:?}/${dest:?}"
    mkdir -p "${w}/${dest}"
    cp "$@" "${w}/${dest}/"
    (
        cd "$w"
        git add -A
        if git diff --cached --quiet; then
            info "${dest} already up to date in ${GITOPS_REPO}"
            exit 0
        fi
        git -c user.name="kubara demo" -c user.email="kubara-demo@${PE_DNS}" commit -q -m "$msg"
        gitops_git push -q origin main
        info "committed ${dest} to ${GITOPS_REPO}"
    )
}

# ── argocd (hub) ─────────────────────────────────────────────────────────────
cmd_argocd() {
    need FORGEJO_ADMIN_USER; need_ca
    local repo="https://${FORGEJO}/${FORGEJO_ADMIN_USER}/${GITOPS_REPO}.git"
    log "Argo CD on ${HUB_CTX}: repository + Application ${ARGO_APP}"
    # Trust the mesh CA for Forgejo instead of `insecure: true`.
    kc "$HUB_CTX" -n argocd create configmap argocd-tls-certs-cm --dry-run=client -o yaml >/dev/null
    kc "$HUB_CTX" -n argocd patch configmap argocd-tls-certs-cm --type merge \
        -p "$(python3 -c 'import json,sys; print(json.dumps({"data": {sys.argv[1]: open(sys.argv[2]).read()}}))' "$FORGEJO" "$CA")" >/dev/null
    kc "$HUB_CTX" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-openbank-gitops
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${repo}
---
# kubara locks the default project down (no repos/destinations), so the app
# gets its own project scoped to exactly this repo and namespace.
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: openbank
  namespace: argocd
spec:
  description: OpenBank on kubara-dev (Justfile.open-bank-oss)
  sourceRepos:
    - ${repo}
  destinations:
    - name: ${ARGO_DEST_CLUSTER}
      namespace: ${NS}
    # OpenBank's Kafka, run by kubara's Strimzi operator (kafka namespace).
    - name: ${ARGO_DEST_CLUSTER}
      namespace: kafka
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${ARGO_APP}
  namespace: argocd
spec:
  project: openbank
  source:
    repoURL: ${repo}
    targetRevision: main
    path: charts/product-catalog
    helm:
      releaseName: product-catalog
      valueFiles:
        - ../../stages/dev/values.yaml
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
    info "Application ${ARGO_APP} -> cluster ${ARGO_DEST_CLUSTER}, namespace ${NS}"
}

# ── kafka (kubara-dev) ───────────────────────────────────────────────────────
# The Kafka cluster itself is kubara's: the `kafka` service (enabled for
# kubara-dev in config.yaml) runs the Strimzi operator and, via
# platform-configs/kubara-dev/helm/kafka/values-custom.yaml (kafkaInstance),
# the openbank-cluster broker. This step only adds upstream's topics through
# the gitops repo, synced by the hub's Argo CD like the catalog.
cmd_kafka() {
    need FORGEJO_ADMIN_USER FORGEJO_ADMIN_PASSWORD; need_ca
    log "Waiting for kubara's Kafka openbank-cluster on ${DEV_CTX} (kafka service + values-custom.yaml)"
    local i
    for i in $(seq 1 60); do
        kc "$DEV_CTX" -n kafka get kafka openbank-cluster >/dev/null 2>&1 && break
        [ "$i" = 60 ] && die "no Kafka openbank-cluster in kafka namespace on ${DEV_CTX}: is kafka enabled for $(printf '%s' "$ARGO_DEST_CLUSTER") in config.yaml and platform-configs/kubara-dev/helm/kafka/values-custom.yaml pushed to main?"
        sleep 5
    done

    # Upstream's explicit topics, re-homed to the operator's namespace. The
    # cluster name (openbank-cluster) matches upstream, so the
    # strimzi.io/cluster labels stay as they are.
    local topics="${STATE}/topics.yaml"
    python3 - "${OBO_SRC}/openbank-infra/gitops/components/kafka/kafka.yaml" > "$topics" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "KafkaTopic"]
for d in docs:
    d["metadata"]["namespace"] = "kafka"
print("# Generated from open-bank-oss openbank-infra/gitops/components/kafka/kafka.yaml")
print(yaml.safe_dump_all(docs, sort_keys=False), end="")
PY
    log "Committing platform/kafka to ${GITOPS_REPO}"
    gitops_commit "kafka: upstream topics for kubara's openbank-cluster" platform/kafka "$topics"

    kc "$HUB_CTX" apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: openbank-kafka-dev
  namespace: argocd
spec:
  project: openbank
  source:
    repoURL: $(gitops_url)
    targetRevision: main
    path: platform/kafka
  destination:
    name: ${ARGO_DEST_CLUSTER}
    namespace: kafka
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 10
      backoff:
        duration: 30s
        maxDuration: 5m
EOF
    kc "$HUB_CTX" -n argocd annotate application openbank-kafka-dev argocd.argoproj.io/refresh=normal --overwrite >/dev/null
    log "Waiting for Kafka openbank-cluster to be Ready (first image pull + KRaft start)"
    for i in $(seq 1 90); do
        [ "$(kc "$DEV_CTX" -n kafka get kafka openbank-cluster -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] && break
        [ "$i" = 90 ] && die "Kafka not Ready after 15 min; see: kubectl -n kafka get kafka,pods (context ${DEV_CTX})"
        sleep 10
    done
    info "Kafka Ready; bootstrap openbank-cluster-kafka-bootstrap.kafka.svc:9092"
    kc "$DEV_CTX" -n kafka get kafkatopics --no-headers 2>/dev/null | awk '{print $1, "ready=" $NF}' | sed 's/^/    topic /'
}

# ── kargo (platform-engineering) ─────────────────────────────────────────────
cmd_kargo() {
    need FORGEJO_ADMIN_USER FORGEJO_ADMIN_PASSWORD
    local repo="https://${FORGEJO}/${FORGEJO_ADMIN_USER}/${GITOPS_REPO}.git"
    log "Kargo on ${PE_CTX}: project ${KARGO_PROJECT}"
    kc "$PE_CTX" apply -f - >/dev/null <<EOF
apiVersion: kargo.akuity.io/v1alpha1
kind: Project
metadata:
  name: ${KARGO_PROJECT}
EOF
    # The Project controller creates the namespace asynchronously.
    local i
    for i in $(seq 1 30); do kc "$PE_CTX" get ns "$KARGO_PROJECT" >/dev/null 2>&1 && break; sleep 2; done
    kc "$PE_CTX" apply -f - >/dev/null <<EOF
apiVersion: kargo.akuity.io/v1alpha1
kind: ProjectConfig
metadata:
  name: ${KARGO_PROJECT}
  namespace: ${KARGO_PROJECT}
spec:
  promotionPolicies:
    - stageSelector:
        name: dev
      autoPromotionEnabled: true
---
apiVersion: v1
kind: Secret
metadata:
  name: openbank-gitops-creds
  namespace: ${KARGO_PROJECT}
  labels:
    kargo.akuity.io/cred-type: git
stringData:
  repoURL: ${repo}
  username: ${FORGEJO_ADMIN_USER}
  password: ${FORGEJO_ADMIN_PASSWORD}
---
apiVersion: kargo.akuity.io/v1alpha1
kind: Warehouse
metadata:
  name: product-catalog
  namespace: ${KARGO_PROJECT}
spec:
  interval: 2m0s
  subscriptions:
    - image:
        repoURL: ${IMAGE_REPO}
        imageSelectionStrategy: Lexical
        discoveryLimit: 10
        # Harbor's certificate comes from the mesh's own kubara-local-ca.
        insecureSkipTLSVerify: true
---
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: dev
  namespace: ${KARGO_PROJECT}
spec:
  requestedFreight:
    - origin:
        kind: Warehouse
        name: product-catalog
      sources:
        direct: true
  promotionTemplate:
    spec:
      vars:
        - name: gitRepo
          value: ${repo}
        - name: imageRepo
          value: ${IMAGE_REPO}
      steps:
        - uses: git-clone
          config:
            repoURL: \${{ vars.gitRepo }}
            insecureSkipTLSVerify: true
            checkout:
              - branch: main
                path: ./src
        - uses: yaml-update
          as: update-image
          config:
            path: ./src/stages/dev/values.yaml
            updates:
              - key: image.tag
                value: \${{ imageFrom(vars.imageRepo).Tag }}
        - uses: git-commit
          as: commit
          config:
            path: ./src
            message: "promote dev: product-catalog \${{ imageFrom(vars.imageRepo).Tag }}"
        - uses: git-push
          config:
            path: ./src
EOF
    info "Warehouse product-catalog (${IMAGE_REPO}) -> Stage dev (auto-promotion, git-only)"
}

# ── status / test ────────────────────────────────────────────────────────────
cmd_status() {
    log "Kargo (${PE_CTX})"
    kc "$PE_CTX" -n "$KARGO_PROJECT" get warehouses,stages 2>&1 | sed 's/^/    /'
    kc "$PE_CTX" -n "$KARGO_PROJECT" get freight --sort-by=.metadata.creationTimestamp \
        -o custom-columns='FREIGHT:.alias,IMAGE:.images[0].tag,CREATED:.metadata.creationTimestamp' 2>&1 | tail -4 | sed 's/^/    /'
    kc "$PE_CTX" -n "$KARGO_PROJECT" get promotions --sort-by=.metadata.creationTimestamp \
        -o custom-columns='PROMOTION:.metadata.name,PHASE:.status.phase,MESSAGE:.status.message' 2>&1 | tail -3 | sed 's/^/    /'
    log "Argo CD (${HUB_CTX})"
    kc "$HUB_CTX" -n argocd get application "$ARGO_APP" \
        -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision' 2>&1 | sed 's/^/    /'
    log "Kafka (${DEV_CTX})"
    kc "$DEV_CTX" -n kafka get kafka,kafkanodepool,pods 2>&1 | sed 's/^/    /'
    log "Workload (${DEV_CTX})"
    kc "$DEV_CTX" -n "$NS" get pods,ingress -o wide 2>&1 | sed 's/^/    /'
}

cmd_test() {
    log "Waiting for http://${APP_HOST}/ (up to 10 min: first pull + Flyway migrations)"
    local i code
    for i in $(seq 1 120); do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${APP_HOST}/api/v2/product-types" || true)"
        case "$code" in
            200|401|403)
                info "catalog answers (${code} on /api/v2/product-types; 401/403 = up, bearer token required)"
                return 0 ;;
        esac
        sleep 5
    done
    die "no answer from http://${APP_HOST}/ (last code ${code}); see: just openbank-status"
}

case "${1:-}" in
    ca) cmd_ca ;;
    trust-nodes) cmd_trust_nodes ;;
    harbor) cmd_harbor ;;
    build) cmd_build ;;
    image) cmd_image ;;
    db) cmd_db ;;
    gitops) cmd_gitops ;;
    argocd) cmd_argocd ;;
    kafka) cmd_kafka ;;
    kargo) cmd_kargo ;;
    status) cmd_status ;;
    test) cmd_test ;;
    *) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
