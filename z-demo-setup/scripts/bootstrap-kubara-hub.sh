#!/usr/bin/env bash
set -Eeuo pipefail

# kubara bootstrap hub --local hardcodes the local evaluation DNS to
# <traefik-LB-IP>.traefik.me (kubara src/internal/localmode/localmode.go and
# src/internal/cmd/bootstrap/local.go) and rewrites config.yaml plus the
# platform-configs tree for the hub. There is no kubara flag, env var or
# config field to pin the DNS name. It also writes .local/openbao/values.yaml
# with server.ingress.ingressClassName: traefik baked in ("Writing local
# OpenBao values" in the binary), independent of config.yaml's per-cluster
# ingressClassName. This wrapper runs the bootstrap and then re-pins the
# demo's *.kubara.test naming and the cilium ingress class so the tracked git
# state and the deployed endpoints stay consistent with the dnsmasq setup.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/kind-demo-common.sh"

ROOT_DIR="${DEMO_REPO_ROOT}"
CONFIG_FILE="${ROOT_DIR}/config.yaml"
HUB_DNS_NAME="${HUB_DNS_NAME:-hub.kubara.test}"
OPENBAO_DNS_NAME="openbao.${HUB_DNS_NAME}"
ARGOCD_DNS_NAME="argocd.${HUB_DNS_NAME}"
ARGOCD_NAMESPACE="argocd"
ARGOCD_INGRESS="argocd-server"
OPENBAO_NAMESPACE="openbao"
OPENBAO_CHART_REPO="openbao"
OPENBAO_CHART_REPO_URL="https://openbao.github.io/openbao-helm"
HUB_KUBECONFIG="${ROOT_DIR}/.local/kind.kubeconfig"
OPENBAO_VALUES="${ROOT_DIR}/.local/openbao/values.yaml"

SKIP_BOOTSTRAP=false

usage() {
  cat <<USAGE
Usage: $0 [options]

Run 'kubara bootstrap hub --local', then re-pin the demo DNS names that
kubara overwrites with <traefik-LB-IP>.traefik.me:

  1. restore config.yaml from git (hub 'dnsName' + the cilium ingress class)
  2. re-run kubara generate --helm (via generate-helm.sh) + restore any
     tracked platform-configs files that picked a traefik reference back up
  3. drop the traefik routes kubara regenerates (traefik is not in the catalog)
  4. re-point the deployed OpenBao ingress/apiAddr to ${OPENBAO_DNS_NAME}
  5. re-pin the openbao values hostnames
  6. verify the argocd-server ingress is ${ARGOCD_DNS_NAME} (git-driven via values-additional.yaml)

Options:
      --skip-bootstrap  Only re-pin (bootstrap already ran successfully)
  -h, --help            Show this help
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-bootstrap) SKIP_BOOTSTRAP=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) demo_die "Unknown argument: $1 (use --help)" ;;
  esac
done

command -v kubara >/dev/null 2>&1 ||
    demo_die "kubara is not installed (required unless --skip-bootstrap)"

demo_require_cmd git
demo_require_cmd kubectl
demo_require_cmd helm

[ -f "${CONFIG_FILE}" ] || demo_die "config file not found: ${CONFIG_FILE}"

restore_config_yaml() {
  # kubara bootstrap hub --local rewrites config.yaml: it re-pins the hub
  # dnsName to <traefik-LB-IP>.traefik.me and re-applies its compiled-in
  # defaults (ingressClassName: traefik, cilium.status: disabled). There is no
  # kubara flag, env var or config field to prevent that.
  #
  # Restoring the whole file (not just the dnsName) matters: kubara generate
  # renders config.yaml's ingressClassName into every
  # platform-configs/<cluster>/helm/<app>/values.generated.yaml, so a stale
  # "traefik" in config.yaml silently reinstates traefik on every cluster.
  # Git main is the source of truth for both the demo naming and the cilium
  # ingress class.
  git -C "${ROOT_DIR}" checkout -- config.yaml
  echo "==> restored config.yaml from git (hub dnsName + cilium ingress class)"
}

restore_tracked_platform_configs() {
  # kubara's bootstrap also rewrites the hand-authored per-cluster
  # platform-configs values with its compiled-in traefik defaults
  # (ingressClassName: traefik, traefik ingress annotations, traefik
  # middleware CRDs). The demo runs cilium as the only ingress controller, so
  # every tracked file that picked a traefik reference back up is restored
  # from git.
  local file
  while IFS= read -r file; do
    [ -n "${file}" ] || continue
    grep -q -E 'ingressClassName:[[:space:]]*traefik|traefik\.ingress\.kubernetes\.io|\.traefik\.me' \
      "${ROOT_DIR}/${file}" 2>/dev/null || continue
    git -C "${ROOT_DIR}" checkout -- "${file}"
    echo "==> restored ${file} from git"
  done < <(git -C "${ROOT_DIR}" ls-files platform-configs/)
}

remove_generated_traefik_configs() {
  # kubara's local bootstrap mode still renders a traefik dashboard ingress
  # route (platform-configs/<cluster>/helm/traefik/) even though traefik is
  # not part of the catalog any more. Those routes target
  # <traefik-lb-ip>.traefik.me and would resurrect the removed controller.
  local dir
  while IFS= read -r dir; do
    [ -n "${dir}" ] || continue
    rm -rf "${dir}"
    echo "==> removed generated ${dir} (traefik is not in the catalog)"
  done < <(find "${ROOT_DIR}/platform-configs" -type d -name traefik 2>/dev/null || true)
}

