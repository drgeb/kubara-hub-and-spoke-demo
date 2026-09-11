# Each kind cluster's traefik LoadBalancer IP is resolved explicitly instead of
# relying on the current kubectl context. Hub apps (argocd, homer, grafana,
# prometheus, alertmanager, openbao) live on kind-hub; PLTFME (platform
# engineering: forgejo, kargo, harbor, nexus, keycloak, ...) on
# kind-kubara-spoke-1; DEV apps on kind-kubara-spoke-2.
HUB_LB_ADDR := `kubectl --kubeconfig .local/kind.kubeconfig --context kind-hub get svc/traefik -n traefik -o=jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true`
PLTFME_LB_ADDR := `kubectl --kubeconfig .local/kind.kubeconfig --context kind-kubara-spoke-1 get svc/traefik -n traefik -o=jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true`
DEV_LB_ADDR := `kubectl --kubeconfig .local/kind.kubeconfig --context kind-kubara-spoke-2 get svc/traefik -n traefik -o=jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true`
CLUSTER_NAME := "test-cluster"
HUB_DNS_NAME := HUB_LB_ADDR + ".traefik.me"
PLTFME_DNS_NAME := PLTFME_LB_ADDR + ".traefik.me"
DEV_DNS_NAME := DEV_LB_ADDR + ".traefik.me"

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

step-0-init-prep:
    kubara init --prep
    @echo analyze the .env template and edit it to your liking, then run `just step-0-2-init-local` to continue

step-0-2-init-local:
    kubara init --env .env.local
    @echo "kubara config initialized for local-only cluster profile, then run `just step-1-kubara-generate` to continue"

step-1-kubara-generate:
    kubara generate --env .env.local
    @echo "kubara config generated for local-only cluster profile, then run `just step-2-kubara-bootstrap` to continue"

step-2-kubara-bootstrap:
    kubara bootstrap control-plane --with-es-css-file clustersecretstore.yaml --with-es-crds --
    kubectl k8s.yml --env-file .env.local
    @echo "kubara bootstrap complete, then run `just step-3-verify-argocd` to continue"
    
# Run kubara generate --helm and restore the charts kubara prunes from the
# repo-root platform-components/helm tree (template-library, harbor).
# Pass-through args are forwarded, e.g. just generate-helm --dry-run
generate-helm *args:
    ./z-demo-setup/scripts/generate-helm.sh {{args}}

# Initialize kubara config with local-evaluation prep files (.env template)
init-prep:
    kubara init --prep --local

# Initialize kubara config for a local-only cluster profile
kubara-init-local:
    kubara init --local

# Bootstrap Argo CD onto the local {{CLUSTER_NAME}}
kubara-bootstrap-local:
    kubara bootstrap --local {{CLUSTER_NAME}}

# Bootstrap Argo CD onto the local {{CLUSTER_NAME}} using a local catalog fix
kubara-bootstrap-local-catalog:
    kubara bootstrap --local {{CLUSTER_NAME}} --catalog .local-catalog-fix --catalog-overwrite

# Test the Kubernetes cluster connection and list namespaces
kubara-test-connection:
    kubara --test-connection

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

# Create the local kind cluster using Cilium (disables the default kindnet CNI)
kind-cluster-create-cilium:
    kind create cluster --name {{CLUSTER_NAME}} --config kind-config-cilium.yaml

# Delete the local kind cluster (destroys all local workloads and data)
kind-cluster-delete:
    kind delete cluster --name {{CLUSTER_NAME}}

# Install Cilium (CNI + kube-proxy replacement + Hubble) on the kind cluster
cilium-install:
    cilium install --context kind-{{CLUSTER_NAME}} -f cilium-values.yaml
    cilium status --wait --context kind-{{CLUSTER_NAME}}

# Uninstall Cilium from the kind cluster
cilium-uninstall:
    cilium uninstall --context kind-{{CLUSTER_NAME}}

# Run the Cilium connectivity test suite
cilium-connectivity-test:
    cilium connectivity test --context kind-{{CLUSTER_NAME}}

# Open the Hubble observability UI
cilium-hubble-ui:
    cilium hubble ui --context kind-{{CLUSTER_NAME}}

# Bootstrap the local platform on a kind cluster using Cilium as the CNI
bootstrap-local-cilium:
    #!/usr/bin/env bash
    if ! kind get clusters 2>/dev/null | grep -q "^{{CLUSTER_NAME}}$"; then
        kind create cluster --name {{CLUSTER_NAME}} --config kind-config-cilium.yaml
    else
        echo "Reusing existing kind cluster: {{CLUSTER_NAME}}"
    fi
    cilium install --context kind-{{CLUSTER_NAME}} -f cilium-values.yaml
    cilium status --wait --context kind-{{CLUSTER_NAME}}
    kubara bootstrap --local {{CLUSTER_NAME}}

