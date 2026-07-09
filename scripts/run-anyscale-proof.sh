#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKLOAD_DIR="${ROOT_DIR}/workloads/deepspeed_finetune"
ENV_FILE="${ANYSCALE_AKS_ENV_FILE:-${ROOT_DIR}/.env}"
STATE_DIR="${ROOT_DIR}/.github/agents/state"
ARTIFACT_DIR="${ROOT_DIR}/.cache/anyscale"
COMPUTE_CONFIG_DIR="${ARTIFACT_DIR}/compute-configs"
VALIDATOR_SCRIPT="${ROOT_DIR}/workloads/deepspeed_finetune/validate_proof_summary.py"
TIMEOUT_LIB="${ROOT_DIR}/scripts/lib/timeout.sh"
SUBMIT_HELPER_LIB="${ROOT_DIR}/scripts/lib/anyscale-job-submit.sh"
FLEX_NETWORK_GATES_LIB="${ROOT_DIR}/scripts/lib/flex-network-gates.sh"
ANYSCALE_DEFAULT_HOST="https://console.azure.anyscale.com"
ANYSCALE_CPU_IMAGE_DEFAULT="anyscale/ray:2.54.1-py311"
ANYSCALE_GPU_IMAGE_DEFAULT="anyscale/ray:2.54.1-py311-cu121"
REMOTE_REQUIREMENTS_FILE_DEFAULT="${ROOT_DIR}/workloads/deepspeed_finetune/requirements-proof.txt"

MODE="cpu"
CPU_CONFIG_NAME="cpu-home"
GPU_CONFIG_NAME="gpu-home"
CLOUD_REF=""
RESOURCE_GROUP_NAME=""
CLUSTER_NAME=""
CPU_IMAGE_URI=""
GPU_IMAGE_URI=""
REMOTE_REQUIREMENTS_FILE=""
JOB_MAX_RETRIES="0"
SUBMIT_TIMEOUT_SECONDS="300"
ANYSCALE_EXTENSION_NAME="${ANYSCALE_EXTENSION_NAME:-anyscale-operator}"
AKS_FLEX_AGENT_POOL_NAME="${AKS_FLEX_AGENT_POOL_NAME:-aksflexnodes}"

# shellcheck source=./lib/timeout.sh
source "${TIMEOUT_LIB}"
# shellcheck source=./lib/anyscale-job-submit.sh
source "${SUBMIT_HELPER_LIB}"
# shellcheck source=./lib/flex-network-gates.sh
source "${FLEX_NETWORK_GATES_LIB}"

usage() {
  cat <<'EOF'
Usage: ./scripts/run-anyscale-proof.sh [--mode cpu|gpu|both]

Modes:
  cpu   Run CPU remote proof only (default).
  gpu   Run GPU remote proof only.
  both  Run CPU then GPU remote proofs.
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

  # Normalize host unless caller explicitly provided a different target.
  if [[ -z "${ANYSCALE_HOST:-}" ]]; then
    export ANYSCALE_HOST="${ANYSCALE_DEFAULT_HOST}"
  fi

  CPU_IMAGE_URI="${ANYSCALE_PROOF_CPU_IMAGE_URI:-${ANYSCALE_CPU_IMAGE_DEFAULT}}"
  GPU_IMAGE_URI="${ANYSCALE_PROOF_GPU_IMAGE_URI:-${ANYSCALE_GPU_IMAGE_DEFAULT}}"
  REMOTE_REQUIREMENTS_FILE="${ANYSCALE_PROOF_REQUIREMENTS_FILE:-${REMOTE_REQUIREMENTS_FILE_DEFAULT}}"
  JOB_MAX_RETRIES="${ANYSCALE_PROOF_JOB_MAX_RETRIES:-0}"
  SUBMIT_TIMEOUT_SECONDS="${ANYSCALE_PROOF_SUBMIT_TIMEOUT_SECONDS:-300}"

  [[ -n "${TF_VAR_anyscale_gateway_name:-}" ]] || TF_VAR_anyscale_gateway_name="anyscale-gateway"
  export TF_VAR_anyscale_gateway_name

  if [[ "${ANYSCALE_PROOF_WORKING_DIR_MODE:-local}" != "local" ]]; then
    die "ANYSCALE_PROOF_WORKING_DIR_MODE is no longer supported; Anyscale Azure proofs use local working-dir upload through the cloud's managed storage identity"
  fi
}

load_names() {
  CLOUD_NAME="${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
  export RESOURCE_GROUP_NAME="rg-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
  export CLUSTER_NAME="aks-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
  STORAGE_ACCOUNT="$(printf 'st%s%s%s' "${TF_VAR_project}" "${TF_VAR_environment}" "${TF_VAR_region_short}" | tr '[:upper:]' '[:lower:]' | cut -c1-24)"
  STORAGE_CONTAINER="${TF_VAR_project}-${TF_VAR_environment}-blob"
}

