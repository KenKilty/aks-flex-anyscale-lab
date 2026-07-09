#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ANYSCALE_AKS_ENV_FILE:-${ROOT_DIR}/.env}"
STATE_DIR="${ROOT_DIR}/.github/agents/state"
FLEX_NETWORK_GATES_LIB="${ROOT_DIR}/scripts/lib/flex-network-gates.sh"

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

source_env() {
  [[ -f "${ENV_FILE}" ]] || die "missing env file: ${ENV_FILE}"
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
}

load_names() {
  RG="rg-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
  CLUSTER="aks-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
}

main() {
  local artifact_dir anyscale_host_name

  need_cmd az
  need_cmd jq
  need_cmd kubectl

  source_env
  load_names
  # shellcheck source=./lib/flex-network-gates.sh
  source "${FLEX_NETWORK_GATES_LIB}"

  [[ "${TF_VAR_flex_host_enabled}" == "true" ]] || die "TF_VAR_flex_host_enabled must be true for Flex network validation"

  az aks get-credentials --resource-group "${RG}" --name "${CLUSTER}" --overwrite-existing --only-show-errors >/dev/null
  artifact_dir="${STATE_DIR}/m5-flex-network"
  anyscale_host_name="$(lab_gate_anyscale_host_name "${TF_VAR_anyscale_control_plane_url:-${ANYSCALE_HOST:-https://console.azure.anyscale.com}}")"

  lab_gate_flex_node_ready "${artifact_dir}"
  lab_gate_kube_proxy_flex_ready "${artifact_dir}"
  lab_gate_flex_dns_ready "${artifact_dir}" "${anyscale_host_name}"
  lab_gate_flex_https_egress "${artifact_dir}" "${anyscale_host_name}"
  lab_gate_aks_to_flex_line_of_sight "${artifact_dir}"
  lab_gate_anyscale_operator_ready "${artifact_dir}"
  lab_gate_anyscale_gateway_ready "${artifact_dir}"
}

main "$@"
