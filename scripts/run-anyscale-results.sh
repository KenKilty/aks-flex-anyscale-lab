#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKLOAD_DIR="${ROOT_DIR}/workloads/deepspeed_finetune"
ENV_FILE="${ANYSCALE_AKS_ENV_FILE:-${ROOT_DIR}/.env}"
STATE_DIR="${ROOT_DIR}/.cache/lab-validation"
ARTIFACT_DIR="${ROOT_DIR}/.cache/anyscale"
COMPUTE_CONFIG_DIR="${ARTIFACT_DIR}/compute-configs"
VALIDATOR_SCRIPT="${ROOT_DIR}/workloads/deepspeed_finetune/validate_workload_summary.py"
TIMEOUT_LIB="${ROOT_DIR}/scripts/lib/timeout.sh"
SUBMIT_HELPER_LIB="${ROOT_DIR}/scripts/lib/anyscale-job-submit.sh"
FLEX_NETWORK_GATES_LIB="${ROOT_DIR}/scripts/lib/flex-network-gates.sh"
ANYSCALE_DEFAULT_HOST="https://console.azure.anyscale.com"
ANYSCALE_CPU_IMAGE_DEFAULT="anyscale/ray:2.54.1-py311"
ANYSCALE_GPU_IMAGE_DEFAULT="anyscale/ray:2.54.1-py311-cu121"
REMOTE_REQUIREMENTS_FILE_DEFAULT="${ROOT_DIR}/workloads/deepspeed_finetune/requirements-results.txt"

MODE="cpu"
CPU_CONFIG_NAME="cpu-home"
GPU_CONFIG_NAME="gpu-dual-home"
CLOUD_REF=""
CLOUD_ID=""
CLOUD_EXPECTED_REF=""
RESOURCE_GROUP_NAME=""
CLUSTER_NAME=""
CPU_IMAGE_URI=""
GPU_IMAGE_URI=""
REMOTE_REQUIREMENTS_FILE=""
JOB_MAX_RETRIES="0"
SUBMIT_TIMEOUT_SECONDS="300"
ANYSCALE_EXTENSION_NAME="${ANYSCALE_EXTENSION_NAME:-anyscale-operator}"
AKS_FLEX_AGENT_POOL_NAME="${AKS_FLEX_AGENT_POOL_NAME:-aksflexnodes}"
PLACEMENT_WATCHER_PID=""
NODE_CPU_HEADROOM_MILLICORES="500"
NODE_MEMORY_HEADROOM_GIB="1"

# shellcheck source=./lib/timeout.sh
source "${TIMEOUT_LIB}"
# shellcheck source=./lib/anyscale-job-submit.sh
source "${SUBMIT_HELPER_LIB}"
# shellcheck source=./lib/flex-network-gates.sh
source "${FLEX_NETWORK_GATES_LIB}"

usage() {
  cat <<'EOF'
Usage: ./scripts/run-anyscale-workload.sh [--mode cpu|gpu|both]

Modes:
  cpu   Run the CPU workload (default).
  gpu   Run the GPU workload.
  both  Run the CPU workload, then the GPU workload.
EOF
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --mode)
      [[ $# -ge 2 ]] || die "--mode requires a value"
      MODE="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
    esac
  done

  case "${MODE}" in
  cpu | gpu | both)
    ;;
  *)
    die "invalid mode: ${MODE} (expected cpu|gpu|both)"
    ;;
  esac
}

source_env() {
  [[ -f "${ENV_FILE}" ]] || die "missing env file: ${ENV_FILE}"
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a

  [[ -z "${ANYSCALE_HOST:-}" || "${ANYSCALE_HOST}" == "${ANYSCALE_DEFAULT_HOST}" ]] ||
    die "ANYSCALE_HOST must be ${ANYSCALE_DEFAULT_HOST} for Anyscale on Azure"
  export ANYSCALE_HOST="${ANYSCALE_DEFAULT_HOST}"

  CPU_IMAGE_URI="${ANYSCALE_RESULTS_CPU_IMAGE_URI:-${ANYSCALE_PROOF_CPU_IMAGE_URI:-${ANYSCALE_CPU_IMAGE_DEFAULT}}}"
  GPU_IMAGE_URI="${ANYSCALE_RESULTS_GPU_IMAGE_URI:-${ANYSCALE_PROOF_GPU_IMAGE_URI:-${ANYSCALE_GPU_IMAGE_DEFAULT}}}"
  REMOTE_REQUIREMENTS_FILE="${ANYSCALE_RESULTS_REQUIREMENTS_FILE:-${ANYSCALE_PROOF_REQUIREMENTS_FILE:-${REMOTE_REQUIREMENTS_FILE_DEFAULT}}}"
  JOB_MAX_RETRIES="${ANYSCALE_RESULTS_JOB_MAX_RETRIES:-${ANYSCALE_PROOF_JOB_MAX_RETRIES:-0}}"
  SUBMIT_TIMEOUT_SECONDS="${ANYSCALE_RESULTS_SUBMIT_TIMEOUT_SECONDS:-${ANYSCALE_PROOF_SUBMIT_TIMEOUT_SECONDS:-300}}"
  NODE_CPU_HEADROOM_MILLICORES="${ANYSCALE_RESULTS_NODE_CPU_HEADROOM_MILLICORES:-500}"
  NODE_MEMORY_HEADROOM_GIB="${ANYSCALE_RESULTS_NODE_MEMORY_HEADROOM_GIB:-1}"

  [[ "${NODE_CPU_HEADROOM_MILLICORES}" =~ ^[0-9]+$ ]] ||
    die "ANYSCALE_RESULTS_NODE_CPU_HEADROOM_MILLICORES must be a non-negative integer"
  [[ "${NODE_MEMORY_HEADROOM_GIB}" =~ ^[0-9]+$ ]] ||
    die "ANYSCALE_RESULTS_NODE_MEMORY_HEADROOM_GIB must be a non-negative integer"

  [[ -n "${TF_VAR_anyscale_gateway_name:-}" ]] || TF_VAR_anyscale_gateway_name="anyscale-gateway"
  export TF_VAR_anyscale_gateway_name

  if [[ "${ANYSCALE_RESULTS_WORKING_DIR_MODE:-${ANYSCALE_PROOF_WORKING_DIR_MODE:-local}}" != "local" ]]; then
    die "ANYSCALE_RESULTS_WORKING_DIR_MODE must be local; Anyscale on Azure workloads upload the local working directory through the cloud's managed storage identity"
  fi
}