ensure_dirs() {
  mkdir -p "${STATE_DIR}" "${ARTIFACT_DIR}" "${ARTIFACT_DIR}/proofs" "${COMPUTE_CONFIG_DIR}"
}

scrub_workload_cache_files() {
  find "${WORKLOAD_DIR}" -type d -name '__pycache__' -prune -exec rm -rf {} + >/dev/null 2>&1 || true
  find "${WORKLOAD_DIR}" -type f -name '*.pyc' -delete >/dev/null 2>&1 || true
}

cloud_accessible() {
  local json_file raw_file
  json_file="${ARTIFACT_DIR}/clouds.json"
  raw_file="${ARTIFACT_DIR}/clouds.raw"

  .venv/bin/anyscale cloud list --json --no-interactive --max-items 100 >"${raw_file}" 2>/dev/null || return 1

  awk 'BEGIN{started=0} /^\[/ {started=1} started {print}' "${raw_file}" |
    awk '/^Fetched [0-9]+ clouds\.$/{exit} {print}' >"${json_file}"

  [[ -s "${json_file}" ]] || return 1
  CLOUD_REF="$(jq -r --arg cloud_name "${CLOUD_NAME}" '.[] | select(.name == $cloud_name or (.name | endswith("/clouds/" + $cloud_name))) | (.name // empty)' "${json_file}" | head -n1)"
  [[ -n "${CLOUD_REF}" ]]
}

resolve_gpu_accelerator_type() {
  if [[ "${TF_VAR_gpu_pool_configs}" != "{}" ]]; then
    jq -r 'to_entries[0].key // empty' <<<"${TF_VAR_gpu_pool_configs}"
    return 0
  fi

  printf '%s\n' "${ANYSCALE_PROOF_GPU_ACCELERATOR_TYPE:-T4}"
}

check_flex_proof_preflight() {
  local anyscale_dns_name

  anyscale_dns_name="$(lab_gate_anyscale_host_name "${ANYSCALE_HOST}")"
  lab_gate_flex_node_ready "${ARTIFACT_DIR}"
  lab_gate_kube_proxy_flex_ready "${ARTIFACT_DIR}"
  lab_gate_flex_dns_ready "${ARTIFACT_DIR}" "${anyscale_dns_name}"
  lab_gate_flex_https_egress "${ARTIFACT_DIR}" "${anyscale_dns_name}"
  lab_gate_aks_to_flex_line_of_sight "${ARTIFACT_DIR}"
  lab_gate_anyscale_operator_ready "${ARTIFACT_DIR}"
  lab_gate_anyscale_gateway_ready "${ARTIFACT_DIR}"
}

