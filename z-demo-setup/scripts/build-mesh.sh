#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${ROOT_DIR}/z-demo-setup/config"

source "${SCRIPT_DIR}/lib/kind-demo-common.sh"

CILIUM_VERSION="${CILIUM_VERSION:-1.19.5}"

# Must match the kube-prometheus-stack dependency pinned in
# platform-components/helm/bootstrap-crds/Chart.yaml.
KUBE_PROMETHEUS_STACK_VERSION="${KUBE_PROMETHEUS_STACK_VERSION:-88.6.3}"

MESH_DOCKER_NETWORK="kubara-mesh"
MESH_DOCKER_SUBNET="172.19.0.0/16"
MESH_DOCKER_GATEWAY="172.19.0.1"
MESH_DOCKER_IP_RANGE="172.19.0.10/28"

DEMO_CLUSTER_CONFIG="${CONFIG_DIR}/kind-demo.yaml"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kubara-cilium.XXXXXX")"
MESH_KUBECONFIG="${TMP_DIR}/mesh.kubeconfig"

LOCAL_DIR="${ROOT_DIR}/.local"
KIND_DEMO_DIR="${LOCAL_DIR}/kind-demo"

OPENBAO_NAMESPACE="openbao"
OPENBAO_MOUNT="kv"
PLATFORM_CONFIG="${ROOT_DIR}/config.yaml"
PERSISTENT_HUB_KUBECONFIG="${LOCAL_DIR}/kind.kubeconfig"

REBUILD=false

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

usage() {
    cat <<EOF
Usage:
  $(basename "$0") [OPTIONS]

Options:
  --rebuild          Delete and recreate all kind clusters
  -c, --config <file>
                     Demo cluster inventory YAML
                     (default: ${DEMO_CLUSTER_CONFIG})
  -h, --help         Show this help

Environment:
  CILIUM_VERSION=1.19.5
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rebuild)
            REBUILD=true
            shift
            ;;
        -c|--config)
            [[ -n "${2:-}" ]] || die "Missing value for $1"
            DEMO_CLUSTER_CONFIG="$2"
            shift 2
            ;;
        --config=*)
            DEMO_CLUSTER_CONFIG="${1#*=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

demo_load_config "$DEMO_CLUSTER_CONFIG"
log "Cluster inventory: ${DEMO_CONFIG_FILE}"

# ---------------------------------------------------------------------------
# Cluster inventory (order-defined): entry 0 must be the hub, the rest spokes.
# Bash 3.2 has no mapfile and no associative arrays, so populate parallel
# indexed arrays from the pipe-delimited parser output.
# ---------------------------------------------------------------------------
CLUSTER_NAMES=()
CLUSTER_CONFIGS=()
CLUSTER_IDS=()

while IFS='|' read -r _name _kind_config _cilium_id; do
    [ -n "$_name" ] || continue

    demo_validate_cluster_name "$_name"
    [ -n "$_kind_config" ] || die "kind_config missing for cluster '${_name}'"
    [ -n "$_cilium_id" ] || die "cilium_id missing for cluster '${_name}'"

    CLUSTER_NAMES+=("$_name")
    CLUSTER_CONFIGS+=("$(demo_resolve_kind_config_path "$_kind_config")")
    CLUSTER_IDS+=("$_cilium_id")
done < <(demo_parse_clusters)