load_names() {
  CLOUD_NAME="${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
  export RESOURCE_GROUP_NAME="rg-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
  export CLUSTER_NAME="aks-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
  CLOUD_EXPECTED_REF="/subscriptions/${TF_VAR_azure_subscription_id}/resourcegroups/${RESOURCE_GROUP_NAME}/providers/anyscale.platform/clouds/${CLOUD_NAME}"
  STORAGE_ACCOUNT="$(terraform -chdir="${ROOT_DIR}/infra/terraform" output -raw storage_account_name)"
  STORAGE_CONTAINER="${TF_VAR_project}-${TF_VAR_environment}-blob"
}

ensure_dirs() {
  mkdir -p "${STATE_DIR}" "${ARTIFACT_DIR}" "${ARTIFACT_DIR}/results" "${COMPUTE_CONFIG_DIR}"
}

scrub_workload_cache_files() {
  find "${WORKLOAD_DIR}" -type d -name '__pycache__' -prune -exec rm -rf {} + >/dev/null 2>&1 || true
  find "${WORKLOAD_DIR}" -type f -name '*.pyc' -delete >/dev/null 2>&1 || true
}

cloud_accessible() {
  local json_file match_count raw_file
  json_file="${ARTIFACT_DIR}/clouds.json"
  raw_file="${ARTIFACT_DIR}/clouds.raw"

  .venv/bin/anyscale cloud list --json --no-interactive --max-items 100 >"${raw_file}" 2>/dev/null || return 1

  awk 'BEGIN{started=0} /^\[/ {started=1} started {print}' "${raw_file}" |
    awk '/^Fetched [0-9]+ clouds\.$/{exit} {print}' >"${json_file}"

  [[ -s "${json_file}" ]] || return 1
  match_count="$(jq --arg expected "${CLOUD_EXPECTED_REF}" '[.[] | select((.name | ascii_downcase) == ($expected | ascii_downcase))] | length' "${json_file}")"
  [[ "${match_count}" -eq 1 ]] || return 1
  CLOUD_REF="$(jq -r --arg expected "${CLOUD_EXPECTED_REF}" '.[] | select((.name | ascii_downcase) == ($expected | ascii_downcase)) | .name' "${json_file}")"
  CLOUD_ID="$(jq -r --arg expected "${CLOUD_EXPECTED_REF}" '.[] | select((.name | ascii_downcase) == ($expected | ascii_downcase)) | .id' "${json_file}")"
  [[ -n "${CLOUD_REF}" && -n "${CLOUD_ID}" ]]
}

verify_cloud_ready() {
  verify_cloud_once() {
    local cloud_id="$1" kubeconfig="$2"

    printf '%s\n' "${TF_VAR_anyscale_operator_namespace}" |
      env KUBECONFIG="${kubeconfig}" \
        .venv/bin/anyscale cloud verify --id "${cloud_id}" --strict --yes
  }

  local verify_kubeconfig="${ARTIFACT_DIR}/cloud-verify.kubeconfig"
  local verify_log="${ARTIFACT_DIR}/cloud-verify.log"

  rm -f "${verify_kubeconfig}"
  if ! az aks get-credentials \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --name "${CLUSTER_NAME}" \
    --file "${verify_kubeconfig}" \
    --overwrite-existing \
    --only-show-errors >/dev/null 2>&1; then
    rm -f "${verify_kubeconfig}"
    die "AKS cluster ${RESOURCE_GROUP_NAME}/${CLUSTER_NAME} is unavailable; restore it before using Anyscale cloud ${CLOUD_REF}"
  fi
  kubelogin convert-kubeconfig --login azurecli --kubeconfig "${verify_kubeconfig}" >/dev/null || {
    rm -f "${verify_kubeconfig}"
    die "unable to convert the isolated kubeconfig for Azure CLI authentication"
  }

  if ! run_with_timeout "${ANYSCALE_RESULTS_CLOUD_VERIFY_TIMEOUT_SECONDS:-60}" \
    verify_cloud_once "${CLOUD_ID}" "${verify_kubeconfig}" >"${verify_log}" 2>&1 ||
    grep -Eq 'FAILED|Failed to verify cloud resource' "${verify_log}"; then
    cat "${verify_log}" >&2
    rm -f "${verify_kubeconfig}"
    die "Anyscale cloud ${CLOUD_REF} failed strict verification; restore the AKS cluster and operator before submitting workloads"
  fi

  rm -f "${verify_kubeconfig}"
}

resolve_gpu_product_label() {
  printf '%s\n' "${ANYSCALE_RESULTS_GPU_PRODUCT_LABEL:-${ANYSCALE_PROOF_GPU_PRODUCT_LABEL:-}}"
}