# Regenerate the local kubeconfig for the kind cluster
regenerate-local-kubeconfig:
    kind get kubeconfig --name {{CLUSTER_NAME}} > .local/kind.kubeconfig
    echo "Regenerated local kubeconfig for kind cluster: {{CLUSTER_NAME}}"

# Bring the whole platform back up after kind delete cluster {{CLUSTER_NAME}}
bring-up:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! kind get clusters 2>/dev/null | grep -q "^{{CLUSTER_NAME}}$"; then
        kind create cluster --name {{CLUSTER_NAME}} --config kind-config-cilium.yaml
    else
        echo "Reusing existing kind cluster: {{CLUSTER_NAME}}"
    fi
    kind get kubeconfig --name {{CLUSTER_NAME}} > .local/kind.kubeconfig
    if ! kubectl get daemonset cilium -n kube-system --context kind-{{CLUSTER_NAME}} >/dev/null 2>&1; then
        cilium install --context kind-{{CLUSTER_NAME}} -f cilium-values.yaml
    else
        echo "Reusing existing Cilium installation"
    fi
    cilium status --wait --context kind-{{CLUSTER_NAME}}
    # kubara bootstrap --local rewrites config.yaml: it updates the cluster
    # dnsName to the LoadBalancer IP of this cluster but forces every service to
    # disabled except its fixed local whitelist. Merge the bootstrapped config
    # back with the pre-bootstrap config so the user's service statuses and the
    # freshly discovered LoadBalancer IP are both kept.
    cp config.yaml .local/config.yaml.pre-bootstrap
    kubara bootstrap --local {{CLUSTER_NAME}} --catalog .local-catalog-fix --catalog-overwrite
    python3 scripts/merge-config.py config.yaml .local/config.yaml.pre-bootstrap
    kubara generate --helm --catalog .local-catalog-fix --catalog-overwrite
    # Render the runtime-discovered LoadBalancer IPs (forgejo SSH pin, traefik
    # dashboard, argo-cd url) into the hand-maintained additional-values files.
    ./scripts/render-runtime-config.sh
    # kubara bootstrap re-writes kube-prometheus-stack values-additional.yaml with
    # a 384Mi prometheus limit that OOM-kills the pod; raise it after generate.
    yq -iy '."kube-prometheus-stack".prometheus.prometheusSpec.resources.requests.memory = "1Gi" | ."kube-prometheus-stack".prometheus.prometheusSpec.resources.limits.memory = "1Gi"' platform-configs/{{CLUSTER_NAME}}/helm/kube-prometheus-stack/values-additional.yaml
    echo ""
    echo "==> Waiting for Argo CD to sync all applications"
    until kubectl get application -n argocd >/dev/null 2>&1; do sleep 5; done
    kubectl wait --timeout=5m --for=jsonpath='{.status.health.status}'=Healthy application -n argocd --all
    @just apply-coredns-patch

# Prune all Docker resources except images
docker-prune-images:
    docker container prune -f && docker network prune -f && docker volume prune -f && docker builder prune -f

docker-restart:
    docker restart {{CLUSTER_NAME}}-control-plane 2>&1

# Stop the kind cluster (and its cloud-provider-kind load balancers) without deleting it
kind-stop:
    docker stop $(docker ps -qa --filter "label=io.x-k8s.kind.cluster={{CLUSTER_NAME}}") $(docker ps -qa --filter "label=io.x-k8s.cloud-provider-kind.cluster={{CLUSTER_NAME}}")

# Restart a stopped kind cluster (containers, load balancers, and services come back)
kind-restart:
    docker start $(docker ps -aq --filter "label=io.x-k8s.kind.cluster={{CLUSTER_NAME}}") $(docker ps -aq --filter "label=io.x-k8s.cloud-provider-kind.cluster={{CLUSTER_NAME}}")

kargo-cli-login:
    @: "${KARGO_ADMIN_PASSWORD:?not set - run 'direnv allow' to load .env}"
    @kargo login http://kargo.{{PLTFME_DNS_NAME}} --admin --password "$KARGO_ADMIN_PASSWORD"

# Seed the go-hello delivery pipeline (Forgejo repo/CI, Harbor robot, Argo CD + Kargo)
# Safe to re-run; required again after `bring-up` recreates the cluster.
go-hello-setup:
    ./bin/setup-go-hello.sh