collect_kubernetes_placement_evidence() {
  local job_name="$1"
  local mode="$2"
  local pods_json nodes_json placement_file

  pods_json="${ARTIFACT_DIR}/proofs/${job_name}-kubernetes-pods.raw.json"
  nodes_json="${ARTIFACT_DIR}/proofs/${job_name}-kubernetes-nodes.raw.json"
  placement_file="${ARTIFACT_DIR}/proofs/${job_name}-kubernetes-placement.json"

  kubectl -n "${TF_VAR_anyscale_operator_namespace}" get pods \
    -l "app.kubernetes.io/name=${job_name}" \
    -o json >"${pods_json}"
  kubectl get nodes -o json >"${nodes_json}"

  jq -n \
    --arg job_name "${job_name}" \
    --arg namespace "${TF_VAR_anyscale_operator_namespace}" \
    --slurpfile pods "${pods_json}" \
    --slurpfile nodes "${nodes_json}" \
    '($nodes[0].items
      | map({
          key: .metadata.name,
          value: {
            region: (.metadata.labels["topology.kubernetes.io/region"] // .metadata.labels["failure-domain.beta.kubernetes.io/region"] // "unknown"),
            agentpool: (.metadata.labels.agentpool // .metadata.labels["kubernetes.azure.com/agentpool"] // "unknown")
          }
        })
      | from_entries) as $node_by_name
    | {
        job_name: $job_name,
        namespace: $namespace,
        pods: [
          $pods[0].items[]
          | {
              name: .metadata.name,
              pod_ip: (.status.podIP // ""),
              node_name: (.spec.nodeName // ""),
              node_region: ($node_by_name[.spec.nodeName].region // "unknown"),
              node_agentpool: ($node_by_name[.spec.nodeName].agentpool // "unknown"),
              phase: (.status.phase // "unknown"),
              ray_node_type: (.metadata.labels["ray-node-type"] // ""),
              anyscale_node_group: (.metadata.labels["anyscale-node-group-id"] // ""),
              containers_ready: ([.status.containerStatuses[]? | select(.ready != true)] | length == 0)
            }
        ]
      }' >"${placement_file}"

  jq -e '.pods | length > 0' "${placement_file}" >/dev/null || die "no Kubernetes placement pods found for ${job_name}"
  if [[ "${mode}" == "cpu" || "${mode}" == "gpu" ]]; then
    jq -e --arg region "${TF_VAR_flex_region}" \
      '.pods[] | select(.ray_node_type == "worker" and .node_region == $region)' \
      "${placement_file}" >/dev/null || die "no ${mode} proof worker pod placed in Flex region ${TF_VAR_flex_region} (placement: ${placement_file})"
    jq -e --arg pool "${AKS_FLEX_AGENT_POOL_NAME}" \
      '.pods[] | select(.ray_node_type == "worker" and .node_agentpool == $pool)' \
      "${placement_file}" >/dev/null || die "no ${mode} proof worker pod placed on Flex agent pool ${AKS_FLEX_AGENT_POOL_NAME} (placement: ${placement_file})"
  fi

  printf '%s\n' "${placement_file}"
}

write_compute_config() {
  local config_name="$1"
  local worker_name="$2"
  local worker_vm_size="$3"
  local worker_count="$4"
  local worker_agentpool="${AKS_FLEX_AGENT_POOL_NAME}"
  local head_cpu="2"
  local head_memory_gi="8"
  local worker_cpu="2"
  local worker_memory_gi="8"
  local worker_gpu=""
  local worker_required_labels=""
  local worker_tolerations

  worker_tolerations="
        tolerations:
          - key: aks-flex-node
            operator: Equal
            value: \"true\"
            effect: NoSchedule"

  # Match private-sample strategy: resource-based config + agentpool selectors,
  # not cloud VM instance_type values. Proof workers run on the Flex node.
  if [[ "${worker_name}" == "gpu-worker" ]]; then
    local gpu_accelerator_type
    gpu_accelerator_type="$(resolve_gpu_accelerator_type)"
    [[ -n "${gpu_accelerator_type}" ]] || die "unable to determine GPU accelerator type from TF_VAR_gpu_pool_configs"
    worker_cpu="4"
    worker_memory_gi="16"
    worker_gpu="
      GPU: 1"
    worker_required_labels="
    required_labels:
      ray.io/accelerator-type: ${gpu_accelerator_type}"
    worker_tolerations="
        tolerations:
          - key: aks-flex-node
            operator: Equal
            value: \"true\"
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
            effect: NoSchedule"
  fi

  cat >"${COMPUTE_CONFIG_DIR}/${config_name}.yaml" <<EOF
cloud: ${CLOUD_REF}
head_node:
  required_resources:
    CPU: ${head_cpu}
    memory: ${head_memory_gi}Gi
  advanced_instance_config:
    spec:
      nodeSelector:
        agentpool: cpu
worker_nodes:
  - name: ${worker_name}
    required_resources:
      CPU: ${worker_cpu}
      memory: ${worker_memory_gi}Gi
${worker_gpu}
${worker_required_labels}
    min_nodes: 0
    max_nodes: ${worker_count:-1}
    advanced_instance_config:
      spec:
        nodeSelector:
          agentpool: ${worker_agentpool}
${worker_tolerations}
EOF
}

ensure_compute_config() {
  local config_name="$1"
  local worker_name="$2"
  local worker_vm_size="$3"
  local worker_count="$4"
  local existing_json
  existing_json="${ARTIFACT_DIR}/compute-configs.json"

  if .venv/bin/anyscale compute-config list --json --max-items 100 --cloud-name "${CLOUD_REF}" >"${existing_json}" 2>/dev/null; then
    if jq -e --arg name "${config_name}" '.results[]? | select(.name == $name)' "${existing_json}" >/dev/null; then
      # Azure control plane does not support archiving compute configs.
      # Creating again with the same name mints a new version.
      :
    fi
  fi

  write_compute_config "${config_name}" "${worker_name}" "${worker_vm_size}" "${worker_count}"
  .venv/bin/anyscale compute-config create \
    --name "${config_name}" \
    --config-file "${COMPUTE_CONFIG_DIR}/${config_name}.yaml" >/dev/null

  .venv/bin/anyscale compute-config get \
    --name "${config_name}" \
    --cloud-name "${CLOUD_REF}" >/dev/null
}

extract_and_validate_logged_proof() {
  local job_name="$1"
  local mode="$2"
  local logs_file="$3"
  local expected_worker_region
  local placement_file
  local remote_summary

  remote_summary="${ARTIFACT_DIR}/proofs/${job_name}-proof-summary.json"

  python3 - "${logs_file}" "${remote_summary}" <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

logs_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
marker = "PROOF_SUMMARY_JSON="
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
  if [[ "${mode}" == "cpu" || "${mode}" == "gpu" ]]; then
    expected_worker_region="${TF_VAR_flex_region}"
  fi

  python3 "${VALIDATOR_SCRIPT}" "${remote_summary}" --expected-worker-region "${expected_worker_region}" >/dev/null
  placement_file="$(collect_kubernetes_placement_evidence "${job_name}" "${mode}")"

  jq -n \
    --arg mode "${mode}" \
    --arg job_name "${job_name}" \
    --arg remote_summary "${remote_summary}" \
    --arg placement_file "${placement_file}" \
    --arg logs_file "${logs_file}" \
    '{
      mode: $mode,
      job_name: $job_name,
      proof_summary_file: $remote_summary,
      kubernetes_placement_file: $placement_file,
      source_logs_file: $logs_file,
      validated: true
    }' >"${STATE_DIR}/anyscale-proof-${mode}.json"
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

  job_name="flex-proof-${mode}-$(date +%Y%m%d-%H%M%S)"
  status_file="${ARTIFACT_DIR}/${job_name}-status.json"
  logs_file="${ARTIFACT_DIR}/${job_name}.log"
  placement_region="${TF_VAR_azure_location}"
  if [[ "${mode}" == "cpu" || "${mode}" == "gpu" ]]; then
    placement_region="${TF_VAR_flex_region}"
  fi
  worker_group_start_timeout_s="${ANYSCALE_PROOF_WORKER_GROUP_START_TIMEOUT_S:-300}"
  if [[ "${mode}" == "gpu" && -z "${ANYSCALE_PROOF_WORKER_GROUP_START_TIMEOUT_S:-}" ]]; then
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
    --env "ANYSCALE_PROOF_STORAGE_ACCOUNT=${STORAGE_ACCOUNT}"
    --env "ANYSCALE_PROOF_STORAGE_CONTAINER=${STORAGE_CONTAINER}"
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
    --evidence-dir "./evidence"
  )

  if [[ -n "${cpu_flag}" ]]; then
    submit_cmd+=("${cpu_flag}")
  fi

  max_submit_attempts="${ANYSCALE_PROOF_SUBMIT_ATTEMPTS:-3}"
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

  set +e
  .venv/bin/anyscale job wait \
    --name "${job_name}" \
    --cloud "${CLOUD_REF}" \
    --timeout-s 1800
  wait_rc=$?
  set -e

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

  extract_and_validate_logged_proof "${job_name}" "${mode}" "${logs_file}"

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
    }' >"${STATE_DIR}/anyscale-proof-job-${mode}.json"
}

run_cpu_mode() {
  check_flex_proof_preflight
  ensure_compute_config "${CPU_CONFIG_NAME}" "cpu-worker" "${TF_VAR_cpu_vm_size}" "1"
  submit_job_for_mode "cpu" "${CPU_CONFIG_NAME}" "1" "--cpu-only" "${CPU_IMAGE_URI}"
}

run_gpu_mode() {
  local gpu_accelerator_type
  local gpu_worker_count

  gpu_accelerator_type="$(resolve_gpu_accelerator_type)"
  [[ -n "${gpu_accelerator_type}" ]] || die "gpu mode requested but no accelerator type was found; set ANYSCALE_PROOF_GPU_ACCELERATOR_TYPE or TF_VAR_gpu_pool_configs"
  gpu_worker_count="${ANYSCALE_PROOF_GPU_WORKER_COUNT:-1}"

  check_flex_proof_preflight
  ensure_compute_config "${GPU_CONFIG_NAME}" "gpu-worker" "${TF_VAR_flex_host_vm_size:-}" "${gpu_worker_count}"
  submit_job_for_mode "gpu" "${GPU_CONFIG_NAME}" "${gpu_worker_count}" "" "${GPU_IMAGE_URI}"
}

write_final_summary() {
  local cpu_file gpu_file
  cpu_file="${STATE_DIR}/anyscale-proof-cpu.json"
  gpu_file="${STATE_DIR}/anyscale-proof-gpu.json"

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
    }' >"${STATE_DIR}/anyscale-proof-run.json"
}

main() {
  parse_args "$@"

  need_cmd python3
  need_cmd jq
  need_cmd az
  need_cmd .venv/bin/anyscale

  source_env
  load_names
  ensure_dirs

  [[ "${TF_VAR_anyscale_enabled}" == "true" ]] || die "TF_VAR_anyscale_enabled must be true"
  cloud_accessible || die "Anyscale cloud ${CLOUD_NAME} not visible at ${ANYSCALE_HOST}; run anyscale login and confirm cloud access"

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

main "$@"
