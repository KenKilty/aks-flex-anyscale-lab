#!/usr/bin/env bash
# shellcheck disable=SC2154
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ANYSCALE_AKS_ENV_FILE:-${ROOT_DIR}/.env}"
NVIDIA_DEVICE_PLUGIN_VERSION="${NVIDIA_DEVICE_PLUGIN_VERSION:-v0.17.1}"
AKS_FLEX_AGENT_POOL_NAME="${AKS_FLEX_AGENT_POOL_NAME:-aksflexnodes}"

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

resolve_gpu_pool_name() {
  jq -r 'to_entries[0].value.name // empty' <<<"${TF_VAR_gpu_pool_configs}"
}

resolve_gpu_product_label() {
  local accelerator_type

  if [[ -n "${ANYSCALE_PROOF_GPU_PRODUCT_LABEL:-}" ]]; then
    printf '%s\n' "${ANYSCALE_PROOF_GPU_PRODUCT_LABEL}"
    return
  fi

  accelerator_type="${ANYSCALE_PROOF_GPU_ACCELERATOR_TYPE:-T4}"
  case "${accelerator_type}" in
  T4)
    printf 'NVIDIA-T4\n'
    ;;
  *)
    printf 'NVIDIA-%s\n' "${accelerator_type}"
    ;;
  esac
}

main() {
  local gpu_allocatable gpu_pool_name gpu_product_label target_pool

  need_cmd jq
  need_cmd kubectl
  source_env

  target_pool="${AKS_FLEX_AGENT_POOL_NAME}"
  if [[ "${ANYSCALE_PROOF_GPU_TARGET:-flex}" == "aks" ]]; then
    [[ "${TF_VAR_gpu_pool_configs}" != "{}" ]] || die "AKS GPU target requested but GPU pool config is disabled in ${ENV_FILE}"
    gpu_pool_name="$(resolve_gpu_pool_name)"
    [[ -n "${gpu_pool_name}" ]] || die "unable to determine GPU pool name from TF_VAR_gpu_pool_configs"
    target_pool="${gpu_pool_name}"
  fi

  kubectl apply -f "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${NVIDIA_DEVICE_PLUGIN_VERSION}/deployments/static/nvidia-device-plugin.yml"

  kubectl -n kube-system patch ds nvidia-device-plugin-daemonset --type strategic -p "$(
    cat <<PATCH
spec:
  template:
    spec:
      nodeSelector:
        agentpool: ${target_pool}
      tolerations:
        - key: aks-flex-node
          operator: Equal
          value: "true"
          effect: NoSchedule
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
        - key: node.anyscale.com/capacity-type
          operator: Equal
          value: ON_DEMAND
          effect: NoSchedule
        - key: node.anyscale.com/accelerator-type
          operator: Equal
          value: GPU
          effect: NoSchedule
PATCH
  )"

  kubectl -n kube-system rollout status ds/nvidia-device-plugin-daemonset --timeout=5m
  gpu_allocatable="0"
  for _ in {1..30}; do
    gpu_allocatable="$(kubectl get nodes -l "agentpool=${target_pool}" -o json | jq '[.items[].status.allocatable["nvidia.com/gpu"]? // empty | tonumber] | add // 0')"
    [[ "${gpu_allocatable}" -ge 1 ]] && break
    sleep 10
  done
  [[ "${gpu_allocatable}" -ge 1 ]] || die "GPU target pool ${target_pool} has no allocatable nvidia.com/gpu after device-plugin rollout"

  if [[ "${ANYSCALE_PROOF_GPU_TARGET:-flex}" != "aks" ]]; then
    gpu_product_label="$(resolve_gpu_product_label)"
    kubectl label nodes -l "agentpool=${target_pool}" "nvidia.com/gpu.product=${gpu_product_label}" --overwrite >/dev/null
  fi

  printf 'NVIDIA device plugin ready: %s allocatable GPU(s) in pool %s\n' "${gpu_allocatable}" "${target_pool}"
}

main "$@"
