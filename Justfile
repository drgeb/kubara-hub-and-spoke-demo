# Each kind cluster's traefik LoadBalancer IP is resolved explicitly instead of
# relying on the current kubectl context. Hub apps (argocd, homer, grafana,
# prometheus, alertmanager, openbao) live on the "hub" kind cluster; PLTFME
# (platform engineering: forgejo, kargo, harbor, nexus, keycloak, ...) on
# kubara-spoke-1; DEV apps on kubara-spoke-2.

KUBARA_KUBECONFIG:=".local/kind.kubeconfig"

MESH_DOCKER_NETWORK:="kubara-mesh"
MESH_DOCKER_SUBNET:="172.19.0.0/16"
MESH_DOCKER_GATEWAY:="172.19.0.1"
MESH_DOCKER_IP_RANGE:="172.19.0.10/28"

HUB_KIND:="hub"
SPOKE1_KIND:="kubara-spoke-1"
SPOKE2_KIND:="kubara-spoke-2"
DEV_KIND:="kubara-dev"
STAGING_KIND:="kubara-staging"
PROD_KIND:="kubara-prod"

HUB_CONTEXT:="kind-hub"
SPOKE1_CONTEXT:="kind-kubara-spoke-1"
SPOKE2_CONTEXT:="kind-kubara-spoke-2"
DEV_CONTEXT:="kind-kubara-dev"
STAGING_CONTEXT:="kind-kubara-staging"
PROD_CONTEXT:="kind-kubara-prod"

HUB_ID:="1"
SPOKE1_ID:="2"
SPOKE2_ID:="3"
DEV_ID:="4"
STAGING_ID:="5"
PROD_ID:="6"

HUB_NAME:="hub"
SPOKE1_NAME:="kubara-spoke-1"
SPOKE2_NAME:="kubara-spoke-2"
DEV_NAME:="kubara-dev"
STAGING_NAME:="kubara-staging"
PROD_NAME:="kubara-prod"

# Stable per-cluster DNS names. Resolved by the local dnsmasq wildcard setup
# in ./dnsmasq: <any>.<cluster>.kubara.test -> that cluster's traefik LB IP.
# Refresh the dnsmasq address= lines with `just -f dnsmasq/Justfile refresh-lb-hosts`.
HUB_DNS_NAME := "hub.kubara.test"
SPOKE1_DNS_NAME := "spoke-1.kubara.test"
SPOKE2_DNS_NAME := "spoke-2.kubara.test"
DEV_DNS_NAME := "dev.kubara.test"
STAGING_DNS_NAME := "staging.kubara.test"
PROD_DNS_NAME := "prod.kubara.test"

# Apply CoreDNS patch (hosts entries pinned to service ClusterIPs, see refresh-coredns-hosts)
apply-coredns-patch:
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl apply -f platform-components/coredns/coredns-configmap.yaml
    kubectl rollout restart deployment coredns -n kube-system
    echo "CoreDNS patched: hosts entries applied, coredns restarted"

# Re-render CoreDNS hosts entries from live service ClusterIPs and apply them.
# Run this after reinstalling traefik or nexus (their ClusterIPs change on recreation).
refresh-coredns-hosts:
    #!/usr/bin/env bash
    set -euo pipefail
    NEXUS_IP="$(kubectl get svc nexus -n nexus -o jsonpath='{.spec.clusterIP}')"
    TRAEFIK_IP="$(kubectl get svc traefik -n traefik -o jsonpath='{.spec.clusterIP}')"
    FILE="platform-components/coredns/coredns-configmap.yaml"
    cat > "$FILE" <<EOF
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: coredns
      namespace: kube-system
    data:
      Corefile: |
        .:53 {
            errors
            health {
               lameduck 5s
            }
            ready
            log
            hosts {
                ${NEXUS_IP} my.nexus.me
                ${TRAEFIK_IP} my.harbor.me
                fallthrough
            }
            kubernetes cluster.local in-addr.arpa ip6.arpa {
               pods insecure
               fallthrough in-addr.arpa ip6.arpa
               ttl 30
            }
            prometheus :9153
            forward . /etc/resolv.conf {
               max_concurrent 1000
            }
            cache 30 {
               disable success cluster.local
               disable denial cluster.local
            }
            loop
            reload
            loadbalance
        }
    EOF
    kubectl apply -f "$FILE"
    kubectl rollout restart deployment coredns -n kube-system
    kubectl rollout status deployment coredns -n kube-system --timeout=120s
    echo "CoreDNS hosts refreshed: my.nexus.me → ${NEXUS_IP} (svc/nexus), my.harbor.me → ${TRAEFIK_IP} (svc/traefik)"