resolve_aks_gpu_pool_name() {
  jq -r 'if length == 1 then to_entries[0].value.name else "" end' <<<"${TF_VAR_gpu_pool_configs}"
}

resolve_aks_gpu_product_label() {
  jq -r 'if length == 1 then to_entries[0].value.product_name else "" end' <<<"${TF_VAR_gpu_pool_configs}"
}

check_dual_gpu_capacity() {
  local aks_gpu_count aks_gpu_pool flex_gpu_count

  [[ "$(jq 'length' <<<"${TF_VAR_gpu_pool_configs}")" -eq 1 ]] ||
    die "gpu mode requires exactly one managed AKS GPU pool in TF_VAR_gpu_pool_configs"
  [[ "$(jq -r 'to_entries[0].value.gpu_count' <<<"${TF_VAR_gpu_pool_configs}")" == "1" ]] ||
    die "gpu mode requires gpu_count=1 for the managed AKS GPU pool"
  aks_gpu_pool="$(resolve_aks_gpu_pool_name)"
  [[ -n "${aks_gpu_pool}" ]] || die "unable to resolve the managed AKS GPU pool name"

  aks_gpu_count="$(kubectl get nodes -l "agentpool=${aks_gpu_pool}" -o json | jq '[.items[].status.allocatable["nvidia.com/gpu"]? // empty | tonumber] | add // 0')"
  flex_gpu_count="$(kubectl get nodes -l "agentpool=${AKS_FLEX_AGENT_POOL_NAME}" -o json | jq '[.items[].status.allocatable["nvidia.com/gpu"]? // empty | tonumber] | add // 0')"
  [[ "${aks_gpu_count}" -eq 1 ]] || die "managed AKS GPU pool ${aks_gpu_pool} must expose exactly one allocatable GPU; found ${aks_gpu_count}"
  [[ "${flex_gpu_count}" -eq 1 ]] || die "Flex GPU pool ${AKS_FLEX_AGENT_POOL_NAME} must expose exactly one allocatable GPU; found ${flex_gpu_count}"
}

check_flex_workload_path() {
  local anyscale_dns_name

  anyscale_dns_name="$(lab_gate_anyscale_host_name)"
  lab_gate_managed_cilium_ready "${ARTIFACT_DIR}"
  lab_gate_flex_node_ready "${ARTIFACT_DIR}"
  lab_gate_unbounded_flex_ready "${ARTIFACT_DIR}"
  lab_gate_flex_dns_ready "${ARTIFACT_DIR}" "${anyscale_dns_name}"
  lab_gate_flex_https_egress "${ARTIFACT_DIR}" "${anyscale_dns_name}"
  lab_gate_aks_to_flex_line_of_sight "${ARTIFACT_DIR}"
  lab_gate_anyscale_operator_ready "${ARTIFACT_DIR}"
  lab_gate_anyscale_gateway_ready "${ARTIFACT_DIR}"
}

placement_capture_file() {
  printf '%s/results/%s-kubernetes-pods.captured.json' "${ARTIFACT_DIR}" "$1"
}

