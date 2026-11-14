#!/usr/bin/env bash
# registry-cache.sh - local pull-through image caches for the kind mesh.
#
# Why: every rebuild starts six empty kind nodes that pull ~150 images from
# the internet at once. Pulls took 20-40 min (diagnose IMAGE_SLOW), and every
# fixed timeout in bring-up raced them. With these caches the first build
# fills them; later rebuilds pull from local disk.
#
# One registry:2 proxy per upstream (registry:2 proxies exactly one remote),
# each with a named volume so the cache survives `delete-kind-demo.sh`. The
# containers join the kubara-mesh docker network so kind nodes reach them by
# container name (docker DNS) - no IPs anywhere (AGENTS.md). Nodes get a
# containerd hosts.toml per registry: cache first, upstream as fallback, so a
# dead cache degrades to today's behaviour instead of breaking pulls.
#
# Usage: registry-cache.sh <command>
#   up               start caches (idempotent) and attach them to kubara-mesh
#   configure-nodes  write containerd mirror config into every demo kind node
#   detach           disconnect caches from kubara-mesh (before deleting it)
#   status           show caches, attachment and size on disk
#   purge            remove cache containers AND volumes (re-download all)
#
# Optional Docker Hub login for the docker.io cache (avoids anonymous rate
# limits): export DOCKERHUB_USERNAME / DOCKERHUB_TOKEN before running.
# Disable the cache entirely for bring-up with KUBARA_REGISTRY_CACHE=0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/kind-demo-common.sh"

REGISTRY_IMAGE="${KUBARA_REGISTRY_CACHE_IMAGE:-registry:2.8.3}"
NETWORK="$DEMO_MESH_DOCKER_NETWORK"
PREFIX="kubara-cache"
LABEL="io.kubara.demo.registry-cache=true"

# name | upstream URL the proxy fetches from | registry hosts nodes mirror
# (image refs like registry-1.docker.io/bitnami/... are a distinct containerd
# host from docker.io, so both point at the same docker.io cache.)
CACHES=(
    "docker-io|https://registry-1.docker.io|docker.io registry-1.docker.io"
    "quay-io|https://quay.io|quay.io"
    "ghcr-io|https://ghcr.io|ghcr.io"
    "registry-k8s-io|https://registry.k8s.io|registry.k8s.io"
    "code-forgejo-org|https://code.forgejo.org|code.forgejo.org"
)

log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

container_running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }
on_network() { docker inspect -f '{{json .NetworkSettings.Networks}}' "$1" 2>/dev/null | grep -q "\"$2\""; }

cmd_up() {
    log "Ensuring registry caches (${REGISTRY_IMAGE})"
    local row name upstream _hosts c
    for row in "${CACHES[@]}"; do
        IFS='|' read -r name upstream _hosts <<<"$row"
        c="${PREFIX}-${name}"
        if ! docker inspect "$c" >/dev/null 2>&1; then
            local -a env_args=(-e "REGISTRY_PROXY_REMOTEURL=${upstream}"
                               -e "REGISTRY_STORAGE_DELETE_ENABLED=true")
            if [ "$name" = "docker-io" ] && [ -n "${DOCKERHUB_USERNAME:-}" ] && [ -n "${DOCKERHUB_TOKEN:-}" ]; then
                env_args+=(-e "REGISTRY_PROXY_USERNAME=${DOCKERHUB_USERNAME}"
                           -e "REGISTRY_PROXY_PASSWORD=${DOCKERHUB_TOKEN}")
                info "${c}: authenticating to Docker Hub as ${DOCKERHUB_USERNAME}"
            fi
            docker run -d --name "$c" --restart unless-stopped \
                --label "$LABEL" \
                -v "${c}:/var/lib/registry" \
                "${env_args[@]}" \
                "$REGISTRY_IMAGE" >/dev/null
            info "${c}: created (proxy for ${upstream})"
        elif ! container_running "$c"; then
            docker start "$c" >/dev/null
            info "${c}: started"
        else
            info "${c}: running"
        fi
        if demo_docker_network_exists "$NETWORK" && ! on_network "$c" "$NETWORK"; then
            docker network connect "$NETWORK" "$c"
            info "${c}: attached to ${NETWORK}"
        fi
    done
}

hosts_toml() {
    # $1 = registry host (e.g. docker.io), $2 = cache container
    local server="https://$1"
    [ "$1" = "docker.io" ] && server="https://registry-1.docker.io"
    cat <<EOF
# Written by z-demo-setup/scripts/registry-cache.sh: try the local
# pull-through cache first; containerd falls back to 'server' if it fails.
server = "${server}"

[host."http://$2:5000"]
  capabilities = ["pull", "resolve"]
EOF
}

