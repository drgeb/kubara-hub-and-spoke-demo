#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_DIR="${ROOT_DIR}/z-demo-setup/config"

CILIUM_VERSION="${CILIUM_VERSION:-1.19.5}"

MESH_DOCKER_NETWORK="kubara-mesh"
MESH_DOCKER_SUBNET="172.19.0.0/16"
MESH_DOCKER_GATEWAY="172.19.0.1"
MESH_DOCKER_IP_RANGE="172.19.0.10/28"

HUB_KIND="hub"
SPOKE1_KIND="kubara-spoke-1"
SPOKE2_KIND="kubara-spoke-2"

HUB_CONTEXT="kind-hub"
SPOKE1_CONTEXT="kind-kubara-spoke-1"
SPOKE2_CONTEXT="kind-kubara-spoke-2"

HUB_ID="1"
SPOKE1_ID="2"
SPOKE2_ID="3"

HUB_NAME="hub"
SPOKE1_NAME="kubara-spoke-1"
SPOKE2_NAME="kubara-spoke-2"

HUB_KIND_CONFIG="${CONFIG_DIR}/kind-hub-cilium.yaml"
SPOKE1_KIND_CONFIG="${CONFIG_DIR}/kind-spoke1-overlay.yaml"
SPOKE2_KIND_CONFIG="${CONFIG_DIR}/kind-spoke2-overlay.yaml"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kubara-cilium.XXXXXX")"

HUB_KUBECONFIG="${TMP_DIR}/hub.kubeconfig"
SPOKE1_KUBECONFIG="${TMP_DIR}/spoke1.kubeconfig"
SPOKE2_KUBECONFIG="${TMP_DIR}/spoke2.kubeconfig"
MESH_KUBECONFIG="${TMP_DIR}/mesh.kubeconfig"

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
  --rebuild    Delete and recreate hub and both spokes
  -h, --help   Show this help

Environment:
  CILIUM_VERSION=1.19.5
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rebuild)
            REBUILD=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
    shift
done

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

    [[ -f "$HUB_KIND_CONFIG" ]] ||
        die "Missing $HUB_KIND_CONFIG"

    [[ -f "$SPOKE1_KIND_CONFIG" ]] ||
        die "Missing $SPOKE1_KIND_CONFIG"

    [[ -f "$SPOKE2_KIND_CONFIG" ]] ||
        die "Missing $SPOKE2_KIND_CONFIG"

    log "Cilium CLI"

    cilium version
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

    docker network inspect kind >/dev/null 2>&1 ||
        die "Docker network 'kind' does not exist"
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

    cat <<EOF

WARNING:

  This will DELETE these Kind clusters:

    ${HUB_KIND}
    ${SPOKE1_KIND}
    ${SPOKE2_KIND}

  The '${HUB_KIND}' cluster currently contains your Kubara hub.

  'test-cluster' will NOT be touched.

EOF

    log "Deleting existing lab clusters"

    delete_cluster "$SPOKE2_KIND"
    delete_cluster "$SPOKE1_KIND"
    delete_cluster "$HUB_KIND"
}

create_kind_cluster() {
    local name="$1"
    local config="$2"

    if cluster_exists "$name"; then
        log "Kind cluster '${name}' already exists"
        return
    fi

    log "Creating Kind cluster '${name}'"

    KIND_EXPERIMENTAL_DOCKER_NETWORK="$MESH_DOCKER_NETWORK" \
    kind create cluster \
    --name "$name" \
    --config "$config"
}

create_clusters() {
    log "Creating Kind clusters"

    create_kind_cluster "$HUB_KIND" "$HUB_KIND_CONFIG"
    create_kind_cluster "$SPOKE1_KIND" "$SPOKE1_KIND_CONFIG"
    create_kind_cluster "$SPOKE2_KIND" "$SPOKE2_KIND_CONFIG"
}

