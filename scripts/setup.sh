#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2089,SC2090
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ANYSCALE_AKS_ENV_FILE:-${ROOT_DIR}/.env}"
TERRAFORM_DIR="${ROOT_DIR}/infra/terraform"
GENERATED_TFVARS="${TERRAFORM_DIR}/terraform.auto.tfvars.json"
CACHE_DIR="${ROOT_DIR}/.cache"
FLEX_CACHE_DIR="${CACHE_DIR}/flex"
ANYSCALE_VENV_DIR="${ROOT_DIR}/.venv"
ANYSCALE_AZURE_HOST="https://console.azure.anyscale.com"

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
      /^ARM_SUBSCRIPTION_ID=/ { print "ARM_SUBSCRIPTION_ID=\"" subscription_id "\""; next }
      /^ARM_TENANT_ID=/ { print "ARM_TENANT_ID=\"" tenant_id "\""; next }
      /^TF_VAR_azure_subscription_id=/ { print "TF_VAR_azure_subscription_id=\"" subscription_id "\""; next }
      /^TF_VAR_azure_tenant_id=/ { print "TF_VAR_azure_tenant_id=\"" tenant_id "\""; next }
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
  printf 'next: ./scripts/anyscale-aks.sh doctor\n'
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
  [[ -n "${TF_VAR_flex_host_vm_size:-}" ]] || TF_VAR_flex_host_vm_size="Standard_D4s_v5"
  [[ -n "${TF_VAR_flex_host_admin_username:-}" ]] || TF_VAR_flex_host_admin_username="azureoperator"
  [[ -n "${TF_VAR_flex_host_public_ip_enabled:-}" ]] || TF_VAR_flex_host_public_ip_enabled="true"
  [[ -n "${TF_VAR_flex_host_secondary_ip_configurations:-}" ]] || TF_VAR_flex_host_secondary_ip_configurations="[]"
  [[ -n "${TF_VAR_flex_host_user_assigned_identity_ids:-}" ]] || TF_VAR_flex_host_user_assigned_identity_ids="[]"
  [[ -n "${TF_VAR_flex_host_os_disk_size_gb:-}" ]] || TF_VAR_flex_host_os_disk_size_gb="256"
  [[ -n "${TF_VAR_flex_host_source_image_reference:-}" ]] || TF_VAR_flex_host_source_image_reference='{"publisher":"Canonical","offer":"ubuntu-24_04-lts","sku":"server","version":"latest"}'
  [[ -n "${TF_VAR_cilium_pod_cidr:-}" ]] || TF_VAR_cilium_pod_cidr="10.83.0.0/16"
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
  export TF_VAR_cilium_pod_cidr
  export TF_VAR_unbounded_flex_pod_cidr
}

sync_azure_context() {
  local account_json subscription_id tenant_id

  account_json="$(az account show -o json --only-show-errors)"
  subscription_id="$(jq -r '.id' <<<"${account_json}")"
  tenant_id="$(jq -r '.tenantId' <<<"${account_json}")"

  [[ -n "${ARM_SUBSCRIPTION_ID:-}" && "${ARM_SUBSCRIPTION_ID}" != "00000000-0000-0000-0000-000000000000" ]] || ARM_SUBSCRIPTION_ID="${subscription_id}"
  [[ -n "${ARM_TENANT_ID:-}" && "${ARM_TENANT_ID}" != "00000000-0000-0000-0000-000000000000" ]] || ARM_TENANT_ID="${tenant_id}"
  [[ -n "${TF_VAR_azure_subscription_id:-}" && "${TF_VAR_azure_subscription_id}" != "00000000-0000-0000-0000-000000000000" ]] || TF_VAR_azure_subscription_id="${subscription_id}"
  [[ -n "${TF_VAR_azure_tenant_id:-}" && "${TF_VAR_azure_tenant_id}" != "00000000-0000-0000-0000-000000000000" ]] || TF_VAR_azure_tenant_id="${tenant_id}"

  export ARM_SUBSCRIPTION_ID ARM_TENANT_ID TF_VAR_azure_subscription_id TF_VAR_azure_tenant_id
}

