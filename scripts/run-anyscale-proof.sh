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
FLEX_NODE_NAME=""

# shellcheck source=./lib/timeout.sh
source "${TIMEOUT_LIB}"
# shellcheck source=./lib/anyscale-job-submit.sh
source "${SUBMIT_HELPER_LIB}"

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
  RESOURCE_GROUP_NAME="rg-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
  CLUSTER_NAME="aks-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
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

resolve_gpu_vm_size() {
  jq -r 'to_entries[0].value.vm_size // empty' <<<"${TF_VAR_gpu_pool_configs}"
}

resolve_gpu_pool_name() {
  jq -r 'to_entries[0].value.name // empty' <<<"${TF_VAR_gpu_pool_configs}"
}

anyscale_host_name() {
  local host
  host="${ANYSCALE_HOST#http://}"
  host="${host#https://}"
  printf '%s\n' "${host%%/*}"
}

check_anyscale_operator_ready() {
  local ext_status_json
  local provisioning_state
  local install_message
  local operator_status_json
  local unhealthy_pods

  ext_status_json="${ARTIFACT_DIR}/anyscale-extension-status-runtime.json"
  operator_status_json="${ARTIFACT_DIR}/anyscale-operator-pods-runtime.json"

  az k8s-extension show \
    --cluster-type managedClusters \
    --cluster-name "${CLUSTER_NAME}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --name "${ANYSCALE_EXTENSION_NAME}" \
    -o json >"${ext_status_json}" 2>/dev/null || {
    die "unable to read AKS extension status for ${ANYSCALE_EXTENSION_NAME} on ${CLUSTER_NAME}; validate cluster credentials and extension installation"
  }

  provisioning_state="$(jq -r '.provisioningState // empty' "${ext_status_json}")"
  install_message="$(jq -r '.statuses[0].message // empty' "${ext_status_json}")"
  if [[ "${provisioning_state}" != "Succeeded" ]]; then
    die "Anyscale AKS extension ${ANYSCALE_EXTENSION_NAME} is ${provisioning_state:-unknown}. ${install_message:-No extension error message provided.}"
  fi

  need_cmd kubectl
  kubectl -n "${TF_VAR_anyscale_operator_namespace}" get pods -l app=anyscale-operator -o json >"${operator_status_json}"
  unhealthy_pods="$(jq -r '
    [.items[]
      | select(
          .status.phase != "Running" or
          ((.status.containerStatuses // []) | length) == 0 or
          ([.status.containerStatuses[]? | select(.ready != true)] | length) > 0
        )
      | .metadata.name]
    | join(",")' "${operator_status_json}")"

  if [[ "$(jq -r '.items | length' "${operator_status_json}")" -lt 1 ]]; then
    die "no anyscale-operator pods found in namespace ${TF_VAR_anyscale_operator_namespace}; operator is not ready"
  fi
  if [[ -n "${unhealthy_pods}" ]]; then
    die "anyscale-operator pods are not 3/3 Running in namespace ${TF_VAR_anyscale_operator_namespace}: ${unhealthy_pods}"
  fi
}

check_anyscale_gateway_ready() {
  local gateway_status_json
  local programmed_status
  local gateway_address

  need_cmd kubectl

  gateway_status_json="${ARTIFACT_DIR}/anyscale-gateway-runtime.json"
  kubectl -n "${TF_VAR_anyscale_operator_namespace}" get gateway "${TF_VAR_anyscale_gateway_name}" -o json >"${gateway_status_json}" || {
    die "Gateway ${TF_VAR_anyscale_operator_namespace}/${TF_VAR_anyscale_gateway_name} is missing; operator gateway is not ready"
  }

  programmed_status="$(jq -r '[.status.conditions[]? | select(.type == "Programmed") | .status] | last // ""' "${gateway_status_json}")"
  gateway_address="$(jq -r '.status.addresses[0].value // empty' "${gateway_status_json}")"

  [[ "${programmed_status}" == "True" ]] || die "Gateway ${TF_VAR_anyscale_gateway_name} is not Programmed=True"
  [[ -n "${gateway_address}" ]] || die "Gateway ${TF_VAR_anyscale_gateway_name} has no programmed address"
  printf 'Gateway %s/%s programmed address: %s\n' "${TF_VAR_anyscale_operator_namespace}" "${TF_VAR_anyscale_gateway_name}" "${gateway_address}"
}

check_flex_nodes_ready() {
  local node_json
  local ready_count
  local node_summary
  local broadly_labeled_nodes

  need_cmd kubectl

  node_json="${ARTIFACT_DIR}/flex-node-preflight.json"
  kubectl get nodes -o json >"${node_json}"

  ready_count="$(jq -r \
    --arg pool "${AKS_FLEX_AGENT_POOL_NAME}" \
    --arg region "${TF_VAR_flex_region}" \
    '[.items[]
      | select((.metadata.labels.agentpool // .metadata.labels["kubernetes.azure.com/agentpool"] // "") == $pool)
      | select((.metadata.labels["topology.kubernetes.io/region"] // .metadata.labels["failure-domain.beta.kubernetes.io/region"] // "") == $region)
      | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))]
      | length' "${node_json}")"

  FLEX_NODE_NAME="$(jq -r \
    --arg pool "${AKS_FLEX_AGENT_POOL_NAME}" \
    --arg region "${TF_VAR_flex_region}" \
    '[.items[]
      | select((.metadata.labels.agentpool // .metadata.labels["kubernetes.azure.com/agentpool"] // "") == $pool)
      | select((.metadata.labels["topology.kubernetes.io/region"] // .metadata.labels["failure-domain.beta.kubernetes.io/region"] // "") == $region)
      | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
      | .metadata.name]
      | first // ""' "${node_json}")"

  if [[ "${ready_count}" -lt 1 ]]; then
    node_summary="$(jq -r '
      [.items[]
        | {
            name: .metadata.name,
            pool: (.metadata.labels.agentpool // .metadata.labels["kubernetes.azure.com/agentpool"] // "unknown"),
            region: (.metadata.labels["topology.kubernetes.io/region"] // .metadata.labels["failure-domain.beta.kubernetes.io/region"] // "unknown"),
            ready: ([.status.conditions[]? | select(.type == "Ready") | .status] | first // "Unknown")
          }]
      | map("\(.name) pool=\(.pool) region=\(.region) ready=\(.ready)")
      | join("; ")' "${node_json}")"
    die "no Ready ${AKS_FLEX_AGENT_POOL_NAME} nodes found in ${TF_VAR_flex_region}; refusing to run CPU proof until flex capacity is joined. Current nodes: ${node_summary}"
  fi

  broadly_labeled_nodes="$(jq -r \
    --arg pool "${AKS_FLEX_AGENT_POOL_NAME}" \
    '[.items[]
      | select((.metadata.labels.agentpool // .metadata.labels["kubernetes.azure.com/agentpool"] // "") == $pool)
      | select(.metadata.labels["kubernetes.azure.com/cluster"] != null)
      | .metadata.name]
      | join(",")' "${node_json}")"
  [[ -z "${broadly_labeled_nodes}" ]] || die "Flex node(s) carry broad kubernetes.azure.com/cluster label and may attract AKS-managed DaemonSets: ${broadly_labeled_nodes}"
}

check_kube_proxy_flex_ready() {
  local daemonset_json
  local desired ready

  need_cmd kubectl

  daemonset_json="${ARTIFACT_DIR}/kube-proxy-flex-runtime.json"
  kubectl -n kube-system rollout status daemonset/kube-proxy-flex --timeout=60s >/dev/null
  kubectl -n kube-system get daemonset kube-proxy-flex -o json >"${daemonset_json}"

  desired="$(jq -r '.status.desiredNumberScheduled // 0' "${daemonset_json}")"
  ready="$(jq -r '.status.numberReady // 0' "${daemonset_json}")"
  [[ "${desired}" -ge 1 ]] || die "kube-proxy-flex has no desired pods; Flex service routing is not programmed"
  [[ "${ready}" == "${desired}" ]] || die "kube-proxy-flex ready=${ready} desired=${desired}; Flex service routing is not ready"
}

check_flex_dns_routing_ready() {
  local pod_name
  local pod_log
  local pod_describe
  local anyscale_dns_name

  need_cmd kubectl

  [[ -n "${FLEX_NODE_NAME}" ]] || die "internal error: FLEX_NODE_NAME is empty before DNS preflight"
  anyscale_dns_name="$(anyscale_host_name)"
  [[ -n "${anyscale_dns_name}" ]] || die "unable to determine Anyscale host name from ANYSCALE_HOST=${ANYSCALE_HOST}"

  pod_name="dns-flex-proof-preflight-$(date +%s)"
  pod_log="${ARTIFACT_DIR}/${pod_name}.log"
  pod_describe="${ARTIFACT_DIR}/${pod_name}-describe.txt"

  kubectl delete pod "${pod_name}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
spec:
  restartPolicy: Never
  nodeSelector:
    agentpool: ${AKS_FLEX_AGENT_POOL_NAME}
  tolerations:
    - key: aks-flex-node
      operator: Equal
      value: "true"
      effect: NoSchedule
  containers:
    - name: dns-flex-debug
      image: busybox:1.36
      command:
        - sh
        - -c
        - |
          set -eu
          cat /etc/resolv.conf
          nslookup ${anyscale_dns_name}
          nslookup kubernetes.default.svc.cluster.local
          sleep 5
EOF

  if ! kubectl wait --for=condition=Ready "pod/${pod_name}" --timeout=180s >/dev/null; then
    kubectl describe pod "${pod_name}" >"${pod_describe}" 2>&1 || true
    kubectl logs "${pod_name}" --tail=120 >"${pod_log}" 2>&1 || true
    kubectl delete pod "${pod_name}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    die "Flex ClusterFirst DNS diagnostic pod did not become Ready (describe: ${pod_describe}, logs: ${pod_log})"
  fi

  kubectl logs "${pod_name}" --tail=120 >"${pod_log}"
  if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${pod_name}" --timeout=60s >/dev/null; then
    kubectl describe pod "${pod_name}" >"${pod_describe}" 2>&1 || true
    kubectl delete pod "${pod_name}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    die "Flex ClusterFirst DNS diagnostic pod did not complete successfully (describe: ${pod_describe}, logs: ${pod_log})"
  fi

  kubectl delete pod "${pod_name}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  grep -q 'svc.cluster.local' "${pod_log}" || die "Flex diagnostic pod resolv.conf did not include cluster search domains (logs: ${pod_log})"
  grep -q "${anyscale_dns_name}" "${pod_log}" || die "Flex diagnostic pod did not resolve ${anyscale_dns_name} (logs: ${pod_log})"
  grep -q 'kubernetes.default.svc.cluster.local' "${pod_log}" || die "Flex diagnostic pod did not resolve kubernetes.default.svc.cluster.local (logs: ${pod_log})"
}

check_cpu_proof_preflight() {
  check_flex_nodes_ready
  check_kube_proxy_flex_ready
  check_flex_dns_routing_ready
  check_anyscale_operator_ready
  check_anyscale_gateway_ready
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

  # Match private-sample strategy: resource-based config + agentpool selectors,
  # not cloud VM instance_type values. CPU proof workers run on the Flex node.
  if [[ "${worker_name}" == "gpu-worker" ]]; then
    worker_agentpool="$(resolve_gpu_pool_name)"
    [[ -n "${worker_agentpool}" ]] || die "unable to determine GPU pool name from TF_VAR_gpu_pool_configs"
    worker_cpu="4"
    worker_memory_gi="16"
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
    min_nodes: 0
    max_nodes: ${worker_count:-1}
    advanced_instance_config:
      spec:
        nodeSelector:
          agentpool: ${worker_agentpool}
        tolerations:
          - key: aks-flex-node
            operator: Equal
            value: "true"
            effect: NoSchedule
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
  if [[ "${mode}" == "cpu" ]]; then
    expected_worker_region="${TF_VAR_flex_region}"
  fi

  python3 "${VALIDATOR_SCRIPT}" "${remote_summary}" --expected-worker-region "${expected_worker_region}" >/dev/null

  jq -n \
    --arg mode "${mode}" \
    --arg job_name "${job_name}" \
    --arg remote_summary "${remote_summary}" \
    --arg logs_file "${logs_file}" \
    '{
      mode: $mode,
      job_name: $job_name,
      proof_summary_file: $remote_summary,
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
  local wait_rc

  job_name="flex-proof-${mode}-$(date +%Y%m%d-%H%M%S)"
  status_file="${ARTIFACT_DIR}/${job_name}-status.json"
  logs_file="${ARTIFACT_DIR}/${job_name}.log"
  placement_region="${TF_VAR_azure_location}"
  if [[ "${mode}" == "cpu" ]]; then
    placement_region="${TF_VAR_flex_region}"
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
    --env "RAY_TRAIN_WORKER_GROUP_START_TIMEOUT_S=${ANYSCALE_PROOF_WORKER_GROUP_START_TIMEOUT_S:-300}"
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
  check_cpu_proof_preflight
  ensure_compute_config "${CPU_CONFIG_NAME}" "cpu-worker" "${TF_VAR_cpu_vm_size}" "1"
  submit_job_for_mode "cpu" "${CPU_CONFIG_NAME}" "1" "--cpu-only" "${CPU_IMAGE_URI}"
}

run_gpu_mode() {
  local gpu_vm_size
  local gpu_pool_name

  [[ "${TF_VAR_gpu_pool_configs}" != "{}" ]] || die "gpu mode requested but TF_VAR_gpu_pool_configs is empty"
  gpu_vm_size="$(resolve_gpu_vm_size)"
  gpu_pool_name="$(resolve_gpu_pool_name)"
  [[ -n "${gpu_vm_size}" ]] || die "unable to determine GPU VM size from TF_VAR_gpu_pool_configs"
  [[ -n "${gpu_pool_name}" ]] || die "unable to determine GPU pool name from TF_VAR_gpu_pool_configs"

  ensure_compute_config "${GPU_CONFIG_NAME}" "gpu-worker" "${gpu_vm_size}" "2"
  submit_job_for_mode "gpu" "${GPU_CONFIG_NAME}" "2" "" "${GPU_IMAGE_URI}"
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
