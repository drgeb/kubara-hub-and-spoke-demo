# Each kind cluster's cilium-ingress LoadBalancer IP is resolved explicitly
# instead of relying on the current kubectl context. Hub apps (argocd, homer,
# grafana, prometheus, alertmanager, openbao) live on the "hub" kind cluster;
# PLTFME (platform engineering: forgejo, kargo, harbor, nexus, keycloak, ...)
# on kubara-platform-engineering; DEV apps on kubara-poc.

# z-demo-setup/bin holds a sudo shim that fires a cmux/macOS notification
# before any sudo password prompt (see z-demo-setup/bin/sudo).
export PATH := justfile_directory() + "/z-demo-setup/bin:" + env_var("PATH")

# open-* recipes (one per demo app UI) live in their own file.
import 'Justfile.open-apps'

# cloud-provider-kind start/stop recipes.
import 'Justfile.cpk'

# Liquibase bootstrap/migration/verify recipes.
import 'Justfile.liquibase'

# Docker container helpers (list, pause/unpause, prune).
import 'Justfile.docker'

# OpenBank product catalog -> kubara-dev via Harbor, Kargo, Argo CD.
import 'Justfile.open-bank-oss'

# Local dnsmasq for *.kubara.test (start/stop/status-dnsmasq, setup-resolver,
# refresh-lb-hosts). Still runnable on its own: just -f dnsmasq/Justfile ...
import 'dnsmasq/Justfile'

KUBARA_KUBECONFIG:=".local/kind.kubeconfig"

MESH_DOCKER_NETWORK:="kubara-mesh"
MESH_DOCKER_SUBNET:="172.19.0.0/16"
MESH_DOCKER_GATEWAY:="172.19.0.1"
MESH_DOCKER_IP_RANGE:="172.19.0.0/24"

HUB_KIND:="hub"
PLATFORM_ENGINEERING_KIND:="kubara-platform-engineering"
POC_KIND:="kubara-poc"
DEV_KIND:="kubara-dev"
STAGING_KIND:="kubara-staging"
PROD_KIND:="kubara-prod"

HUB_CONTEXT:="kind-hub"
PLATFORM_ENGINEERING_CONTEXT:="kind-kubara-platform-engineering"
POC_CONTEXT:="kind-kubara-poc"
DEV_CONTEXT:="kind-kubara-dev"
STAGING_CONTEXT:="kind-kubara-staging"
PROD_CONTEXT:="kind-kubara-prod"

HUB_ID:="1"
PLATFORM_ENGINEERING_ID:="2"
POC_ID:="3"
DEV_ID:="4"
STAGING_ID:="5"
PROD_ID:="6"

HUB_NAME:="hub"
PLATFORM_ENGINEERING_NAME:="kubara-platform-engineering"
POC_NAME:="kubara-poc"
DEV_NAME:="kubara-dev"
STAGING_NAME:="kubara-staging"
PROD_NAME:="kubara-prod"

# Stable per-cluster DNS names. Resolved by the local dnsmasq wildcard setup
# in ./dnsmasq: <any>.<cluster>.kubara.test -> that cluster's cilium-ingress LB IP.
# Refresh the dnsmasq address= lines with `just refresh-lb-hosts`.
HUB_DNS_NAME := "hub.kubara.test"
PLATFORM_ENGINEERING_DNS_NAME := "platform-engineering.kubara.test"
POC_DNS_NAME := "poc.kubara.test"
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
# Run this after reinstalling cilium-ingress or nexus (their ClusterIPs change on recreation).
refresh-coredns-hosts:
    #!/usr/bin/env bash
    set -euo pipefail
    NEXUS_IP="$(kubectl get svc nexus -n nexus -o jsonpath='{.spec.clusterIP}')"
    INGRESS_IP="$(kubectl get svc cilium-ingress -n kube-system -o jsonpath='{.spec.clusterIP}')"
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
                ${INGRESS_IP} my.harbor.me
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
    echo "CoreDNS hosts refreshed: my.nexus.me → ${NEXUS_IP} (svc/nexus), my.harbor.me → ${INGRESS_IP} (svc/cilium-ingress)"

