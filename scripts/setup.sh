#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154,SC2089,SC2090
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ANYSCALE_AKS_ENV_FILE:-${ROOT_DIR}/.env}"
TERRAFORM_DIR="${ROOT_DIR}/infra/terraform"
GENERATED_TFVARS="${TERRAFORM_DIR}/terraform.auto.tfvars.json"
CACHE_DIR="${ROOT_DIR}/.cache"
FLEX_CACHE_DIR="${CACHE_DIR}/flex"
ANYSCALE_VENV_DIR="${ROOT_DIR}/.venv"
ANYSCALE_AZURE_HOST="https://console.azure.anyscale.com"
TIMEOUT_LIB="${ROOT_DIR}/scripts/lib/timeout.sh"
ANYSCALE_CLOUD_ID=""
ANYSCALE_CLOUD_REF=""

# shellcheck source=./lib/timeout.sh
source "${TIMEOUT_LIB}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

source_env() {
  [[ -f "${ENV_FILE}" ]] || die "Missing ${ENV_FILE}. Copy .env-template to .env first."
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
}

bootstrap() {
  local account_json subscription_id tenant_id env_tmp ssh_key_path

  need_cmd az
  need_cmd jq
  need_cmd python3
  need_cmd ssh-keygen
  mkdir -p "${CACHE_DIR}"

  if [[ ! -f "${ENV_FILE}" ]]; then
    cp "${ROOT_DIR}/.env-template" "${ENV_FILE}"
    chmod 600 "${ENV_FILE}"
    printf 'created: %s\n' "${ENV_FILE}"
  fi

  account_json="$(az account show -o json --only-show-errors)"
  subscription_id="$(jq -r '.id' <<<"${account_json}")"
  tenant_id="$(jq -r '.tenantId' <<<"${account_json}")"
  env_tmp="$(mktemp)"
  awk \
    -v subscription_id="${subscription_id}" \
    -v tenant_id="${tenant_id}" '
      /^ARM_SUBSCRIPTION_ID=/ { next }
      /^ARM_TENANT_ID=/ { next }
      /^TF_VAR_azure_subscription_id=/ { print "TF_VAR_azure_subscription_id=\"" subscription_id "\""; next }
      /^TF_VAR_azure_tenant_id=/ { print "TF_VAR_azure_tenant_id=\"" tenant_id "\""; next }
      /^TF_VAR_cilium_pod_cidr=/ { sub(/^TF_VAR_cilium_pod_cidr=/, "TF_VAR_aks_pod_cidr="); print; next }
      { print }
    ' "${ENV_FILE}" >"${env_tmp}"
  mv "${env_tmp}" "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"

  source_env
  ssh_key_path="${SSH_PRIVATE_KEY_PATH:-${HOME}/.ssh/id_ed25519}"
  if [[ ! -f "${ssh_key_path}" ]]; then
    mkdir -p "$(dirname "${ssh_key_path}")"
    ssh-keygen -q -t ed25519 -N '' -f "${ssh_key_path}"
    printf 'created: %s\n' "${ssh_key_path}"
  fi

  if [[ ! -x "${ANYSCALE_VENV_DIR}/bin/anyscale" ]]; then
    python3 -m venv "${ANYSCALE_VENV_DIR}"
    "${ANYSCALE_VENV_DIR}/bin/python" -m pip install --upgrade pip
    "${ANYSCALE_VENV_DIR}/bin/python" -m pip install \
      --requirement "${ROOT_DIR}/requirements-tooling.txt"
  fi

  printf 'azure subscription: %s\n' "${subscription_id}"
  printf 'azure tenant: %s\n' "${tenant_id}"
  printf 'Anyscale CLI: %s\n' "${ANYSCALE_VENV_DIR}/bin/anyscale"
  printf 'next: choose Region A and Region B, then run ./scripts/anyscale-aks.sh sku-options <region-a> <region-b> cpu|gpu\n'
}

resource_group_name() {
  printf 'rg-%s-%s-%s\n' "${TF_VAR_project}" "${TF_VAR_environment}" "${TF_VAR_region_short}"
}

aks_cluster_name() {
  printf 'aks-%s-%s-%s\n' "${TF_VAR_project}" "${TF_VAR_environment}" "${TF_VAR_region_short}"
}