validate_network_cidrs() {
  local validation_error

  validation_error="$(
    python3 - \
      "${TF_VAR_vnet_address_space}" \
      "${TF_VAR_flex_vnet_address_space}" \
      "${TF_VAR_service_cidr}" \
      "${TF_VAR_cilium_pod_cidr}" \
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
    TF_VAR_cilium_pod_cidr
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
    --arg cilium_pod_cidr "${TF_VAR_cilium_pod_cidr}" \
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
      cilium_pod_cidr: $cilium_pod_cidr,
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

delete_anyscale_gateway() {
  local rg cluster namespace gateway_name service_name attempt

  [[ "${TF_VAR_anyscale_enabled:-false}" == "true" ]] || return 0
  [[ -z "${TF_VAR_anyscale_gateway_hostname:-}" ]] || return 0

  rg="$(resource_group_name)"
  cluster="$(aks_cluster_name)"
  namespace="${TF_VAR_anyscale_operator_namespace:-anyscale-operator}"
  gateway_name="${TF_VAR_anyscale_gateway_name:-anyscale-gateway}"

  [[ "$(az aks show --resource-group "${rg}" --name "${cluster}" --query provisioningState -o tsv --only-show-errors 2>/dev/null || true)" == "Succeeded" ]] || return 0

  printf 'info: deleting Anyscale Gateway before Terraform releases its static public IP\n' >&2
  az aks get-credentials \
    --resource-group "${rg}" \
    --name "${cluster}" \
    --overwrite-existing \
    --only-show-errors >/dev/null

  kubectl get namespace "${namespace}" >/dev/null 2>&1 || return 0
  kubectl delete gateway "${gateway_name}" \
    --namespace "${namespace}" \
    --ignore-not-found \
    --wait=true

  for ((attempt = 1; attempt <= 60; attempt++)); do
    service_name="$(kubectl get svc \
      --namespace "${namespace}" \
      --selector "gateway.networking.k8s.io/gateway-name=${gateway_name}" \
      --output name 2>/dev/null || true)"
    if [[ -z "${service_name}" ]]; then
      printf 'info: Anyscale Gateway service released the Terraform-managed public IP\n' >&2
      return 0
    fi
    sleep 5
  done

  kubectl get svc \
    --namespace "${namespace}" \
    --selector "gateway.networking.k8s.io/gateway-name=${gateway_name}" \
    --output wide >&2
  die "Anyscale Gateway service did not release the Terraform-managed public IP"
}

cleanup_residual_anyscale_platform_resources() {
  local rg cloud child parent api attempt group_exists show_output

  [[ "${TF_VAR_anyscale_enabled:-false}" == "true" ]] || return 0

  rg="$(resource_group_name)"
  if ! group_exists="$(az group exists --name "${rg}" --only-show-errors 2>/dev/null)"; then
    die "unable to check resource group ${rg} before Anyscale.Platform cleanup"
  fi
  [[ "${group_exists}" == "true" ]] || return 0

  cloud="${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
  child="/subscriptions/${TF_VAR_azure_subscription_id}/resourceGroups/${rg}/providers/Anyscale.Platform/clouds/${cloud}/cloudResources/default"
  parent="/subscriptions/${TF_VAR_azure_subscription_id}/resourceGroups/${rg}/providers/Anyscale.Platform/clouds/${cloud}"

  printf 'info: cleaning residual Anyscale.Platform resources before destroy retry\n' >&2
  for api in 2026-02-01-preview 2023-04-01-preview; do
    az rest --method delete --url "https://management.azure.com${child}?api-version=${api}" --only-show-errors >/dev/null 2>&1 || true
  done
  for api in 2026-02-01-preview 2023-04-01-preview; do
    az rest --method delete --url "https://management.azure.com${parent}?api-version=${api}" --only-show-errors >/dev/null 2>&1 || true
  done

  for ((attempt = 1; attempt <= 60; attempt++)); do
    if ! group_exists="$(az group exists --name "${rg}" --only-show-errors 2>/dev/null)"; then
      printf 'warning: unable to check resource group deletion on attempt %s/60\n' "${attempt}" >&2
    elif [[ "${group_exists}" == "false" ]]; then
      printf 'info: residual Anyscale.Platform resources are absent\n' >&2
      return 0
    elif show_output="$(az resource show --ids "${parent}" --api-version 2026-02-01-preview --only-show-errors 2>&1)"; then
      :
    elif grep -Eq 'ResourceNotFound|ParentResourceNotFound|ResourceGroupNotFound|could not be found' <<<"${show_output}"; then
      printf 'info: residual Anyscale.Platform resources are absent\n' >&2
      return 0
    else
      printf 'warning: unable to check Anyscale.Platform cloud deletion on attempt %s/60: %s\n' "${attempt}" "${show_output}" >&2
    fi
    ((attempt < 60)) && sleep 5
  done

  die "residual Anyscale.Platform cloud did not delete within 5 minutes"
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

ensure_anyscale_gateway() {
  local rg cluster namespace gateway_name gateway_class

  [[ "${TF_VAR_anyscale_enabled:-false}" == "true" ]] || return 0

  need_cmd az
  need_cmd kubectl

  rg="rg-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
  cluster="$(aks_cluster_name)"
  namespace="${TF_VAR_anyscale_operator_namespace}"
  gateway_name="${TF_VAR_anyscale_gateway_name:-anyscale-gateway}"
  gateway_class="approuting-istio"

  az aks get-credentials --resource-group "${rg}" --name "${cluster}" --overwrite-existing --only-show-errors >/dev/null
  kubectl get gatewayclass "${gateway_class}" >/dev/null
  kubectl get namespace "${namespace}" >/dev/null

  if ! kubectl get gateway "${gateway_name}" -n "${namespace}" >/dev/null 2>&1; then
    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${gateway_name}
  namespace: ${namespace}
spec:
  gatewayClassName: ${gateway_class}
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
EOF
  fi
  kubectl -n "${namespace}" wait "gateway/${gateway_name}" --for=condition=Programmed --timeout=5m
}

import_untracked_anyscale_resources() {
  local deployment_address deployment_name extension_address extension_id

  [[ "${TF_VAR_anyscale_enabled:-false}" == "true" ]] || return 0

  deployment_address='azapi_resource.anyscale_platform[0]'
  if ! terraform_cmd state show "${deployment_address}" >/dev/null 2>&1; then
    deployment_name="dep-anyscale-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
    if az deployment group show \
      --resource-group "$(resource_group_name)" \
      --name "${deployment_name}" \
      --query id \
      -o tsv \
      --only-show-errors >/dev/null 2>&1; then
      printf 'info: deleting untracked Anyscale ARM deployment record after an interrupted create; deployed resources remain\n' >&2
      az deployment group delete \
        --resource-group "$(resource_group_name)" \
        --name "${deployment_name}" \
        --only-show-errors
    fi
  fi

  extension_address='azurerm_kubernetes_cluster_extension.anyscale_operator[0]'
  terraform_cmd state show "${extension_address}" >/dev/null 2>&1 && return 0

  extension_id="/subscriptions/${TF_VAR_azure_subscription_id}/resourceGroups/$(resource_group_name)/providers/Microsoft.ContainerService/managedClusters/$(aks_cluster_name)/providers/Microsoft.KubernetesConfiguration/extensions/anyscale-operator"
  if az resource show --ids "${extension_id}" --only-show-errors >/dev/null 2>&1; then
    printf 'info: importing existing Anyscale extension after an interrupted create\n' >&2
    terraform_cmd import "${extension_address}" "${extension_id}"
  fi
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
  local flex_node_name="$1"

  kubectl label node "${flex_node_name}" \
    "agentpool=${AKS_FLEX_AGENT_POOL_NAME}" \
    "kubernetes.azure.com/agentpool=${AKS_FLEX_AGENT_POOL_NAME}" \
    "topology.kubernetes.io/region=${TF_VAR_flex_region}" \
    "kubernetes.azure.com/cluster-" \
    --overwrite
  kubectl taint node "${flex_node_name}" aks-flex-node=true:NoSchedule --overwrite
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
  local cluster_rg="$1" cluster_name="$2" network_profile network_plugin network_plugin_mode network_data_plane

  network_profile="$(az aks show \
    --resource-group "${cluster_rg}" \
    --name "${cluster_name}" \
    --query networkProfile \
    --output json \
    --only-show-errors)"
  network_plugin="$(jq -r '.networkPlugin // empty' <<<"${network_profile}")"
  network_plugin_mode="$(jq -r '.networkPluginMode // empty' <<<"${network_profile}")"
  network_data_plane="$(jq -r '.networkDataplane // .networkDataPlane // empty' <<<"${network_profile}")"

  [[ "${network_plugin}" == "azure" && "${network_plugin_mode}" == "overlay" && "${network_data_plane}" == "cilium" ]] ||
    die "This mixed-CNI experiment requires Azure CNI Overlay powered by Cilium on AKS-managed nodes. Observed plugin=${network_plugin:-unset} mode=${network_plugin_mode:-unset} dataplane=${network_data_plane:-unset}."
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
  local config_path config_release_tag flex_checksums_url flex_release_url host_ip admin_user flex_node_name cluster_rg cluster_name release_tag secondary_ip_count ssh_opts

  need_cmd az
  need_cmd kubectl
  need_cmd kubelogin
  need_cmd jq
  need_cmd openssl
  need_cmd scp
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

  scp "${ssh_opts[@]}" "${config_path}" "${admin_user}@${host_ip}:/tmp/aks-flex-node-config.json"
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
      "AKS_FLEX_NODE_RELEASE_TAG='${release_tag}' FLEX_CHECKSUMS_URL='${flex_checksums_url}' FLEX_RELEASE_URL='${flex_release_url}' bash -s" <<'REMOTE_FLEX_BOOTSTRAP'
set -euo pipefail

for command in curl grep sha256sum tar; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "missing required command on Flex host: ${command}" >&2
    exit 1
  }
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
curl -fsSLo "${TMP_DIR}/aks-flex-node-linux-amd64.tar.gz" "${FLEX_RELEASE_URL}"
curl -fsSLo "${TMP_DIR}/checksums.txt" "${FLEX_CHECKSUMS_URL}"
(
  cd "${TMP_DIR}"
  grep -E '^[[:xdigit:]]{64}  aks-flex-node-linux-amd64\.tar\.gz$' checksums.txt |
    sha256sum -c -
)
tar -xzf "${TMP_DIR}/aks-flex-node-linux-amd64.tar.gz" -C "${TMP_DIR}"

printf 'AKS Flex Node stable release: %s\n' "${AKS_FLEX_NODE_RELEASE_TAG}"

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
  local account_json subscription_id tenant_id variable_name

  account_json="$(az account show -o json --only-show-errors)" ||
    die "Azure CLI is not authenticated; run az login"
  subscription_id="$(jq -r '.id' <<<"${account_json}")"
  tenant_id="$(jq -r '.tenantId' <<<"${account_json}")"

  for variable_name in ARM_SUBSCRIPTION_ID TF_VAR_azure_subscription_id; do
    [[ "${!variable_name:-}" == "${subscription_id}" ]] ||
      die "${variable_name} does not match Azure CLI subscription ${subscription_id}; rerun bootstrap or correct ${ENV_FILE}"
  done
  for variable_name in ARM_TENANT_ID TF_VAR_azure_tenant_id; do
    [[ "${!variable_name:-}" == "${tenant_id}" ]] ||
      die "${variable_name} does not match Azure CLI tenant ${tenant_id}; rerun bootstrap or correct ${ENV_FILE}"
  done

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
    TF_VAR_cilium_pod_cidr
    TF_VAR_unbounded_flex_pod_cidr
  )
  local variable_name

  for variable_name in "${required_vars[@]}"; do
    [[ -n "${!variable_name:-}" ]] || die "Missing required variable ${variable_name} in ${ENV_FILE}"
  done
  jq -e 'type == "object"' <<<"${TF_VAR_gpu_pool_configs}" >/dev/null ||
    die "TF_VAR_gpu_pool_configs must be a JSON object in ${ENV_FILE}"
  [[ "${TF_VAR_region_short}" =~ ^[a-z0-9]+$ ]] ||
    die "TF_VAR_region_short must contain only lowercase letters and numbers"
  [[ "${TF_VAR_flex_region_short}" =~ ^[a-z0-9]+$ ]] ||
    die "TF_VAR_flex_region_short must contain only lowercase letters and numbers"
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

  doctor_pass "${label} ${vm_size} is available in ${region} (${available_vcpus} ${family} vCPUs remain)"
}