generate_kubeconfigs() {
    log "Generating isolated Kind kubeconfigs"

    kind get kubeconfig --name "$HUB_KIND" > "$HUB_KUBECONFIG"
    kind get kubeconfig --name "$SPOKE1_KIND" > "$SPOKE1_KUBECONFIG"
    kind get kubeconfig --name "$SPOKE2_KIND" > "$SPOKE2_KUBECONFIG"

    KUBECONFIG="${HUB_KUBECONFIG}:${SPOKE1_KUBECONFIG}:${SPOKE2_KUBECONFIG}" \
        kubectl config view --flatten > "$MESH_KUBECONFIG"

    chmod 600 \
        "$HUB_KUBECONFIG" \
        "$SPOKE1_KUBECONFIG" \
        "$SPOKE2_KUBECONFIG" \
        "$MESH_KUBECONFIG"
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

    wait_for_api_cluster "$HUB_CONTEXT"
    wait_for_api_cluster "$SPOKE1_CONTEXT"
    wait_for_api_cluster "$SPOKE2_CONTEXT"
}

wait_for_nodes() {
    log "Waiting for Kubernetes nodes"

    local contexts=(
        "$HUB_CONTEXT"
        "$SPOKE1_CONTEXT"
        "$SPOKE2_CONTEXT"
    )

    for context in "${contexts[@]}"; do
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

install_cilium() {
    local context="$1"
    local cluster_name="$2"
    local cluster_id="$3"

    log "Installing Cilium ${CILIUM_VERSION} on ${cluster_name}"

    # Cilium CLI may time out while Kubernetes components are still
    # becoming ready. Do not make the CLI timeout itself fatal.
    cilium install \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$context" \
        --version "$CILIUM_VERSION" \
        --set "cluster.name=${cluster_name}" \
        --set "cluster.id=${cluster_id}" \
        --set "ipam.mode=kubernetes" \
        --set "clustermesh.apiserver.replicas=1" \
        --wait \
        || {
            echo "    Cilium install returned non-zero; Kubernetes readiness will be checked separately."
        }
}

install_all_cilium() {
    install_cilium "$HUB_CONTEXT" "$HUB_NAME" "$HUB_ID"
    install_cilium "$SPOKE1_CONTEXT" "$SPOKE1_NAME" "$SPOKE1_ID"
    install_cilium "$SPOKE2_CONTEXT" "$SPOKE2_NAME" "$SPOKE2_ID"
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

    wait_for_cilium_cluster "$HUB_CONTEXT"
    wait_for_cilium_cluster "$SPOKE1_CONTEXT"
    wait_for_cilium_cluster "$SPOKE2_CONTEXT"
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

        local spoke1_connected=false
        local spoke2_connected=false

        if grep -Eq \
            'kubara-spoke-1: [0-9]+/[0-9]+ configured, [0-9]+/[0-9]+ connected - KVStoreMesh: [0-9]+/[0-9]+ configured, [0-9]+/[0-9]+ connected' \
            <<< "$hub_status"; then

            local spoke1_line
            spoke1_line="$(
                grep 'kubara-spoke-1:' <<< "$hub_status" || true
            )"

            if [[ "$spoke1_line" =~ configured,\ 1/1\ connected ]] &&
               [[ "$spoke1_line" =~ KVStoreMesh:\ 1/1\ configured,\ 1/1\ connected ]]; then
                spoke1_connected=true
            fi
        fi

        if grep -Eq \
            'kubara-spoke-2: [0-9]+/[0-9]+ configured, [0-9]+/[0-9]+ connected - KVStoreMesh: [0-9]+/[0-9]+ configured, [0-9]+/[0-9]+ connected' \
            <<< "$hub_status"; then

            local spoke2_line
            spoke2_line="$(
                grep 'kubara-spoke-2:' <<< "$hub_status" || true
            )"

            if [[ "$spoke2_line" =~ configured,\ 1/1\ connected ]] &&
               [[ "$spoke2_line" =~ KVStoreMesh:\ 1/1\ configured,\ 1/1\ connected ]]; then
                spoke2_connected=true
            fi
        fi

        if [[ "$spoke1_connected" == true &&
              "$spoke2_connected" == true ]]; then

            echo "    ClusterMesh connections are established"
            echo "      hub -> kubara-spoke-1: connected"
            echo "      hub -> kubara-spoke-2: connected"
            echo "      KVStoreMesh -> kubara-spoke-1: connected"
            echo "      KVStoreMesh -> kubara-spoke-2: connected"

            return 0
        fi

        local spoke1_line
        local spoke2_line

        spoke1_line="$(grep 'kubara-spoke-1:' <<< "$hub_status" || echo 'not ready')"
        spoke2_line="$(grep 'kubara-spoke-2:' <<< "$hub_status" || echo 'not ready')"

        echo "    waiting..."
        echo "      ${spoke1_line}"
        echo "      ${spoke2_line}"

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
        --service-type NodePort \
        || {
            echo "    ClusterMesh enable returned non-zero; waiting for Kubernetes readiness..."
        }

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

    wait_for_clustermesh \
        "$MESH_KUBECONFIG" \
        "$context" \
        180
}

