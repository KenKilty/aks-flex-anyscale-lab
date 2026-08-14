#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sku-options-test.XXXXXX")"
trap 'rm -rf "${TEST_DIR}"' EXIT

cat >"${TEST_DIR}/az" <<'MOCK_AZ'
#!/usr/bin/env bash
set -euo pipefail

command_group="${1:-} ${2:-}"
case "${command_group}" in
"account show")
  printf '%s\n' 'test-subscription'
  ;;
"account list-locations")
  cat <<'JSON'
[
  {"name":"region-a","displayName":"Region A"},
  {"name":"region-b","displayName":"Region B"}
]
JSON
  ;;
"provider show")
  cat <<'JSON'
{"resourceTypes":[{"resourceType":"clouds","locations":["Region A"]}]}
JSON
  ;;
"vm list-skus")
  location=""
  while (($# > 0)); do
    if [[ "$1" == "--location" ]]; then
      location="$2"
      break
    fi
    shift
  done
  if [[ "${location}" == "region-a" ]]; then
    cat <<'JSON'
[
  {"name":"Standard_D4s_test","family":"cpuFamily","restrictions":[],"capabilities":[{"name":"vCPUs","value":"4"},{"name":"MemoryGB","value":"16"},{"name":"GPUs","value":"0"},{"name":"PremiumIO","value":"True"}]},
  {"name":"Standard_D2s_too_small","family":"cpuFamily","restrictions":[],"capabilities":[{"name":"vCPUs","value":"2"},{"name":"MemoryGB","value":"8"},{"name":"GPUs","value":"0"},{"name":"PremiumIO","value":"True"}]},
  {"name":"Standard_E16s_too_large","family":"cpuFamily","restrictions":[],"capabilities":[{"name":"vCPUs","value":"16"},{"name":"MemoryGB","value":"64"},{"name":"GPUs","value":"0"},{"name":"PremiumIO","value":"True"}]},
  {"name":"Standard_D8s_noquota","family":"noQuotaFamily","restrictions":[],"capabilities":[{"name":"vCPUs","value":"8"},{"name":"MemoryGB","value":"32"},{"name":"GPUs","value":"0"},{"name":"PremiumIO","value":"True"}]},
  {"name":"Standard_D4s_restricted","family":"cpuFamily","restrictions":[],"capabilities":[{"name":"vCPUs","value":"4"},{"name":"MemoryGB","value":"16"},{"name":"GPUs","value":"0"},{"name":"PremiumIO","value":"True"}]},
  {"name":"Standard_NC4_test","family":"gpuFamily","restrictions":[],"capabilities":[{"name":"vCPUs","value":"4"},{"name":"MemoryGB","value":"28"},{"name":"GPUs","value":"1"},{"name":"PremiumIO","value":"True"}]}
  ,{"name":"Standard_NC16_too_large","family":"gpuFamily","restrictions":[],"capabilities":[{"name":"vCPUs","value":"16"},{"name":"MemoryGB","value":"64"},{"name":"GPUs","value":"1"},{"name":"PremiumIO","value":"True"}]}
]
JSON
  else
    cat <<'JSON'
[
  {"name":"Standard_D4s_test","family":"cpuFamily","restrictions":[],"capabilities":[{"name":"vCPUs","value":"4"},{"name":"MemoryGB","value":"16"},{"name":"GPUs","value":"0"},{"name":"PremiumIO","value":"True"}]},
  {"name":"Standard_D2s_too_small","family":"cpuFamily","restrictions":[],"capabilities":[{"name":"vCPUs","value":"2"},{"name":"MemoryGB","value":"8"},{"name":"GPUs","value":"0"},{"name":"PremiumIO","value":"True"}]},
  {"name":"Standard_E16s_too_large","family":"cpuFamily","restrictions":[],"capabilities":[{"name":"vCPUs","value":"16"},{"name":"MemoryGB","value":"64"},{"name":"GPUs","value":"0"},{"name":"PremiumIO","value":"True"}]},
  {"name":"Standard_D8s_noquota","family":"noQuotaFamily","restrictions":[],"capabilities":[{"name":"vCPUs","value":"8"},{"name":"MemoryGB","value":"32"},{"name":"GPUs","value":"0"},{"name":"PremiumIO","value":"True"}]},
  {"name":"Standard_D4s_restricted","family":"cpuFamily","restrictions":[{"reasonCode":"NotAvailableForSubscription"}],"capabilities":[{"name":"vCPUs","value":"4"},{"name":"MemoryGB","value":"16"},{"name":"GPUs","value":"0"},{"name":"PremiumIO","value":"True"}]},
  {"name":"Standard_NC4_test","family":"gpuFamily","restrictions":[],"capabilities":[{"name":"vCPUs","value":"4"},{"name":"MemoryGB","value":"28"},{"name":"GPUs","value":"1"},{"name":"PremiumIO","value":"True"}]}
  ,{"name":"Standard_NC16_too_large","family":"gpuFamily","restrictions":[],"capabilities":[{"name":"vCPUs","value":"16"},{"name":"MemoryGB","value":"64"},{"name":"GPUs","value":"1"},{"name":"PremiumIO","value":"True"}]}
]
JSON
  fi
  ;;
"vm list-usage")
  cat <<'JSON'
[
  {"name":{"value":"cpuFamily"},"currentValue":2,"limit":10},
  {"name":{"value":"noQuotaFamily"},"currentValue":8,"limit":8},
  {"name":{"value":"gpuFamily"},"currentValue":0,"limit":8}
]
JSON
  ;;
*)
  printf 'unexpected mock az command: %s\n' "$*" >&2
  exit 1
  ;;
esac
MOCK_AZ
chmod +x "${TEST_DIR}/az"

# shellcheck source=scripts/setup.sh
source "${ROOT_DIR}/scripts/setup.sh"

cpu_output="$(PATH="${TEST_DIR}:${PATH}" sku_options region-a region-b cpu)"
grep -q 'Standard_D4s_test' <<<"${cpu_output}"
if grep -qE 'Standard_D2s_too_small|Standard_E16s_too_large|Standard_D8s_noquota|Standard_D4s_restricted|Standard_NC4_test' <<<"${cpu_output}"; then
  printf 'CPU output included an ineligible SKU\n' >&2
  exit 1
fi

gpu_output="$(PATH="${TEST_DIR}:${PATH}" sku_options region-a region-b gpu)"
grep -q 'Standard_NC4_test' <<<"${gpu_output}"
if grep -qE 'Standard_D4s_test|Standard_NC16_too_large' <<<"${gpu_output}"; then
  printf 'GPU output included a CPU-only SKU\n' >&2
  exit 1
fi

printf 'cross-region SKU option tests passed\n'