resolve_flex_release_tag() {
  local latest_url release_tag

  need_cmd curl
  latest_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/Azure/AKSFlexNode/releases/latest")"
  release_tag="${latest_url##*/}"

  [[ "${latest_url}" == "https://github.com/Azure/AKSFlexNode/releases/tag/${release_tag}" ]] ||
    die "Unable to resolve the AKS Flex Node stable release from GitHub."
  [[ "${release_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "GitHub latest AKS Flex Node release ${release_tag} is not a stable semantic-version release."

  printf '%s\n' "${release_tag}"
}

record_flex_release_tag() {
  local release_tag="$1" tag_path tmp_path

  mkdir -p "${FLEX_CACHE_DIR}"
  tag_path="${FLEX_CACHE_DIR}/aks-flex-node-release-tag"
  tmp_path="$(mktemp "${FLEX_CACHE_DIR}/.aks-flex-node-release-tag.XXXXXX")"
  printf '%s\n' "${release_tag}" >"${tmp_path}"
  chmod 600 "${tmp_path}"
  mv "${tmp_path}" "${tag_path}"
}

read_flex_release_tag() {
  local tag_path release_tag

  tag_path="${FLEX_CACHE_DIR}/aks-flex-node-release-tag"
  [[ -f "${tag_path}" ]] || die "Missing ${tag_path}. Run ./scripts/anyscale-aks.sh flex-config again."
  release_tag="$(tr -d '[:space:]' <"${tag_path}")"
  [[ "${release_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "Invalid AKS Flex Node release tag in ${tag_path}. Run ./scripts/anyscale-aks.sh flex-config again."

  printf '%s\n' "${release_tag}"
}

ensure_defaults() {
  [[ -n "${SSH_PRIVATE_KEY_PATH:-}" ]] || SSH_PRIVATE_KEY_PATH="${HOME}/.ssh/id_ed25519"
  [[ -n "${AKS_FLEX_AGENT_POOL_NAME:-}" ]] || AKS_FLEX_AGENT_POOL_NAME="aksflexnodes"
  [[ -n "${TF_VAR_anyscale_enabled:-}" ]] || TF_VAR_anyscale_enabled="false"
  [[ -n "${TF_VAR_anyscale_release_train:-}" ]] || TF_VAR_anyscale_release_train="Stable"
  [[ -n "${TF_VAR_anyscale_gateway_name:-}" ]] || TF_VAR_anyscale_gateway_name="anyscale-gateway"
  [[ -n "${TF_VAR_anyscale_gateway_hostname:-}" ]] || TF_VAR_anyscale_gateway_hostname=""
  [[ -n "${TF_VAR_flex_host_enabled:-}" ]] || TF_VAR_flex_host_enabled="true"
  [[ -n "${TF_VAR_flex_host_admin_username:-}" ]] || TF_VAR_flex_host_admin_username="azureoperator"
  [[ -n "${TF_VAR_flex_host_public_ip_enabled:-}" ]] || TF_VAR_flex_host_public_ip_enabled="true"
  [[ -n "${TF_VAR_flex_host_secondary_ip_configurations:-}" ]] || TF_VAR_flex_host_secondary_ip_configurations="[]"
  [[ -n "${TF_VAR_flex_host_user_assigned_identity_ids:-}" ]] || TF_VAR_flex_host_user_assigned_identity_ids="[]"
  [[ -n "${TF_VAR_flex_host_os_disk_size_gb:-}" ]] || TF_VAR_flex_host_os_disk_size_gb="256"
  [[ -n "${TF_VAR_flex_host_source_image_reference:-}" ]] || TF_VAR_flex_host_source_image_reference='{"publisher":"Canonical","offer":"ubuntu-24_04-lts","sku":"server","version":"latest"}'
  grep -q 'ubuntu-24_04-lts' <<<"${TF_VAR_flex_host_source_image_reference}" || die "Flex host image must remain Ubuntu 24.04 to match the upstream AKS Flex Node guidance. Update TF_VAR_flex_host_source_image_reference in .env."
  [[ -n "${TF_VAR_aks_pod_cidr:-}" ]] || TF_VAR_aks_pod_cidr="10.83.0.0/16"
  [[ -n "${TF_VAR_unbounded_flex_pod_cidr:-}" ]] || TF_VAR_unbounded_flex_pod_cidr="10.84.0.0/16"

  if [[ "${TF_VAR_flex_host_enabled}" == "true" && -z "${TF_VAR_flex_host_admin_ssh_public_key:-}" ]]; then
    [[ -f "${SSH_PRIVATE_KEY_PATH}.pub" ]] || die "Missing TF_VAR_flex_host_admin_ssh_public_key and SSH public key ${SSH_PRIVATE_KEY_PATH}.pub"
    TF_VAR_flex_host_admin_ssh_public_key="$(<"${SSH_PRIVATE_KEY_PATH}.pub")"
  fi

  export SSH_PRIVATE_KEY_PATH
  export AKS_FLEX_AGENT_POOL_NAME
  export TF_VAR_anyscale_enabled
  export TF_VAR_anyscale_release_train
  export TF_VAR_anyscale_gateway_name
  export TF_VAR_anyscale_gateway_hostname
  export TF_VAR_flex_host_enabled
  export TF_VAR_flex_host_vm_size
  export TF_VAR_flex_host_admin_username
  export TF_VAR_flex_host_public_ip_enabled
  export TF_VAR_flex_host_secondary_ip_configurations
  export TF_VAR_flex_host_user_assigned_identity_ids
  export TF_VAR_flex_host_os_disk_size_gb
  export TF_VAR_flex_host_source_image_reference
  export TF_VAR_flex_host_admin_ssh_public_key
  export TF_VAR_aks_pod_cidr
  export TF_VAR_unbounded_flex_pod_cidr
}

sync_azure_context() {
  local account_json subscription_id tenant_id

  account_json="$(az account show -o json --only-show-errors)"
  subscription_id="$(jq -r '.id' <<<"${account_json}")"
  tenant_id="$(jq -r '.tenantId' <<<"${account_json}")"

  [[ -n "${TF_VAR_azure_subscription_id:-}" && "${TF_VAR_azure_subscription_id}" != "00000000-0000-0000-0000-000000000000" ]] || TF_VAR_azure_subscription_id="${subscription_id}"
  [[ -n "${TF_VAR_azure_tenant_id:-}" && "${TF_VAR_azure_tenant_id}" != "00000000-0000-0000-0000-000000000000" ]] || TF_VAR_azure_tenant_id="${tenant_id}"

  ARM_SUBSCRIPTION_ID="${TF_VAR_azure_subscription_id}"
  ARM_TENANT_ID="${TF_VAR_azure_tenant_id}"

  export ARM_SUBSCRIPTION_ID ARM_TENANT_ID TF_VAR_azure_subscription_id TF_VAR_azure_tenant_id
}

validate_network_cidrs() {
  local validation_error

  validation_error="$(
    python3 - \
      "${TF_VAR_vnet_address_space}" \
      "${TF_VAR_flex_vnet_address_space}" \
      "${TF_VAR_service_cidr}" \
      "${TF_VAR_aks_pod_cidr}" \
      "${TF_VAR_unbounded_flex_pod_cidr}" <<'PY'
import ipaddress
import itertools
import json
import sys

groups = {
    "AKS VNet": json.loads(sys.argv[1]),
    "Flex VNet": json.loads(sys.argv[2]),
    "service CIDR": [sys.argv[3]],
    "AKS pod CIDR": [sys.argv[4]],
    "Flex pod CIDR": [sys.argv[5]],
}

try:
    networks = {
        name: [ipaddress.ip_network(value) for value in values]
        for name, values in groups.items()
    }
except (ValueError, TypeError, json.JSONDecodeError) as error:
    print(f"invalid network CIDR configuration: {error}")
    raise SystemExit(1)

for (left_name, left_networks), (right_name, right_networks) in itertools.combinations(networks.items(), 2):
    for left in left_networks:
        for right in right_networks:
            if left.version == right.version and left.overlaps(right):
                print(f"network ranges overlap: {left_name} {left} and {right_name} {right}")
                raise SystemExit(1)
PY
  )" || die "${validation_error}"
}

render_tfvars() {
  local required_vars=(
    TF_VAR_azure_subscription_id
    TF_VAR_azure_tenant_id
    TF_VAR_project
    TF_VAR_environment
    TF_VAR_azure_location
    TF_VAR_region_short
    TF_VAR_flex_region
    TF_VAR_flex_region_short
    TF_VAR_aks_sku_tier
    TF_VAR_system_vm_size
    TF_VAR_cpu_vm_size
    TF_VAR_service_cidr
    TF_VAR_dns_service_ip
    TF_VAR_anyscale_operator_namespace
    TF_VAR_anyscale_operator_serviceaccount
    TF_VAR_anyscale_enabled
    TF_VAR_anyscale_release_train
    TF_VAR_storage_replication_type
    TF_VAR_ampls_ingestion_access_mode
    TF_VAR_ampls_query_access_mode
    TF_VAR_container_insights_data_collection_interval
    TF_VAR_container_insights_namespace_filtering_mode
    TF_VAR_anyscale_operator_identity
    TF_VAR_vnet_address_space
    TF_VAR_subnet_cidrs
    TF_VAR_aks_pod_cidr
    TF_VAR_unbounded_flex_pod_cidr
    TF_VAR_flex_vnet_address_space
    TF_VAR_flex_subnet_cidr
    TF_VAR_dns_forwarding_rules
    TF_VAR_availability_zones
    TF_VAR_system_node_pool_min_count
    TF_VAR_system_node_pool_max_count
    TF_VAR_aks_defender_enabled
    TF_VAR_gpu_pool_configs
    TF_VAR_kubernetes_version
    TF_VAR_storage_cors_rule
    TF_VAR_acr_zone_redundancy_enabled
    TF_VAR_log_analytics_retention_days
    TF_VAR_log_analytics_internet_ingestion_enabled
    TF_VAR_log_analytics_internet_query_enabled
    TF_VAR_ampls_enabled
    TF_VAR_container_insights_v2_enabled
    TF_VAR_container_insights_streams
    TF_VAR_container_insights_namespaces
    TF_VAR_terraform_managed_diagnostic_settings_enabled
    TF_VAR_tags
    TF_VAR_assign_current_principal_cluster_access
    TF_VAR_aks_cluster_admin_principal_ids
    TF_VAR_aks_cluster_user_principal_ids
  )

  ensure_defaults

  local name
  for name in "${required_vars[@]}"; do
    [[ -n "${!name:-}" ]] || die "Missing required variable ${name} in .env"
  done
  validate_network_cidrs

  mkdir -p "${TERRAFORM_DIR}"

  jq -n \
    --arg azure_subscription_id "${TF_VAR_azure_subscription_id}" \
    --arg azure_tenant_id "${TF_VAR_azure_tenant_id}" \
    --arg project "${TF_VAR_project}" \
    --arg environment "${TF_VAR_environment}" \
    --arg azure_location "${TF_VAR_azure_location}" \
    --arg region_short "${TF_VAR_region_short}" \
    --arg flex_region "${TF_VAR_flex_region}" \
    --arg flex_region_short "${TF_VAR_flex_region_short}" \
    --arg aks_sku_tier "${TF_VAR_aks_sku_tier}" \
    --arg system_vm_size "${TF_VAR_system_vm_size}" \
    --arg cpu_vm_size "${TF_VAR_cpu_vm_size}" \
    --arg service_cidr "${TF_VAR_service_cidr}" \
    --arg dns_service_ip "${TF_VAR_dns_service_ip}" \
    --arg anyscale_operator_namespace "${TF_VAR_anyscale_operator_namespace}" \
    --arg anyscale_operator_serviceaccount "${TF_VAR_anyscale_operator_serviceaccount}" \
    --arg anyscale_release_train "${TF_VAR_anyscale_release_train}" \
    --arg anyscale_gateway_name "${TF_VAR_anyscale_gateway_name}" \
    --arg anyscale_gateway_hostname "${TF_VAR_anyscale_gateway_hostname}" \
    --arg flex_host_vm_size "${TF_VAR_flex_host_vm_size}" \
    --arg flex_host_admin_username "${TF_VAR_flex_host_admin_username}" \
    --arg flex_host_admin_ssh_public_key "${TF_VAR_flex_host_admin_ssh_public_key:-}" \
    --arg storage_replication_type "${TF_VAR_storage_replication_type}" \
    --arg ampls_ingestion_access_mode "${TF_VAR_ampls_ingestion_access_mode}" \
    --arg ampls_query_access_mode "${TF_VAR_ampls_query_access_mode}" \
    --arg container_insights_data_collection_interval "${TF_VAR_container_insights_data_collection_interval}" \
    --arg container_insights_namespace_filtering_mode "${TF_VAR_container_insights_namespace_filtering_mode}" \
    --arg flex_subnet_cidr "${TF_VAR_flex_subnet_cidr}" \
    --arg aks_pod_cidr "${TF_VAR_aks_pod_cidr}" \
    --arg unbounded_flex_pod_cidr "${TF_VAR_unbounded_flex_pod_cidr}" \
    --argjson anyscale_operator_identity "${TF_VAR_anyscale_operator_identity}" \
    --argjson anyscale_enabled "${TF_VAR_anyscale_enabled}" \
    --argjson flex_host_enabled "${TF_VAR_flex_host_enabled}" \
    --argjson flex_host_public_ip_enabled "${TF_VAR_flex_host_public_ip_enabled}" \
    --argjson flex_host_secondary_ip_configurations "${TF_VAR_flex_host_secondary_ip_configurations}" \
    --argjson flex_host_user_assigned_identity_ids "${TF_VAR_flex_host_user_assigned_identity_ids}" \
    --argjson flex_host_os_disk_size_gb "${TF_VAR_flex_host_os_disk_size_gb}" \
    --argjson flex_host_source_image_reference "${TF_VAR_flex_host_source_image_reference}" \
    --argjson vnet_address_space "${TF_VAR_vnet_address_space}" \
    --argjson subnet_cidrs "${TF_VAR_subnet_cidrs}" \
    --argjson flex_vnet_address_space "${TF_VAR_flex_vnet_address_space}" \
    --argjson dns_forwarding_rules "${TF_VAR_dns_forwarding_rules}" \
    --argjson availability_zones "${TF_VAR_availability_zones}" \
    --argjson system_node_pool_min_count "${TF_VAR_system_node_pool_min_count}" \
    --argjson system_node_pool_max_count "${TF_VAR_system_node_pool_max_count}" \
    --argjson aks_defender_enabled "${TF_VAR_aks_defender_enabled}" \
    --argjson gpu_pool_configs "${TF_VAR_gpu_pool_configs}" \
    --argjson kubernetes_version "${TF_VAR_kubernetes_version}" \
    --argjson storage_cors_rule "${TF_VAR_storage_cors_rule}" \
    --argjson acr_zone_redundancy_enabled "${TF_VAR_acr_zone_redundancy_enabled}" \
    --argjson log_analytics_retention_days "${TF_VAR_log_analytics_retention_days}" \
    --argjson log_analytics_internet_ingestion_enabled "${TF_VAR_log_analytics_internet_ingestion_enabled}" \
    --argjson log_analytics_internet_query_enabled "${TF_VAR_log_analytics_internet_query_enabled}" \
    --argjson ampls_enabled "${TF_VAR_ampls_enabled}" \
    --argjson container_insights_v2_enabled "${TF_VAR_container_insights_v2_enabled}" \
    --argjson container_insights_streams "${TF_VAR_container_insights_streams}" \
    --argjson container_insights_namespaces "${TF_VAR_container_insights_namespaces}" \
    --argjson terraform_managed_diagnostic_settings_enabled "${TF_VAR_terraform_managed_diagnostic_settings_enabled}" \
    --argjson tags "${TF_VAR_tags}" \
    --argjson assign_current_principal_cluster_access "${TF_VAR_assign_current_principal_cluster_access}" \
    --argjson aks_cluster_admin_principal_ids "${TF_VAR_aks_cluster_admin_principal_ids}" \
    --argjson aks_cluster_user_principal_ids "${TF_VAR_aks_cluster_user_principal_ids}" \
    '{
      azure_subscription_id: $azure_subscription_id,
      azure_tenant_id: $azure_tenant_id,
      project: $project,
      environment: $environment,
      azure_location: $azure_location,
      region_short: $region_short,
      flex_region: $flex_region,
      flex_region_short: $flex_region_short,
      aks_sku_tier: $aks_sku_tier,
      system_vm_size: $system_vm_size,
      cpu_vm_size: $cpu_vm_size,
      service_cidr: $service_cidr,
      dns_service_ip: $dns_service_ip,
      anyscale_operator_namespace: $anyscale_operator_namespace,
      anyscale_operator_serviceaccount: $anyscale_operator_serviceaccount,
      anyscale_enabled: $anyscale_enabled,
      anyscale_release_train: $anyscale_release_train,
      anyscale_gateway_name: $anyscale_gateway_name,
      anyscale_gateway_hostname: $anyscale_gateway_hostname,
      flex_host_enabled: $flex_host_enabled,
      flex_host_vm_size: $flex_host_vm_size,
      flex_host_admin_username: $flex_host_admin_username,
      flex_host_admin_ssh_public_key: $flex_host_admin_ssh_public_key,
      flex_host_public_ip_enabled: $flex_host_public_ip_enabled,
      flex_host_secondary_ip_configurations: $flex_host_secondary_ip_configurations,
      flex_host_user_assigned_identity_ids: $flex_host_user_assigned_identity_ids,
      flex_host_os_disk_size_gb: $flex_host_os_disk_size_gb,
      flex_host_source_image_reference: $flex_host_source_image_reference,
      storage_replication_type: $storage_replication_type,
      ampls_ingestion_access_mode: $ampls_ingestion_access_mode,
      ampls_query_access_mode: $ampls_query_access_mode,
      container_insights_data_collection_interval: $container_insights_data_collection_interval,
      container_insights_namespace_filtering_mode: $container_insights_namespace_filtering_mode,
      anyscale_operator_identity: $anyscale_operator_identity,
      vnet_address_space: $vnet_address_space,
      subnet_cidrs: $subnet_cidrs,
      flex_vnet_address_space: $flex_vnet_address_space,
      flex_subnet_cidr: $flex_subnet_cidr,
      aks_pod_cidr: $aks_pod_cidr,
      unbounded_flex_pod_cidr: $unbounded_flex_pod_cidr,
      dns_forwarding_rules: $dns_forwarding_rules,
      availability_zones: $availability_zones,
      system_node_pool_min_count: $system_node_pool_min_count,
      system_node_pool_max_count: $system_node_pool_max_count,
      aks_defender_enabled: $aks_defender_enabled,
      gpu_pool_configs: $gpu_pool_configs,
      kubernetes_version: $kubernetes_version,
      storage_cors_rule: $storage_cors_rule,
      acr_zone_redundancy_enabled: $acr_zone_redundancy_enabled,
      log_analytics_retention_days: $log_analytics_retention_days,
      log_analytics_internet_ingestion_enabled: $log_analytics_internet_ingestion_enabled,
      log_analytics_internet_query_enabled: $log_analytics_internet_query_enabled,
      ampls_enabled: $ampls_enabled,
      container_insights_v2_enabled: $container_insights_v2_enabled,
      container_insights_streams: $container_insights_streams,
      container_insights_namespaces: $container_insights_namespaces,
      terraform_managed_diagnostic_settings_enabled: $terraform_managed_diagnostic_settings_enabled,
      tags: $tags,
      assign_current_principal_cluster_access: $assign_current_principal_cluster_access,
      aks_cluster_admin_principal_ids: $aks_cluster_admin_principal_ids,
      aks_cluster_user_principal_ids: $aks_cluster_user_principal_ids
    }' >"${GENERATED_TFVARS}"
}

terraform_cmd() {
  (cd "${TERRAFORM_DIR}" && terraform "$@")
}

resolve_anyscale_cloud() {
  local cloud_name expected_ref json_file match_count raw_file rg

  [[ "${TF_VAR_anyscale_enabled:-false}" == "true" ]] || return 1
  [[ -x "${ANYSCALE_VENV_DIR}/bin/anyscale" ]] || die "missing Anyscale CLI; run ./scripts/anyscale-aks.sh bootstrap"
  [[ -z "${ANYSCALE_HOST:-}" || "${ANYSCALE_HOST}" == "${ANYSCALE_AZURE_HOST}" ]] ||
    die "ANYSCALE_HOST must be ${ANYSCALE_AZURE_HOST}"
  export ANYSCALE_HOST="${ANYSCALE_AZURE_HOST}"

  rg="$(resource_group_name)"
  cloud_name="${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
  expected_ref="/subscriptions/${TF_VAR_azure_subscription_id}/resourcegroups/${rg}/providers/anyscale.platform/clouds/${cloud_name}"
  raw_file="${CACHE_DIR}/anyscale-clouds.raw"
  json_file="${CACHE_DIR}/anyscale-clouds.json"
  mkdir -p "${CACHE_DIR}"

  "${ANYSCALE_VENV_DIR}/bin/anyscale" cloud list --json --no-interactive --max-items 100 >"${raw_file}" 2>/dev/null ||
    die "unable to list Anyscale clouds at ${ANYSCALE_HOST}; run ANYSCALE_HOST=${ANYSCALE_AZURE_HOST} .venv/bin/anyscale login"
  awk 'BEGIN{started=0} /^\[/ {started=1} started {print}' "${raw_file}" |
    awk '/^Fetched [0-9]+ clouds\.$/{exit} {print}' >"${json_file}"
  jq -e 'type == "array"' "${json_file}" >/dev/null || die "Anyscale cloud list did not return a JSON array"

  match_count="$(jq --arg expected "${expected_ref}" '[.[] | select((.name | ascii_downcase) == ($expected | ascii_downcase))] | length' "${json_file}")"
  [[ "${match_count}" -eq 1 ]] || return 1
  ANYSCALE_CLOUD_REF="$(jq -r --arg expected "${expected_ref}" '.[] | select((.name | ascii_downcase) == ($expected | ascii_downcase)) | .name' "${json_file}")"
  ANYSCALE_CLOUD_ID="$(jq -r --arg expected "${expected_ref}" '.[] | select((.name | ascii_downcase) == ($expected | ascii_downcase)) | .id' "${json_file}")"
  [[ -n "${ANYSCALE_CLOUD_REF}" && -n "${ANYSCALE_CLOUD_ID}" ]]
}

verify_anyscale_cloud_once() {
  local cloud_id="$1" kubeconfig="$2"

  printf '%s\n' "${TF_VAR_anyscale_operator_namespace}" |
    env KUBECONFIG="${kubeconfig}" \
      "${ANYSCALE_VENV_DIR}/bin/anyscale" cloud verify --id "${cloud_id}" --strict --yes
}

verify_anyscale_cloud() {
  local attempt verify_kubeconfig="${CACHE_DIR}/anyscale-cloud-verify.kubeconfig"
  local verify_log="${CACHE_DIR}/anyscale-cloud-verify.log"

  [[ "${TF_VAR_anyscale_enabled:-false}" == "true" ]] || return 0

  rm -f "${verify_kubeconfig}"
  az aks get-credentials \
    --resource-group "$(resource_group_name)" \
    --name "$(aks_cluster_name)" \
    --file "${verify_kubeconfig}" \
    --overwrite-existing \
    --only-show-errors >/dev/null || {
    rm -f "${verify_kubeconfig}"
    die "unable to create an isolated kubeconfig for Anyscale cloud verification"
  }
  kubelogin convert-kubeconfig --login azurecli --kubeconfig "${verify_kubeconfig}" >/dev/null || {
    rm -f "${verify_kubeconfig}"
    die "unable to convert the isolated kubeconfig for Azure CLI authentication"
  }

  for ((attempt = 1; attempt <= 4; attempt++)); do
    if resolve_anyscale_cloud &&
      run_with_timeout "${ANYSCALE_CLOUD_VERIFY_TIMEOUT_SECONDS:-60}" \
        verify_anyscale_cloud_once "${ANYSCALE_CLOUD_ID}" "${verify_kubeconfig}" >"${verify_log}" 2>&1 &&
      ! grep -Eq 'FAILED|Failed to verify cloud resource' "${verify_log}"; then
      rm -f "${verify_kubeconfig}"
      printf 'info: Anyscale cloud %s passed strict verification\n' "${ANYSCALE_CLOUD_ID}" >&2
      return 0
    fi
    printf 'info: waiting for Anyscale cloud verification (%s/4)\n' "${attempt}" >&2
    ((attempt < 4)) && sleep 10
  done

  [[ -f "${verify_log}" ]] && cat "${verify_log}" >&2
  rm -f "${verify_kubeconfig}"
  die "the exact Anyscale cloud for $(resource_group_name) did not pass strict verification within 5 minutes"
}

drain_anyscale_jobs() {
  local active_json active_count attempt cloud_name job_id parent rg terminated_file

  [[ "${TF_VAR_anyscale_enabled:-false}" == "true" ]] || return 0
  rg="$(resource_group_name)"
  cloud_name="${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
  parent="/subscriptions/${TF_VAR_azure_subscription_id}/resourceGroups/${rg}/providers/Anyscale.Platform/clouds/${cloud_name}"

  if ! resolve_anyscale_cloud; then
    if az resource show --ids "${parent}" --api-version 2026-02-01-preview --only-show-errors >/dev/null 2>&1; then
      die "Azure cloud ${parent} exists but its exact Anyscale control-plane record is unavailable; stop before teardown to avoid orphaning workloads"
    fi
    printf 'warning: no exact Anyscale control-plane cloud found for the absent Azure cloud %s\n' "${parent}" >&2
    return 0
  fi

  active_json="${CACHE_DIR}/anyscale-active-jobs.json"
  terminated_file="${CACHE_DIR}/anyscale-terminating-job-ids.txt"
  : >"${terminated_file}"
  "${ANYSCALE_VENV_DIR}/bin/anyscale" job list \
    --v2 \
    --cloud "${ANYSCALE_CLOUD_REF}" \
    --include-all-users \
    --state STARTING \
    --state RUNNING \
    --json \
    --no-interactive \
    --max-items 100 >"${active_json}" || die "unable to list active jobs for ${ANYSCALE_CLOUD_REF}"
  jq -e 'type == "array"' "${active_json}" >/dev/null || die "Anyscale active job list did not return a JSON array"

  for ((attempt = 1; attempt <= 60; attempt++)); do
    "${ANYSCALE_VENV_DIR}/bin/anyscale" job list \
      --v2 \
      --cloud "${ANYSCALE_CLOUD_REF}" \
      --include-all-users \
      --state STARTING \
      --state RUNNING \
      --json \
      --no-interactive \
      --max-items 100 >"${active_json}" || die "unable to confirm Anyscale Job termination for ${ANYSCALE_CLOUD_REF}"
    active_count="$(jq 'length' "${active_json}")"
    if [[ "${active_count}" -eq 0 ]]; then
      printf 'info: no active Anyscale Jobs remain on %s\n' "${ANYSCALE_CLOUD_ID}" >&2
      return 0
    fi

    while IFS= read -r job_id; do
      [[ -n "${job_id}" ]] || continue
      grep -qxF "${job_id}" "${terminated_file}" && continue
      printf 'info: terminating active Anyscale Job %s before cloud teardown\n' "${job_id}" >&2
      "${ANYSCALE_VENV_DIR}/bin/anyscale" job terminate --id "${job_id}"
      printf '%s\n' "${job_id}" >>"${terminated_file}"
    done < <(jq -r '.[].id // empty' "${active_json}")

    ((attempt < 60)) && sleep 5
  done

  die "Anyscale Jobs remained active on ${ANYSCALE_CLOUD_REF} after 5 minutes; stop before deleting the Azure cloud"
}

assert_no_active_anyscale_services_or_workspaces() {
  local active_count services_json workspaces_json

  [[ "${TF_VAR_anyscale_enabled:-false}" == "true" ]] || return 0
  [[ -n "${ANYSCALE_CLOUD_ID}" && -n "${ANYSCALE_CLOUD_REF}" ]] || return 0
  services_json="${CACHE_DIR}/anyscale-active-services.json"
  workspaces_json="${CACHE_DIR}/anyscale-active-workspaces.json"

  "${ANYSCALE_VENV_DIR}/bin/anyscale" service list \
    --cloud "${ANYSCALE_CLOUD_REF}" \
    --state STARTING \
    --state RUNNING \
    --state UPDATING \
    --state ROLLING_OUT \
    --state ROLLING_BACK \
    --state UNHEALTHY \
    --state TERMINATING \
    --state SYSTEM_FAILURE \
    --state USER_ERROR_FAILURE \
    --json \
    --no-interactive \
    --max-items 100 >"${services_json}" || die "unable to list active services for ${ANYSCALE_CLOUD_REF}"
  jq -e 'type == "array"' "${services_json}" >/dev/null || die "Anyscale active service list did not return a JSON array"
  active_count="$(jq 'length' "${services_json}")"
  if [[ "${active_count}" -ne 0 ]]; then
    jq -r '.[] | "active service: \(.id // "unknown-id") \(.name // "unknown-name") [\(.state // "unknown-state")]"' "${services_json}" >&2
    die "active Anyscale Services remain on ${ANYSCALE_CLOUD_REF}; terminate them explicitly before destroying this lab"
  fi

  "${ANYSCALE_VENV_DIR}/bin/anyscale" workspace_v2 list \
    --cloud "${ANYSCALE_CLOUD_REF}" \
    --state STARTING \
    --state UPDATING \
    --state RUNNING \
    --state TERMINATING \
    --state ERRORED \
    --state UNKNOWN \
    --json \
    --no-interactive \
    --max-items 100 >"${workspaces_json}" || die "unable to list active workspaces for ${ANYSCALE_CLOUD_REF}"
  jq -e 'type == "array"' "${workspaces_json}" >/dev/null || die "Anyscale active workspace list did not return a JSON array"
  active_count="$(jq 'length' "${workspaces_json}")"
  if [[ "${active_count}" -ne 0 ]]; then
    jq -r '.[] | "active workspace: \(.id // "unknown-id") \(.name // "unknown-name") [\(.state // "unknown-state")]"' "${workspaces_json}" >&2
    die "active Anyscale Workspaces remain on ${ANYSCALE_CLOUD_REF}; terminate them explicitly before destroying this lab"
  fi

  printf 'info: no active Anyscale Services or Workspaces remain on %s\n' "${ANYSCALE_CLOUD_ID}" >&2
}

terminate_anyscale_system_cluster() {
  local terminate_log="${CACHE_DIR}/anyscale-system-cluster-terminate.log"

  [[ "${TF_VAR_anyscale_enabled:-false}" == "true" ]] || return 0
  [[ -n "${ANYSCALE_CLOUD_ID}" ]] || return 0

  if run_with_timeout "${ANYSCALE_SYSTEM_CLUSTER_TERMINATE_TIMEOUT_SECONDS:-600}" \
    "${ANYSCALE_VENV_DIR}/bin/anyscale" cloud terminate-system-cluster \
    --id "${ANYSCALE_CLOUD_ID}" \
    --wait >"${terminate_log}" 2>&1; then
    printf 'info: Anyscale system cluster is terminated for %s\n' "${ANYSCALE_CLOUD_ID}" >&2
    return 0
  fi

  cat "${terminate_log}" >&2
  die "unable to confirm system-cluster termination for ${ANYSCALE_CLOUD_ID}; stop before deleting the Azure cloud"
}

archive_anyscale_compute_configs() {
  local config_id config_name configs_json

  [[ "${TF_VAR_anyscale_enabled:-false}" == "true" ]] || return 0
  [[ -n "${ANYSCALE_CLOUD_ID}" && -n "${ANYSCALE_CLOUD_REF}" ]] || return 0
  configs_json="${CACHE_DIR}/anyscale-compute-configs.json"

  if ! "${ANYSCALE_VENV_DIR}/bin/anyscale" compute-config list \
    --json \
    --max-items 100 \
    --cloud-name "${ANYSCALE_CLOUD_REF}" >"${configs_json}"; then
    printf 'warning: unable to list compute configs for %s; stale config metadata may require Anyscale support cleanup\n' "${ANYSCALE_CLOUD_ID}" >&2
    return 0
  fi

  while IFS=$'\t' read -r config_id config_name; do
    [[ -n "${config_id}" ]] || continue
    case "${config_name}" in
    cpu-home | gpu-dual-home)
      printf 'info: archiving lab compute config %s (%s)\n' "${config_name}" "${config_id}" >&2
      if ! "${ANYSCALE_VENV_DIR}/bin/anyscale" compute-config archive --id "${config_id}"; then
        printf 'warning: unable to archive compute config %s; ask Anyscale support to retire it if it remains after cloud deletion\n' "${config_id}" >&2
      fi
      ;;
    esac
  done < <(jq -r '.results[]? | [.id, .name] | @tsv' "${configs_json}")
}

destroy_verified_complete() {
  local rg state_resources group_exists

  rg="$(resource_group_name)"
  if ! state_resources="$(terraform_cmd state list 2>/dev/null)"; then
    printf 'warning: unable to read Terraform state while verifying destroy\n' >&2
    return 1
  fi
  if ! group_exists="$(az group exists --name "${rg}" --only-show-errors 2>/dev/null)"; then
    printf 'warning: unable to check resource group %s while verifying destroy\n' "${rg}" >&2
    return 1
  fi

  if [[ -z "${state_resources}" && "${group_exists}" == "false" ]]; then
    printf 'info: destroy verified complete; Terraform state is empty and resource group %s is absent\n' "${rg}" >&2
    return 0
  fi

  return 1
}

import_untracked_anyscale_resources() {
  local cloud_address cloud_id cloud_resource_address cloud_resource_id
  local deployment_address deployment_id deployment_name extension_address extension_id

  [[ "${TF_VAR_anyscale_enabled:-false}" == "true" ]] || return 0

  deployment_address='azapi_resource.anyscale_platform[0]'
  if ! terraform_cmd state show "${deployment_address}" >/dev/null 2>&1; then
    deployment_name="dep-anyscale-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
    if deployment_id="$(az deployment group show \
      --resource-group "$(resource_group_name)" \
      --name "${deployment_name}" \
      --query id \
      -o tsv \
      --only-show-errors 2>/dev/null)"; then
      printf 'info: importing existing Anyscale ARM deployment record into Terraform state\n' >&2
      terraform_cmd import "${deployment_address}" "${deployment_id}"
    fi
  fi

  cloud_id="/subscriptions/${TF_VAR_azure_subscription_id}/resourceGroups/$(resource_group_name)/providers/Anyscale.Platform/clouds/${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
  cloud_address='azapi_resource.anyscale_cloud[0]'
  if ! terraform_cmd state show "${cloud_address}" >/dev/null 2>&1 &&
    az resource show --ids "${cloud_id}" --api-version 2026-02-01-preview --only-show-errors >/dev/null 2>&1; then
    printf 'info: importing existing Anyscale.Platform cloud into Terraform state\n' >&2
    terraform_cmd import "${cloud_address}" "${cloud_id}"
  fi

  cloud_resource_id="${cloud_id}/cloudResources/default"
  cloud_resource_address='azapi_resource.anyscale_cloud_resource[0]'
  if ! terraform_cmd state show "${cloud_resource_address}" >/dev/null 2>&1 &&
    az resource show --ids "${cloud_resource_id}" --api-version 2026-02-01-preview --only-show-errors >/dev/null 2>&1; then
    printf 'info: importing existing Anyscale.Platform cloud resource into Terraform state\n' >&2
    terraform_cmd import "${cloud_resource_address}" "${cloud_resource_id}"
  fi

  extension_address='azurerm_kubernetes_cluster_extension.anyscale_operator[0]'
  terraform_cmd state show "${extension_address}" >/dev/null 2>&1 && return 0

  extension_id="/subscriptions/${TF_VAR_azure_subscription_id}/resourceGroups/$(resource_group_name)/providers/Microsoft.ContainerService/managedClusters/$(aks_cluster_name)/providers/Microsoft.KubernetesConfiguration/extensions/anyscale-operator"
  if az resource show --ids "${extension_id}" --only-show-errors >/dev/null 2>&1; then
    printf 'info: importing existing Anyscale extension after an interrupted create\n' >&2
    terraform_cmd import "${extension_address}" "${extension_id}"
  fi
}

reuse_existing_anyscale_default_admin_assignment() {
  local assignment_address assignment_config assignment_id enabled principal_id principal_type role_name scope

  [[ "${TF_VAR_anyscale_enabled:-false}" == "true" ]] || return 0
  assignment_address='azurerm_role_assignment.anyscale_platform["current_principal_admin"]'
  terraform_cmd state show "${assignment_address}" >/dev/null 2>&1 && return 0

  if [[ -n "${TF_VAR_anyscale_platform_default_admin_assignment:-}" ]]; then
    assignment_config="${TF_VAR_anyscale_platform_default_admin_assignment}"
  else
    assignment_config='{}'
  fi
  enabled="$(jq -r '.enabled // true' <<<"${assignment_config}")"
  principal_type="$(jq -r '.principal_type // "User"' <<<"${assignment_config}")"
  role_name="$(jq -r '.role_definition_name // "Anyscale Platform Administrator"' <<<"${assignment_config}")"
  scope="$(jq -r '.scope // "subscription"' <<<"${assignment_config}")"
  [[ "${enabled}" == "true" && "${principal_type}" == "User" && "${scope}" == "subscription" ]] || return 0
  [[ "${role_name}" == "Anyscale Platform Administrator" || "${role_name}" == "Anyscale Platform Administrator Role" ]] || return 0

  principal_id="$(printf '%s\n' 'data.azurerm_client_config.current.object_id' | terraform_cmd console | tr -d '"')"
  [[ "${principal_id}" =~ ^[0-9a-fA-F-]{36}$ ]] || die "unable to resolve the current Azure principal from Terraform client configuration"
  assignment_id="$(az role assignment list \
    --assignee-object-id "${principal_id}" \
    --scope "/subscriptions/${TF_VAR_azure_subscription_id}" \
    --fill-principal-name false \
    --query "[?scope=='/subscriptions/${TF_VAR_azure_subscription_id}' && (roleDefinitionName=='Anyscale Platform Administrator' || roleDefinitionName=='Anyscale Platform Administrator Role')].id | [0]" \
    -o tsv \
    --only-show-errors)"
  [[ -n "${assignment_id}" ]] || return 0

  export TF_VAR_anyscale_platform_default_admin_assignment
  TF_VAR_anyscale_platform_default_admin_assignment="$(jq -c '.enabled = false' <<<"${assignment_config}")"
  printf 'info: reusing existing Anyscale Platform Administrator assignment %s; Terraform will not adopt or delete shared access\n' "${assignment_id}" >&2
}

download_flex_helper() {
  local release_tag="$1" helper_path

  [[ "${release_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid AKS Flex Node release tag ${release_tag}."
  helper_path="${FLEX_CACHE_DIR}/aks-flex-config-${release_tag}"
  mkdir -p "${FLEX_CACHE_DIR}"

  if [[ ! -x "${helper_path}" ]]; then
    need_cmd curl
    curl -fsSLo "${helper_path}" "https://raw.githubusercontent.com/Azure/AKSFlexNode/${release_tag}/scripts/aks-flex-config"
    chmod +x "${helper_path}"
  fi

  printf '%s\n' "${helper_path}"
}

wait_for_flex_node_object() {
  local flex_node_name="$1" timeout_seconds="${2:-300}" deadline

  deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    if kubectl get node "${flex_node_name}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done

  die "Timed out waiting for Flex node ${flex_node_name} to register."
}

label_flex_node() {
  local flex_node_name="$1" attempt

  for attempt in {1..12}; do
    if kubectl label node "${flex_node_name}" \
      "agentpool=${AKS_FLEX_AGENT_POOL_NAME}" \
      "kubernetes.azure.com/agentpool=${AKS_FLEX_AGENT_POOL_NAME}" \
      "topology.kubernetes.io/region=${TF_VAR_flex_region}" \
      "kubernetes.azure.com/cluster-" \
      --overwrite &&
      kubectl taint node "${flex_node_name}" aks-flex-node=true:NoSchedule --overwrite; then
      return 0
    fi
    sleep 5
  done

  die "Timed out labeling and tainting Flex node ${flex_node_name}."
}

approve_flex_daemon_csrs() {
  local flex_node_name="$1" timeout_seconds="${2:-300}" deadline csr_name subject ready

  deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    while IFS= read -r csr_name; do
      [[ -n "${csr_name}" ]] || continue
      subject="$(kubectl get csr "${csr_name}" -o jsonpath='{.spec.request}' | base64 --decode | openssl req -noout -subject -nameopt RFC2253)"
      if [[ "${subject}" == *"CN=system:node:${flex_node_name}"* &&
        "${subject}" == *"O=aks-flex-node-daemons"* &&
        "${subject}" == *"O=system:nodes"* ]]; then
        kubectl certificate approve "${csr_name}" >/dev/null
        printf 'Approved AKS Flex Node daemon CSR: %s\n' "${csr_name}"
      fi
    done < <(
      kubectl get csr -o json |
        jq -r '
          .items[]
          | select(.spec.signerName == "kubernetes.io/kube-apiserver-client")
          | select((.status.conditions // []) | length == 0)
          | select(.spec.username | startswith("system:bootstrap:"))
          | select(.spec.groups | index("system:bootstrappers:aks-flex-node"))
          | .metadata.name
        '
    )

    ready="$(kubectl get node "${flex_node_name}" -o json 2>/dev/null |
      jq -r '[.status.conditions[]? | select(.type == "Ready") | .status] | first // "False"')"
    [[ "${ready}" == "True" ]] && return 0
    sleep 5
  done

  kubectl describe node "${flex_node_name}" || true
  die "Timed out waiting for Flex node ${flex_node_name} to become Ready."
}

require_supported_flex_networking() {
  local cluster_rg="$1" cluster_name="$2" network_profile network_plugin

  network_profile="$(az aks show \
    --resource-group "${cluster_rg}" \
    --name "${cluster_name}" \
    --query networkProfile \
    --output json \
    --only-show-errors)"
  network_plugin="$(jq -r '.networkPlugin // empty' <<<"${network_profile}")"

  [[ "${network_plugin}" == "none" ]] ||
    die "This no-CNI Unbounded experiment requires AKS networkPlugin=none. Observed plugin=${network_plugin:-unset}."
}

generate_flex_config() {
  local helper_path config_path cluster_rg cluster_name flex_host_private_ip flex_node_name release_tag token_id local_accounts_disabled api_server_url ca_cert dns_ip token_secret bootstrap_token token_expiration

  need_cmd az
  need_cmd python3
  need_cmd kubectl
  need_cmd kubelogin
  source_env
  sync_azure_context
  ensure_defaults

  cluster_rg="$(resource_group_name)"
  cluster_name="$(aks_cluster_name)"
  require_supported_flex_networking "${cluster_rg}" "${cluster_name}"
  [[ "${TF_VAR_flex_host_enabled}" == "true" ]] || die "TF_VAR_flex_host_enabled must be true in ${ENV_FILE} to generate a Flex host config."
  flex_host_private_ip="$(terraform_cmd output -raw flex_host_private_ip 2>/dev/null || true)"
  flex_node_name="$(terraform_cmd output -raw flex_host_vm_name 2>/dev/null || true)"
  [[ -n "${flex_host_private_ip}" ]] || die "Missing flex_host_private_ip Terraform output. Deploy the Flex host before generating its config."
  [[ -n "${flex_node_name}" ]] || die "Missing flex_host_vm_name Terraform output. Deploy the Flex host before generating its config."

  release_tag="$(resolve_flex_release_tag)"
  helper_path="$(download_flex_helper "${release_tag}")"
  config_path="${FLEX_CACHE_DIR}/aks-flex-node-config.json"

  mkdir -p "${FLEX_CACHE_DIR}"

  local_accounts_disabled="$(az aks show \
    --resource-group "${cluster_rg}" \
    --name "${cluster_name}" \
    --subscription "${TF_VAR_azure_subscription_id}" \
    --query disableLocalAccounts \
    --output tsv \
    --only-show-errors)"

  if [[ "${local_accounts_disabled}" != "true" ]]; then
    "${helper_path}" setup-node-rbac \
      --resource-group "${cluster_rg}" \
      --cluster-name "${cluster_name}" \
      --subscription "${TF_VAR_azure_subscription_id}"

    "${helper_path}" generate-node-config \
      --resource-group "${cluster_rg}" \
      --cluster-name "${cluster_name}" \
      --subscription "${TF_VAR_azure_subscription_id}" \
      --agent-pool-name "${AKS_FLEX_AGENT_POOL_NAME}" \
      --bootstrap-token \
      --output "${config_path}"
  else
    # Preserve the upstream token schema without re-enabling static AKS credentials.
    az aks get-credentials \
      --resource-group "${cluster_rg}" \
      --name "${cluster_name}" \
      --subscription "${TF_VAR_azure_subscription_id}" \
      --overwrite-existing \
      --only-show-errors >/dev/null
    kubelogin convert-kubeconfig -l azurecli >/dev/null

    kubectl apply -f - >/dev/null <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: aks-flex-node-bootstrapper
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:node-bootstrapper
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:bootstrappers:aks-flex-node
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: aks-flex-node-auto-approve-csr
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:nodeclient
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:bootstrappers:aks-flex-node
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: aks-flex-node-role
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:node
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: system:bootstrappers:aks-flex-node
EOF

    "${helper_path}" generate-node-config \
      --resource-group "${cluster_rg}" \
      --cluster-name "${cluster_name}" \
      --subscription "${TF_VAR_azure_subscription_id}" \
      --agent-pool-name "${AKS_FLEX_AGENT_POOL_NAME}" \
      --identity \
      --output "${config_path}"

    token_id="$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
    token_secret="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    bootstrap_token="${token_id}.${token_secret}"
    token_expiration="$(date -u -d '+24 hours' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+24H +%Y-%m-%dT%H:%M:%SZ)"

    kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-token-${token_id}
  namespace: kube-system
type: bootstrap.kubernetes.io/token
stringData:
  description: "AKS Flex Node bootstrap token"
  token-id: "${token_id}"
  token-secret: "${token_secret}"
  expiration: "${token_expiration}"
  usage-bootstrap-authentication: "true"
  usage-bootstrap-signing: "true"
  auth-extra-groups: "system:bootstrappers:aks-flex-node"
EOF

    api_server_url="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
    api_server_url="${api_server_url#https://}"
    api_server_url="${api_server_url#http://}"
    api_server_url="${api_server_url%%/*}"
    ca_cert="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
    dns_ip="$(az aks show \
      --resource-group "${cluster_rg}" \
      --name "${cluster_name}" \
      --subscription "${TF_VAR_azure_subscription_id}" \
      --query networkProfile.dnsServiceIp \
      --output tsv \
      --only-show-errors)"
    [[ -n "${api_server_url}" ]] || die "Failed to resolve the AKS API endpoint for Flex bootstrap."
    [[ -n "${ca_cert}" ]] || die "Failed to resolve the AKS CA certificate for Flex bootstrap."
    [[ -n "${dns_ip}" ]] || die "Failed to resolve the AKS DNS service IP for Flex bootstrap."

    jq --arg token "${bootstrap_token}" --arg api_server_url "${api_server_url}" --arg ca_cert "${ca_cert}" --arg dns_ip "${dns_ip}" '
      .azure |= (del(.managedIdentity) | .bootstrapToken = {token: $token} | .arc = {enabled: false}) |
      .networking = {dnsServiceIP: $dns_ip} |
      .node = {kubelet: {clusterFQDN: $api_server_url, caCertData: $ca_cert}}
    ' "${config_path}" >"${config_path}.tmp" && mv "${config_path}.tmp" "${config_path}"
  fi

  token_id="$(jq -er '.azure.bootstrapToken.token | split(".")[0]' "${config_path}")"
  kubectl get secret -n kube-system "bootstrap-token-${token_id}" >/dev/null

  jq --arg node_ip "${flex_host_private_ip}" --arg node_name "${flex_node_name}" \
    '.node.kubelet.nodeIP = $node_ip | .agent.nodeName = $node_name' \
    "${config_path}" >"${config_path}.tmp" && mv "${config_path}.tmp" "${config_path}"
  jq -e --arg node_ip "${flex_host_private_ip}" --arg node_name "${flex_node_name}" '
    (.azure.bootstrapToken.token | type == "string" and contains(".")) and
    .azure.arc.enabled == false and
    (.components.kubernetes | type == "string" and length > 0) and
    (.networking.dnsServiceIP | type == "string" and length > 0) and
    (.node.kubelet.clusterFQDN | type == "string" and length > 0) and
    (.node.kubelet.caCertData | type == "string" and length > 0) and
    .node.kubelet.nodeIP == $node_ip and
    .agent.nodeName == $node_name
  ' "${config_path}" >/dev/null || die "Generated Flex config does not satisfy the upstream bootstrap-token contract."
  chmod 600 "${config_path}"
  record_flex_release_tag "${release_tag}"

  printf 'AKS Flex Node stable release: %s\n' "${release_tag}"
  printf 'generated: %s\n' "${config_path}"
}

bootstrap_flex_host() {
  local config_path config_release_tag flex_archive_path flex_checksums_path flex_checksums_url flex_release_url host_ip admin_user flex_node_name cluster_rg cluster_name release_tag secondary_ip_count ssh_opts

  need_cmd az
  need_cmd curl
  need_cmd kubectl
  need_cmd kubelogin
  need_cmd jq
  need_cmd openssl
  need_cmd scp
  need_cmd shasum
  need_cmd ssh
  need_cmd terraform
  source_env
  sync_azure_context
  ensure_defaults

  config_path="${FLEX_CACHE_DIR}/aks-flex-node-config.json"
  [[ -f "${config_path}" ]] || die "Missing ${config_path}. Run ./scripts/anyscale-aks.sh flex-config first."
  release_tag="$(resolve_flex_release_tag)"
  config_release_tag="$(read_flex_release_tag)"
  [[ "${config_release_tag}" == "${release_tag}" ]] ||
    die "AKS Flex Node latest stable release changed from ${config_release_tag} to ${release_tag}. Run ./scripts/anyscale-aks.sh flex-config again before bootstrap."

  host_ip="$(terraform_cmd output -raw flex_host_public_ip 2>/dev/null || true)"
  admin_user="$(terraform_cmd output -raw flex_host_admin_username 2>/dev/null || true)"
  flex_node_name="$(terraform_cmd output -raw flex_host_vm_name 2>/dev/null || true)"
  cluster_rg="$(resource_group_name)"
  cluster_name="$(aks_cluster_name)"

  [[ -n "${host_ip}" ]] || die "Missing flex_host_public_ip Terraform output. Deploy with TF_VAR_flex_host_enabled=true and TF_VAR_flex_host_public_ip_enabled=true."
  [[ -n "${admin_user}" ]] || admin_user="${TF_VAR_flex_host_admin_username}"
  [[ -n "${flex_node_name}" ]] || die "Missing flex_host_vm_name Terraform output. Deploy with TF_VAR_flex_host_enabled=true."
  [[ -f "${SSH_PRIVATE_KEY_PATH}" ]] || die "Missing SSH private key at ${SSH_PRIVATE_KEY_PATH}"
  secondary_ip_count="$(jq -er 'if type == "array" then length else error("expected array") end' <<<"${TF_VAR_flex_host_secondary_ip_configurations}")"

  ssh_opts=(
    -i "${SSH_PRIVATE_KEY_PATH}"
    -o ConnectTimeout=15
    -o ServerAliveInterval=10
    -o ServerAliveCountMax=3
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
  )
  flex_release_url="https://github.com/Azure/AKSFlexNode/releases/download/${release_tag}/aks-flex-node-linux-amd64.tar.gz"
  flex_checksums_url="https://github.com/Azure/AKSFlexNode/releases/download/${release_tag}/checksums.txt"
  flex_archive_path="${FLEX_CACHE_DIR}/aks-flex-node-linux-amd64.tar.gz"
  flex_checksums_path="${FLEX_CACHE_DIR}/checksums.txt"

  curl --connect-timeout 30 --retry 5 --retry-all-errors -fsSLo \
    "${flex_archive_path}" "${flex_release_url}"
  curl --connect-timeout 30 --retry 5 --retry-all-errors -fsSLo \
    "${flex_checksums_path}" "${flex_checksums_url}"
  (
    cd "${FLEX_CACHE_DIR}"
    grep -E '^[[:xdigit:]]{64}  aks-flex-node-linux-amd64\.tar\.gz$' checksums.txt |
      shasum -a 256 -c -
  )

  scp "${ssh_opts[@]}" \
    "${config_path}" \
    "${flex_archive_path}" \
    "${flex_checksums_path}" \
    "${admin_user}@${host_ip}:/tmp/"
  printf 'AKS Flex Node stable release: %s\n' "${release_tag}"

  if ssh "${ssh_opts[@]}" "${admin_user}@${host_ip}" 'sudo systemctl is-active --quiet aks-flex-node-agent'; then
    ssh "${ssh_opts[@]}" "${admin_user}@${host_ip}" \
      bash -s -- "${secondary_ip_count}" <<'REMOTE_FLEX_REFRESH'
set -euo pipefail

FLEX_SECONDARY_IP_COUNT="$1"

if [[ "${FLEX_SECONDARY_IP_COUNT}" == "0" && -f /etc/netplan/50-cloud-init.yaml ]]; then
  if sudo grep -q '^[[:space:]]*addresses:[[:space:]]*$' /etc/netplan/50-cloud-init.yaml; then
    sudo awk '
      /^[[:space:]]*addresses:[[:space:]]*$/ { skipping = 1; next }
      skipping && /^[[:space:]]*dhcp4:[[:space:]]*/ { skipping = 0 }
      !skipping { print }
    ' /etc/netplan/50-cloud-init.yaml | sudo tee /etc/netplan/50-cloud-init.yaml.tmp >/dev/null
    sudo mv /etc/netplan/50-cloud-init.yaml.tmp /etc/netplan/50-cloud-init.yaml
    sudo netplan apply
  fi
  sudo chmod 600 /etc/netplan/50-cloud-init.yaml
fi

sudo install -d -m 0755 /etc/aks-flex-node
sudo install -m 0600 /tmp/aks-flex-node-config.json /etc/aks-flex-node/config.json
sudo systemctl restart aks-flex-node-agent
sudo systemctl is-active --quiet aks-flex-node-agent
REMOTE_FLEX_REFRESH
    printf 'AKS Flex Node agent configuration refreshed and service restarted; continuing with cluster-side reconciliation.\n'
  else
    # shellcheck disable=SC2029
    ssh "${ssh_opts[@]}" "${admin_user}@${host_ip}" \
      "AKS_FLEX_NODE_RELEASE_TAG='${release_tag}' FLEX_GPU_ENABLED='${ANYSCALE_FLEX_GPU_ENABLED:-false}' bash -s" <<'REMOTE_FLEX_BOOTSTRAP'
set -euo pipefail

    for command in grep sha256sum tar; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "missing required command on Flex host: ${command}" >&2
    exit 1
  }
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
mv /tmp/aks-flex-node-linux-amd64.tar.gz "${TMP_DIR}/"
mv /tmp/checksums.txt "${TMP_DIR}/"
(
  cd "${TMP_DIR}"
  grep -E '^[[:xdigit:]]{64}  aks-flex-node-linux-amd64\.tar\.gz$' checksums.txt |
    sha256sum -c -
)
tar -xzf "${TMP_DIR}/aks-flex-node-linux-amd64.tar.gz" -C "${TMP_DIR}"

printf 'AKS Flex Node stable release: %s\n' "${AKS_FLEX_NODE_RELEASE_TAG}"

if [[ "${FLEX_GPU_ENABLED}" == "true" ]]; then
  for attempt in $(seq 1 120); do
    modules_ready=true
    for module in nvidia nvidia_modeset nvidia_uvm nvidia_drm; do
      sudo modprobe "${module}" >/dev/null 2>&1 || modules_ready=false
      grep -q "^${module} " /proc/modules || modules_ready=false
    done
    if [[ "${modules_ready}" == "true" ]] && command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
  [[ "${modules_ready}" == "true" ]] && command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1 || {
    echo 'NVIDIA driver did not become ready within 10 minutes' >&2
    exit 1
  }
fi

if command -v cloud-init >/dev/null 2>&1; then
  sudo cloud-init status --wait
fi

for attempt in $(seq 1 120); do
  if ! sudo fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

if sudo fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1; then
  echo 'Timed out waiting for the Flex host package manager lock' >&2
  exit 1
fi

sudo install -d -m 0755 /etc/aks-flex-node
sudo install -m 0600 /tmp/aks-flex-node-config.json /etc/aks-flex-node/config.json
sudo "${TMP_DIR}/aks-flex-node-linux-amd64" preflight --config /etc/aks-flex-node/config.json
sudo systemctl stop aks-flex-node-agent || true
sudo install -m 0755 "${TMP_DIR}/aks-flex-node-linux-amd64" /usr/local/bin/aks-flex-node

sudo /usr/local/bin/aks-flex-node start --config /etc/aks-flex-node/config.json
if sudo systemctl cat aks-flex-node-agent >/dev/null 2>&1; then
  sudo systemctl status aks-flex-node-agent --no-pager -l || true
  sudo systemctl is-active --quiet aks-flex-node-agent || {
    echo 'aks-flex-node-agent.service is not active after bootstrap' >&2
    sudo journalctl -u aks-flex-node-agent -n 200 --no-pager || true
    exit 1
  }
else
  echo 'aks-flex-node-agent.service unit was not created by bootstrap' >&2
  sudo machinectl list --no-pager || true
  sudo journalctl -M kube1 -u kubelet -n 200 --no-pager || true
  exit 1
fi
REMOTE_FLEX_BOOTSTRAP
  fi

  az aks get-credentials \
    --resource-group "${cluster_rg}" \
    --name "${cluster_name}" \
    --subscription "${TF_VAR_azure_subscription_id}" \
    --overwrite-existing \
    --only-show-errors >/dev/null
  kubelogin convert-kubeconfig -l azurecli >/dev/null

  wait_for_flex_node_object "${flex_node_name}"
  label_flex_node "${flex_node_name}"
  approve_flex_daemon_csrs "${flex_node_name}"
}

doctor_pass() {
  printf 'PASS %s\n' "$*"
}

doctor_check_host() {
  if [[ -n "${ANYSCALE_HOST:-}" && "${ANYSCALE_HOST}" != "${ANYSCALE_AZURE_HOST}" ]]; then
    die "ANYSCALE_HOST must be ${ANYSCALE_AZURE_HOST}; unset the current value and retry"
  fi
  if [[ -n "${TF_VAR_anyscale_control_plane_url:-}" && "${TF_VAR_anyscale_control_plane_url}" != "${ANYSCALE_AZURE_HOST}" ]]; then
    die "obsolete TF_VAR_anyscale_control_plane_url must not override ${ANYSCALE_AZURE_HOST}; remove it from ${ENV_FILE}"
  fi

  export ANYSCALE_HOST="${ANYSCALE_AZURE_HOST}"
  doctor_pass "Anyscale control plane is ${ANYSCALE_HOST}"
}

doctor_check_azure_context() {
  local account_json subscription_id tenant_id

  account_json="$(az account show -o json --only-show-errors)" ||
    die "Azure CLI is not authenticated; run az login"
  subscription_id="$(jq -r '.id' <<<"${account_json}")"
  tenant_id="$(jq -r '.tenantId' <<<"${account_json}")"

  [[ "${TF_VAR_azure_subscription_id:-}" == "${subscription_id}" ]] ||
    die "TF_VAR_azure_subscription_id does not match Azure CLI subscription ${subscription_id}; rerun bootstrap or correct ${ENV_FILE}"
  [[ "${TF_VAR_azure_tenant_id:-}" == "${tenant_id}" ]] ||
    die "TF_VAR_azure_tenant_id does not match Azure CLI tenant ${tenant_id}; rerun bootstrap or correct ${ENV_FILE}"

  doctor_pass "Azure CLI subscription and tenant match ${ENV_FILE}"
  jq '{subscription:.id,tenant:.tenantId,user:.user.name}' <<<"${account_json}"
}

doctor_check_env() {
  local required_vars=(
    TF_VAR_project
    TF_VAR_environment
    TF_VAR_azure_location
    TF_VAR_region_short
    TF_VAR_flex_region
    TF_VAR_flex_region_short
    TF_VAR_system_vm_size
    TF_VAR_cpu_vm_size
    TF_VAR_flex_host_vm_size
    TF_VAR_gpu_pool_configs
    TF_VAR_vnet_address_space
    TF_VAR_flex_vnet_address_space
    TF_VAR_service_cidr
    TF_VAR_aks_pod_cidr
    TF_VAR_unbounded_flex_pod_cidr
  )
  local variable_name

  for variable_name in "${required_vars[@]}"; do
    [[ -n "${!variable_name:-}" ]] || die "Missing required variable ${variable_name} in ${ENV_FILE}"
  done
  jq -e 'type == "object"' <<<"${TF_VAR_gpu_pool_configs}" >/dev/null ||
    die "TF_VAR_gpu_pool_configs must be a JSON object in ${ENV_FILE}"
  local gpu_pool_count gpu_vm_size
  gpu_pool_count="$(jq 'length' <<<"${TF_VAR_gpu_pool_configs}")"
  if ((gpu_pool_count == 0)); then
    [[ "${ANYSCALE_FLEX_GPU_ENABLED:-false}" == "false" ]] ||
      die "ANYSCALE_FLEX_GPU_ENABLED must be false when TF_VAR_gpu_pool_configs is empty"
    [[ "${TF_VAR_cpu_vm_size}" == "${TF_VAR_flex_host_vm_size}" ]] ||
      die "CPU mode requires TF_VAR_cpu_vm_size and TF_VAR_flex_host_vm_size to use the same SKU"
  else
    ((gpu_pool_count == 1)) || die "GPU mode requires exactly one entry in TF_VAR_gpu_pool_configs"
    [[ "${ANYSCALE_FLEX_GPU_ENABLED:-false}" == "true" ]] ||
      die "ANYSCALE_FLEX_GPU_ENABLED must be true when TF_VAR_gpu_pool_configs is configured"
    gpu_vm_size="$(jq -r 'to_entries[0].value.vm_size // empty' <<<"${TF_VAR_gpu_pool_configs}")"
    [[ -n "${gpu_vm_size}" && "${gpu_vm_size}" == "${TF_VAR_flex_host_vm_size}" ]] ||
      die "GPU mode requires the Region A GPU pool and Region B Flex host to use the same VM SKU"
  fi
  [[ "${TF_VAR_region_short}" =~ ^[a-z0-9]{2,8}$ ]] ||
    die "TF_VAR_region_short must contain 2-8 lowercase letters and numbers"
  [[ "${TF_VAR_region_short}" != "${TF_VAR_azure_location}" ]] ||
    die "TF_VAR_region_short must abbreviate TF_VAR_azure_location, not repeat it"
  [[ "${TF_VAR_flex_region_short}" =~ ^[a-z0-9]{2,8}$ ]] ||
    die "TF_VAR_flex_region_short must contain 2-8 lowercase letters and numbers"
  [[ "${TF_VAR_flex_region_short}" != "${TF_VAR_flex_region}" ]] ||
    die "TF_VAR_flex_region_short must abbreviate TF_VAR_flex_region, not repeat it"
  validate_network_cidrs

  doctor_pass "required environment values are present and parseable"
}

doctor_check_providers() {
  local required_providers=(
    Anyscale.Platform
    Microsoft.Authorization
    Microsoft.Compute
    Microsoft.ContainerRegistry
    Microsoft.ContainerService
    Microsoft.Insights
    Microsoft.ManagedIdentity
    Microsoft.Monitor
    Microsoft.Network
    Microsoft.OperationalInsights
    Microsoft.Resources
    Microsoft.Storage
  )
  local providers_json provider state
  local missing=()

  providers_json="$(az provider list -o json --only-show-errors)"
  for provider in "${required_providers[@]}"; do
    state="$(jq -r --arg provider "${provider}" '.[] | select((.namespace | ascii_downcase) == ($provider | ascii_downcase)) | (.registrationState // "" | ascii_downcase)' <<<"${providers_json}")"
    [[ "${state}" == "registered" ]] || missing+=("${provider}")
  done
  if ((${#missing[@]} > 0)); then
    die "unregistered Azure resource providers: ${missing[*]}; register each with az provider register --namespace <name>"
  fi

  doctor_pass "required Azure resource providers are registered"
}

doctor_check_anyscale_service_principal() {
  local app_id="086bc555-6989-4362-ba30-fded273e432b"

  az ad sp show --id "${app_id}" --query id -o tsv --only-show-errors >/dev/null 2>&1 ||
    die "Anyscale service principal ${app_id} is missing or unreadable; run az ad sp create --id ${app_id}"
  doctor_pass "Anyscale on Azure service principal is available"
}

doctor_check_anyscale_region() {
  local provider_json region_display_name

  provider_json="$(az provider show --namespace Anyscale.Platform -o json --only-show-errors)"
  region_display_name="$(az account list-locations --query "[?name=='${TF_VAR_azure_location}'].displayName | [0]" -o tsv --only-show-errors)"
  [[ -n "${region_display_name}" ]] || die "unknown Azure Region A value: ${TF_VAR_azure_location}"
  jq -e --arg location "${region_display_name}" \
    '[.resourceTypes[] | select(.resourceType == "clouds") | .locations[] | ascii_downcase] | index($location | ascii_downcase) != null' \
    <<<"${provider_json}" >/dev/null ||
    die "Anyscale.Platform does not list Region A ${TF_VAR_azure_location} as supported; choose a supported Region A"

  doctor_pass "Anyscale.Platform supports Region A ${TF_VAR_azure_location}"
}

doctor_reset_vm_quota_requirements() {
  DOCTOR_VM_QUOTA_KEYS=()
  DOCTOR_VM_QUOTA_REQUIRED=()
  DOCTOR_VM_QUOTA_AVAILABLE=()
  DOCTOR_VM_QUOTA_LABELS=()
}

doctor_record_vm_quota_requirement() {
  local label="$1"
  local key="${DOCTOR_VM_QUOTA_REGION}"$'\t'"${DOCTOR_VM_QUOTA_FAMILY}"
  local index

  for ((index = 0; index < ${#DOCTOR_VM_QUOTA_KEYS[@]}; index++)); do
    if [[ "${DOCTOR_VM_QUOTA_KEYS[index]}" == "${key}" ]]; then
      DOCTOR_VM_QUOTA_REQUIRED[index]=$((DOCTOR_VM_QUOTA_REQUIRED[index] + DOCTOR_VM_REQUIRED_VCPUS))
      DOCTOR_VM_QUOTA_AVAILABLE[index]="${DOCTOR_VM_AVAILABLE_VCPUS}"
      DOCTOR_VM_QUOTA_LABELS[index]="${DOCTOR_VM_QUOTA_LABELS[index]}, ${label}"
      return
    fi
  done

  index="${#DOCTOR_VM_QUOTA_KEYS[@]}"
  DOCTOR_VM_QUOTA_KEYS[index]="${key}"
  DOCTOR_VM_QUOTA_REQUIRED[index]="${DOCTOR_VM_REQUIRED_VCPUS}"
  DOCTOR_VM_QUOTA_AVAILABLE[index]="${DOCTOR_VM_AVAILABLE_VCPUS}"
  DOCTOR_VM_QUOTA_LABELS[index]="${label}"
}

doctor_check_combined_vm_quota() {
  local index key region family required_vcpus available_vcpus labels

  for ((index = 0; index < ${#DOCTOR_VM_QUOTA_KEYS[@]}; index++)); do
    key="${DOCTOR_VM_QUOTA_KEYS[index]}"
    region="${key%%$'\t'*}"
    family="${key#*$'\t'}"
    required_vcpus="${DOCTOR_VM_QUOTA_REQUIRED[index]}"
    available_vcpus="${DOCTOR_VM_QUOTA_AVAILABLE[index]}"
    labels="${DOCTOR_VM_QUOTA_LABELS[index]}"

    ((available_vcpus >= required_vcpus)) ||
      die "combined minimum for ${labels} is ${required_vcpus} ${family} vCPUs in ${region}, but only ${available_vcpus} remain"
    doctor_pass "combined minimum for ${labels} is ${required_vcpus} ${family} vCPUs in ${region} (${available_vcpus} remain)"
  done
}

doctor_check_vm_sku() {
  local region="$1" vm_size="$2" label="$3" required_instances="${4:-1}"
  local sku_json usage_json family vcpus restriction_reasons current limit required_vcpus available_vcpus

  sku_json="$(az vm list-skus \
    --location "${region}" \
    --resource-type virtualMachines \
    --size "${vm_size}" \
    -o json \
    --only-show-errors)"
  [[ "$(jq 'length' <<<"${sku_json}")" -gt 0 ]] ||
    die "${label} VM size ${vm_size} is not listed in ${region}"

  restriction_reasons="$(jq -r '[.[0].restrictions[]?.reasonCode] | unique | join(", ")' <<<"${sku_json}")"
  [[ -z "${restriction_reasons}" ]] ||
    die "${label} VM size ${vm_size} is restricted in ${region}: ${restriction_reasons}"

  family="$(jq -r '.[0].family // empty' <<<"${sku_json}")"
  vcpus="$(jq -r '.[0].capabilities[] | select(.name == "vCPUs") | .value' <<<"${sku_json}")"
  [[ -n "${family}" && "${vcpus}" =~ ^[0-9]+$ ]] ||
    die "unable to resolve quota family and vCPU count for ${vm_size} in ${region}"

  usage_json="$(az vm list-usage --location "${region}" -o json --only-show-errors)"
  current="$(jq -r --arg family "${family}" '.[] | select(.name.value == $family) | .currentValue' <<<"${usage_json}")"
  limit="$(jq -r --arg family "${family}" '.[] | select(.name.value == $family) | .limit' <<<"${usage_json}")"
  [[ "${current}" =~ ^[0-9]+$ && "${limit}" =~ ^[0-9]+$ ]] ||
    die "unable to read ${family} quota for ${vm_size} in ${region}"

  required_vcpus=$((vcpus * required_instances))
  available_vcpus=$((limit - current))
  ((available_vcpus >= required_vcpus)) ||
    die "${label} needs ${required_vcpus} ${family} vCPUs in ${region}, but only ${available_vcpus} remain"

  DOCTOR_VM_QUOTA_REGION="${region}"
  DOCTOR_VM_QUOTA_FAMILY="${family}"
  DOCTOR_VM_REQUIRED_VCPUS="${required_vcpus}"
  DOCTOR_VM_AVAILABLE_VCPUS="${available_vcpus}"
  doctor_record_vm_quota_requirement "${label}"
  doctor_pass "${label} ${vm_size} is available in ${region} (${available_vcpus} ${family} vCPUs remain)"
}

sku_options() {
  local region_a="${1:-}" region_b="${2:-}" mode="${3:-}"
  local temp_dir candidates_json candidate_count

  [[ -n "${region_a}" && -n "${region_b}" && -n "${mode}" && $# -eq 3 ]] ||
    die "usage: ./scripts/anyscale-aks.sh sku-options REGION_A REGION_B cpu|gpu"
  [[ "${mode}" == "cpu" || "${mode}" == "gpu" ]] ||
    die "mode must be cpu or gpu"

  need_cmd az
  need_cmd jq
  az account show --query id -o tsv --only-show-errors >/dev/null ||
    die "Azure CLI is not authenticated; run az login"

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/anyscale-sku-options.XXXXXX")"
  az account list-locations -o json --only-show-errors >"${temp_dir}/locations.json"
  for region in "${region_a}" "${region_b}"; do
    jq -e --arg region "${region}" 'any(.[]; .name == $region)' "${temp_dir}/locations.json" >/dev/null ||
      die "unknown Azure region: ${region}; use a canonical name from az account list-locations"
  done

  az provider show --namespace Anyscale.Platform -o json --only-show-errors >"${temp_dir}/provider.json"
  jq -e \
    --arg region "${region_a}" \
    --slurpfile locations "${temp_dir}/locations.json" '
      ($locations[0][] | select(.name == $region) | .displayName) as $display_name
      | [.resourceTypes[] | select(.resourceType == "clouds") | .locations[] | ascii_downcase]
      | index($display_name | ascii_downcase) != null
    ' "${temp_dir}/provider.json" >/dev/null ||
    die "Anyscale.Platform does not list Region A ${region_a} as supported"

  az vm list-skus --location "${region_a}" --resource-type virtualMachines -o json --only-show-errors >"${temp_dir}/region-a-skus.json"
  az vm list-skus --location "${region_b}" --resource-type virtualMachines -o json --only-show-errors >"${temp_dir}/region-b-skus.json"
  az vm list-usage --location "${region_a}" -o json --only-show-errors >"${temp_dir}/region-a-usage.json"
  az vm list-usage --location "${region_b}" -o json --only-show-errors >"${temp_dir}/region-b-usage.json"

  candidates_json="$({ jq -n \
    --arg mode "${mode}" \
    --slurpfile a_skus "${temp_dir}/region-a-skus.json" \
    --slurpfile b_skus "${temp_dir}/region-b-skus.json" \
    --slurpfile a_usage "${temp_dir}/region-a-usage.json" \
    --slurpfile b_usage "${temp_dir}/region-b-usage.json" '
      def quota_map($usage):
        reduce $usage[] as $item ({};
          .[$item.name.value] = (($item.limit | tonumber) - ($item.currentValue | tonumber))
        );
      def normalize($skus):
        [
          $skus[]
          | select(([.restrictions[]? | select(.reasonCode != null)] | length) == 0)
          | . as $sku
          | (reduce .capabilities[]? as $cap ({}; .[$cap.name] = $cap.value)) as $caps
          | {
              name: $sku.name,
              family: $sku.family,
              vcpus: (($caps.vCPUs // "0") | tonumber),
              gpus: (($caps.GPUs // "0") | tonumber),
              memory_gib: (($caps.MemoryGB // "0") | tonumber),
              premium_io: (($caps.PremiumIO // "False") == "True")
            }
          | select(.vcpus > 0)
        ];
      (quota_map($a_usage[0])) as $a_quota
      | (quota_map($b_usage[0])) as $b_quota
      | (normalize($a_skus[0])) as $a
      | (normalize($b_skus[0])) as $b
      | [
          $a[] as $left
          | $b[]
          | select(.name == $left.name)
            | select(.vcpus >= 4 and .vcpus <= 8)
            | select(if $mode == "gpu" then .gpus > 0 else .gpus == 0 and .premium_io and .memory_gib >= 8 end)
          | {
              sku: .name,
              vcpus: .vcpus,
              gpus: .gpus,
              memory_gib: .memory_gib,
              family: (if $left.family == .family then .family else ($left.family + "/" + .family) end),
              region_a_remaining: ($a_quota[$left.family] // -1),
              region_b_remaining: ($b_quota[.family] // -1)
            }
          | select(.region_a_remaining >= .vcpus and .region_b_remaining >= .vcpus)
        ]
      | sort_by(
          (if $mode == "cpu" and (.sku | startswith("Standard_D")) then 0 else 1 end),
          .vcpus,
          .gpus,
          .sku
        )
      | if $mode == "cpu" then .[:20] else . end
    '; } 2>/dev/null)"
  rm -rf "${temp_dir}"

  candidate_count="$(jq 'length' <<<"${candidates_json}")"
  ((candidate_count > 0)) ||
    die "no unrestricted ${mode} VM SKU has quota for one VM in both ${region_a} and ${region_b}"

  printf 'Shared %s VM SKU candidates with quota for one VM in both regions:\n' "${mode}"
  printf 'SKU\tVCPUS\tMEMORY_GIB\tGPUS\tREGION_A_VCPUS_REMAINING\tREGION_B_VCPUS_REMAINING\tQUOTA_FAMILY\n'
  jq -r '.[] | [.sku, .vcpus, .memory_gib, .gpus, .region_a_remaining, .region_b_remaining, .family] | @tsv' <<<"${candidates_json}"
  if [[ "${mode}" == "cpu" ]]; then
    printf '\nShowing up to 20 shared 4-8 vCPU, Premium SSD-capable CPU candidates. Choose one SKU for both TF_VAR_cpu_vm_size and TF_VAR_flex_host_vm_size.\n'
  else
    printf '\nShowing shared 4-8 vCPU GPU candidates. Choose one SKU for both the Region A GPU pool and TF_VAR_flex_host_vm_size. Azure does not provide the Kubernetes GPU product label in this response.\n'
  fi
}

doctor_check_vm_capacity() {
  local gpu_key gpu_vm_size gpu_min_count

  doctor_reset_vm_quota_requirements

  doctor_check_vm_sku \
    "${TF_VAR_azure_location}" \
    "${TF_VAR_system_vm_size}" \
    "AKS system pool" \
    "${TF_VAR_system_node_pool_min_count:-1}"
  doctor_check_vm_sku "${TF_VAR_azure_location}" "${TF_VAR_cpu_vm_size}" "AKS CPU pool"
  doctor_check_vm_sku "${TF_VAR_flex_region}" "${TF_VAR_flex_host_vm_size}" "Flex host"

  while IFS=$'\t' read -r gpu_key gpu_vm_size gpu_min_count; do
    [[ -n "${gpu_vm_size}" ]] || die "GPU pool ${gpu_key} is missing vm_size"
    doctor_check_vm_sku \
      "${TF_VAR_azure_location}" \
      "${gpu_vm_size}" \
      "AKS GPU pool ${gpu_key}" \
      "$((gpu_min_count > 0 ? gpu_min_count : 1))"
  done < <(jq -r 'to_entries[] | [.key, .value.vm_size, (.value.min_count // 0)] | @tsv' <<<"${TF_VAR_gpu_pool_configs}")

  doctor_check_combined_vm_quota
}

doctor_check_anyscale_cli() {
  [[ -x "${ANYSCALE_VENV_DIR}/bin/anyscale" ]] ||
    die "missing Anyscale CLI; run ./scripts/anyscale-aks.sh bootstrap"
  ANYSCALE_HOST="${ANYSCALE_AZURE_HOST}" \
    "${ANYSCALE_VENV_DIR}/bin/anyscale" cloud list --json --no-interactive --max-items 1 >/dev/null 2>&1 ||
    die "Anyscale CLI is not authenticated to ${ANYSCALE_AZURE_HOST}; run ANYSCALE_HOST=${ANYSCALE_AZURE_HOST} .venv/bin/anyscale login"
  doctor_pass "Anyscale CLI is authenticated to ${ANYSCALE_AZURE_HOST}"
}

doctor_check_extension_if_cluster_exists() {
  local resource_group cluster_name extension_json

  resource_group="$(resource_group_name)"
  cluster_name="$(aks_cluster_name)"
  if ! az aks show --resource-group "${resource_group}" --name "${cluster_name}" --query id -o tsv --only-show-errors >/dev/null 2>&1; then
    doctor_pass "AKS is not deployed; operator extension availability will be checked after cluster creation"
    return 0
  fi

  extension_json="$(az k8s-extension extension-types list-by-cluster \
    --resource-group "${resource_group}" \
    --cluster-name "${cluster_name}" \
    --cluster-type managedClusters \
    -o json \
    --only-show-errors)"
  jq -e 'any(.[]; (.name | ascii_downcase) == "anyscale.aks.operator" or (.name | ascii_downcase) == "preview.anyscale.aks.operator")' \
    <<<"${extension_json}" >/dev/null ||
    die "AKS cluster ${cluster_name} does not report an Anyscale operator extension type; choose another Region A"
  doctor_pass "AKS cluster ${cluster_name} reports an Anyscale operator extension type"
}

doctor() {
  local command_name
  local required_commands=(az curl git helm jq kubectl kubelogin openssl python3 scp ssh ssh-keygen terraform)

  for command_name in "${required_commands[@]}"; do
    need_cmd "${command_name}"
  done
  doctor_pass "required local commands are installed"

  source_env
  sync_azure_context
  ensure_defaults
  doctor_check_host
  doctor_check_azure_context
  doctor_check_env
  doctor_check_providers
  doctor_check_anyscale_service_principal
  doctor_check_anyscale_region
  doctor_check_vm_capacity
  doctor_check_anyscale_cli
  doctor_check_extension_if_cluster_exists
  doctor_pass "Anyscale on Azure prerequisites are ready"
}

status() {
  need_cmd az
  need_cmd jq
  need_cmd terraform
  source_env
  sync_azure_context
  ensure_defaults

  printf 'azure-context:\n'
  az account show --query '{subscription:id,tenant:tenantId,user:user.name}' -o json --only-show-errors
  printf '\nterraform-outputs:\n'
  terraform_cmd output -json
}

main() {
  local command="${1:-}"
  local destroy_rc

  case "${command}" in
  bootstrap)
    bootstrap
    ;;
  doctor)
    doctor
    ;;
  sku-options)
    sku_options "${@:2}"
    ;;
  status)
    status
    ;;
  render-tfvars)
    need_cmd az
    need_cmd jq
    need_cmd python3
    source_env
    sync_azure_context
    render_tfvars
    ;;
  init)
    terraform_cmd init
    ;;
  validate)
    terraform_cmd validate
    ;;
  test)
    terraform_cmd test
    ;;
  plan)
    need_cmd az
    need_cmd jq
    source_env
    sync_azure_context
    render_tfvars
    terraform_cmd init
    reuse_existing_anyscale_default_admin_assignment
    terraform_cmd validate
    terraform_cmd plan -out=tfplan
    ;;
  apply)
    need_cmd az
    need_cmd jq
    need_cmd kubelogin
    source_env
    sync_azure_context
    render_tfvars
    terraform_cmd init
    terraform_cmd validate
    import_untracked_anyscale_resources
    reuse_existing_anyscale_default_admin_assignment
    if [[ "${ANYSCALE_RUN_TERRAFORM_TESTS:-false}" == "true" ]]; then
      terraform_cmd test
    fi
    terraform_cmd apply -auto-approve
    verify_anyscale_cloud
    ;;
  destroy)
    need_cmd az
    need_cmd jq
    need_cmd kubectl
    source_env
    sync_azure_context
    render_tfvars
    terraform_cmd init
    if destroy_verified_complete; then
      terraform_cmd destroy -auto-approve
      return 0
    fi
    import_untracked_anyscale_resources
    drain_anyscale_jobs
    assert_no_active_anyscale_services_or_workspaces
    terminate_anyscale_system_cluster
    archive_anyscale_compute_configs
    set +e
    terraform_cmd destroy -auto-approve
    destroy_rc=$?
    set -e
    if [[ "${destroy_rc}" -ne 0 ]]; then
      destroy_verified_complete && return 0
      return "${destroy_rc}"
    fi
    ;;
  output)
    terraform_cmd output "${@:2}"
    ;;
  flex-config)
    generate_flex_config
    ;;
  flex-bootstrap)
    bootstrap_flex_host
    ;;
  *)
    die "Unknown command ${command}"
    ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