# Run the default recipe (list)
default:
    @just list

# List all available recipes
list:
    @just --list

#You can check the image used by the current version of cloud-provider-kind running
list-images-cloud-provider-kind:
	@cloud-provider-kind list-images

check-nodes-running:
    docker ps --format "table {{"{{.Names}}"}}\t{{"{{.Status}}"}}"

export-loadbalancer-ip:
    @echo "LoadBalancer service was assigned an EXTERNAL-IP by cloud-provider-kind"
    @kubectl get svc/traefik -n traefik -o=jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Run kubara generate --helm and restore the charts kubara prunes from the
# repo-root platform-components/helm tree (template-library, harbor).
# Pass-through args are forwarded, e.g. just generate-helm --dry-run
generate-helm *args:
    ./z-demo-setup/scripts/generate-helm.sh {{args}}

# Create Kubernetes Secrets for platform services from .env credentials
create-platform-secrets:
    ./z-demo-setup/scripts/create-platform-secrets.sh

# Publish the Docker-internal spoke kubeconfigs to OpenBao so the hub
# ExternalSecrets can materialize the argocd cluster secrets.
setup-openbao-secrets:
    make -C z-demo-setup openbao-secrets

# Verify the spoke ExternalSecrets synced their OpenBao kubeconfigs into
# Kubernetes secrets and that the hub-argocd app is healthy.
verify-secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> Kubernetes secrets (argocd) =="
    kubectl --kubeconfig ${KUBARA_KUBECONFIG} --context ${HUB_CONTEXT} \
        get secrets -n argocd | grep -Ei 'spoke|dev|staging|prod' || echo "  (none found)"
    echo
    echo "==> ExternalSecrets status =="
    kubectl --kubeconfig ${KUBARA_KUBECONFIG} --context ${HUB_CONTEXT} \
        get externalsecret -n argocd
    echo
    echo "==> hub-argocd application =="
    kubectl --kubeconfig ${KUBARA_KUBECONFIG} --context ${HUB_CONTEXT} \
        get application hub-argocd -n argocd \
        -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

# Build the custom Liquibase Docker image with PostgreSQL driver
liquibase-build-image:
    docker build -t liquibase-bootstrap:local z-demo-setup/liquibase/

# Install bootstrap chart (creates PostgreSQL roles/databases)
liquibase-bootstrap:
    helm upgrade --install liquibase-bootstrap z-demo-setup/liquibase/bootstrap/ \
        --namespace postgresql --create-namespace \
        --kubeconfig {{ KUBARA_KUBECONFIG }} \
        --kube-context {{ SPOKE2_CONTEXT }} \
        --set "services[0].name=openproject" \
        --set "services[0].database=openproject" \
        --set "services[0].password=${OPENPROJECT_DB_PASSWORD}" \
        --set "services[0].passwordSecretName=openproject-postgresql" \
        --set "services[0].passwordSecretKey=password" \
        --set "services[1].name=keycloak" \
        --set "services[1].database=keycloak" \
        --set "services[1].password=${KEYCLOAK_DB_PASSWORD}" \
        --set "services[1].passwordSecretName=keycloak-credentials" \
        --set "services[1].passwordSecretKey=db-password" \
        --set "services[2].name=apicurio" \
        --set "services[2].database=apicurio" \
        --set "services[2].password=${APICURIO_DB_PASSWORD}" \
        --set "services[2].passwordSecretName=apicurio-credentials" \
        --set "services[2].passwordSecretKey=password" \
        --wait --timeout 5m

# Install all Liquibase migration charts (bootstrap + per-service)
liquibase-install: liquibase-build-image liquibase-bootstrap
    @for svc in openproject keycloak apicurio; do \
        echo "==> Installing liquibase-$${svc}"; \
        helm upgrade --install "liquibase-$${svc}" "z-demo-setup/liquibase/$${svc}/" \
            --namespace "$${svc}" --create-namespace \
            --kubeconfig {{ KUBARA_KUBECONFIG }} \
            --kube-context {{ SPOKE2_CONTEXT }} \
            --wait --timeout 5m; \
    done
    @echo "All Liquibase charts installed."

