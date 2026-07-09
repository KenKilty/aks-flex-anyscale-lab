#!/usr/bin/env bash
# shellcheck disable=SC2154
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ANYSCALE_AKS_ENV_FILE:-${ROOT_DIR}/.env}"
GATE_SCRIPT="${ROOT_DIR}/scripts/validate-lab-gates.sh"
STATE_DIR="${ROOT_DIR}/.github/agents/state"
PHASE_RESULTS_FILE="${STATE_DIR}/e2e-phase-results.json"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'error: missing required command: %s\n' "$1" >&2
    exit 1
  }
}

source_env() {
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
}

load_names() {
  RG="rg-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
  CLUSTER="aks-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
}

run_step() {
  local label="$1"
  shift
  printf '\n=== %s ===\n' "${label}"
  "$@"
}

init_phase_results() {
  mkdir -p "${STATE_DIR}"
  cat >"${PHASE_RESULTS_FILE}" <<EOF
{
  "env_file": "${ENV_FILE}",
  "resource_group": "${RG}",
  "cluster": "${CLUSTER}",
  "home_region": "${TF_VAR_azure_location}",
  "flex_region": "${TF_VAR_flex_region}",
  "phases": []
}
EOF
}

record_phase_result() {
  local phase="$1"
  local status="$2"
  local started_at="$3"
  local ended_at="$4"
  local evidence="$5"
  local tmp_file

  tmp_file="$(mktemp)"
  jq \
    --arg phase "${phase}" \
    --arg status "${status}" \
    --arg started_at "${started_at}" \
    --arg ended_at "${ended_at}" \
    --arg evidence "${evidence}" \
    '.phases += [{
      phase: $phase,
      status: $status,
      started_at: $started_at,
      ended_at: $ended_at,
      evidence: $evidence
    }]' "${PHASE_RESULTS_FILE}" >"${tmp_file}"
  mv "${tmp_file}" "${PHASE_RESULTS_FILE}"
}

run_phase() {
  local phase_name="$1"
  local evidence_file="$2"
  shift 2
  local started_at ended_at

  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if "$@"; then
    ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    record_phase_result "${phase_name}" "PASS" "${started_at}" "${ended_at}" "${evidence_file}"
  else
    ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    record_phase_result "${phase_name}" "FAIL" "${started_at}" "${ended_at}" "${evidence_file}"
    return 1
  fi
}

usage() {
  cat <<'EOF'
Usage: ./scripts/run-lab-e2e.sh <phase>

Phases:
  foundation   Run Modules 1-2 apply flow and Module 2 hard gate.
  flex         Run Module 3 apply/bootstrap flow and Module 3 hard gate.
  anyscale     Run Module 4 apply flow and Module 4 hard gate.
  autoscale    Run Module 5 gate checks.
  proof-remote-cpu Run Module 6 remote Anyscale CPU proof.
  proof-remote-gpu Run Module 6 remote Anyscale GPU proof.
  proof-remote Run Module 6 remote Anyscale CPU then GPU proof.
  teardown     Run destroy and Module 7 teardown gate.
  all          Run foundation, flex, anyscale, autoscale, proof-remote, teardown in order.
EOF
}

phase_foundation() {
  run_step "Module 1 doctor" "${ROOT_DIR}/scripts/anyscale-aks.sh" doctor
  run_step "Module 2 apply" "${ROOT_DIR}/scripts/anyscale-aks.sh" apply
  run_step "Module 2 gate" "${GATE_SCRIPT}" m2
}

phase_flex() {
  run_step "Module 3 apply" "${ROOT_DIR}/scripts/anyscale-aks.sh" apply
  run_step "Module 3 flex-config" "${ROOT_DIR}/scripts/anyscale-aks.sh" flex-config
  run_step "Module 3 flex-bootstrap" "${ROOT_DIR}/scripts/anyscale-aks.sh" flex-bootstrap
  run_step "Module 3 gate" "${GATE_SCRIPT}" m3
}