# Show go-hello pipeline status (Kargo freight/promotions + Argo CD app + deployment)
go-hello-verify:
    kubectl --kubeconfig .local/kind.kubeconfig -n go-hello get warehouses,stages,freight,promotions
    kubectl --kubeconfig .local/kind.kubeconfig -n argocd get application go-hello -o wide
    kubectl --kubeconfig .local/kind.kubeconfig -n go-hello get deploy,pods

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
    kubectl --kubeconfig .local/kind.kubeconfig -n ebank get warehouses,stages,freight,promotions
    kubectl --kubeconfig .local/kind.kubeconfig -n argocd get application ebank-kargo ebank-dev ebank-staging ebank-prod -o wide
    kubectl --kubeconfig .local/kind.kubeconfig -n ebank-simple-dev get deploy,pods

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

# Open Argo CD UI (hub)
open-argo-cd:
    @echo user: wizard
    @echo passwd: $ARGOCD_WIZARD_ACCOUNT_PASSWORD
    @echo $ARGOCD_WIZARD_ACCOUNT_PASSWORD | pbcopy
    @open https://{{HUB_DNS_NAME}}/argocd

# Open Homer dashboard (hub)
open-homer-dashboard:
    @echo user: 
    @echo passwd: 
    @open https://{{HUB_DNS_NAME}}/

# Open Grafana (hub)
open-grafana:
    @echo user: 
    @echo passwd: 
    @open https://{{HUB_DNS_NAME}}/grafana

# Open Prometheus (hub)
open-prometheus:
    @echo user: wizard
    @echo passwd: ${ARGOCD_WIZARD_ACCOUNT_PASSWORD}
    @echo $ARGOCD_WIZARD_ACCOUNT_PASSWORD | pbcopy
    @open https://{{HUB_DNS_NAME}}/prometheus

# Open Alertmanager (hub)
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
    @open https://forgejo.{{PLTFME_DNS_NAME}}/

# Create the Forgejo repo for forgejo-build-image if missing, then push it
push-forgejo-build-image:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${FORGEJO_ADMIN_USER:?set in .env - run 'direnv allow'}"
    : "${FORGEJO_ADMIN_PASSWORD:?set in .env - run 'direnv allow'}"

    REPO_DIR="forgejo-build-image"
    REPO_NAME="$(basename "$REPO_DIR")"
    OWNER="$FORGEJO_ADMIN_USER"
    FORGEJO_URL="https://forgejo.{{PLTFME_DNS_NAME}}"

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
    : "${HARBOR_ADMIN_PASSWORD:?set in .env - run 'direnv allow'}"
    HARBOR_ADMIN_USER="${HARBOR_ADMIN_USER:-admin}"

    REPO_NAME="forgejo-build-image"
    OWNER="$FORGEJO_ADMIN_USER"
    FORGEJO_URL="https://forgejo.{{PLTFME_DNS_NAME}}"
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
    @echo user: admin
    @echo passwd: ${HARBOR_ADMIN_PASSWORD} 
    @echo ${HARBOR_ADMIN_PASSWORD} | pbcopy
    @open https://harbor.{{PLTFME_DNS_NAME}}/

# Open Kargo
open-kargo:
    @echo user: admin
    @echo passwd: ${KARGO_ADMIN_PASSWORD}
    @echo ${KARGO_ADMIN_PASSWORD} | pbcopy
    @open https://kargo.{{PLTFME_DNS_NAME}}/

# Open Nexus
open-nexus:
    @echo user: admin
    @echo passwd: ${NEXUS_ADMIN_PASSWORD}
    @echo ${NEXUS_ADMIN_PASSWORD} | pbcopy
    @open https://nexus.{{PLTFME_DNS_NAME}}/

open-keycloak:
    @echo user: admin
    @echo passwd: ${KEYCLOAK_ADMIN_PASSWORD}
    @echo ${KEYCLOAK_ADMIN_PASSWORD} | pbcopy
    @open https://keycloak.{{PLTFME_DNS_NAME}}/

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
        -connect forgejo.{{PLTFME_DNS_NAME}}:443 \
        -servername forgejo.{{PLTFME_DNS_NAME}} \
        2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName

get-harbor-credentials:
    @kubectl get secret -n ebank harbor-creds -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d

pause-cluster:
    docker pause $(docker ps -q --filter label=io.x-k8s.kind.cluster=$PROJECT_NAME)

un-pause-cluster:
    docker unpause $(docker ps -q --filter label=io.x-k8s.kind.cluster=$PROJECT_NAME)


