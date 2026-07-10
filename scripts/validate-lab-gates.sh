#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ANYSCALE_AKS_ENV_FILE:-${ROOT_DIR}/.env}"
STATE_DIR="${ROOT_DIR}/.github/agents/state"
FLEX_NETWORK_GATES_LIB="${ROOT_DIR}/scripts/lib/flex-network-gates.sh"

# shellcheck source=./lib/flex-network-gates.sh
source "${FLEX_NETWORK_GATES_LIB}"

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
  PROJECT="${TF_VAR_project}"
  ENVIRONMENT="${TF_VAR_environment}"
  REGION_SHORT="${TF_VAR_region_short}"
  FLEX_REGION_SHORT="${TF_VAR_flex_region_short}"

  RG="rg-${PROJECT}-${ENVIRONMENT}-${REGION_SHORT}"
  CLUSTER="aks-${PROJECT}-${ENVIRONMENT}-${REGION_SHORT}"
  FLEX_VM="vm-flex-${PROJECT}-${ENVIRONMENT}-${FLEX_REGION_SHORT}"
}

resolve_gpu_pool_name() {
  jq -r 'to_entries[0].value.name // empty' <<<"${TF_VAR_gpu_pool_configs}"
}

print_section() {
  printf '\n[%s]\n' "$1"
}

pass() {
  printf 'PASS %s\n' "$1"
}

skip() {
  printf 'SKIP %s\n' "$1"
}

capture_m4_artifacts() {
  local pod_name

  mkdir -p "${STATE_DIR}"
  kubectl get pods -n anyscale-operator -o wide >"${STATE_DIR}/m4-pods.txt" 2>&1 || true
  kubectl get events -n anyscale-operator --sort-by=.lastTimestamp >"${STATE_DIR}/m4-events.txt" 2>&1 || true
  kubectl describe deployment anyscale-operator -n anyscale-operator >"${STATE_DIR}/m4-operator-deploy-describe.txt" 2>&1 || true

  pod_name="$(kubectl get pods -n anyscale-operator --no-headers 2>/dev/null | awk 'NR==1 {print $1}')"
  if [[ -n "${pod_name}" ]]; then
    kubectl describe pod -n anyscale-operator "${pod_name}" >"${STATE_DIR}/m4-operator-pod-describe.txt" 2>&1 || true
    kubectl logs -n anyscale-operator "${pod_name}" --all-containers=true --tail=500 >"${STATE_DIR}/m4-operator-logs.txt" 2>&1 || true
    kubectl logs -n anyscale-operator "${pod_name}" --all-containers=true --previous --tail=500 >"${STATE_DIR}/m4-operator-logs-previous.txt" 2>&1 || true
  fi
}

resolve_anyscale_platform_role_name() {
  case "$1" in
  "Anyscale Platform Administrator")
    printf 'Anyscale Platform Administrator Role'
    ;;
  "Anyscale Platform Contributor")
    printf 'Anyscale Platform Contributor Role'
    ;;
  "Anyscale Platform Reader")
    printf 'Anyscale Platform Reader Role'
    ;;
  *)
    printf '%s' "$1"
    ;;
  esac
}

resolve_current_principal_object_id() {
  local account_user account_type object_id

  account_type="$(az account show --query 'user.type' -o tsv 2>/dev/null || true)"
  account_user="$(az account show --query 'user.name' -o tsv 2>/dev/null || true)"
  object_id=""

  if [[ "${account_type}" == "user" ]]; then
    object_id="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
  elif [[ -n "${account_user}" ]]; then
    object_id="$(az ad sp show --id "${account_user}" --query id -o tsv 2>/dev/null || true)"
  fi

  [[ -n "${object_id}" ]] || die "unable to resolve current Azure principal object id for Anyscale Platform RBAC gate"
  printf '%s' "${object_id}"
}