phase_anyscale() {
  run_step "Module 4 apply" "${ROOT_DIR}/scripts/anyscale-aks.sh" apply
  run_step "Module 4 gate" "${GATE_SCRIPT}" m4
}

phase_autoscale() {
  if [[ "${ANYSCALE_FLEX_GPU_ENABLED:-false}" == "true" || "${TF_VAR_gpu_pool_configs}" != "{}" ]]; then
    run_step "Module 5 NVIDIA device plugin" "${ROOT_DIR}/scripts/install-nvidia-device-plugin.sh"
  fi
  run_step "Module 5 gate" "${GATE_SCRIPT}" m5
}

phase_proof_remote() {
  run_step "Module 6 remote Anyscale CPU+GPU proof" "${ROOT_DIR}/scripts/run-anyscale-proof.sh" --mode both
}

phase_proof_remote_cpu() {
  run_step "Module 6 remote Anyscale CPU proof" "${ROOT_DIR}/scripts/run-anyscale-proof.sh" --mode cpu
}

phase_proof_remote_gpu() {
  run_step "Module 6 remote Anyscale GPU proof" "${ROOT_DIR}/scripts/run-anyscale-proof.sh" --mode gpu
}

phase_teardown() {
  run_step "Module 7 destroy" "${ROOT_DIR}/scripts/anyscale-aks.sh" destroy
  run_step "Module 7 gate" "${GATE_SCRIPT}" teardown
}

write_run_metadata() {
  mkdir -p "${STATE_DIR}"
  cat >"${STATE_DIR}/e2e-run-context.json" <<EOF
{
  "env_file": "${ENV_FILE}",
  "resource_group": "${RG}",
  "cluster": "${CLUSTER}",
  "home_region": "${TF_VAR_azure_location}",
  "flex_region": "${TF_VAR_flex_region}",
  "flex_host_enabled": ${TF_VAR_flex_host_enabled},
  "anyscale_enabled": ${TF_VAR_anyscale_enabled}
}
EOF
}

main() {
  local phase="${1:-}"

  need_cmd az
  need_cmd terraform
  need_cmd kubectl
  need_cmd python3
  [[ -x "${GATE_SCRIPT}" ]] || chmod +x "${GATE_SCRIPT}"

  source_env
  load_names
  write_run_metadata
  init_phase_results

  case "${phase}" in
  foundation)
    run_phase "foundation" "${STATE_DIR}/e2e-run-context.json" phase_foundation
    ;;
  flex)
    run_phase "flex" "${STATE_DIR}/e2e-run-context.json" phase_flex
    ;;
  anyscale)
    run_phase "anyscale" "${STATE_DIR}/e2e-run-context.json" phase_anyscale
    ;;
  autoscale)
    run_phase "autoscale" "${STATE_DIR}/e2e-run-context.json" phase_autoscale
    ;;
  proof-remote-cpu)
    run_phase "proof-remote-cpu" "${STATE_DIR}/anyscale-proof-cpu.json" phase_proof_remote_cpu
    ;;
  proof-remote-gpu)
    run_phase "proof-remote-gpu" "${STATE_DIR}/anyscale-proof-gpu.json" phase_proof_remote_gpu
    ;;
  proof-remote)
    run_phase "proof-remote" "${STATE_DIR}/anyscale-proof-run.json" phase_proof_remote
    ;;
  teardown)
    run_phase "teardown" "${STATE_DIR}/e2e-run-context.json" phase_teardown
    ;;
  all)
    run_phase "foundation" "${STATE_DIR}/e2e-run-context.json" phase_foundation
    run_phase "flex" "${STATE_DIR}/e2e-run-context.json" phase_flex
    run_phase "anyscale" "${STATE_DIR}/e2e-run-context.json" phase_anyscale
    run_phase "autoscale" "${STATE_DIR}/e2e-run-context.json" phase_autoscale
    run_phase "proof-remote" "${STATE_DIR}/anyscale-proof-run.json" phase_proof_remote
    run_phase "teardown" "${STATE_DIR}/e2e-run-context.json" phase_teardown
    ;;
  *)
    usage
    exit 1
    ;;
  esac
}

main "$@"