# Run the default recipe (list). [default] pins it: otherwise a bare `just`
# runs the first recipe in the file (apply-coredns-patch, a kubectl apply).
[default]
default:
    @just list

# List all available recipes
list:
    @just --list

export-loadbalancer-ip:
    @echo "LoadBalancer service was assigned an EXTERNAL-IP by cloud-provider-kind"
    @kubectl get svc/cilium-ingress -n kube-system -o=jsonpath='{.status.loadBalancer.ingress[0].ip}'

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
    kubectl --kubeconfig {{ KUBARA_KUBECONFIG }} --context {{ HUB_CONTEXT }} \
        get secrets -n argocd | grep -Ei 'spoke|dev|staging|prod' || echo "  (none found)"
    echo
    echo "==> ExternalSecrets status =="
    kubectl --kubeconfig {{ KUBARA_KUBECONFIG }} --context {{ HUB_CONTEXT }} \
        get externalsecret -n argocd
    echo
    echo "==> hub-argocd application =="
    kubectl --kubeconfig {{ KUBARA_KUBECONFIG }} --context {{ HUB_CONTEXT }} \
        get application hub-argocd -n argocd \
        -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

# Idempotent platform provisioning: seed secrets on all spokes, wait for
# postgres, then run liquibase bootstrap + per-service migrations per cluster.
# Safe to re-run (kubectl apply + helm upgrade + guarded SQL).
provision-platform:
    ./z-demo-setup/scripts/provision-platform.sh --refresh-local-kubeconfig

# Re-merge all six kind cluster kubeconfigs into ${KUBARA_KUBECONFIG}
refresh-kind-kubeconfig:
    ./z-demo-setup/scripts/provision-platform.sh --refresh-only

# Test the Kubernetes cluster connection and list namespaces
kubara-test-connection:
    kubara --test-connection

# Bootstrap the hub with kubara (--local), then re-pin the demo's *.kubara.test
# DNS names that kubara overwrites with <lb-ip>.traefik.me during bootstrap.
# Use `bootstrap-kubara-hub -- --skip-bootstrap` to only re-pin an existing setup.
bootstrap-kubara-hub:
    ./z-demo-setup/scripts/bootstrap-kubara-hub.sh

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
    for cluster in {{HUB_KIND}} {{PLATFORM_ENGINEERING_NAME}} {{POC_NAME}}; do
        echo "Opening Hubble UI for kind-$cluster on :$port"
        cilium hubble ui --context "kind-$cluster" --port-forward "$port" &
        port=$((port + 1))
    done
    wait

# Local pull-through image caches for the kind nodes (up | configure-nodes |
# detach | status | purge). bring-up runs `up` + `configure-nodes` itself.
registry-cache *args:
    ./z-demo-setup/scripts/registry-cache.sh {{args}}

# Snapshot why the mesh is unhealthy: host, DNS/LB map, per-cluster pods,
# events, image-pull timings, Argo CD apps. Writes .local/diagnostics/<ts>/.
# Read-only; runs automatically when bring-up fails.
diagnose *args:
    ./z-demo-setup/scripts/diagnose.sh {{args}}

# Ensures cloud-provider-kind runs, waits until every LB's status IP matches its
# live container (restarting cpk once if stuck), rewrites the dnsmasq map and
# verifies each zone resolves and answers. Idempotent; needs sudo.
# Re-sync LoadBalancer IPs into DNS for a built mesh (e.g. after a Docker restart)
sync-lb-dns:
    ./z-demo-setup/scripts/sync-lb-dns.sh