check_anyscale_platform_current_principal_rbac() {
  local config enabled role_name effective_role_name scope_key custom_scope effective_scope principal_id artifact_file assignment_count

  if [[ "${TF_VAR_anyscale_enabled}" != "true" ]]; then
    return 0
  fi

  config="${TF_VAR_anyscale_platform_default_admin_assignment:-}"
  [[ -n "${config}" ]] || config='{}'
  enabled="$(jq -r '.enabled // true' <<<"${config}")"
  if [[ "${enabled}" != "true" ]]; then
    skip "M4-04 current-principal Anyscale Platform RBAC gate disabled"
    return 0
  fi

  role_name="$(jq -r '.role_definition_name // "Anyscale Platform Administrator"' <<<"${config}")"
  effective_role_name="$(resolve_anyscale_platform_role_name "${role_name}")"
  scope_key="$(jq -r '.scope // "subscription"' <<<"${config}")"
  custom_scope="$(jq -r '.custom_scope // empty' <<<"${config}")"

  case "${scope_key}" in
  subscription)
    effective_scope="/subscriptions/${TF_VAR_azure_subscription_id}"
    ;;
  resource_group)
    effective_scope="/subscriptions/${TF_VAR_azure_subscription_id}/resourceGroups/${RG}"
    ;;
  cloud)
    effective_scope="/subscriptions/${TF_VAR_azure_subscription_id}/resourceGroups/${RG}/providers/Anyscale.Platform/clouds/${PROJECT}-${ENVIRONMENT}-${REGION_SHORT}"
    ;;
  custom)
    [[ -n "${custom_scope}" ]] || die "M4-04 custom Anyscale Platform RBAC scope requires custom_scope"
    effective_scope="${custom_scope}"
    ;;
  *)
    die "M4-04 unsupported Anyscale Platform RBAC scope: ${scope_key}"
    ;;
  esac

  principal_id="$(resolve_current_principal_object_id)"
  artifact_file="${STATE_DIR}/m4-anyscale-platform-rbac.json"
  mkdir -p "${STATE_DIR}"
  az role assignment list \
    --assignee "${principal_id}" \
    --scope "${effective_scope}" \
    -o json >"${artifact_file}"
  assignment_count="$(jq --arg role "${effective_role_name}" '[.[] | select(.roleDefinitionName == $role)] | length' "${artifact_file}")"
  [[ "${assignment_count}" -ge 1 ]] || die "M4-04 missing ${effective_role_name} for current principal ${principal_id} at ${effective_scope} (details: ${artifact_file})"
  pass "M4-04 current principal has ${effective_role_name} at ${scope_key} scope"
}

check_m2() {
  print_section "Module 2 gates"

  [[ "$(az group exists --name "${RG}")" == "true" ]] || die "M2-01 resource group missing: ${RG}"
  pass "M2-01 resource group exists"

  local aks_state
  aks_state="$(az aks show --resource-group "${RG}" --name "${CLUSTER}" --query provisioningState -o tsv)"
  [[ "${aks_state}" == "Succeeded" ]] || die "M2-02 AKS provisioningState=${aks_state}"
  pass "M2-02 AKS provisioning succeeded"

  az aks get-credentials --resource-group "${RG}" --name "${CLUSTER}" --overwrite-existing --only-show-errors >/dev/null
  kubectl get nodes --no-headers >/dev/null
  pass "M2-03 kubeconfig and kubectl access"

  local failing_pods
  failing_pods="$(kubectl get pods -n kube-system --no-headers | grep -v Running | grep -v Completed || true)"
  [[ -z "${failing_pods}" ]] || die "M2-04 kube-system has non-running pods"
  pass "M2-04 kube-system healthy"
}

check_m3() {
  print_section "Module 3 gates"

  if [[ "${TF_VAR_flex_host_enabled}" != "true" ]]; then
    skip "M3 Flex host disabled in env profile"
    return 0
  fi

  local vm_state vm_power flex_nodes ready_flex_nodes
  vm_state="$(az vm show --resource-group "${RG}" --name "${FLEX_VM}" --query provisioningState -o tsv 2>/dev/null || true)"
  [[ "${vm_state}" == "Succeeded" ]] || die "M3-01 Flex VM provisioningState=${vm_state:-missing}"
  vm_power="$(az vm get-instance-view --resource-group "${RG}" --name "${FLEX_VM}" --query 'instanceView.statuses[1].displayStatus' -o tsv 2>/dev/null || true)"
  [[ "${vm_power}" == "VM running" ]] || die "M3-02 Flex VM power=${vm_power:-missing}"
  pass "M3-01/M3-02 Flex VM exists and is running"

  flex_nodes="$(kubectl get nodes --show-labels | grep flex || true)"
  [[ -n "${flex_nodes}" ]] || die "M3-03 No Flex node appears in cluster"
  ready_flex_nodes="$(kubectl get nodes --no-headers | grep -i flex | grep ' Ready ' || true)"
  [[ -n "${ready_flex_nodes}" ]] || die "M3-04 Flex node not Ready"
  pass "M3-03/M3-04 Flex node joined and Ready"
}

