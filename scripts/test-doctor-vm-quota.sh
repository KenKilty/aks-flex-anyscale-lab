#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=scripts/setup.sh
source "${ROOT_DIR}/scripts/setup.sh"

doctor_reset_vm_quota_requirements
DOCTOR_VM_QUOTA_REGION="region-a"
DOCTOR_VM_QUOTA_FAMILY="family-from-azure"
DOCTOR_VM_REQUIRED_VCPUS=7
DOCTOR_VM_AVAILABLE_VCPUS=20
doctor_record_vm_quota_requirement "configured pool one"
DOCTOR_VM_REQUIRED_VCPUS=9
doctor_record_vm_quota_requirement "configured pool two"

pass_output="$(doctor_check_combined_vm_quota)"
grep -q \
  "combined minimum for configured pool one, configured pool two is 16 family-from-azure vCPUs in region-a (20 remain)" \
  <<<"${pass_output}"

doctor_reset_vm_quota_requirements
DOCTOR_VM_QUOTA_REGION="another-region"
DOCTOR_VM_QUOTA_FAMILY="another-live-family"
DOCTOR_VM_REQUIRED_VCPUS=12
DOCTOR_VM_AVAILABLE_VCPUS=10
doctor_record_vm_quota_requirement "configured pool"

set +e
fail_output="$(doctor_check_combined_vm_quota 2>&1)"
fail_code=$?
set -e

[[ "${fail_code}" -eq 1 ]]
grep -q \
  "combined minimum for configured pool is 12 another-live-family vCPUs in another-region, but only 10 remain" \
  <<<"${fail_output}"

TF_VAR_project="test"
TF_VAR_environment="test"
TF_VAR_azure_location="region-a"
TF_VAR_region_short="regiona"
TF_VAR_flex_region="region-b"
TF_VAR_flex_region_short="regionb"
TF_VAR_system_vm_size="system-sku"
TF_VAR_cpu_vm_size="worker-sku-a"
TF_VAR_flex_host_vm_size="worker-sku-b"
TF_VAR_gpu_pool_configs='{}'
TF_VAR_vnet_address_space='["10.50.0.0/16"]'
TF_VAR_flex_vnet_address_space='["10.60.0.0/16"]'
TF_VAR_service_cidr="10.100.0.0/16"
TF_VAR_aks_pod_cidr="10.83.0.0/16"
TF_VAR_unbounded_flex_pod_cidr="10.84.0.0/16"
ANYSCALE_FLEX_GPU_ENABLED="false"

set +e
cpu_mismatch_output="$(doctor_check_env 2>&1)"
cpu_mismatch_code=$?
set -e
[[ "${cpu_mismatch_code}" -eq 1 ]]
grep -q 'CPU mode requires TF_VAR_cpu_vm_size and TF_VAR_flex_host_vm_size to use the same SKU' <<<"${cpu_mismatch_output}"

TF_VAR_cpu_vm_size="head-sku"
TF_VAR_flex_host_vm_size="gpu-sku-b"
TF_VAR_gpu_pool_configs='{"gpu":{"vm_size":"gpu-sku-a"}}'
ANYSCALE_FLEX_GPU_ENABLED="true"

set +e
gpu_mismatch_output="$(doctor_check_env 2>&1)"
gpu_mismatch_code=$?
set -e
[[ "${gpu_mismatch_code}" -eq 1 ]]
grep -q 'GPU mode requires the Region A GPU pool and Region B Flex host to use the same VM SKU' <<<"${gpu_mismatch_output}"

TF_VAR_flex_host_vm_size="gpu-sku-a"
TF_VAR_azure_location="regiona"
TF_VAR_region_short="${TF_VAR_azure_location}"
set +e
region_label_output="$(doctor_check_env 2>&1)"
region_label_code=$?
set -e
[[ "${region_label_code}" -eq 1 ]]
grep -q 'TF_VAR_region_short must abbreviate TF_VAR_azure_location, not repeat it' <<<"${region_label_output}"

printf 'doctor VM quota aggregation tests passed\n'