start_placement_watcher() {
  local job_name="$1"
  local mode="${2:-cpu}"
  local aks_gpu_pool captured concurrent_sample

  captured="$(placement_capture_file "${job_name}")"
  concurrent_sample="${ARTIFACT_DIR}/results/${job_name}-gpu-concurrent-sample.json"
  aks_gpu_pool="$(resolve_aks_gpu_pool_name)"
  rm -f "${captured}" "${captured}.new" "${captured}.merged" \
    "${captured}.nodes" "${concurrent_sample}" "${concurrent_sample}.new"

  (
    while true; do
      if kubectl -n "${TF_VAR_anyscale_operator_namespace}" get pods \
        -l "app.kubernetes.io/name=${job_name}" \
        -o json >"${captured}.new" 2>/dev/null &&
        jq -e '.items | length > 0' "${captured}.new" >/dev/null 2>&1; then
        if [[ -s "${captured}" ]]; then
          if jq -s \
            '{items: ([.[0].items[], .[1].items[]] | group_by(.metadata.name) | map(.[-1]))}' \
            "${captured}" "${captured}.new" >"${captured}.merged" 2>/dev/null; then
            mv "${captured}.merged" "${captured}"
          fi
        else
          cp "${captured}.new" "${captured}"
        fi

        if [[ "${mode}" == "gpu" ]] && kubectl get nodes -o json >"${captured}.nodes" 2>/dev/null; then
          if jq -en \
            --arg observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --arg aks_pool "${aks_gpu_pool}" \
            --arg flex_pool "${AKS_FLEX_AGENT_POOL_NAME}" \
            --slurpfile pods "${captured}.new" \
            --slurpfile nodes "${captured}.nodes" \
            '($nodes[0].items
              | map({key: .metadata.name, value: (.metadata.labels.agentpool // .metadata.labels["kubernetes.azure.com/agentpool"] // "unknown")})
              | from_entries) as $pool_by_node
            | {
                observed_at: $observed_at,
                workers: [
                  $pods[0].items[]
                  | select(.metadata.labels["ray-node-type"] == "worker")
                  | select(.status.phase == "Running")
                  | select(([.status.containerStatuses[]? | select(.ready != true)] | length) == 0)
                  | {
                      pod_name: .metadata.name,
                      pod_ip: (.status.podIP // ""),
                      node_name: (.spec.nodeName // ""),
                      node_agentpool: ($pool_by_node[.spec.nodeName] // "unknown"),
                      gpu_requested: ([.spec.containers[] | ((.resources.limits["nvidia.com/gpu"] // .resources.requests["nvidia.com/gpu"] // "0") | tonumber)] | add // 0)
                    }
                ]
              }
            | select((.workers | map(select(.node_agentpool == $aks_pool and .gpu_requested >= 1)) | length) >= 1)
            | select((.workers | map(select(.node_agentpool == $flex_pool and .gpu_requested >= 1)) | length) >= 1)' \
            >"${concurrent_sample}.new" 2>/dev/null; then
            mv "${concurrent_sample}.new" "${concurrent_sample}"
          fi
        fi
      fi
      sleep 5
    done
  ) &
  PLACEMENT_WATCHER_PID=$!
}

stop_placement_watcher() {
  [[ -n "${PLACEMENT_WATCHER_PID}" ]] || return 0
  kill "${PLACEMENT_WATCHER_PID}" 2>/dev/null || true
  wait "${PLACEMENT_WATCHER_PID}" 2>/dev/null || true
  PLACEMENT_WATCHER_PID=""
}

collect_kubernetes_placement_results() {
  local job_name="$1"
  local mode="$2"
  local aks_gpu_pool captured concurrent_sample nodes_json placement_file pods_json

  pods_json="${ARTIFACT_DIR}/results/${job_name}-kubernetes-pods.raw.json"
  nodes_json="${ARTIFACT_DIR}/results/${job_name}-kubernetes-nodes.raw.json"
  placement_file="${ARTIFACT_DIR}/results/${job_name}-kubernetes-placement.json"
  captured="$(placement_capture_file "${job_name}")"

  kubectl -n "${TF_VAR_anyscale_operator_namespace}" get pods \
    -l "app.kubernetes.io/name=${job_name}" -o json >"${pods_json}"
  if ! jq -e '.items | length > 0' "${pods_json}" >/dev/null 2>&1 && [[ -s "${captured}" ]]; then
    cp "${captured}" "${pods_json}"
  fi
  kubectl get nodes -o json >"${nodes_json}"

  jq -n \
    --arg job_name "${job_name}" \
    --arg namespace "${TF_VAR_anyscale_operator_namespace}" \
    --slurpfile pods "${pods_json}" \
    --slurpfile nodes "${nodes_json}" \
    '($nodes[0].items
      | map({key: .metadata.name, value: {
          region: (.metadata.labels["topology.kubernetes.io/region"] // .metadata.labels["failure-domain.beta.kubernetes.io/region"] // "unknown"),
          agentpool: (.metadata.labels.agentpool // .metadata.labels["kubernetes.azure.com/agentpool"] // "unknown")
        }})
      | from_entries) as $node_by_name
    | {
        job_name: $job_name,
        namespace: $namespace,
        pods: [$pods[0].items[] | {
          name: .metadata.name,
          pod_ip: (.status.podIP // ""),
          node_name: (.spec.nodeName // ""),
          node_region: ($node_by_name[.spec.nodeName].region // "unknown"),
          node_agentpool: ($node_by_name[.spec.nodeName].agentpool // "unknown"),
          phase: (.status.phase // "unknown"),
          ray_node_type: (.metadata.labels["ray-node-type"] // ""),
          anyscale_node_group: (.metadata.labels["anyscale-node-group-id"] // ""),
          gpu_requested: ([.spec.containers[] | ((.resources.limits["nvidia.com/gpu"] // .resources.requests["nvidia.com/gpu"] // "0") | tonumber)] | add // 0),
          containers_ready: ([.status.containerStatuses[]? | select(.ready != true)] | length == 0)
        }]
      }' >"${placement_file}"

  jq -e '.pods | length > 0' "${placement_file}" >/dev/null || die "no Kubernetes placement pods found for ${job_name}"
  if [[ "${mode}" == "cpu" ]]; then
    jq -e \
      --arg region "${TF_VAR_flex_region}" \
      --arg pool "${AKS_FLEX_AGENT_POOL_NAME}" \
      '.pods[] | select(.ray_node_type == "worker" and .node_region == $region and .node_agentpool == $pool)' \
      "${placement_file}" >/dev/null || die "no CPU worker pod placed on Flex pool ${AKS_FLEX_AGENT_POOL_NAME} in region ${TF_VAR_flex_region}"
  elif [[ "${mode}" == "gpu" ]]; then
    aks_gpu_pool="$(resolve_aks_gpu_pool_name)"
    concurrent_sample="${ARTIFACT_DIR}/results/${job_name}-gpu-concurrent-sample.json"
    jq -e --arg pool "${aks_gpu_pool}" \
      '.pods[] | select(.ray_node_type == "worker" and .node_agentpool == $pool and .gpu_requested >= 1)' \
      "${placement_file}" >/dev/null || die "no GPU worker pod placed on managed AKS pool ${aks_gpu_pool}"
    jq -e --arg pool "${AKS_FLEX_AGENT_POOL_NAME}" \
      '.pods[] | select(.ray_node_type == "worker" and .node_agentpool == $pool and .gpu_requested >= 1)' \
      "${placement_file}" >/dev/null || die "no GPU worker pod placed on Flex pool ${AKS_FLEX_AGENT_POOL_NAME}"
    [[ -s "${concurrent_sample}" ]] || die "no sample captured with managed and Flex GPU workers Running concurrently"
  fi

  printf '%s\n' "${placement_file}"
}

resolve_node_resources() {
  local selector="$1"
  local cpu_target="$2"
  local memory_target_gib="$3"
  local minimum_cpu="$4"
  local minimum_memory_gib="$5"
  local role="$6"
  local nodes_json safe_cpu safe_memory_gib resolved_cpu resolved_memory_gib

  nodes_json="$(kubectl get nodes -l "${selector}" -o json)" ||
    die "unable to read Kubernetes capacity for ${role} (${selector})"

  safe_cpu="$(jq -r --argjson headroom "${NODE_CPU_HEADROOM_MILLICORES}" '
    [
      .items[]
      | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
      | (.status.allocatable.cpu // "0")
      | if endswith("m") then (rtrimstr("m") | tonumber) else (tonumber * 1000) end
      | (((. - $headroom) / 1000) | floor)
    ] | min // 0
  ' <<<"${nodes_json}")"

  safe_memory_gib="$(jq -r --argjson headroom "${NODE_MEMORY_HEADROOM_GIB}" '
    def bytes:
      if endswith("Ki") then ((rtrimstr("Ki") | tonumber) * 1024)
      elif endswith("Mi") then ((rtrimstr("Mi") | tonumber) * 1048576)
      elif endswith("Gi") then ((rtrimstr("Gi") | tonumber) * 1073741824)
      elif endswith("Ti") then ((rtrimstr("Ti") | tonumber) * 1099511627776)
      elif endswith("K") then ((rtrimstr("K") | tonumber) * 1000)
      elif endswith("M") then ((rtrimstr("M") | tonumber) * 1000000)
      elif endswith("G") then ((rtrimstr("G") | tonumber) * 1000000000)
      elif endswith("T") then ((rtrimstr("T") | tonumber) * 1000000000000)
      else tonumber
      end;
    [
      .items[]
      | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
      | (.status.allocatable.memory // "0")
      | bytes
      | (((. / 1073741824) - $headroom) | floor)
    ] | min // 0
  ' <<<"${nodes_json}")"

  resolved_cpu="${cpu_target}"
  ((safe_cpu < resolved_cpu)) && resolved_cpu="${safe_cpu}"
  resolved_memory_gib="${memory_target_gib}"
  ((safe_memory_gib < resolved_memory_gib)) && resolved_memory_gib="${safe_memory_gib}"

  ((resolved_cpu >= minimum_cpu)) ||
    die "${role} needs at least ${minimum_cpu} CPU after headroom; ${selector} supports ${safe_cpu}"
  ((resolved_memory_gib >= minimum_memory_gib)) ||
    die "${role} needs at least ${minimum_memory_gib}Gi memory after headroom; ${selector} supports ${safe_memory_gib}Gi"

  printf 'info: %s uses CPU=%s memory=%sGi from live capacity on %s\n' \
    "${role}" "${resolved_cpu}" "${resolved_memory_gib}" "${selector}" >&2
  printf '%s %s\n' "${resolved_cpu}" "${resolved_memory_gib}"
}

write_dual_gpu_compute_config() {
  local config_name="$1"
  local aks_gpu_pool aks_gpu_product_label flex_gpu_product_label
  local head_cpu head_memory managed_cpu managed_memory flex_cpu flex_memory

  aks_gpu_pool="$(resolve_aks_gpu_pool_name)"
  aks_gpu_product_label="$(resolve_aks_gpu_product_label)"
  flex_gpu_product_label="$(resolve_gpu_product_label)"
  [[ -n "${aks_gpu_pool}" && -n "${aks_gpu_product_label}" ]] || die "managed AKS GPU pool name and product_name are required"
  [[ -n "${flex_gpu_product_label}" ]] || die "ANYSCALE_RESULTS_GPU_PRODUCT_LABEL is required"

  read -r head_cpu head_memory < <(resolve_node_resources "agentpool=cpu" 2 8 1 4 "Ray head")
  read -r managed_cpu managed_memory < <(resolve_node_resources "agentpool=${aks_gpu_pool}" 4 16 1 8 "managed GPU worker")
  read -r flex_cpu flex_memory < <(resolve_node_resources "agentpool=${AKS_FLEX_AGENT_POOL_NAME}" 4 16 1 8 "Flex GPU worker")

  cat >"${COMPUTE_CONFIG_DIR}/${config_name}.yaml" <<EOF
cloud: ${CLOUD_REF}
head_node:
  required_resources:
    CPU: ${head_cpu}
    memory: ${head_memory}Gi
  advanced_instance_config:
    spec:
      nodeSelector:
        agentpool: cpu
worker_nodes:
  - name: managed-gpu-worker
    required_resources: {CPU: ${managed_cpu}, memory: ${managed_memory}Gi, GPU: 1}
    required_labels: {ray.io/accelerator-type: ${aks_gpu_product_label}}
    min_nodes: 1
    max_nodes: 1
    advanced_instance_config:
      spec:
        nodeSelector: {agentpool: ${aks_gpu_pool}, nvidia.com/gpu.product: ${aks_gpu_product_label}}
        tolerations:
          - {key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}
          - {key: node.anyscale.com/capacity-type, operator: Equal, value: ON_DEMAND, effect: NoSchedule}
          - {key: node.anyscale.com/accelerator-type, operator: Equal, value: GPU, effect: NoSchedule}
  - name: flex-gpu-worker
    required_resources: {CPU: ${flex_cpu}, memory: ${flex_memory}Gi, GPU: 1}
    required_labels: {ray.io/accelerator-type: ${flex_gpu_product_label}}
    min_nodes: 1
    max_nodes: 1
    advanced_instance_config:
      spec:
        nodeSelector: {agentpool: ${AKS_FLEX_AGENT_POOL_NAME}, nvidia.com/gpu.product: ${flex_gpu_product_label}}
        tolerations:
          - {key: aks-flex-node, operator: Equal, value: "true", effect: NoSchedule}
          - {key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}
          - {key: node.anyscale.com/capacity-type, operator: Equal, value: ON_DEMAND, effect: NoSchedule}
          - {key: node.anyscale.com/accelerator-type, operator: Equal, value: GPU, effect: NoSchedule}
EOF
}

write_compute_config() {
  local config_name="$1"
  local worker_name="$2"
  local worker_count="$3"
  local head_cpu head_memory worker_cpu worker_memory

  if [[ "${worker_name}" == "gpu-worker" ]]; then
    write_dual_gpu_compute_config "${config_name}"
    return
  fi

  read -r head_cpu head_memory < <(resolve_node_resources "agentpool=cpu" 2 8 1 4 "Ray head")
  read -r worker_cpu worker_memory < <(resolve_node_resources "agentpool=${AKS_FLEX_AGENT_POOL_NAME}" 2 8 1 4 "Flex CPU worker")

  cat >"${COMPUTE_CONFIG_DIR}/${config_name}.yaml" <<EOF
cloud: ${CLOUD_REF}
head_node:
  required_resources: {CPU: ${head_cpu}, memory: ${head_memory}Gi}
  advanced_instance_config:
    spec:
      nodeSelector: {agentpool: cpu}
worker_nodes:
  - name: ${worker_name}
    required_resources: {CPU: ${worker_cpu}, memory: ${worker_memory}Gi}
    min_nodes: 0
    max_nodes: ${worker_count:-1}
    advanced_instance_config:
      spec:
        nodeSelector: {agentpool: ${AKS_FLEX_AGENT_POOL_NAME}}
        tolerations:
          - {key: aks-flex-node, operator: Equal, value: "true", effect: NoSchedule}
EOF
}

ensure_compute_config() {
  local config_name="$1"
  local worker_name="$2"
  local worker_count="$3"
  local existing_json
  existing_json="${ARTIFACT_DIR}/compute-configs.json"

  if .venv/bin/anyscale compute-config list --json --max-items 100 --cloud-name "${CLOUD_REF}" >"${existing_json}" 2>/dev/null; then
    if jq -e --arg name "${config_name}" '.results[]? | select(.name == $name)' "${existing_json}" >/dev/null; then
      # Azure control plane does not support archiving compute configs.
      # Creating again with the same name mints a new version.
      :
    fi
  fi

  write_compute_config "${config_name}" "${worker_name}" "${worker_count}"
  .venv/bin/anyscale compute-config create \
    --name "${config_name}" \
    --config-file "${COMPUTE_CONFIG_DIR}/${config_name}.yaml" >/dev/null

  .venv/bin/anyscale compute-config get \
    --name "${config_name}" \
    --cloud-name "${CLOUD_REF}" >/dev/null
}

write_dual_gpu_training_proof() {
  local job_name="$1"
  local summary_file="$2"
  local placement_file="$3"
  local aks_gpu_pool concurrent_sample proof_file

  aks_gpu_pool="$(resolve_aks_gpu_pool_name)"
  concurrent_sample="${ARTIFACT_DIR}/results/${job_name}-gpu-concurrent-sample.json"
  proof_file="${ARTIFACT_DIR}/results/${job_name}-dual-gpu-training-proof.json"

  if ! jq -en \
    --arg job_name "${job_name}" \
    --arg aks_pool "${aks_gpu_pool}" \
    --arg flex_pool "${AKS_FLEX_AGENT_POOL_NAME}" \
    --slurpfile summary "${summary_file}" \
    --slurpfile placement "${placement_file}" \
    --slurpfile concurrent "${concurrent_sample}" \
    '($summary[0].worker_training_records // []) as $training
    | ($placement[0].pods | map(select(.ray_node_type == "worker" and .gpu_requested >= 1))) as $gpu_pods
    | {
        status: "passed",
        job_name: $job_name,
        world_size: ($summary[0].placement.observed_world_size // 0),
        concurrent_observed_at: ($concurrent[0].observed_at // ""),
        workers: [
          $training[] as $record
          | ($gpu_pods | map(select(.name == $record.hostname)) | first) as $pod
          | {
              rank: $record.rank,
              hostname: $record.hostname,
              cuda_available: $record.cuda_available,
              device_name: $record.device_name,
              steps_per_worker: $record.steps_per_worker,
              loss: $record.loss,
              node_name: ($pod.node_name // ""),
              node_region: ($pod.node_region // ""),
              node_agentpool: ($pod.node_agentpool // ""),
              pod_ip: ($pod.pod_ip // ""),
              gpu_requested: ($pod.gpu_requested // 0)
            }
        ],
        concurrent_workers: $concurrent[0].workers
      }
    | select(.world_size == 2)
    | select((.workers | length) == 2)
    | select(all(.workers[]; .cuda_available == true and .steps_per_worker > 0 and (.loss | type) == "number" and .gpu_requested >= 1 and .node_name != ""))
    | select((.workers | map(.node_agentpool) | sort) == ([$aks_pool, $flex_pool] | sort))
    | select((.concurrent_workers | map(.node_agentpool) | unique | sort) == ([$aks_pool, $flex_pool] | sort))' \
    >"${proof_file}.new"; then
    rm -f "${proof_file}.new"
    die "GPU training evidence did not join two CUDA ranks to managed and Flex GPU pods"
  fi

  mv "${proof_file}.new" "${proof_file}"
  printf '%s\n' "${proof_file}"
}

extract_and_validate_workload_summary() {
  local job_name="$1"
  local mode="$2"
  local logs_file="$3"
  local expected_worker_region
  local placement_file proof_file
  local remote_summary

  remote_summary="${ARTIFACT_DIR}/results/${job_name}-workload-summary.json"

  python3 - "${logs_file}" "${remote_summary}" <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

logs_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
marker = "WORKLOAD_SUMMARY_JSON="
ansi = re.compile(r"\x1b\[[0-9;]*m")

summary = None
for raw_line in logs_path.read_text(encoding="utf-8", errors="replace").splitlines():
    line = ansi.sub("", raw_line)
    if marker not in line:
        continue
    summary = json.loads(line.split(marker, 1)[1].strip())

if summary is None:
    raise SystemExit(f"no {marker} record found in {logs_path}")

summary_path.parent.mkdir(parents=True, exist_ok=True)
summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

  expected_worker_region="${TF_VAR_azure_location}"
  if [[ "${mode}" == "cpu" ]]; then
    expected_worker_region="${TF_VAR_flex_region}"
  fi

  if [[ "${mode}" == "gpu" ]]; then
    python3 "${VALIDATOR_SCRIPT}" "${remote_summary}" \
      --expected-worker-count 2 --require-cuda >/dev/null
  else
    python3 "${VALIDATOR_SCRIPT}" "${remote_summary}" \
      --expected-worker-region "${expected_worker_region}" >/dev/null
  fi
  placement_file="$(collect_kubernetes_placement_results "${job_name}" "${mode}")"
  proof_file=""
  if [[ "${mode}" == "gpu" ]]; then
    proof_file="$(write_dual_gpu_training_proof "${job_name}" "${remote_summary}" "${placement_file}")"
  fi

  jq -n \
    --arg mode "${mode}" \
    --arg job_name "${job_name}" \
    --arg remote_summary "${remote_summary}" \
    --arg placement_file "${placement_file}" \
    --arg proof_file "${proof_file}" \
    --arg logs_file "${logs_file}" \
    '{
      mode: $mode,
      job_name: $job_name,
      workload_summary_file: $remote_summary,
      kubernetes_placement_file: $placement_file,
      dual_gpu_training_proof_file: (if $proof_file == "" then null else $proof_file end),
      source_logs_file: $logs_file,
      validated: true
    }' >"${STATE_DIR}/anyscale-results-${mode}.json"
}

submit_job_for_mode() {
  local mode="$1"
  local compute_config_name="$2"
  local worker_count="$3"
  local cpu_flag="$4"
  local image_uri="$5"
  local placement_region
  local job_name status_file logs_file
  local submit_attempt max_submit_attempts
  local submit_rc
  local submit_ok="false"
  local submit_cmd
  local submit_workdir_value
  local worker_group_start_timeout_s
  local wait_rc

  job_name="flex-results-${mode}-$(date +%Y%m%d-%H%M%S)"
  status_file="${ARTIFACT_DIR}/${job_name}-status.json"
  logs_file="${ARTIFACT_DIR}/${job_name}.log"
  placement_region="${TF_VAR_azure_location}"
  if [[ "${mode}" == "cpu" || "${mode}" == "gpu" ]]; then
    placement_region="${TF_VAR_flex_region}"
  fi
  worker_group_start_timeout_s="${ANYSCALE_RESULTS_WORKER_GROUP_START_TIMEOUT_S:-${ANYSCALE_PROOF_WORKER_GROUP_START_TIMEOUT_S:-300}}"
  if [[ "${mode}" == "gpu" && -z "${ANYSCALE_RESULTS_WORKER_GROUP_START_TIMEOUT_S:-${ANYSCALE_PROOF_WORKER_GROUP_START_TIMEOUT_S:-}}" ]]; then
    worker_group_start_timeout_s="900"
  fi

  submit_workdir_value="${WORKLOAD_DIR}"

  submit_cmd=(
    .venv/bin/anyscale job submit
    --name "${job_name}"
    --cloud "${CLOUD_REF}"
    --compute-config "${compute_config_name}"
    --image-uri "${image_uri}"
    --max-retries "${JOB_MAX_RETRIES}"
  )

  submit_cmd+=(
    --working-dir "${submit_workdir_value}"
    --exclude "__pycache__"
    --exclude "*.pyc"
  )

  if [[ -f "${REMOTE_REQUIREMENTS_FILE}" ]]; then
    submit_cmd+=(--requirements "${REMOTE_REQUIREMENTS_FILE}")
  fi

  if [[ -n "${cpu_flag}" ]]; then
    submit_cmd+=(--env "DS_ACCELERATOR=cpu")
  fi

  submit_cmd+=(
    --env "ANYSCALE_RESULTS_STORAGE_ACCOUNT=${STORAGE_ACCOUNT}"
    --env "ANYSCALE_RESULTS_STORAGE_CONTAINER=${STORAGE_CONTAINER}"
    --env "RAY_TRAIN_WORKER_GROUP_START_TIMEOUT_S=${worker_group_start_timeout_s}"
  )

  submit_cmd+=(
    --env "AKS_NODE_REGION=${placement_region}"
    --
    python train.py
    --run-id "${job_name}"
    --profile smoke
    --num-workers "${worker_count}"
    --expected-regions "${TF_VAR_azure_location}" "${TF_VAR_flex_region}"
    --results-dir "./results"
  )

  if [[ -n "${cpu_flag}" ]]; then
    submit_cmd+=("${cpu_flag}")
  fi

  max_submit_attempts="${ANYSCALE_RESULTS_SUBMIT_ATTEMPTS:-${ANYSCALE_PROOF_SUBMIT_ATTEMPTS:-3}}"
  scrub_workload_cache_files
  for ((submit_attempt = 1; submit_attempt <= max_submit_attempts; submit_attempt++)); do
    printf 'info: submit attempt %s/%s for %s\n' "${submit_attempt}" "${max_submit_attempts}" "${job_name}" >&2

    set +e
    run_with_timeout "${SUBMIT_TIMEOUT_SECONDS}" "${submit_cmd[@]}" >"${ARTIFACT_DIR}/${job_name}-submit.log" 2>&1
    submit_rc=$?
    set -e

    if [[ ${submit_rc} -eq 0 ]]; then
      submit_ok="true"
      break
    fi

    if [[ ${submit_rc} -eq 124 ]]; then
      printf 'warn: submit attempt %s/%s timed out for %s after %ss\n' "${submit_attempt}" "${max_submit_attempts}" "${job_name}" "${SUBMIT_TIMEOUT_SECONDS}" >&2
      sleep 8
      continue
    fi

    if should_retry_anyscale_job_submission "${ARTIFACT_DIR}/${job_name}-submit.log" "${submit_attempt}"; then
      printf 'warn: submit attempt %s/%s hit a retryable Anyscale submission error for %s; retrying\n' "${submit_attempt}" "${max_submit_attempts}" "${job_name}" >&2
      sleep 8
      continue
    fi
    printf 'warn: submit attempt %s/%s failed for %s; retrying\n' "${submit_attempt}" "${max_submit_attempts}" "${job_name}" >&2
    sleep 8
  done

  [[ "${submit_ok}" == "true" ]] || die "job submit failed after ${max_submit_attempts} attempts for ${job_name}"

  start_placement_watcher "${job_name}" "${mode}"

  set +e
  .venv/bin/anyscale job wait \
    --name "${job_name}" \
    --cloud "${CLOUD_REF}" \
    --timeout-s 1800
  wait_rc=$?
  set -e

  stop_placement_watcher

  .venv/bin/anyscale job status \
    --name "${job_name}" \
    --cloud "${CLOUD_REF}" \
    --json >"${status_file}"

  .venv/bin/anyscale job logs \
    --name "${job_name}" \
    --cloud "${CLOUD_REF}" \
    --tail --max-lines 400 >"${logs_file}" || true

  if [[ ${wait_rc} -ne 0 ]]; then
    die "job ${job_name} did not reach SUCCEEDED (status: ${status_file}, logs: ${logs_file})"
  fi

  extract_and_validate_workload_summary "${job_name}" "${mode}" "${logs_file}"

  jq -n \
    --arg mode "${mode}" \
    --arg job_name "${job_name}" \
    --arg cloud "${CLOUD_REF}" \
    --arg compute_config "${compute_config_name}" \
    --arg status_file "${status_file}" \
    --arg logs_file "${logs_file}" \
    '{
      mode: $mode,
      job_name: $job_name,
      cloud: $cloud,
      compute_config: $compute_config,
      status_file: $status_file,
      logs_file: $logs_file
    }' >"${STATE_DIR}/anyscale-results-job-${mode}.json"
}

run_cpu_mode() {
  check_flex_workload_path
  ensure_compute_config "${CPU_CONFIG_NAME}" "cpu-worker" "1"
  submit_job_for_mode "cpu" "${CPU_CONFIG_NAME}" "1" "--cpu-only" "${CPU_IMAGE_URI}"
}

run_gpu_mode() {
  local gpu_worker_count
  check_flex_workload_path
  gpu_worker_count="2"
  check_dual_gpu_capacity
  ensure_compute_config "${GPU_CONFIG_NAME}" "gpu-worker" "${gpu_worker_count}"
  submit_job_for_mode "gpu" "${GPU_CONFIG_NAME}" "${gpu_worker_count}" "" "${GPU_IMAGE_URI}"
}

write_final_summary() {
  local cpu_file gpu_file
  cpu_file="${STATE_DIR}/anyscale-results-cpu.json"
  gpu_file="${STATE_DIR}/anyscale-results-gpu.json"

  jq -n \
    --arg mode "${MODE}" \
    --arg env_file "${ENV_FILE}" \
    --arg cloud "${CLOUD_REF}" \
    --arg storage_account "${STORAGE_ACCOUNT}" \
    --arg storage_container "${STORAGE_CONTAINER}" \
    --arg cpu_file "${cpu_file}" \
    --arg gpu_file "${gpu_file}" \
    '{
      mode: $mode,
      env_file: $env_file,
      cloud: $cloud,
      storage_account: $storage_account,
      storage_container: $storage_container,
      cpu_result_file: (if ($mode == "cpu" or $mode == "both") then $cpu_file else null end),
      gpu_result_file: (if ($mode == "gpu" or $mode == "both") then $gpu_file else null end),
      timestamp_utc: now | todate
    }' >"${STATE_DIR}/anyscale-results-run.json"
}

main() {
  parse_args "$@"

  need_cmd python3
  need_cmd jq
  need_cmd az
  need_cmd kubelogin
  need_cmd .venv/bin/anyscale

  source_env
  load_names
  ensure_dirs

  [[ "${TF_VAR_anyscale_enabled}" == "true" ]] || die "TF_VAR_anyscale_enabled must be true"
  cloud_accessible || die "expected Anyscale cloud ${CLOUD_EXPECTED_REF} was not uniquely visible at ${ANYSCALE_HOST}; run anyscale login and verify the Azure cloud resource"
  verify_cloud_ready

  case "${MODE}" in
  cpu)
    run_cpu_mode
    ;;
  gpu)
    run_gpu_mode
    ;;
  both)
    run_cpu_mode
    run_gpu_mode
    ;;
  esac

  write_final_summary
}

trap 'stop_placement_watcher 2>/dev/null || true' EXIT
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