# Idempotent platform provisioning: seed secrets on all spokes, wait for
# postgres, then run liquibase bootstrap + per-service migrations per cluster.
# Safe to re-run (kubectl apply + helm upgrade + guarded SQL).
provision-platform:
    ./z-demo-setup/scripts/provision-platform.sh --refresh-local-kubeconfig

# Re-merge all six kind cluster kubeconfigs into ${KUBARA_KUBECONFIG}
refresh-kind-kubeconfig:
    ./z-demo-setup/scripts/provision-platform.sh --refresh-only

# Verify liquibase roles/databases exist on each spoke cluster
verify-liquibase:
    #!/usr/bin/env bash
    set -euo pipefail
    KCFG="{{ KUBARA_KUBECONFIG }}"
    ADMIN_PASS="${POSTGRES_PASSWORD:-}"
    if [[ -z "$ADMIN_PASS" ]]; then
        echo "POSTGRES_PASSWORD is not set — run 'direnv allow'" >&2
        exit 1
    fi
    declare -A SVC=(
        [${SPOKE1_CONTEXT}]="openproject keycloak apicurio"
        [${SPOKE2_CONTEXT}]="app"
        [${DEV_CONTEXT}]="app"
        [${STAGING_CONTEXT}]="app"
        [${PROD_CONTEXT}]="app"
    )
    for ctx in "${!SVC[@]}"; do
        for svc in ${SVC[$ctx]}; do
            role="$(kubectl --kubeconfig "$KCFG" --context "$ctx" exec postgresql-0 -n postgresql -- \
                bash -c "PGPASSWORD='$ADMIN_PASS' psql -U postgres -tAc \"SELECT rolname FROM pg_roles WHERE rolname='$svc'\"")" || true
            db="$(kubectl --kubeconfig "$KCFG" --context "$ctx" exec postgresql-0 -n postgresql -- \
                bash -c "PGPASSWORD='$ADMIN_PASS' psql -U postgres -tAc \"SELECT datname FROM pg_database WHERE datname='$svc'\"")" || true
            printf '%s/%s  role=%s db=%s\n' "$ctx" "$svc" "${role:-MISSING}" "${db:-MISSING}"
        done
    done

# Test the Kubernetes cluster connection and list namespaces
kubara-test-connection:
    kubara --test-connection

# Bootstrap the hub with kubara (--local), then re-pin the demo's *.kubara.test
# DNS names that kubara overwrites with <lb-ip>.traefik.me during bootstrap.
# Use `bootstrap-kubara-hub -- --skip-bootstrap` to only re-pin an existing setup.
bootstrap-kubara-hub:
    ./z-demo-setup/scripts/bootstrap-kubara-hub.sh

# Start the cloud-provider-kind (LBs are placed on the kubara-mesh network)
start-cloud-provider-kind:
    @if [ -f .cloud-provider-kind ] && kill -0 "$(cat .cloud-provider-kind)" 2>/dev/null; then \
      echo "cloud-provider-kind already running (pid $(cat .cloud-provider-kind))"; \
    elif pgrep -f cloud-provider-kind >/dev/null; then \
      echo "cloud-provider-kind already running (pid $(pgrep -f cloud-provider-kind | head -1))"; \
    else \
      echo "removing stale load balancers so they are recreated on the kubara-mesh network"; \
      docker rm -f $(docker ps -aq --filter label=io.x-k8s.cloud-provider-kind.cluster=hub) 2>/dev/null || true; \
      sudo -n env KIND_EXPERIMENTAL_DOCKER_NETWORK=kubara-mesh \
        nohup cloud-provider-kind > .cloud-provider-kind.log 2>&1 & \
      echo $! > .cloud-provider-kind; \
      echo "started cloud-provider-kind (pid $(cat .cloud-provider-kind)), logs in .cloud-provider-kind.log"; \
    fi