doctor_check_vm_capacity() {
  local gpu_key gpu_vm_size gpu_min_count

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
    terraform_cmd validate
    terraform_cmd plan -out=tfplan
    ;;
  apply)
    need_cmd az
    need_cmd jq
    source_env
    sync_azure_context
    render_tfvars
    terraform_cmd init
    terraform_cmd validate
    import_untracked_anyscale_resources
    if [[ "${ANYSCALE_RUN_TERRAFORM_TESTS:-false}" == "true" ]]; then
      terraform_cmd test
    fi
    terraform_cmd apply -auto-approve
    ensure_anyscale_gateway
    ;;
  destroy)
    need_cmd az
    need_cmd jq
    need_cmd kubectl
    source_env
    sync_azure_context
    render_tfvars
    terraform_cmd init
    delete_anyscale_gateway
    set +e
    terraform_cmd destroy -auto-approve
    destroy_rc=$?
    set -e
    if [[ "${destroy_rc}" -ne 0 ]]; then
      cleanup_residual_anyscale_platform_resources
      set +e
      terraform_cmd destroy -auto-approve
      destroy_rc=$?
      set -e
      if [[ "${destroy_rc}" -ne 0 ]]; then
        destroy_verified_complete && return 0
        return "${destroy_rc}"
      fi
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

main "$@"
