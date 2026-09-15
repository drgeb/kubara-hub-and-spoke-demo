#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/kind-demo-common.sh"

CONFIG_FILE="$DEMO_DEFAULT_CONFIG"
DRY_RUN="false"

usage() {
  cat <<USAGE
Usage: $0 [options]

Delete the kind clusters defined in z-demo-setup/config/kind-demo.yaml plus
the hub cluster (${DEMO_HUB_CLUSTER_NAME}), along with any cloud-provider-kind
load balancers and leftover Docker networks (kubara-mesh, empty 'kind' default).

Options:
  -c, --config <file>  Path to the demo environment YAML
      --dry-run        Print the kind commands without executing them
  -h, --help           Show this help
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -c|--config)
      [ -n "${2:-}" ] || demo_die "Missing value for $1"
      CONFIG_FILE="$2"
      shift 2
      ;;
    --config=*)
      CONFIG_FILE="${1#*=}"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      demo_die "Unknown argument: $1"
      ;;
  esac
done

demo_load_config "$CONFIG_FILE"

if [ "$DRY_RUN" != "true" ]; then
  demo_require_cmd kind
  demo_require_cmd docker
fi

demo_delete_cluster() {
  local cluster_name="$1"

  demo_validate_cluster_name "$cluster_name"

  if [ "$DRY_RUN" = "true" ]; then
    demo_run kind delete cluster --name "$cluster_name"
    demo_delete_cloud_provider_kind_lbs "$cluster_name"
    return
  fi

  if demo_cluster_exists "$cluster_name"; then
    printf 'Deleting kind cluster: %s\n' "$cluster_name"
    demo_run kind delete cluster --name "$cluster_name"
  else
    printf 'kind cluster does not exist, skipping: %s\n' "$cluster_name"
  fi

  demo_delete_cloud_provider_kind_lbs "$cluster_name"
}

cluster_count=0

while IFS='|' read -r cluster_name _kind_config; do
  [ -n "$cluster_name" ] || continue

  cluster_count=$((cluster_count + 1))
  demo_delete_cluster "$cluster_name"
done < <(demo_parse_clusters)

[ "$cluster_count" -gt 0 ] || demo_die "No clusters found in config: $DEMO_CONFIG_FILE"

printf 'Deleting hub cluster: %s\n' "$DEMO_HUB_CLUSTER_NAME"
demo_delete_cluster "$DEMO_HUB_CLUSTER_NAME"

demo_cleanup_demo_networks