# Stop cloud-provider-kind
stop-cloud-provider-kind:
    @if [ -f .cloud-provider-kind ] && kill -0 "$(cat .cloud-provider-kind)" 2>/dev/null; then \
      pid="$(cat .cloud-provider-kind)"; \
      if sudo kill "$pid" && rm -f .cloud-provider-kind; then \
        echo "stopped cloud-provider-kind (pid $pid)"; \
      else \
        echo "failed to stop cloud-provider-kind"; \
        exit 1; \
      fi; \
    elif pgrep -f cloud-provider-kind >/dev/null; then \
      pids="$(pgrep -f cloud-provider-kind | tr '\n' ' ')"; \
      if sudo kill $pids; then \
        rm -f .cloud-provider-kind; \
        echo "stopped cloud-provider-kind (pids $pids)"; \
      else \
        echo "failed to stop cloud-provider-kind"; \
        exit 1; \
      fi; \
    else \
      echo "cloud-provider-kind is not running"; \
    fi

# Verify Argo CD is deployed and running after bootstrap
verify-argocd:
    kubectl get pods,svc -n argocd
    kubectl get applications -n argocd
    kubectl rollout status deploy/argocd-server -n argocd
    kubectl get events -n argocd --sort-by=.lastTimestamp

# Open the Hubble observability UI for every kind cluster
cilium-hubble-ui:
    #!/usr/bin/env bash
    set -euo pipefail
    port=12100
    for cluster in {{HUB_KIND}} {{SPOKE1_NAME}} {{SPOKE2_NAME}}; do
        echo "Opening Hubble UI for kind-$cluster on :$port"
        cilium hubble ui --context "kind-$cluster" --port-forward "$port" &
        port=$((port + 1))
    done
    wait

# Prune all Docker resources except images
docker-prune-images:
    docker container prune -f && docker network prune -f && docker volume prune -f && docker builder prune -f

# Stop all kind clusters (and their cloud-provider-kind load balancers) without deleting them
kind-stop:
    #!/usr/bin/env bash
    set -euo pipefail
    for cluster in {{HUB_KIND}} {{SPOKE1_NAME}} {{SPOKE2_NAME}}; do
        docker stop $(docker ps -qa --filter "label=io.x-k8s.kind.cluster=$cluster") $(docker ps -qa --filter "label=io.x-k8s.cloud-provider-kind.cluster=$cluster")
    done

# Restart all stopped kind clusters (containers, load balancers, and services come back)
kind-restart:
    #!/usr/bin/env bash
    set -euo pipefail
    for cluster in {{HUB_KIND}} {{SPOKE1_NAME}} {{SPOKE2_NAME}}; do
        docker start $(docker ps -aq --filter "label=io.x-k8s.kind.cluster=$cluster") $(docker ps -aq --filter "label=io.x-k8s.cloud-provider-kind.cluster=$cluster")
    done

kargo-cli-login:
    @: "${KARGO_ADMIN_PASSWORD:?not set - run 'direnv allow' to load .env}"
    @kargo login http://kargo.{{SPOKE1_DNS_NAME}} --admin --password "$KARGO_ADMIN_PASSWORD"

# Seed the go-hello delivery pipeline (Forgejo repo/CI, Harbor robot, Argo CD + Kargo)
# Safe to re-run; required again after `bring-up` recreates the cluster.
go-hello-setup:
    ./bin/setup-go-hello.sh

# Show go-hello pipeline status (Kargo freight/promotions + Argo CD app + deployment)
go-hello-verify:
    kubectl --kubeconfig ${KUBARA_KUBECONFIG} -n go-hello get warehouses,stages,freight,promotions
    kubectl --kubeconfig ${KUBARA_KUBECONFIG} -n argocd get application go-hello -o wide
    kubectl --kubeconfig ${KUBARA_KUBECONFIG} -n go-hello get deploy,pods

# Open the go-hello service
open-go-hello:
    @open http://go-hello.{{DEV_DNS_NAME}}/

# Curl the go-hello endpoint
go-hello-test:
    @curl http://go-hello.{{DEV_DNS_NAME}}/

# Seed the ebank delivery pipeline (Argo CD repo creds + AppProject/Applications)
# Safe to re-run; required again after `bring-up` recreates the cluster.
ebank-setup:
    ./bin/setup-ebank.sh

# Show ebank pipeline status (Kargo freight/promotions + Argo CD apps + deployment)
ebank-verify:
    kubectl --kubeconfig ${KUBARA_KUBECONFIG} -n ebank get warehouses,stages,freight,promotions
    kubectl --kubeconfig ${KUBARA_KUBECONFIG} -n argocd get application ebank-kargo ebank-dev ebank-staging ebank-prod -o wide
    kubectl --kubeconfig ${KUBARA_KUBECONFIG} -n ebank-simple-dev get deploy,pods

