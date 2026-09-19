#!/usr/bin/env bash
set -Eeuo pipefail

# kubara bootstrap hub --local hardcodes the local evaluation DNS to
# <traefik-LB-IP>.traefik.me (kubara src/internal/localmode/localmode.go and
# src/internal/cmd/bootstrap/local.go) and rewrites config.yaml plus the
# platform-configs tree for the hub. There is no kubara flag, env var or
# config field to pin the DNS name. This wrapper runs the bootstrap and then
# re-pins the demo's *.kubara.test naming so the tracked git state and the
# deployed endpoints stay consistent with the dnsmasq setup.

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
TRAEFIK_OVERLAY="${ROOT_DIR}/platform-configs/hub/helm/traefik/values-additional.yaml"
OPENBAO_VALUES="${ROOT_DIR}/.local/openbao/values.yaml"

SKIP_BOOTSTRAP=false

usage() {
  cat <<USAGE
Usage: $0 [options]

Run 'kubara bootstrap hub --local', then re-pin the demo DNS names that
kubara overwrites with <traefik-LB-IP>.traefik.me:

  1. restore the hub 'dnsName' in config.yaml
  2. re-run kubara generate --helm (via generate-helm.sh) + restore any
     tracked platform-configs files that still contain .traefik.me
  3. re-point the deployed OpenBao ingress/apiAddr to ${OPENBAO_DNS_NAME}
  4. re-pin the gitignored traefik dashboard / openbao values hostnames
  5. re-point the deployed argocd-server ingress to ${ARGOCD_DNS_NAME}

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

hub_dns_name_from() {
  awk '
    /^  - name: hub/ { f = 1 }
    /^  - name:/ && $0 !~ /^  - name: hub/ { f = 0 }
    f && /^    dnsName:/ {
      sub(/^[ \t]*dnsName:[ \t]*/, "")
      print
      exit
    }
  ' "$1"
}

restore_hub_dns_name() {
  local target
  target="$(hub_dns_name_from <(git -C "${ROOT_DIR}" show "HEAD:config.yaml" 2>/dev/null) 2>/dev/null || true)"
  if [ -z "${target}" ]; then
    target="${HUB_DNS_NAME}"
  fi
  if grep -q "    dnsName: ${target}" "${CONFIG_FILE}"; then
    echo "==> hub dnsName already: ${target}"
    return 0
  fi
  mkdir -p "${ROOT_DIR}/.local"
  awk -v target="${target}" '
    /^  - name: hub/ { f = 1 }
    /^  - name:/ && $0 !~ /^  - name: hub/ { f = 0 }
    f && /^    dnsName:/ { printf "    dnsName: %s\n", target; next }
    { print }
  ' "${CONFIG_FILE}" > "${ROOT_DIR}/.local/config.yaml.repin"
  mv "${ROOT_DIR}/.local/config.yaml.repin" "${CONFIG_FILE}"
  echo "==> restored hub dnsName to: ${target}"
}

restore_tracked_platform_configs() {
  local file
  while IFS= read -r file; do
    [ -n "${file}" ] || continue
    git -C "${ROOT_DIR}" checkout -- "${file}"
    echo "==> restored ${file} from git"
  done < <(git -C "${ROOT_DIR}" grep -l '\.traefik\.me' -- platform-configs/ 2>/dev/null || true)
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
  helm upgrade openbao "${OPENBAO_CHART_REPO}/openbao" \
      --kubeconfig "${HUB_KUBECONFIG}" \
      --namespace "${OPENBAO_NAMESPACE}" \
      --reuse-values \
      --set "server.ingress.hosts[0].host=${OPENBAO_DNS_NAME}" \
      --set "server.ha.apiAddr=http://${OPENBAO_DNS_NAME}"
  echo "==> OpenBao ingress/apiAddr re-pointed to ${OPENBAO_DNS_NAME}"
}

repoint_argocd_ingress() {
  [ -f "${HUB_KUBECONFIG}" ] ||
      { echo "==> skip argocd re-pin: hub kubeconfig missing: ${HUB_KUBECONFIG}"; return 0; }
  kubectl --kubeconfig "${HUB_KUBECONFIG}" -n "${ARGOCD_NAMESPACE}" \
      get ingress "${ARGOCD_INGRESS}" >/dev/null 2>&1 ||
      { echo "==> skip argocd re-pin: argocd-server ingress not deployed yet"; return 0; }
  local current_host current_path
  current_host="$(kubectl --kubeconfig "${HUB_KUBECONFIG}" -n "${ARGOCD_NAMESPACE}" \
      get ingress "${ARGOCD_INGRESS}" \
      -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
  current_path="$(kubectl --kubeconfig "${HUB_KUBECONFIG}" -n "${ARGOCD_NAMESPACE}" \
      get ingress "${ARGOCD_INGRESS}" \
      -o jsonpath='{.spec.rules[0].http.paths[0].path}' 2>/dev/null || true)"
  if [ "${current_host}" = "${ARGOCD_DNS_NAME}" ] && [ "${current_path}" = "/argocd" ]; then
    echo "==> argocd ingress already re-pinned: ${ARGOCD_DNS_NAME}/argocd"
    return 0
  fi
  kubectl --kubeconfig "${HUB_KUBECONFIG}" -n "${ARGOCD_NAMESPACE}" \
      patch ingress "${ARGOCD_INGRESS}" --type='json' -p \
      '[{"op":"replace","path":"/spec/rules","value":[{"host":"'${ARGOCD_DNS_NAME}'","http":{"paths":[{"path":"/argocd","pathType":"Prefix","backend":{"service":{"name":"argocd-server","port":{"number":80}}}}]}}]}]'
  echo "==> argocd ingress host re-pinned to ${ARGOCD_DNS_NAME}/argocd"
}

if ! "${SKIP_BOOTSTRAP}"; then
  echo "==> kubara bootstrap hub --local"
  if ! kubara bootstrap hub --local; then
    echo "==> bootstrap failed; files may already be rewritten." >&2
    echo "==> fix the bootstrap, then re-run $0 --skip-bootstrap" >&2
    exit 1
  fi
fi

restore_hub_dns_name
"${SCRIPT_DIR}/generate-helm.sh"
restore_tracked_platform_configs
repoint_openbao
repoint_argocd_ingress
repoint_host_in_file "${TRAEFIK_OVERLAY}" "${HUB_DNS_NAME}"
repoint_host_in_file "${OPENBAO_VALUES}" "${OPENBAO_DNS_NAME}"

echo "==> kubara bootstrap + DNS re-pin complete"