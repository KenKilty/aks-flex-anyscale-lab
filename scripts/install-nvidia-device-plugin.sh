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
  printf '%s\n' "${ANYSCALE_RESULTS_GPU_PRODUCT_LABEL:-${ANYSCALE_PROOF_GPU_PRODUCT_LABEL:-}}"
}

main() {
  local aks_gpu_allocatable flex_gpu_allocatable gpu_pool_name gpu_product_label

  need_cmd jq
  need_cmd kubectl
  source_env

  [[ "$(jq 'length' <<<"${TF_VAR_gpu_pool_configs}")" -eq 1 ]] || die "dual GPU path requires exactly one AKS GPU pool in ${ENV_FILE}"
  gpu_pool_name="$(resolve_gpu_pool_name)"
  [[ -n "${gpu_pool_name}" ]] || die "unable to determine GPU pool name from TF_VAR_gpu_pool_configs"
  gpu_product_label="$(resolve_gpu_product_label)"
  [[ -n "${gpu_product_label}" ]] || die "dual GPU path requires ANYSCALE_RESULTS_GPU_PRODUCT_LABEL in ${ENV_FILE}"

  kubectl label nodes -l "agentpool=${AKS_FLEX_AGENT_POOL_NAME}" \
    "kubernetes.azure.com/agentpool=${AKS_FLEX_AGENT_POOL_NAME}" \
    "topology.kubernetes.io/region=${TF_VAR_flex_region}" \
    "nvidia.com/gpu.product=${gpu_product_label}" \
    --overwrite >/dev/null

  kubectl apply -f "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${NVIDIA_DEVICE_PLUGIN_VERSION}/deployments/static/nvidia-device-plugin.yml"

  kubectl -n kube-system patch ds nvidia-device-plugin-daemonset --type strategic -p "$(
    cat <<PATCH
spec:
  template:
    spec:
      nodeSelector: null
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: agentpool
                    operator: In
                    values:
                      - ${gpu_pool_name}
                      - ${AKS_FLEX_AGENT_POOL_NAME}
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
  aks_gpu_allocatable="0"
  flex_gpu_allocatable="0"
  for _ in {1..30}; do
    aks_gpu_allocatable="$(kubectl get nodes -l "agentpool=${gpu_pool_name}" -o json | jq '[.items[].status.allocatable["nvidia.com/gpu"]? // empty | tonumber] | add // 0')"
    flex_gpu_allocatable="$(kubectl get nodes -l "agentpool=${AKS_FLEX_AGENT_POOL_NAME}" -o json | jq '[.items[].status.allocatable["nvidia.com/gpu"]? // empty | tonumber] | add // 0')"
    [[ "${aks_gpu_allocatable}" -ge 1 && "${flex_gpu_allocatable}" -ge 1 ]] && break
    sleep 10
  done
  [[ "${aks_gpu_allocatable}" -eq 1 ]] || die "managed AKS GPU pool ${gpu_pool_name} must expose exactly one allocatable GPU; found ${aks_gpu_allocatable}"
  [[ "${flex_gpu_allocatable}" -eq 1 ]] || die "Flex GPU pool ${AKS_FLEX_AGENT_POOL_NAME} must expose exactly one allocatable GPU; found ${flex_gpu_allocatable}"

  printf 'NVIDIA device plugin ready: 1 allocatable GPU in %s and 1 in %s\n' \
    "${gpu_pool_name}" "${AKS_FLEX_AGENT_POOL_NAME}"
}

main "$@"