(( ${#CLUSTER_NAMES[@]} > 0 )) || die "No clusters found in inventory: ${DEMO_CONFIG_FILE}"

CLUSTER_COUNT="${#CLUSTER_NAMES[@]}"

[[ "${CLUSTER_NAMES[0]}" == "$DEMO_HUB_CLUSTER_NAME" ]] ||
    die "First cluster in ${DEMO_CONFIG_FILE} must be the hub (${DEMO_HUB_CLUSTER_NAME})"

[[ "${CLUSTER_IDS[0]}" == "1" ]] ||
    die "Hub Cilium cluster ID must be 1"

for ((i = 0; i < CLUSTER_COUNT; i++)); do
    for ((j = i + 1; j < CLUSTER_COUNT; j++)); do
        if [[ "${CLUSTER_IDS[i]}" == "${CLUSTER_IDS[j]}" ]]; then
            die "Duplicate Cilium cluster ID ${CLUSTER_IDS[i]}: ${CLUSTER_NAMES[i]} and ${CLUSTER_NAMES[j]}"
        fi
    done
done

CONTEXTS=()
TMP_KUBECONFIGS=()
INTERNAL_KUBECONFIGS=()

for ((i = 0; i < CLUSTER_COUNT; i++)); do
    CONTEXTS+=("kind-${CLUSTER_NAMES[i]}")
    TMP_KUBECONFIGS+=("${TMP_DIR}/${CLUSTER_NAMES[i]}.kubeconfig")
    INTERNAL_KUBECONFIGS+=("${KIND_DEMO_DIR}/${CLUSTER_NAMES[i]}.internal.kubeconfig")
done

HUB_ID="${CLUSTER_IDS[0]}"
HUB_NAME="${CLUSTER_NAMES[0]}"
HUB_CONTEXT="${CONTEXTS[0]}"
HUB_STAGE=""

check_prerequisites() {
    log "Checking prerequisites"

    command -v kind >/dev/null 2>&1 ||
        die "kind is not installed"

    command -v kubectl >/dev/null 2>&1 ||
        die "kubectl is not installed"

    command -v cilium >/dev/null 2>&1 ||
        die "cilium CLI is not installed"

    command -v docker >/dev/null 2>&1 ||
        die "docker is not installed"

    docker info >/dev/null 2>&1 ||
        die "Docker is not running"

    local i
    local config

    for ((i = 0; i < CLUSTER_COUNT; i++)); do
        config="${CLUSTER_CONFIGS[i]}"

        [[ -f "$config" ]] ||
            die "Missing $config"
    done

    log "Cilium CLI"

    cilium version
}

get_cluster_stage() {
    local cluster_name="$1"

    awk -v target="$cluster_name" '
        function clean(value) {
            sub(/[ \t]+#.*/, "", value)
            gsub(/^[ \t]+|[ \t]+$/, "", value)
            gsub(/^"|"$/, "", value)
            return value
        }

        /^[ \t]*-[ \t]*name:[ \t]*/ {
            line = $0
            sub(/^[ \t]*-[ \t]*name:[ \t]*/, "", line)
            current = clean(line)
            next
        }

        current == target && /^[ \t]*stage:[ \t]*/ {
            line = $0
            sub(/^[ \t]*stage:[ \t]*/, "", line)
            print clean(line)
            exit
        }
    ' "$PLATFORM_CONFIG"
}

ensure_cilium_helm_repo() {
    log "Checking Cilium Helm repository"

    if ! helm repo list 2>/dev/null |
        awk 'NR > 1 {print $1}' |
        grep -Fxq "cilium"; then

        echo "    Cilium Helm repository not found; adding it"

        helm repo add cilium https://helm.cilium.io/
    else
        echo "    Cilium Helm repository already exists"
    fi

    echo "    Updating Cilium Helm repository"

    helm repo update cilium
}

ensure_prometheus_helm_repo() {
    log "Checking Prometheus Helm repository"

    if ! helm repo list 2>/dev/null |
        awk 'NR > 1 {print $1}' |
        grep -Fxq "prometheus-community"; then

        echo "    Prometheus Helm repository not found; adding it"

        helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    else
        echo "    Prometheus Helm repository already exists"
    fi

    echo "    Updating Prometheus Helm repository"

    helm repo update prometheus-community
}

ensure_mesh_docker_network() {
    log "Ensuring mesh Docker network '${MESH_DOCKER_NETWORK}'"

    if docker network inspect "$MESH_DOCKER_NETWORK" >/dev/null 2>&1; then
        echo "    Docker network already exists"

        return
    fi

    docker network create \
        --driver bridge \
        --subnet "$MESH_DOCKER_SUBNET" \
        --gateway "$MESH_DOCKER_GATEWAY" \
        --ip-range "$MESH_DOCKER_IP_RANGE" \
        "$MESH_DOCKER_NETWORK"
}

check_kind_network() {
    log "Checking Kind Docker network"

    if docker network inspect kind >/dev/null 2>&1; then
        return
    fi

    # kind auto-creates its default 'kind' network on the first cluster, but
    # the demo deletes it during teardown, so create it up-front when missing.
    docker network create --driver bridge kind
}

cluster_exists() {
    local cluster="$1"

    kind get clusters 2>/dev/null |
        grep -Fxq "$cluster"
}

delete_cluster() {
    local cluster="$1"

    if cluster_exists "$cluster"; then
        log "Deleting Kind cluster '${cluster}'"
        kind delete cluster --name "$cluster"
    fi
}

rebuild_clusters() {
    log "Rebuild requested"

    printf '\nWARNING:\n\n  This will DELETE these Kind clusters:\n\n'

    for name in "${CLUSTER_NAMES[@]}"; do
        printf '    %s\n' "$name"
    done

    printf "\n  The '${HUB_NAME}' cluster currently contains your Kubara hub.\n\n"
    printf "  'test-cluster' will NOT be touched.\n\n"

    log "Deleting existing lab clusters"

    for ((i = CLUSTER_COUNT - 1; i >= 0; i--)); do
        delete_cluster "${CLUSTER_NAMES[i]}"
    done
}

create_kind_cluster() {
    local name="$1"
    local config="$2"

    if cluster_exists "$name"; then
        log "Kind cluster '${name}' already exists"
        return
    fi

    log "Creating Kind cluster '${name}' with config: ${config}"

    KIND_EXPERIMENTAL_DOCKER_NETWORK="$MESH_DOCKER_NETWORK" \
    kind create cluster \
    --name "$name" \
    --config "$config"

    if [ $? -ne 0 ]; then
        die "Failed to create Kind cluster '${name}'"
    fi
}

create_clusters() {
    log "Creating Kind clusters"

    for ((i = 0; i < CLUSTER_COUNT; i++)); do
        create_kind_cluster "${CLUSTER_NAMES[i]}" "${CLUSTER_CONFIGS[i]}"
    done
}

generate_kubeconfigs() {
    log "Generating isolated Kind kubeconfigs"

    local -a tmp_files=()
    local i

    for ((i = 0; i < CLUSTER_COUNT; i++)); do
        kind get kubeconfig --name "${CLUSTER_NAMES[i]}" > "${TMP_KUBECONFIGS[i]}"
        chmod 600 "${TMP_KUBECONFIGS[i]}"
        tmp_files+=("${TMP_KUBECONFIGS[i]}")
    done

    KUBECONFIG="$(IFS=:; echo "${tmp_files[*]}")" \
        kubectl config view --flatten > "$MESH_KUBECONFIG"

    chmod 600 "$MESH_KUBECONFIG"

    # Merge the demo clusters into the shared .local/kind.kubeconfig.
    # Wildcarding `kind get clusters` leaks unrelated/stray clusters (e.g. the
    # preserved 'test-cluster') into the kubeconfig that local tooling relies on.
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local -a parts=()
    local cluster part

    for cluster in "${CLUSTER_NAMES[@]}"; do
        part="${tmp_dir}/${cluster}.yaml"
        if kind get kubeconfig --name "$cluster" > "$part" 2>/dev/null; then
            parts+=("$part")
        else
            echo "    WARN: kind cluster '${cluster}' not found; excluding" >&2
        fi
    done
    mkdir -p "$LOCAL_DIR"
    KUBECONFIG="$(IFS=:; echo "${parts[*]}")" \
        kubectl config view --flatten > "${LOCAL_DIR}/kind.kubeconfig"
    chmod 600 "${LOCAL_DIR}/kind.kubeconfig"
    rm -rf "$tmp_dir"
}

wait_for_api_cluster() {
    local context="$1"
    local timeout="${2:-300}"

    printf '    Waiting for Kubernetes API on %s...\n' "$context"

    local deadline=$((SECONDS + timeout))

    while (( SECONDS < deadline )); do
        if kubectl \
            --kubeconfig "$MESH_KUBECONFIG" \
            --context "$context" \
            get --raw='/readyz' >/dev/null 2>&1; then

            printf '    Kubernetes API is ready on %s\n' "$context"
            return 0
        fi

        sleep 2
    done

    echo "ERROR: Kubernetes API did not become ready on ${context}" >&2

    kubectl \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$context" \
        get nodes -o wide || true

    return 1
}

wait_for_api() {
    log "Waiting for Kubernetes APIs"

    for context in "${CONTEXTS[@]}"; do
        wait_for_api_cluster "$context"
    done
}

wait_for_nodes() {
    log "Waiting for Kubernetes nodes"

    for context in "${CONTEXTS[@]}"; do
        printf '    Waiting for node readiness on %s...\n' "$context"

        kubectl \
            --kubeconfig "$MESH_KUBECONFIG" \
            --context "$context" \
            wait \
            --for=condition=Ready \
            node \
            --all \
            --timeout=180s

        printf '    %s node is ready\n' "$context"
    done
}

ensure_hub_prometheus_crds() {
    log "Installing Prometheus Operator CRDs on hub"

    helm show crds prometheus-community/kube-prometheus-stack \
        --version "$KUBE_PROMETHEUS_STACK_VERSION" |
        kubectl \
            --kubeconfig "$MESH_KUBECONFIG" \
            --context "$HUB_CONTEXT" \
            apply --server-side -f - \
            >/dev/null

    kubectl \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$HUB_CONTEXT" \
        wait \
        --for=condition=Established \
        crd/servicemonitors.monitoring.coreos.com \
        --timeout=120s

    echo "    ServiceMonitor CRDs are ready on hub"
}

install_cilium() {
    local context="$1"
    local cluster_name="$2"
    local cluster_id="$3"

    log "Installing Cilium ${CILIUM_VERSION} on ${cluster_name}"

    # Check if Cilium is already installed
    if kubectl \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$context" \
        -n kube-system \
        get deployment cilium-operator >/dev/null 2>&1; then

        log "Cilium is already installed on ${cluster_name}"
        return
    fi

    # Cilium CLI may time out while Kubernetes components are still
    # becoming ready. Do not make the CLI timeout itself fatal.
    local -a install_args=(
        --kubeconfig "$MESH_KUBECONFIG"
        --context "$context"
        --version "$CILIUM_VERSION"
        --set "cluster.name=${cluster_name}"
        --set "cluster.id=${cluster_id}"
        --set "ipam.mode=kubernetes"
        --set "clustermesh.apiserver.replicas=1"
        --set "prometheus.enabled=true"
        --set "hubble.metrics.enabled={dns,drop,tcp,flow,http,icmp}"
    )
    # Only the hub runs Prometheus Operator, so only it can consume
    # Cilium ServiceMonitors.
    local -a servicemonitor_args=()
    if [[ "$cluster_id" == "$HUB_ID" ]]; then
        servicemonitor_args=(
            --set "prometheus.serviceMonitor.enabled=true"
            --set "prometheus.serviceMonitor.trustCRDsExist=true"
            --set "prometheus.serviceMonitor.labels.monitoring\.instance=hub-local"
            --set "hubble.metrics.serviceMonitor.enabled=true"
            --set "hubble.metrics.serviceMonitor.trustCRDsExist=true"
            --set "hubble.metrics.serviceMonitor.labels.monitoring\.instance=hub-local"
            --set "operator.prometheus.enabled=true"
            --set "operator.prometheus.serviceMonitor.enabled=true"
            --set "operator.prometheus.serviceMonitor.trustCRDsExist=true"
            --set "operator.prometheus.serviceMonitor.labels.monitoring\.instance=hub-local"
        )
    fi

    if (( ${#servicemonitor_args[@]} > 0 )); then
        install_args+=("${servicemonitor_args[@]}")
    fi
    install_args+=(--wait)

    cilium install "${install_args[@]}"

    if [ $? -ne 0 ]; then
        die "Failed to install Cilium on ${cluster_name}"
    fi
}

install_all_cilium() {
    for ((i = 0; i < CLUSTER_COUNT; i++)); do
        install_cilium "${CONTEXTS[i]}" "${CLUSTER_NAMES[i]}" "${CLUSTER_IDS[i]}"
    done
}

wait_for_cilium_cluster() {
    local context="$1"
    local timeout="${2:-180}"

    echo "    Waiting for Cilium on ${context}..."

    local deadline=$((SECONDS + timeout))

    while (( SECONDS < deadline )); do
        if cilium status \
            --kubeconfig "$MESH_KUBECONFIG" \
            --context "$context" \
            >/dev/null 2>&1; then

            echo "    Cilium is ready on ${context}"
            return 0
        fi

        sleep 3
    done

    echo "ERROR: Cilium did not become ready on ${context}" >&2

    cilium status \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$context" \
        || true

    return 1
}

wait_for_cilium() {
    log "Waiting for Cilium"

    for context in "${CONTEXTS[@]}"; do
        wait_for_cilium_cluster "$context"
    done
}

wait_for_deployment_exists() {
    local context="$1"
    local namespace="$2"
    local deployment="$3"
    local timeout="${4:-180}"

    echo "    Waiting for deployment ${deployment} to be created on ${context}..."

    local deadline=$((SECONDS + timeout))

    while (( SECONDS < deadline )); do
        if kubectl \
            --kubeconfig "$MESH_KUBECONFIG" \
            --context "$context" \
            -n "$namespace" \
            get deployment "$deployment" >/dev/null 2>&1; then

            echo "    Deployment ${deployment} exists on ${context}"
            return 0
        fi

        sleep 3
    done

    echo "ERROR: Deployment ${deployment} was not created on ${context}" >&2
    return 1
}

wait_for_clustermesh() {
    local kubeconfig="$1"
    local context="$2"
    local timeout="${3:-180}"

    echo "    Waiting for ClusterMesh API server on ${context}..."

    local deadline=$((SECONDS + timeout))

    while (( SECONDS < deadline )); do

        if ! kubectl \
            --kubeconfig "$kubeconfig" \
            --context "$context" \
            -n kube-system \
            get deployment clustermesh-apiserver \
            >/dev/null 2>&1; then

            sleep 3
            continue
        fi

        local replicas
        local available
        local ready
        local updated

        replicas="$(
            kubectl \
                --kubeconfig "$kubeconfig" \
                --context "$context" \
                -n kube-system \
                get deployment clustermesh-apiserver \
                -o jsonpath='{.spec.replicas}' \
                2>/dev/null || true
        )"

        available="$(
            kubectl \
                --kubeconfig "$kubeconfig" \
                --context "$context" \
                -n kube-system \
                get deployment clustermesh-apiserver \
                -o jsonpath='{.status.availableReplicas}' \
                2>/dev/null || true
        )"

        ready="$(
            kubectl \
                --kubeconfig "$kubeconfig" \
                --context "$context" \
                -n kube-system \
                get deployment clustermesh-apiserver \
                -o jsonpath='{.status.readyReplicas}' \
                2>/dev/null || true
        )"

        updated="$(
            kubectl \
                --kubeconfig "$kubeconfig" \
                --context "$context" \
                -n kube-system \
                get deployment clustermesh-apiserver \
                -o jsonpath='{.status.updatedReplicas}' \
                2>/dev/null || true
        )"

        if [[ "$replicas" == "1" &&
              "$available" == "1" &&
              "$ready" == "1" &&
              "$updated" == "1" ]]; then

            # Verify that the actual pod has all three containers ready.
            local ready_pods

            ready_pods="$(
                kubectl \
                    --kubeconfig "$kubeconfig" \
                    --context "$context" \
                    -n kube-system \
                    get pods \
                    -l k8s-app=clustermesh-apiserver \
                    -o jsonpath='{range .items[*]}{.status.containerStatuses[*].ready}{"\n"}{end}' \
                    2>/dev/null || true
            )"

            if [[ "$ready_pods" == *"true true true"* ]]; then
                echo "    ClusterMesh API server is ready on ${context}"
                return 0
            fi
        fi

        echo "    waiting... replicas=${replicas:-0}, available=${available:-0}, ready=${ready:-0}, updated=${updated:-0}"

        sleep 3
    done

    echo "ERROR: ClusterMesh API server did not become ready on ${context}" >&2

    kubectl \
        --kubeconfig "$kubeconfig" \
        --context "$context" \
        -n kube-system \
        get deployment clustermesh-apiserver -o wide \
        || true

    kubectl \
        --kubeconfig "$kubeconfig" \
        --context "$context" \
        -n kube-system \
        get pods \
        -l k8s-app=clustermesh-apiserver \
        -o wide \
        || true

    kubectl \
        --kubeconfig "$kubeconfig" \
        --context "$context" \
        -n kube-system \
        get events \
        --sort-by='.lastTimestamp' |
        tail -30 \
        || true

    return 1
}

wait_for_mesh_connections() {
    local timeout="${1:-300}"

    log "Waiting for ClusterMesh connections"

    local deadline=$((SECONDS + timeout))

    while (( SECONDS < deadline )); do
        local hub_status

        hub_status="$(
            cilium clustermesh status \
                --kubeconfig "$MESH_KUBECONFIG" \
                --context "$HUB_CONTEXT" \
                2>/dev/null || true
        )"

        if [[ -z "$hub_status" ]]; then
            echo "    Waiting for ClusterMesh status from hub..."
            sleep 5
            continue
        fi

        local -a not_ready_parts=()
        local pattern
        local line
        local i
        local name

        for ((i = 1; i < CLUSTER_COUNT; i++)); do
            name="${CLUSTER_NAMES[i]}"
            pattern="${name}: [0-9]+/[0-9]+ configured, [0-9]+/[0-9]+ connected - KVStoreMesh: [0-9]+/[0-9]+ configured, [0-9]+/[0-9]+ connected"

            if grep -Eq "$pattern" <<< "$hub_status"; then
                line="$(grep "${name}:" <<< "$hub_status" || true)"

                if [[ "$line" =~ configured,\ 1/1\ connected ]] &&
                   [[ "$line" =~ KVStoreMesh:\ 1/1\ configured,\ 1/1\ connected ]]; then
                    continue
                fi
            fi

            not_ready_parts+=("${name}")
        done

        if (( ${#not_ready_parts[@]} == 0 )); then
            echo "    ClusterMesh connections are established"

            for ((i = 1; i < CLUSTER_COUNT; i++)); do
                echo "      hub -> ${CLUSTER_NAMES[i]}: connected"
            done

            for ((i = 1; i < CLUSTER_COUNT; i++)); do
                echo "      KVStoreMesh -> ${CLUSTER_NAMES[i]}: connected"
            done

            return 0
        fi

        echo "    waiting..."
        for name in "${CLUSTER_NAMES[@]:1}"; do
            line="$(grep "${name}:" <<< "$hub_status" || echo 'not ready')"
            echo "      ${line}"
        done
        sleep 5
    done

    echo "ERROR: ClusterMesh connections did not become established within ${timeout}s" >&2

    echo
    echo "Hub ClusterMesh status:"
    cilium clustermesh status \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$HUB_CONTEXT" \
        || true

    return 1
}

enable_clustermesh() {
    local context="$1"

    log "Enabling ClusterMesh on ${context}"

    # clustermesh enable can return a timeout while Kubernetes is still
    # starting the API server. The Kubernetes readiness check below is
    # authoritative.
    cilium clustermesh enable \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$context" \
        --service-type NodePort

    if [ $? -ne 0 ]; then
        die "Failed to enable ClusterMesh on ${context}"
    fi

    wait_for_deployment_exists \
        "$context" \
        kube-system \
        clustermesh-apiserver \
        180

    # Kind has one node per cluster. Keep the ClusterMesh API server at
    # one replica for this local lab.
    helm upgrade cilium cilium/cilium \
        --kubeconfig "$MESH_KUBECONFIG" \
        --kube-context "$context" \
        --namespace kube-system \
        --version "$CILIUM_VERSION" \
        --reuse-values \
        --set "clustermesh.apiserver.replicas=1"

    if [ $? -ne 0 ]; then
        die "Failed to upgrade Cilium Helm chart on ${context}"
    fi

    wait_for_clustermesh \
        "$MESH_KUBECONFIG" \
        "$context" \
        180

    if [ $? -ne 0 ]; then
        die "ClusterMesh did not become ready on ${context}"
    fi
}

enable_all_clustermesh() {
    for context in "${CONTEXTS[@]}"; do
        enable_clustermesh "$context"
    done
}

enforce_clustermesh_replicas() {
    local context="$1"

    log "Enforcing ClusterMesh API server replicas on ${context}"

    helm upgrade cilium cilium/cilium \
        --kubeconfig "$MESH_KUBECONFIG" \
        --kube-context "$context" \
        --namespace kube-system \
        --version "$CILIUM_VERSION" \
        --reuse-values \
        --set "clustermesh.apiserver.replicas=1"

    kubectl \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$context" \
        -n kube-system \
        rollout status deployment/clustermesh-apiserver \
        --timeout=180s

    local replicas

    replicas="$(
        kubectl \
            --kubeconfig "$MESH_KUBECONFIG" \
            --context "$context" \
            -n kube-system \
            get deployment clustermesh-apiserver \
            -o jsonpath='{.spec.replicas}'
    )"

    if [[ "$replicas" != "1" ]]; then
        die "ClusterMesh API server on ${context} has ${replicas} desired replicas; expected 1"
    fi

    echo "    ClusterMesh API server is configured for 1 replica on ${context}"
}

connect_cluster() {
    local source_context="$1"
    local destination_context="$2"

    log "Connecting ${source_context} <-> ${destination_context}"

    cilium clustermesh connect \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$source_context" \
        --destination-context "$destination_context" \
        --allow-mismatching-ca

    wait_for_clustermesh \
        "$MESH_KUBECONFIG" \
        "$source_context" \
        180

    wait_for_clustermesh \
        "$MESH_KUBECONFIG" \
        "$destination_context" \
        180
}

connect_clusters() {
    for ((i = 1; i < CLUSTER_COUNT; i++)); do
        connect_cluster "${CONTEXTS[0]}" "${CONTEXTS[i]}"
    done
}

bootstrap_kubara_hub() {
    log "Bootstrapping Kubara hub"

    "${ROOT_DIR}/z-demo-setup/scripts/bootstrap-kubara-hub.sh"
}

generate_internal_kubeconfigs() {
    log "Generating Docker-internal kubeconfigs"

    mkdir -p "$KIND_DEMO_DIR"

    # Only spokes are published to OpenBao; the hub uses the merged
    # .local/kind.kubeconfig for local tooling.
    for ((i = 1; i < CLUSTER_COUNT; i++)); do
        kind get kubeconfig \
            --name "${CLUSTER_NAMES[i]}" \
            --internal \
            > "${INTERNAL_KUBECONFIGS[i]}"

        chmod 600 "${INTERNAL_KUBECONFIGS[i]}"

        echo "    ${INTERNAL_KUBECONFIGS[i]}"
    done
}

publish_spoke_kubeconfig() {
    local cluster_name="$1"
    local spoke_stage="$2"
    local kubeconfig="$3"
    local openbao_addr="$4"
    local root_token="$5"

    local secret_path="${HUB_NAME}/${HUB_STAGE}/argocd/${cluster_name}-${spoke_stage}"
    local api_url="${openbao_addr}/v1/${OPENBAO_MOUNT}/data/${secret_path}"

    [[ -f "$kubeconfig" ]] ||
        die "Internal kubeconfig not found: $kubeconfig"

    jq -Rs '{data: {kubeconfig: .}}' "$kubeconfig" |
        curl -fsS \
            --header "X-Vault-Token: ${root_token}" \
            --header 'Content-Type: application/json' \
            --request POST \
            --data-binary @- \
            "$api_url" >/dev/null

    curl -fsS \
        --header "X-Vault-Token: ${root_token}" \
        "$api_url" |
        jq -e '.data.data.kubeconfig | type == "string" and length > 0' \
        >/dev/null

    echo "    Published ${OPENBAO_MOUNT}/${secret_path}"
}

set_values_to_publish_spoke_kubeconfigs_to_openbao() {
    CLUSTER_STAGES=()
    local stage
    local i

    for ((i = 0; i < CLUSTER_COUNT; i++)); do
        stage="$(get_cluster_stage "${CLUSTER_NAMES[i]}")"

        [[ -n "$stage" ]] ||
            die "Stage not found for ${CLUSTER_NAMES[i]}"

        CLUSTER_STAGES+=("$stage")
    done

    HUB_STAGE="${CLUSTER_STAGES[0]}"
}

wait_for_openbao() {
    log "Waiting for OpenBao to become ready on the hub"

    local deadline=$((SECONDS + 300))
    local host=""

    while [[ $SECONDS -lt $deadline ]]; do
        host="$(
            kubectl \
                --kubeconfig "$PERSISTENT_HUB_KUBECONFIG" \
                --context "$HUB_CONTEXT" \
                -n "$OPENBAO_NAMESPACE" \
                get ingress openbao \
                -o jsonpath='{.spec.rules[0].host}' \
                2>/dev/null || true
        )"

        if [[ -n "$host" ]] &&
                 curl -sf "http://${host}/v1/sys/health" >/dev/null 2>&1; then
            log "OpenBao is ready at http://${host}"
            return 0
        fi

        sleep 5
    done

    die "OpenBao did not become ready within 300s (last host: ${host})"
}

publish_spoke_kubeconfigs_to_openbao() {
    log "Publishing spoke kubeconfigs to OpenBao"

    command -v curl >/dev/null 2>&1 ||
        die "curl is not installed"

    command -v jq >/dev/null 2>&1 ||
        die "jq is not installed"

    local ingress_host

    ingress_host="$(
        kubectl \
            --kubeconfig "$PERSISTENT_HUB_KUBECONFIG" \
            --context "$HUB_CONTEXT" \
            -n "$OPENBAO_NAMESPACE" \
            get ingress openbao \
            -o jsonpath='{.spec.rules[0].host}'
    )"

    [[ -n "$ingress_host" ]] ||
        die "OpenBao ingress host not found"

    local root_token

    root_token="$(
        kubectl \
            --kubeconfig "$PERSISTENT_HUB_KUBECONFIG" \
            --context "$HUB_CONTEXT" \
            -n "$OPENBAO_NAMESPACE" \
            exec openbao-0 -c openbao -- \
            sh -c \
            'tr -d "\n\r" < /openbao/data/local-bootstrap/init.json |
             sed -n '\''s/.*"root_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'\'''
    )"

    [[ -n "$root_token" ]] ||
        die "Could not read OpenBao root token"

    local openbao_addr="http://${ingress_host}"

    echo "    OpenBao: ${openbao_addr}"

    for ((i = 1; i < CLUSTER_COUNT; i++)); do
        publish_spoke_kubeconfig \
            "${CLUSTER_NAMES[i]}" \
            "${CLUSTER_STAGES[i]}" \
            "${INTERNAL_KUBECONFIGS[i]}" \
            "$openbao_addr" \
            "$root_token"
    done

    unset root_token
}

