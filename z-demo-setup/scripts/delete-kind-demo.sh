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

stop_cloud_provider_kind() {
    # The Justfile start-cloud-provider-kind recipe writes the PID file to the
    # repo root; tolerate the legacy SCRIPT_DIR location as well.
    local root_pid_file="${DEMO_REPO_ROOT}/.cloud-provider-kind"
    local script_pid_file="${SCRIPT_DIR}/.cloud-provider-kind"
    local pid=""
    local pids=""

    if [ "$DRY_RUN" = "true" ]; then
        printf '+\tstop cloud-provider-kind (pidfile or pgrep + sudo kill)\n'
        return 0
    fi

    if [ -f "$root_pid_file" ]; then
        pid="$(cat "$root_pid_file")"
    elif [ -f "$script_pid_file" ]; then
        pid="$(cat "$script_pid_file")"
    fi

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        if sudo kill "$pid" 2>/dev/null; then
            rm -f "$root_pid_file" "$script_pid_file"
            echo "stopped cloud-provider-kind (pid $pid)"
            return 0
        fi
        echo "failed to stop cloud-provider-kind (pid $pid)" >&2
        return 1
    fi

    pids="$(pgrep -f cloud-provider-kind 2>/dev/null || true)"
    if [ -n "$pids" ]; then
        # shellcheck disable=SC2086
        if sudo kill $pids 2>/dev/null; then
            rm -f "$root_pid_file" "$script_pid_file"
            echo "stopped cloud-provider-kind (pids $pids)"
            return 0
        fi
        echo "failed to stop cloud-provider-kind (pids $pids)" >&2
        return 1
    fi

    rm -f "$root_pid_file" "$script_pid_file"
    echo "cloud-provider-kind is not running"
}
cleanup_local_artifacts() {
  local local_dir="${DEMO_REPO_ROOT}/.local"

  if [ -d "${local_dir}/kind-demo" ]; then
    printf 'Removing stale internal kubeconfigs: %s\n' "${local_dir}/kind-demo"
    demo_run rm -rf "${local_dir}/kind-demo"
  fi

  for file in kind.kubeconfig kind.kubeconfig.bak; do
    if [ -f "${local_dir}/${file}" ]; then
      printf 'Removing stale kubeconfig: %s\n' "${local_dir}/${file}"
      demo_run rm -f "${local_dir}/${file}"
    fi
  done
}

cluster_count=0
failures=0

printf '\n=== Deleting demo clusters ===\n'

while IFS='|' read -r cluster_name _kind_config; do
  [ -n "$cluster_name" ] || continue

  cluster_count=$((cluster_count + 1))
  demo_delete_cluster "$cluster_name" || failures=$((failures + 1))
done < <(demo_parse_clusters)

[ "$cluster_count" -gt 0 ] || demo_die "No clusters found in config: $DEMO_CONFIG_FILE"

printf '\n=== Deleting hub cluster ===\n'
demo_delete_cluster "$DEMO_HUB_CLUSTER_NAME" || failures=$((failures + 1))

printf '\n=== Stopping cloud-provider-kind ===\n'
stop_cloud_provider_kind || failures=$((failures + 1))

printf '\n=== Cleaning up Docker networks ===\n'
demo_cleanup_demo_networks || failures=$((failures + 1))

printf '\n=== Cleaning up local artifacts ===\n'
cleanup_local_artifacts || failures=$((failures + 1))

if [ "$failures" -gt 0 ]; then
  demo_die "${failures} step(s) reported errors; see messages above"
fi

printf '\nCleanup complete.\n'