# Open the ebank service (pass staging or prod, default: dev)
open-ebank env="dev":
    @open http://ebank-simple-{{env}}.{{DEV_DNS_NAME}}/

# Open the kargo-simple guestbook app (pass staging or prod, default: dev)
open-kargo-simple env="dev":
    @open http://guestbook-simple-{{env}}.{{DEV_DNS_NAME}}/

open-portal:
    @echo "Opening Argo CD portal in the default browser..."
    @kubectl port-forward svc/argocd-server -n argocd 8080:443 &
    @sleep 5
    @open http://localhost:8080

# Open Argo CD UI
login-argo-cd:
    @echo user: ${ARGOCD_ADMIN_USER}
    @echo passwd: $ARGOCD_WIZARD_ACCOUNT_PASSWORD
    @echo $ARGOCD_WIZARD_ACCOUNT_PASSWORD | pbcopy
    argocd login {{HUB_DNS_NAME}} --grpc-web --grpc-web-root-path argocd --insecure

open-argo-cd:
    @echo user: ${ARGOCD_ADMIN_USER}
    @echo passwd: $ARGOCD_WIZARD_ACCOUNT_PASSWORD
    @echo $ARGOCD_WIZARD_ACCOUNT_PASSWORD | pbcopy
    @open https://{{HUB_DNS_NAME}}/argocd

# Open Homer dashboard
open-homer-dashboard:
    @echo user: 
    @echo passwd: 
    @open https://{{HUB_DNS_NAME}}/

# Open Grafana
open-grafana:
    @echo user: 
    @echo passwd: 
    @open https://{{HUB_DNS_NAME}}/grafana

# Open Prometheus
open-prometheus:
    @echo user: ${ARGOCD_ADMIN_USER}
    @echo passwd: ${ARGOCD_WIZARD_ACCOUNT_PASSWORD}
    @echo $ARGOCD_WIZARD_ACCOUNT_PASSWORD | pbcopy
    @open https://{{HUB_DNS_NAME}}/prometheus

# Open Alertmanager
open-alertmanager:
    @echo user: 
    @echo passwd: 
    @open https://{{HUB_DNS_NAME}}/alertmanager

# Open Uptime Kuma
open-uptime-kuma:
    @echo user: 
    @echo passwd: 
    @open https://uptime-kuma.{{DEV_DNS_NAME}}/

# Open Forgejo
open-forgejo:
    @echo user: ${FORGEJO_ADMIN_USER}
    @echo passwd: ${FORGEJO_ADMIN_PASSWORD}
    @echo $FORGEJO_ADMIN_PASSWORD | pbcopy
    @open https://forgejo.{{SPOKE1_DNS_NAME}}/

# Create the Forgejo repo for forgejo-build-image if missing, then push it
push-forgejo-build-image:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${FORGEJO_ADMIN_USER:?set in .env - run 'direnv allow'}"
    : "${FORGEJO_ADMIN_PASSWORD:?set in .env - run 'direnv allow'}"

    REPO_DIR="forgejo-build-image"
    REPO_NAME="$(basename "$REPO_DIR")"
    OWNER="$FORGEJO_ADMIN_USER"
    FORGEJO_URL="https://forgejo.{{SPOKE1_DNS_NAME}}"

    # "Push to create" is disabled for users on Forgejo, so create the repo first.
    status="$(curl -sk -o /dev/null -w '%{http_code}' \
        -u "$FORGEJO_ADMIN_USER:$FORGEJO_ADMIN_PASSWORD" \
        "$FORGEJO_URL/api/v1/repos/$OWNER/$REPO_NAME")"
    if [ "$status" = "404" ]; then
        echo ">> Creating Forgejo repo $OWNER/$REPO_NAME"
        curl -fskS -X POST \
            -u "$FORGEJO_ADMIN_USER:$FORGEJO_ADMIN_PASSWORD" \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"$REPO_NAME\",\"private\":false,\"default_branch\":\"main\"}" \
            "$FORGEJO_URL/api/v1/user/repos" >/dev/null
    fi

    git -C "$REPO_DIR" push --set-upstream origin HEAD