show_cluster_config() {
    local context="$1"

    log "Cilium configuration: ${context}"

    cilium config view \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$context" |
        grep -E '^(cluster-id|cluster-name)' || true
}

verify_cluster_config() {
    for context in "${CONTEXTS[@]}"; do
        show_cluster_config "$context"
    done
}

provision_platform() {
    log "Provisioning platform secrets and databases"

    # Create platform secrets on all spokes, wait for postgres, then run the
    # (idempotent) liquibase bootstrap + per-service migrations. Uses the
    # shared merge config so every spoke context is reachable regardless of the
    # ambient kubeconfig. Also refreshes .local/kind.kubeconfig with all six
    # cluster contexts so local tooling can reach dev/staging/prod too.
    "${ROOT_DIR}/z-demo-setup/scripts/provision-platform.sh" \
        --kubeconfig "$MESH_KUBECONFIG" \
        --refresh-local-kubeconfig
}

show_mesh_status() {
    for ((i = 0; i < CLUSTER_COUNT; i++)); do
        log "ClusterMesh status: ${CLUSTER_NAMES[i]}"

        cilium clustermesh status \
            --kubeconfig "$MESH_KUBECONFIG" \
            --context "${CONTEXTS[i]}"
    done
}

show_nodes() {
    log "Kubernetes nodes"

    for context in "${CONTEXTS[@]}"; do
        kubectl \
            --kubeconfig "$MESH_KUBECONFIG" \
            --context "$context" \
            get nodes -o wide
    done
}