check_m4() {
  print_section "Module 4 gates"

  if [[ "${TF_VAR_anyscale_enabled}" != "true" ]]; then
    skip "M4 Anyscale disabled in env profile"
    return 0
  fi

  local ext_state pod_issues ext_json
  local wait_seconds wait_interval attempts attempt last_status
  mkdir -p "${STATE_DIR}"
  ext_json="${STATE_DIR}/m4-extension-status.json"
  wait_seconds="${M4_EXTENSION_WAIT_SECONDS:-180}"
  wait_interval="${M4_EXTENSION_WAIT_INTERVAL:-15}"
  attempts=$((wait_seconds / wait_interval))
  ((attempts < 1)) && attempts=1

  if [[ "${wait_interval}" -lt 1 ]]; then
    die "M4 gate invalid M4_EXTENSION_WAIT_INTERVAL=${wait_interval}"
  fi

  # Persist full extension status for deterministic troubleshooting.
  if az k8s-extension show \
    --cluster-type managedClusters \
    --cluster-name "${CLUSTER}" \
    --resource-group "${RG}" \
    --name anyscale-operator -o json >"${ext_json}" 2>/dev/null; then
    jq \
      --arg rg "${RG}" \
      --arg cluster "${CLUSTER}" \
      --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{
        checked_at: $checked_at,
        resource_group: $rg,
        cluster: $cluster,
        name: .name,
        extension_type: .extensionType,
        release_train: .releaseTrain,
        provisioning_state: .provisioningState,
        current_version: .currentVersion,
        statuses: (.statuses // [] | map({code, level, message})),
        config: (.configurationSettings // {})
      }' "${ext_json}" >"${ext_json}.tmp"
    mv "${ext_json}.tmp" "${ext_json}"
    ext_state="$(jq -r '.provisioning_state // "missing"' "${ext_json}")"
  else
    ext_state="missing"
    jq -n \
      --arg rg "${RG}" \
      --arg cluster "${CLUSTER}" \
      --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg provisioning_state "missing" \
      --arg message "anyscale-operator extension not found or query failed" \
      '{
        checked_at: $checked_at,
        resource_group: $rg,
        cluster: $cluster,
        provisioning_state: $provisioning_state,
        statuses: [{code: "NotFound", level: "Error", message: $message}]
      }' >"${ext_json}"
  fi

  if [[ "${ext_state}" != "Succeeded" ]]; then
    last_status="$(jq -r '.statuses[0].message // "no status message"' "${ext_json}" 2>/dev/null || echo "no status message")"
    printf 'M4-01 extension state=%s, waiting up to %ss (%s attempts)\n' "${ext_state}" "${wait_seconds}" "${attempts}"
    for ((attempt = 1; attempt <= attempts; attempt++)); do
      sleep "${wait_interval}"
      if az k8s-extension show \
        --cluster-type managedClusters \
        --cluster-name "${CLUSTER}" \
        --resource-group "${RG}" \
        --name anyscale-operator -o json >"${ext_json}" 2>/dev/null; then
        jq \
          --arg rg "${RG}" \
          --arg cluster "${CLUSTER}" \
          --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '{
            checked_at: $checked_at,
            resource_group: $rg,
            cluster: $cluster,
            name: .name,
            extension_type: .extensionType,
            release_train: .releaseTrain,
            provisioning_state: .provisioningState,
            current_version: .currentVersion,
            statuses: (.statuses // [] | map({code, level, message})),
            config: (.configurationSettings // {})
          }' "${ext_json}" >"${ext_json}.tmp"
        mv "${ext_json}.tmp" "${ext_json}"
        ext_state="$(jq -r '.provisioning_state // "missing"' "${ext_json}")"
        last_status="$(jq -r '.statuses[0].message // "no status message"' "${ext_json}" 2>/dev/null || echo "no status message")"
        printf 'M4-01 recheck %s/%s state=%s\n' "${attempt}" "${attempts}" "${ext_state}"
        if [[ "${ext_state}" == "Succeeded" ]]; then
          break
        fi
      fi
    done
  fi

  if [[ "${ext_state}" != "Succeeded" ]]; then
    capture_m4_artifacts
    die "M4-01 extension provisioningState=${ext_state:-missing}; status=${last_status} (details: ${ext_json}, logs: ${STATE_DIR}/m4-operator-logs.txt)"
  fi
  pass "M4-01 Azure extension provisioning succeeded"

  [[ "$(kubectl get ns anyscale-operator -o jsonpath='{.status.phase}' 2>/dev/null || true)" == "Active" ]] || die "M4-02 anyscale-operator namespace missing or inactive"
  pass "M4-02 anyscale-operator namespace active"

  pod_issues="$(kubectl get pods -n anyscale-operator --no-headers 2>/dev/null | grep -E 'CrashLoopBackOff|Error|ImagePullBackOff|Pending|ContainerCreating' || true)"
  if [[ -n "${pod_issues}" ]]; then
    capture_m4_artifacts
    die "M4-03 unhealthy Anyscale operator pods detected (logs: ${STATE_DIR}/m4-operator-logs.txt)"
  fi
  pass "M4-03 operator pods healthy"

  check_anyscale_platform_current_principal_rbac
}

check_m5() {
  print_section "Module 5 gates"

  local autoscale_enabled cpu_max gpu_config anyscale_host_name artifact_dir
  autoscale_enabled="$(az aks nodepool show --resource-group "${RG}" --cluster-name "${CLUSTER}" --name cpu --query enableAutoScaling -o tsv 2>/dev/null || true)"
  cpu_max="$(az aks nodepool show --resource-group "${RG}" --cluster-name "${CLUSTER}" --name cpu --query maxCount -o tsv 2>/dev/null || true)"
  [[ "${autoscale_enabled}" == "true" ]] || die "M5-01 CPU node pool autoscaling disabled"
  [[ -n "${cpu_max}" && "${cpu_max}" -ge 1 ]] || die "M5-01 CPU node pool maxCount invalid: ${cpu_max:-missing}"
  pass "M5-01 CPU node pool autoscaling configured"

  gpu_config="${TF_VAR_gpu_pool_configs}"
  if [[ "${ANYSCALE_FLEX_GPU_ENABLED:-false}" == "true" ]]; then
    local flex_gpu_allocatable flex_gpu_ready_node_count
    [[ "${TF_VAR_flex_host_enabled}" == "true" ]] || die "M5-02 Flex GPU path requires TF_VAR_flex_host_enabled=true"
    az aks get-credentials --resource-group "${RG}" --name "${CLUSTER}" --overwrite-existing --only-show-errors >/dev/null
    flex_gpu_ready_node_count="$(kubectl get nodes -l "agentpool=${AKS_FLEX_AGENT_POOL_NAME:-aksflexnodes}" -o json | jq '[.items[] | select((.status.conditions[]? | select(.type == "Ready" and .status == "True")))] | length')"
    [[ "${flex_gpu_ready_node_count}" -ge 1 ]] || die "M5-02 Flex GPU pool ${AKS_FLEX_AGENT_POOL_NAME:-aksflexnodes} has no Ready nodes"
    flex_gpu_allocatable="$(kubectl get nodes -l "agentpool=${AKS_FLEX_AGENT_POOL_NAME:-aksflexnodes}" -o json | jq '[.items[].status.allocatable["nvidia.com/gpu"]? // empty | tonumber] | add // 0')"
    [[ "${flex_gpu_allocatable}" -ge 1 ]] || die "M5-02 Flex GPU pool ${AKS_FLEX_AGENT_POOL_NAME:-aksflexnodes} has no allocatable nvidia.com/gpu; use a GPU driver image and install the NVIDIA device plugin before running GPU proof"
    pass "M5-02 Flex GPU node available with allocatable GPU"
  elif [[ "${gpu_config}" == "{}" ]]; then
    skip "M5-02 GPU path disabled in current env profile"
  else
    local gpu_allocatable gpu_pool_name gpu_pool_state gpu_ready_node_count
    gpu_pool_name="$(resolve_gpu_pool_name)"
    [[ -n "${gpu_pool_name}" ]] || die "M5-02 unable to determine GPU pool name from TF_VAR_gpu_pool_configs"
    gpu_pool_state="$(az aks nodepool show --resource-group "${RG}" --cluster-name "${CLUSTER}" --name "${gpu_pool_name}" --query provisioningState -o tsv 2>/dev/null || true)"
    [[ "${gpu_pool_state}" == "Succeeded" ]] || die "M5-02 GPU node pool ${gpu_pool_name} not ready: ${gpu_pool_state:-missing}"
    gpu_ready_node_count="$(kubectl get nodes -l "agentpool=${gpu_pool_name}" -o json | jq '[.items[] | select((.status.conditions[]? | select(.type == "Ready" and .status == "True")))] | length')"
    [[ "${gpu_ready_node_count}" -ge 1 ]] || die "M5-02 GPU node pool ${gpu_pool_name} has no Ready nodes"
    gpu_allocatable="$(kubectl get nodes -l "agentpool=${gpu_pool_name}" -o json | jq '[.items[].status.allocatable["nvidia.com/gpu"]? // empty | tonumber] | add // 0')"
    [[ "${gpu_allocatable}" -ge 1 ]] || die "M5-02 GPU node pool ${gpu_pool_name} has no allocatable nvidia.com/gpu; install/repair NVIDIA device plugin and driver readiness before running GPU proof"
    pass "M5-02 GPU node pool available with allocatable GPU"
  fi

  if [[ "${TF_VAR_flex_host_enabled}" != "true" ]]; then
    skip "M5-03 Flex network checks skipped because Flex host is disabled"
    return 0
  fi

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

check_m6_local() {
  print_section "Module 6 local proof gates"

  local proof_path
  proof_path="${ROOT_DIR}/.cache/workloads/deepspeed_finetune/smoke/proof-summary.json"
  [[ -f "${proof_path}" ]] || die "M6-01 missing local smoke proof summary: ${proof_path}"
  pass "M6-01 local proof summary exists"

  python3 "${ROOT_DIR}/workloads/deepspeed_finetune/validate_proof_summary.py" "${proof_path}" >/dev/null
  pass "M6-02 local proof summary validates"
}

check_m7() {
  print_section "Module 7 teardown gates"

  [[ "$(az group exists --name "${RG}")" == "false" ]] || die "M7-01 resource group still exists: ${RG}"
  pass "M7-01 resource group deleted"

  local state_output
  state_output="$(cd "${ROOT_DIR}/infra/terraform" && terraform state list 2>/dev/null || true)"
  [[ -z "${state_output}" ]] || die "M7-02 terraform state not empty"
  pass "M7-02 terraform state empty"
}

usage() {
  cat <<'EOF'
Usage: ./scripts/validate-lab-gates.sh <phase>

Phases:
  m2          Run Module 2 live gates.
  m3          Run Module 3 live gates.
  m4          Run Module 4 live gates.
  m5          Run Module 5 live gates.
  m6-local    Run local Module 6 proof gates.
  preflight   Run live readiness gates for Modules 2, 3, 4, and 5.
  teardown    Run post-destroy cleanup gates for Module 7.
EOF
}

main() {
  local phase="${1:-}"

  need_cmd az
  need_cmd kubectl
  need_cmd jq
  need_cmd python3
  source_env
  load_names

  case "${phase}" in
  m2)
    check_m2
    ;;
  m3)
    check_m3
    ;;
  m4)
    check_m4
    ;;
  m5)
    check_m5
    ;;
  m6-local)
    check_m6_local
    ;;
  preflight)
    check_m2
    check_m3
    check_m4
    check_m5
    ;;
  teardown)
    check_m7
    ;;
  *)
    usage
    exit 1
    ;;
  esac
}

main "$@"