# Set HARBOR_USERNAME/HARBOR_PASSWORD secrets on the forgejo-build-image repo in Forgejo
set-forgejo-harbor-secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${FORGEJO_ADMIN_USER:?set in .env - run 'direnv allow'}"
    : "${FORGEJO_ADMIN_PASSWORD:?set in .env - run 'direnv allow'}"
    : "${HARBOR_ADMIN_USER:?set in .env - run 'direnv allow'}"
    : "${HARBOR_ADMIN_PASSWORD:?set in .env - run 'direnv allow'}"

    REPO_NAME="forgejo-build-image"
    OWNER="$FORGEJO_ADMIN_USER"
    FORGEJO_URL="https://forgejo.{{SPOKE1_DNS_NAME}}"
    AUTH=(-u "$FORGEJO_ADMIN_USER:$FORGEJO_ADMIN_PASSWORD" -H "Content-Type: application/json")

    api() {
        local name="$1" value="$2"
        curl -fskS "${AUTH[@]}" -X PUT -d "{\"data\":\"$value\"}" \
            "$FORGEJO_URL/api/v1/repos/$OWNER/$REPO_NAME/actions/secrets/$name" >/dev/null
        echo ">> set secret $name on $OWNER/$REPO_NAME"
    }

    api HARBOR_USERNAME "$HARBOR_ADMIN_USER"
    api HARBOR_PASSWORD "$HARBOR_ADMIN_PASSWORD"

# Open Bao (Vault) UI
open-bao:
    @echo user: 
    @echo passwd: 
    @open https://openbao.{{HUB_DNS_NAME}}/

# Open Harbor registry
open-harbor:
    @echo user: ${HARBOR_ADMIN_USER}
    @echo passwd: ${HARBOR_ADMIN_PASSWORD} 
    @echo ${HARBOR_ADMIN_PASSWORD} | pbcopy
    @open https://harbor.{{SPOKE1_DNS_NAME}}/

# Open Kargo
open-kargo:
    @echo user: ${KARGO_ADMIN_USER}
    @echo passwd: ${KARGO_ADMIN_PASSWORD}
    @echo ${KARGO_ADMIN_PASSWORD} | pbcopy
    @open https://kargo.{{SPOKE1_DNS_NAME}}/

# Open Nexus
open-nexus:
    @echo user: ${NEXUS_ADMIN_USER}
    @echo passwd: ${NEXUS_ADMIN_PASSWORD}
    @echo ${NEXUS_ADMIN_PASSWORD} | pbcopy
    @open https://nexus.{{SPOKE1_DNS_NAME}}/

open-keycloak:
    @echo user: ${KEYCLOAK_ADMIN_USER}
    @echo passwd: ${KEYCLOAK_ADMIN_PASSWORD}
    @echo ${KEYCLOAK_ADMIN_PASSWORD} | pbcopy
    @open https://keycloak.{{SPOKE1_DNS_NAME}}/

# Exec into the running postgres pod and open a psql shell
open-postgres-shell:
    @: "${APP_POSTGRES_PASSWORD:?not set - run 'direnv allow' to load .env}"
    kubectl exec -it postgresql-0 -n postgresql -- env "PGPASSWORD=$APP_POSTGRES_PASSWORD" psql -U app -d app

# Exec into the running postgres pod and open a psql shell
open-postgres19-shell:
    @: "${APP_POSTGRES_PASSWORD:?not set - run 'direnv allow' to load .env}"
    kubectl exec -it postgresql19-1 -n postgresql19 -- env "PGPASSWORD=$APP_POSTGRES_PASSWORD" psql -h 127.0.0.1 -U app -d app

inspect-what-certificate-Traefik-is-serving:
    @echo "Traefik is serving the following certificate:"
    echo | openssl s_client \
        -connect forgejo.{{SPOKE1_DNS_NAME}}:443 \
        -servername forgejo.{{SPOKE1_DNS_NAME}} \
        2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName

get-harbor-credentials:
    @kubectl get secret -n ebank harbor-creds -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d

pause-cluster:
    docker pause $(docker ps -q --filter label=io.x-k8s.kind.cluster=$PROJECT_NAME)

un-pause-cluster:
    docker unpause $(docker ps -q --filter label=io.x-k8s.kind.cluster=$PROJECT_NAME)


