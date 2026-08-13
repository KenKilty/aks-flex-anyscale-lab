#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/run-anyscale-results.sh"

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

printf 'dynamic Anyscale resource sizing tests passed\n'