show_clustermesh_services() {
    log "ClusterMesh services"

    for context in "${CONTEXTS[@]}"; do
        kubectl \
            --kubeconfig "$MESH_KUBECONFIG" \
            --context "$context" \
            -n kube-system \
            get svc clustermesh-apiserver -o wide
    done
}

test_connectivity() {
    for ((i = 1; i < CLUSTER_COUNT; i++)); do
        log "Testing hub -> ${CLUSTER_NAMES[i]} multi-cluster connectivity"

        cilium connectivity test \
            --kubeconfig "$MESH_KUBECONFIG" \
            --context "$HUB_CONTEXT" \
            --multi-cluster "${CONTEXTS[i]}"
    done
}

main() {
    check_prerequisites
    ensure_cilium_helm_repo
    ensure_prometheus_helm_repo
    check_kind_network

    if "$REBUILD"; then
        rebuild_clusters
    fi

    ensure_mesh_docker_network
    create_clusters
    generate_kubeconfigs
    wait_for_api

    ensure_hub_prometheus_crds
    install_all_cilium
    wait_for_cilium
    wait_for_nodes

    enable_all_clustermesh
    connect_clusters

    for context in "${CONTEXTS[@]}"; do
        enforce_clustermesh_replicas "$context"
    done

    wait_for_mesh_connections 300

    bootstrap_kubara_hub
    generate_internal_kubeconfigs
    set_values_to_publish_spoke_kubeconfigs_to_openbao
    wait_for_openbao
    publish_spoke_kubeconfigs_to_openbao

    provision_platform

    verify_cluster_config
    show_mesh_status
    show_nodes
    show_clustermesh_services

    test_connectivity

    log "Cilium hub-and-spoke mesh successfully built"

    cat <<EOF

=======================================================================
Cilium ClusterMesh complete
=======================================================================
EOF

    printf '\nClusters:\n'

    for ((i = 0; i < CLUSTER_COUNT; i++)); do
        printf '\n  %s\n' "${CLUSTER_NAMES[i]}"
        printf '    Cilium cluster ID:   %s\n' "${CLUSTER_IDS[i]}"
        printf '    Cilium cluster name: %s\n' "${CLUSTER_NAMES[i]}"
    done

    cat <<EOF

Topology:

              hub =================================
             /   \\.          \\      \\.         \\.     
            /     \\.          \\.     \\.         \\.    
       spoke-1   spoke-2.     dev.     staging    prod.

test-cluster was not modified.

The hub was rebuilt with Cilium, so Kubara itself must now be
bootstrapped again:

  z-demo-setup/scripts/bootstrap-kubara-hub.sh

(equivalent to 'kubara bootstrap hub --local' followed by the demo
DNS re-pin back to *.kubara.test, since kubara --local hardcodes the
<traefik-LB-IP>.traefik.me magic DNS)

=======================================================================
EOF
}

main "$@"