demo_nodes() {
    local cluster_name _rest
    while IFS='|' read -r cluster_name _rest; do
        [ -n "$cluster_name" ] || continue
        demo_cluster_exists "$cluster_name" || continue
        kind get nodes --name "$cluster_name" 2>/dev/null
    done < <(demo_parse_clusters)
}

cmd_configure_nodes() {
    demo_load_config "$DEMO_DEFAULT_CONFIG"
    log "Configuring containerd registry mirrors on demo kind nodes"
    local node row name _upstream hosts host c dir configured=0 legacy="" nodes probe_node=""
    # Read the node list once: `demo_nodes | head -1` would SIGPIPE under
    # pipefail and abort the script (exit 141).
    nodes="$(demo_nodes)"
    while read -r node; do
        [ -n "$node" ] || continue
        if ! docker exec "$node" grep -q 'config_path *= *"/etc/containerd/certs.d"' /etc/containerd/config.toml 2>/dev/null; then
            legacy="${legacy} ${node}"
            continue
        fi
        for row in "${CACHES[@]}"; do
            IFS='|' read -r name _upstream hosts <<<"$row"
            c="${PREFIX}-${name}"
            for host in $hosts; do
                dir="/etc/containerd/certs.d/${host}"
                hosts_toml "$host" "$c" |
                    docker exec -i "$node" sh -c "mkdir -p '${dir}' && cat > '${dir}/hosts.toml'"
            done
        done
        configured=$((configured + 1))
        [ -n "$probe_node" ] || probe_node="$node"
        info "${node}: mirrors configured"
    done <<<"$nodes"

    if [ -n "$legacy" ]; then
        warn "these nodes were created without containerd config_path and will NOT use the cache:${legacy}"
        warn "rebuild them (delete-kind-demo.sh && just bring-up) to pick up the kind config patch"
    fi

    # Reachability from inside the mesh, as containerd will see it (from a
    # node that actually uses the mirrors).
    [ -n "$probe_node" ] || return 0
    for row in "${CACHES[@]}"; do
        IFS='|' read -r name _upstream _hosts <<<"$row"
        c="${PREFIX}-${name}"
        if docker exec "$probe_node" curl -fsS -m 5 -o /dev/null "http://${c}:5000/v2/" 2>/dev/null; then
            info "${c}: reachable from ${probe_node}"
        else
            warn "${c}: NOT reachable from ${probe_node}; pulls will fall back to the upstream registry"
        fi
    done
}

cmd_detach() {
    demo_docker_network_exists "$NETWORK" || return 0
    local row name _u _h c
    for row in "${CACHES[@]}"; do
        IFS='|' read -r name _u _h <<<"$row"
        c="${PREFIX}-${name}"
        if on_network "$c" "$NETWORK"; then
            docker network disconnect "$NETWORK" "$c" >/dev/null 2>&1 &&
                info "${c}: detached from ${NETWORK} (cache kept)"
        fi
    done
}

cmd_status() {
    local row name upstream _h c state net size
    printf '%-32s %-9s %-9s %-8s %s\n' CACHE STATE MESH SIZE UPSTREAM
    for row in "${CACHES[@]}"; do
        IFS='|' read -r name upstream _h <<<"$row"
        c="${PREFIX}-${name}"
        if ! docker inspect "$c" >/dev/null 2>&1; then
            printf '%-32s %-9s %-9s %-8s %s\n' "$c" missing - - "$upstream"; continue
        fi
        container_running "$c" && state=running || state=stopped
        on_network "$c" "$NETWORK" && net=attached || net=detached
        size="$(docker exec "$c" du -sh /var/lib/registry 2>/dev/null | cut -f1)"
        printf '%-32s %-9s %-9s %-8s %s\n' "$c" "$state" "$net" "${size:--}" "$upstream"
    done
}

cmd_purge() {
    local row name _u _h c
    for row in "${CACHES[@]}"; do
        IFS='|' read -r name _u _h <<<"$row"
        c="${PREFIX}-${name}"
        docker rm -f "$c" >/dev/null 2>&1 && info "removed container ${c}"
        docker volume rm "$c" >/dev/null 2>&1 && info "removed volume ${c}"
    done
    return 0
}

case "${1:-}" in
    up) cmd_up ;;
    configure-nodes) cmd_configure_nodes ;;
    detach) cmd_detach ;;
    status) cmd_status ;;
    purge) cmd_purge ;;
    *) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