# Full demo bring-up from scratch: build the Cilium hub-and-spoke mesh (creates
# clusters, starts cloud-provider-kind before bootstrap, boots the hub and
# provisions platform services), wait until all six cilium-ingress LoadBalancer
# IPs are live, then refresh the local dnsmasq map. Run `just bring-up -- --rebuild`
# to recreate existing clusters. Needs sudo (first prompt is the cpk start inside
# build-mesh, second is the dnsmasq refresh).
bring-up *args:
    #!/usr/bin/env bash
    set -euo pipefail
    # Authenticate sudo up front, while you are still at the terminal, instead
    # of minutes into the run (cloud-provider-kind start) and again at the end
    # (dnsmasq refresh, after macOS's 5-minute sudo timeout has expired). The
    # z-demo-setup/bin/sudo shim alerts (notification + sound, repeated) if a
    # password is ever needed. The keep-alive refreshes the cached credentials
    # without prompting until this recipe exits.
    echo "==> bring-up needs sudo (cloud-provider-kind, dnsmasq); authenticate now:"
    sudo -v
    ( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null || true; sleep 60; done ) </dev/null >/dev/null 2>&1 &
    SUDO_KEEPALIVE_PID=$!

    # Long, mostly unattended run. On failure, snapshot the mesh immediately
    # (events expire after ~1h) and then alert.
    on_exit() {
        rc=$?
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        if [ "$rc" -eq 0 ]; then
            notify-attention "kubara bring-up finished" "Mesh is up; run just test-open-apps"
            return
        fi
        echo
        echo "==> bring-up failed (exit $rc); capturing diagnostics..."
        ./z-demo-setup/scripts/diagnose.sh || true
        notify-attention "kubara bring-up FAILED" "exit $rc - diagnostics in .local/diagnostics/"
    }
    trap on_exit EXIT
    ./z-demo-setup/scripts/build-mesh.sh {{args}}

    KCFG="{{ KUBARA_KUBECONFIG }}"
    echo "Waiting for all six cilium-ingress LoadBalancer IPs..."
    for _ in $(seq 1 120); do
        missing=""
        for ctx in {{HUB_CONTEXT}} {{PLATFORM_ENGINEERING_CONTEXT}} {{POC_CONTEXT}} {{DEV_CONTEXT}} {{STAGING_CONTEXT}} {{PROD_CONTEXT}}; do
            ip=$(kubectl --kubeconfig "$KCFG" --context "$ctx" get svc/cilium-ingress -n kube-system \
                -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
            if [ -z "$ip" ]; then
                missing="$missing $ctx"
            fi
        done
        if [ -z "$missing" ]; then
            echo "All cilium-ingress LoadBalancer IPs live"
            break
        fi
        sleep 5
    done
    if [ -n "${missing:-}" ]; then
        echo "WARN: still no LoadBalancer IP for:$missing (refresh-lb-hosts will fail until they appear)" >&2
    fi

    just refresh-lb-hosts

    echo
    echo "Post-bring-up steps:"
    echo "  just setup-uptime-kuma"
    echo "  just test-open-apps"

# Show every demo kind cluster: node containers running, nodes Ready,
# cilium-ingress LoadBalancer IP (read-only)
kind-status:
    ./z-demo-setup/scripts/kind-power.sh status

# Stop every demo kind cluster (all six, from kind-demo.yaml) and its
# cloud-provider-kind LoadBalancer containers, without deleting anything.
kind-stop:
    ./z-demo-setup/scripts/kind-power.sh stop

# Start all stopped demo kind clusters (hub first), wait for every
# cilium-ingress LoadBalancer IP and for ClusterMesh to reconnect, then refresh
# the dnsmasq map so DNS never goes stale. The refresh needs sudo.
kind-restart:
    ./z-demo-setup/scripts/kind-power.sh start || echo "WARN: continuing to DNS refresh despite the problems above" >&2
    just refresh-lb-hosts

kargo-cli-login:
    @: "${KARGO_ADMIN_PASSWORD:?not set - run 'direnv allow' to load .env}"
    @kargo login http://kargo.{{PLATFORM_ENGINEERING_DNS_NAME}} --admin --password "$KARGO_ADMIN_PASSWORD"

# Seed the go-hello delivery pipeline (Forgejo repo/CI, Harbor robot, Argo CD + Kargo)
# Safe to re-run; required again after `bring-up` recreates the cluster.
go-hello-setup:
    ./bin/setup-go-hello.sh

# Show go-hello pipeline status (Kargo freight/promotions + Argo CD app + deployment)
go-hello-verify:
    kubectl --kubeconfig {{ KUBARA_KUBECONFIG }} -n go-hello get warehouses,stages,freight,promotions
    kubectl --kubeconfig {{ KUBARA_KUBECONFIG }} -n argocd get application go-hello -o wide
    kubectl --kubeconfig {{ KUBARA_KUBECONFIG }} -n go-hello get deploy,pods

# Curl the go-hello endpoint
go-hello-test:
    @curl http://go-hello.{{DEV_DNS_NAME}}/

# Test every app entry point (mirrors the open-* recipes; exit 1 on any failure)
test-open-apps:
    ./z-demo-setup/scripts/test-open-apps.sh

# Verify delete-kind-demo.sh left the host clean (read-only; exit 1 on any failure)
test-teardown *args:
    ./z-demo-setup/scripts/test-teardown.sh {{ args }}

# Seed the ebank delivery pipeline (Argo CD repo creds + AppProject/Applications)
# Safe to re-run; required again after `bring-up` recreates the cluster.
ebank-setup:
    ./bin/setup-ebank.sh

# Show ebank pipeline status (Kargo freight/promotions + Argo CD apps + deployment)
ebank-verify:
    kubectl --kubeconfig {{ KUBARA_KUBECONFIG }} -n ebank get warehouses,stages,freight,promotions
    kubectl --kubeconfig {{ KUBARA_KUBECONFIG }} -n argocd get application ebank-kargo ebank-dev ebank-staging ebank-prod -o wide
    kubectl --kubeconfig {{ KUBARA_KUBECONFIG }} -n ebank-simple-dev get deploy,pods

# Open Argo CD UI
login-argo-cd:
    @echo user: ${ARGOCD_ADMIN_USER}
    @echo passwd: $ARGOCD_WIZARD_ACCOUNT_PASSWORD
    @echo $ARGOCD_WIZARD_ACCOUNT_PASSWORD | pbcopy
    argocd login argocd.{{HUB_DNS_NAME}} --insecure

# Create the Uptime Kuma admin from .env (UPTIME_KUMA_ADMIN_USER / UPTIME_KUMA_PASSWORD)
# Safe to re-run; required again after `bring-up` recreates the cluster.
setup-uptime-kuma:
    ./z-demo-setup/scripts/setup-uptime-kuma.sh

# Create the Forgejo repo for forgejo-build-image if missing, then push it
push-forgejo-build-image:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${FORGEJO_ADMIN_USER:?set in .env - run 'direnv allow'}"
    : "${FORGEJO_ADMIN_PASSWORD:?set in .env - run 'direnv allow'}"

    REPO_DIR="forgejo-build-image"
    REPO_NAME="$(basename "$REPO_DIR")"
    OWNER="$FORGEJO_ADMIN_USER"
    FORGEJO_URL="https://forgejo.{{PLATFORM_ENGINEERING_DNS_NAME}}"

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
    FORGEJO_URL="https://forgejo.{{PLATFORM_ENGINEERING_DNS_NAME}}"
    AUTH=(-u "$FORGEJO_ADMIN_USER:$FORGEJO_ADMIN_PASSWORD" -H "Content-Type: application/json")

    api() {
        local name="$1" value="$2"
        curl -fskS "${AUTH[@]}" -X PUT -d "{\"data\":\"$value\"}" \
            "$FORGEJO_URL/api/v1/repos/$OWNER/$REPO_NAME/actions/secrets/$name" >/dev/null
        echo ">> set secret $name on $OWNER/$REPO_NAME"
    }

    api HARBOR_USERNAME "$HARBOR_ADMIN_USER"
    api HARBOR_PASSWORD "$HARBOR_ADMIN_PASSWORD"

inspect-what-certificate-cilium-is-serving:
    @echo "Cilium is serving the following certificate:"
    echo | openssl s_client \
        -connect forgejo.{{PLATFORM_ENGINEERING_DNS_NAME}}:443 \
        -servername forgejo.{{PLATFORM_ENGINEERING_DNS_NAME}} \
        2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName

get-harbor-credentials:
    @kubectl get secret -n ebank harbor-creds -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d