restore_demo_overrides() {
  # kubara generate --helm treats platform-components/helm as its render
  # output and prunes anything it does not generate, and the bootstrap rewrites
  # the per-cluster platform-configs values-additional.yaml files it manages.
  # That drops our durable tracked additions (argo-cd root redirect, cert-manager
  # local CA, homer subdomain, kube-prometheus-stack subdomain routing) on every
  # run. Git main is the source of truth for these paths, so restore them after
  # generate to keep bootstrap idempotent.
  local file
  for file in \
      "platform-components/helm/argo-cd/values.yaml" \
      "platform-configs/hub/helm/cert-manager/values-additional.yaml" \
      "platform-configs/hub/helm/homer-dashboard/values-additional.yaml" \
      "platform-configs/hub/helm/kube-prometheus-stack/values-additional.yaml"; do
    [ -f "${ROOT_DIR}/${file}" ] || continue
    git -C "${ROOT_DIR}" checkout -- "${file}"
    echo "==> restored ${file} from git"
  done
}

repoint_host_in_file() {
  local file="$1"
  local host="$2"
  local tmp
  [ -f "${file}" ] || return 0
  grep -q '\.traefik\.me' "${file}" || return 0
  tmp="$(mktemp "${ROOT_DIR}/.local/re-pin-host.XXXXXX")"
  sed -e 's/Host(`[^`]*`)/Host(`'"${host}"'`)/' \
      -e 's#apiAddr: "http://[^"]*#apiAddr: "http://'"${host}"'#' \
      -e 's#^      - host: .*#      - host: '"${host}"'#' \
      "${file}" > "${tmp}"
  mv "${tmp}" "${file}"
  echo "==> re-pinned ${file} host to ${host}"
}

repoint_openbao() {
  [ -f "${HUB_KUBECONFIG}" ] ||
      { echo "==> skip OpenBao re-pin: hub kubeconfig missing: ${HUB_KUBECONFIG}"; return 0; }
  kubectl --kubeconfig "${HUB_KUBECONFIG}" -n "${OPENBAO_NAMESPACE}" \
      get ingress openbao >/dev/null 2>&1 ||
      { echo "==> skip OpenBao re-pin: openbao not deployed yet"; return 0; }
  helm repo add "${OPENBAO_CHART_REPO}" "${OPENBAO_CHART_REPO_URL}" >/dev/null 2>&1 || true
  # kubara bootstrap hub --local regenerates .local/openbao/values.yaml with
  # ingressClassName: traefik hardcoded (see the header note), and --reuse-values
  # would otherwise keep that stale class forever. Force the demo's cilium class
  # explicitly so the release self-heals on every run and its Ingress is actually
  # served (traefik is removed from the mesh).
  helm upgrade openbao "${OPENBAO_CHART_REPO}/openbao" \
      --kubeconfig "${HUB_KUBECONFIG}" \
      --namespace "${OPENBAO_NAMESPACE}" \
      --reuse-values \
      --set "server.ingress.ingressClassName=cilium" \
      --set "server.ingress.hosts[0].host=${OPENBAO_DNS_NAME}" \
      --set "server.ha.apiAddr=http://${OPENBAO_DNS_NAME}"
  echo "==> OpenBao ingress/apiAddr re-pointed to ${OPENBAO_DNS_NAME} (ingressClassName=cilium)"
}

repoint_argocd_ingress() {
  [ -f "${HUB_KUBECONFIG}" ] ||
      { echo "==> skip argocd verification: hub kubeconfig missing: ${HUB_KUBECONFIG}"; return 0; }
  kubectl --kubeconfig "${HUB_KUBECONFIG}" -n "${ARGOCD_NAMESPACE}" \
      get ingress "${ARGOCD_INGRESS}" >/dev/null 2>&1 ||
      { echo "==> skip argocd verification: argocd-server ingress not deployed yet"; return 0; }
  local current_host current_path
  current_host="$(kubectl --kubeconfig "${HUB_KUBECONFIG}" -n "${ARGOCD_NAMESPACE}" \
      get ingress "${ARGOCD_INGRESS}" \
      -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
  current_path="$(kubectl --kubeconfig "${HUB_KUBECONFIG}" -n "${ARGOCD_NAMESPACE}" \
      get ingress "${ARGOCD_INGRESS}" \
      -o jsonpath='{.spec.rules[0].http.paths[0].path}' 2>/dev/null || true)"
  if [ "${current_host}" = "${ARGOCD_DNS_NAME}" ] && [ "${current_path}" = "/argocd" ]; then
    echo "==> argocd ingress already git-driven: ${ARGOCD_DNS_NAME}/argocd"
  else
    echo "==> WARNING: argocd ingress is '${current_host}${current_path}' (expected ${ARGOCD_DNS_NAME}/argocd)." >&2
    echo "==> WARNING: host is set by platform-configs/hub/helm/argo-cd/values-additional.yaml; push main and let Argo sync." >&2
  fi
}

if ! "${SKIP_BOOTSTRAP}"; then
  echo "==> kubara bootstrap hub --local"
  if ! kubara bootstrap hub --local; then
    echo "==> bootstrap failed; files may already be rewritten." >&2
    echo "==> fix the bootstrap, then re-run $0 --skip-bootstrap" >&2
    exit 1
  fi
fi

restore_config_yaml
"${SCRIPT_DIR}/generate-helm.sh"
restore_tracked_platform_configs
restore_demo_overrides
remove_generated_traefik_configs
repoint_openbao
repoint_argocd_ingress
repoint_host_in_file "${OPENBAO_VALUES}" "${OPENBAO_DNS_NAME}"

echo "==> kubara bootstrap + DNS re-pin complete"