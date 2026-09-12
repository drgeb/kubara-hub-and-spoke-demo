#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# kubara generate --helm treats the repo-root platform-components/helm tree as
# its render output and prunes anything it does not generate. The library chart
# template-library is only a helm dependency (file://../template-library), not
# a catalog service, so it is never rendered and would be deleted on every run.
# The same applies to harbor while its service definition stays disabled.
# This wrapper restores those charts from their catalog sources after running.

RESTORE_CHARTS=(
  "platform-components/helm/template-library|${ROOT_DIR}/catalogs/bootstrap/platform-components/helm/template-library"
  "platform-components/helm/harbor|${ROOT_DIR}/catalogs/platform-engineering/platform-components/helm/harbor"
)

cd "${ROOT_DIR}"

DRY_RUN=false
PASSTHROUGH_ARGS=()
for arg in "$@"; do
  if [[ "${arg}" == "--dry-run" ]]; then
    DRY_RUN=true
  fi
  PASSTHROUGH_ARGS+=("${arg}")
done

echo "==> kubara generate --helm ${PASSTHROUGH_ARGS[*]}"
kubara generate --helm "${PASSTHROUGH_ARGS[@]}"

if [[ "${DRY_RUN}" == true ]]; then
  echo "==> dry-run: skipping template-library/harbor restore"
  exit 0
fi

for spec in "${RESTORE_CHARTS[@]}"; do
  target="${spec%%|*}"
  source="${spec#*|}"
  if [[ ! -d "${source}" ]]; then
    echo "ERROR: catalog source missing for ${target}: ${source}" >&2
    exit 1
  fi
  echo "==> restoring ${target} <- ${source}"
  rm -rf "${ROOT_DIR}/${target}"
  cp -R "${source}" "${ROOT_DIR}/${target}"
done

echo "==> creating platform secrets"
"${ROOT_DIR}/z-demo-setup/scripts/create-platform-secrets.sh"