enable_all_clustermesh() {
    enable_clustermesh "$HUB_CONTEXT"
    enable_clustermesh "$SPOKE1_CONTEXT"
    enable_clustermesh "$SPOKE2_CONTEXT"
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
    connect_cluster "$HUB_CONTEXT" "$SPOKE1_CONTEXT"
    connect_cluster "$HUB_CONTEXT" "$SPOKE2_CONTEXT"
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
    show_cluster_config "$HUB_CONTEXT"
    show_cluster_config "$SPOKE1_CONTEXT"
    show_cluster_config "$SPOKE2_CONTEXT"
}

show_mesh_status() {
    log "ClusterMesh status: hub"

    cilium clustermesh status \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$HUB_CONTEXT"

    log "ClusterMesh status: spoke-1"

    cilium clustermesh status \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$SPOKE1_CONTEXT"

    log "ClusterMesh status: spoke-2"

    cilium clustermesh status \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$SPOKE2_CONTEXT"
}

show_nodes() {
    log "Kubernetes nodes"

    kubectl \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$HUB_CONTEXT" \
        get nodes -o wide

    kubectl \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$SPOKE1_CONTEXT" \
        get nodes -o wide

    kubectl \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$SPOKE2_CONTEXT" \
        get nodes -o wide
}

show_clustermesh_services() {
    log "ClusterMesh services"

    kubectl \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$HUB_CONTEXT" \
        -n kube-system \
        get svc clustermesh-apiserver -o wide

    kubectl \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$SPOKE1_CONTEXT" \
        -n kube-system \
        get svc clustermesh-apiserver -o wide

    kubectl \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$SPOKE2_CONTEXT" \
        -n kube-system \
        get svc clustermesh-apiserver -o wide
}

test_connectivity() {
    log "Testing hub -> spoke-1 multi-cluster connectivity"

    cilium connectivity test \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$HUB_CONTEXT" \
        --multi-cluster "$SPOKE1_CONTEXT"

    log "Testing hub -> spoke-2 multi-cluster connectivity"

    cilium connectivity test \
        --kubeconfig "$MESH_KUBECONFIG" \
        --context "$HUB_CONTEXT" \
        --multi-cluster "$SPOKE2_CONTEXT"
}

main() {
    check_prerequisites
    ensure_cilium_helm_repo
    check_kind_network

    if "$REBUILD"; then
        rebuild_clusters
    fi

    ensure_mesh_docker_network
    create_clusters
    generate_kubeconfigs
    wait_for_api

    install_all_cilium
    wait_for_cilium
    wait_for_nodes

    enable_all_clustermesh

    connect_clusters

    enforce_clustermesh_replicas "$HUB_CONTEXT"
    enforce_clustermesh_replicas "$SPOKE1_CONTEXT"
    enforce_clustermesh_replicas "$SPOKE2_CONTEXT"

    wait_for_mesh_connections 300
    
    verify_cluster_config
    show_mesh_status
    show_nodes
    show_clustermesh_services

    test_connectivity

    log "Cilium hub-and-spoke mesh successfully built"

    cat <<EOF

========================================================================
Cilium ClusterMesh complete
========================================================================

Clusters:

  hub
    Cilium cluster ID:   ${HUB_ID}
    Cilium cluster name: ${HUB_NAME}

  kubara-spoke-1
    Cilium cluster ID:   ${SPOKE1_ID}
    Cilium cluster name: ${SPOKE1_NAME}

  kubara-spoke-2
    Cilium cluster ID:   ${SPOKE2_ID}
    Cilium cluster name: ${SPOKE2_NAME}

Topology:

              hub
             /   \\
            /     \\
       spoke-1   spoke-2

test-cluster was not modified.

The hub was rebuilt with Cilium, so Kubara itself must now be
bootstrapped again:

  kubara bootstrap hub --local

========================================================================
EOF
}

main "$@"