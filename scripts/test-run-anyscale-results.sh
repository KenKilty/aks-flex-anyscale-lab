#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/run-anyscale-results-test.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/run-anyscale-results.sh"

[[ "${JOB_WAIT_TIMEOUT_SECONDS}" == "2700" ]]

NODE_FIXTURE_JSON=""

kubectl() {
  printf '%s\n' "${NODE_FIXTURE_JSON}"
}

assert_resources() {
  local expected="$1"
  shift
  local actual

  actual="$(resolve_node_resources "$@")"
  [[ "${actual}" == "${expected}" ]] || {
    printf 'expected resources %s, got %s\n' "${expected}" "${actual}" >&2
    exit 1
  }
}

NODE_FIXTURE_JSON='{"items":[{"status":{"conditions":[{"type":"Ready","status":"True"}],"allocatable":{"cpu":"3860m","memory":"29360128Ki"}}}]}'
assert_resources "3 16" "agentpool=gpu" 4 16 1 8 "test GPU worker"

NODE_FIXTURE_JSON='{"items":[{"status":{"conditions":[{"type":"Ready","status":"True"}],"allocatable":{"cpu":"1900m","memory":"7340032Ki"}}}]}'
assert_resources "1 6" "agentpool=flex" 2 8 1 4 "test CPU worker"

NODE_FIXTURE_JSON='{"items":[{"status":{"conditions":[{"type":"Ready","status":"True"}],"allocatable":{"cpu":"8","memory":"64Gi"}}}]}'
assert_resources "4 16" "agentpool=gpu" 4 16 1 8 "test capped GPU worker"

NODE_FIXTURE_JSON='{"items":[{"status":{"conditions":[{"type":"Ready","status":"True"}],"allocatable":{"cpu":"7500m","memory":"32Gi"}}},{"status":{"conditions":[{"type":"Ready","status":"True"}],"allocatable":{"cpu":"3860m","memory":"20Gi"}}},{"status":{"conditions":[{"type":"Ready","status":"False"}],"allocatable":{"cpu":"1","memory":"1Gi"}}}]}'
assert_resources "3 16" "agentpool=mixed" 4 16 1 8 "test heterogeneous workers"

NODE_FIXTURE_JSON='{"items":[{"status":{"conditions":[{"type":"Ready","status":"True"}],"allocatable":{"cpu":"900m","memory":"4Gi"}}}]}'
if (resolve_node_resources "agentpool=tiny" 2 8 1 4 "test undersized worker" >/dev/null 2>&1); then
  printf 'expected undersized node resolution to fail\n' >&2
  exit 1
fi

RESOURCE_CALLS_FILE="${TEST_DIR}/resource-calls"
resolve_node_resources() {
  printf '%s\n' "$*" >>"${RESOURCE_CALLS_FILE}"
  printf '1 4\n'
}

COMPUTE_CONFIG_DIR="${TEST_DIR}"
CLOUD_REF="/subscriptions/test/resourceGroups/test/providers/Anyscale.Platform/clouds/test"
AKS_FLEX_AGENT_POOL_NAME="aksflexnodes"
write_dual_cpu_compute_config "cpu-dual"

cpu_config="${COMPUTE_CONFIG_DIR}/cpu-dual.yaml"
grep -q '^agentpool=cpu 2 8 1 4 Ray head$' "${RESOURCE_CALLS_FILE}"
grep -q '^agentpool=cpu 2 8 1 4 managed CPU worker$' "${RESOURCE_CALLS_FILE}"
grep -q '^agentpool=aksflexnodes 2 8 1 4 Flex CPU worker$' "${RESOURCE_CALLS_FILE}"
[[ "$(grep -c 'min_nodes: 1' "${cpu_config}")" -eq 2 ]]
[[ "$(grep -c 'max_nodes: 1' "${cpu_config}")" -eq 2 ]]
grep -q 'name: managed-cpu-worker' "${cpu_config}"
grep -q 'nodeSelector: {agentpool: cpu}' "${cpu_config}"
grep -q 'name: flex-cpu-worker' "${cpu_config}"
grep -q 'nodeSelector: {agentpool: aksflexnodes}' "${cpu_config}"

CPU_CONFIG_NAME="cpu-home"
CPU_IMAGE_URI="cpu-image"
cpu_compute_call=""
cpu_submit_call=""
check_flex_workload_path() { :; }
ensure_compute_config() { cpu_compute_call="$*"; }
submit_job_for_mode() { cpu_submit_call="$*"; }
run_cpu_mode
[[ "${cpu_compute_call}" == "cpu-home cpu-worker 2" ]]
[[ "${cpu_submit_call}" == "cpu cpu-home 2 --cpu-only cpu-image" ]]

log_attempts=0
fetch_job_logs_once() {
  local _job_name="$1"
  local logs_file="$2"
  log_attempts=$((log_attempts + 1))
  if [[ ${log_attempts} -eq 1 ]]; then
    printf 'job still publishing logs\n' >"${logs_file}"
  else
    printf 'WORKLOAD_SUMMARY_JSON={}\n' >"${logs_file}"
  fi
}
sleep() { :; }
ANYSCALE_RESULTS_LOG_ATTEMPTS=2
ANYSCALE_RESULTS_LOG_DELAY_SECONDS=0
wait_for_workload_summary_log "test-job" "${TEST_DIR}/test-job.log"
[[ ${log_attempts} -eq 2 ]]

TF_VAR_azure_location="westus2"
TF_VAR_flex_region="southcentralus"
cat >"${TEST_DIR}/cpu-summary.json" <<'EOF'
{"worker_training_records":[{"hostname":"managed-pod"},{"hostname":"flex-pod"}]}
EOF
cat >"${TEST_DIR}/cpu-placement.json" <<'EOF'
{"pods":[
  {"name":"managed-pod","ray_node_type":"worker","node_region":"westus2","node_agentpool":"cpu"},
  {"name":"flex-pod","ray_node_type":"worker","node_region":"southcentralus","node_agentpool":"aksflexnodes"}
]}
EOF
validate_dual_cpu_training_placement "${TEST_DIR}/cpu-summary.json" "${TEST_DIR}/cpu-placement.json"
cat >"${TEST_DIR}/cpu-colocated-summary.json" <<'EOF'
{"worker_training_records":[{"hostname":"flex-pod"},{"hostname":"flex-pod"}]}
EOF
if (validate_dual_cpu_training_placement "${TEST_DIR}/cpu-colocated-summary.json" "${TEST_DIR}/cpu-placement.json" >/dev/null 2>&1); then
  printf 'expected co-located CPU training evidence to fail\n' >&2
  exit 1
fi

printf 'dynamic Anyscale resource sizing and dual CPU topology tests passed\n'
