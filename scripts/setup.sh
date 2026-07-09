#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2089,SC2090
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ANYSCALE_AKS_ENV_FILE:-${ROOT_DIR}/.env}"
TERRAFORM_DIR="${ROOT_DIR}/infra/terraform"
GENERATED_TFVARS="${TERRAFORM_DIR}/terraform.auto.tfvars.json"
CACHE_DIR="${ROOT_DIR}/.cache"
FLEX_CACHE_DIR="${CACHE_DIR}/flex"

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

resource_group_name() {
  printf 'rg-%s-%s-%s\n' "${TF_VAR_project}" "${TF_VAR_environment}" "${TF_VAR_region_short}"
}

aks_cluster_name() {
  printf 'aks-%s-%s-%s\n' "${TF_VAR_project}" "${TF_VAR_environment}" "${TF_VAR_region_short}"
}

ensure_defaults() {
  [[ -n "${SSH_PRIVATE_KEY_PATH:-}" ]] || SSH_PRIVATE_KEY_PATH="${HOME}/.ssh/id_ed25519"
  [[ -n "${AKS_FLEX_AGENT_POOL_NAME:-}" ]] || AKS_FLEX_AGENT_POOL_NAME="aksflexnodes"
  [[ -n "${AKS_FLEX_NODE_VERSION:-}" ]] || AKS_FLEX_NODE_VERSION="v0.1.4.alpha-3"
  [[ -n "${TF_VAR_anyscale_enabled:-}" ]] || TF_VAR_anyscale_enabled="false"
  [[ -n "${TF_VAR_anyscale_release_train:-}" ]] || TF_VAR_anyscale_release_train="Stable"
  [[ -n "${TF_VAR_anyscale_control_plane_url:-}" ]] || TF_VAR_anyscale_control_plane_url="https://console.azure.anyscale.com"
  [[ -n "${TF_VAR_anyscale_gateway_name:-}" ]] || TF_VAR_anyscale_gateway_name="anyscale-gateway"
  [[ -n "${TF_VAR_anyscale_gateway_hostname:-}" ]] || TF_VAR_anyscale_gateway_hostname=""
  [[ -n "${TF_VAR_flex_host_enabled:-}" ]] || TF_VAR_flex_host_enabled="false"
  [[ -n "${TF_VAR_flex_host_vm_size:-}" ]] || TF_VAR_flex_host_vm_size="Standard_D4s_v5"
  [[ -n "${TF_VAR_flex_host_admin_username:-}" ]] || TF_VAR_flex_host_admin_username="azureoperator"
  [[ -n "${TF_VAR_flex_host_public_ip_enabled:-}" ]] || TF_VAR_flex_host_public_ip_enabled="true"
  [[ -n "${TF_VAR_flex_host_secondary_ip_configurations:-}" ]] || TF_VAR_flex_host_secondary_ip_configurations="[]"
  [[ -n "${TF_VAR_flex_host_user_assigned_identity_ids:-}" ]] || TF_VAR_flex_host_user_assigned_identity_ids="[]"
  [[ -n "${TF_VAR_flex_host_os_disk_size_gb:-}" ]] || TF_VAR_flex_host_os_disk_size_gb="256"
  [[ -n "${TF_VAR_flex_host_source_image_reference:-}" ]] || TF_VAR_flex_host_source_image_reference='{"publisher":"Canonical","offer":"0001-com-ubuntu-server-jammy","sku":"22_04-lts-gen2","version":"latest"}'

  if [[ "${TF_VAR_flex_host_enabled}" == "true" && -z "${TF_VAR_flex_host_admin_ssh_public_key:-}" ]]; then
    [[ -f "${SSH_PRIVATE_KEY_PATH}.pub" ]] || die "Missing TF_VAR_flex_host_admin_ssh_public_key and SSH public key ${SSH_PRIVATE_KEY_PATH}.pub"
    TF_VAR_flex_host_admin_ssh_public_key="$(<"${SSH_PRIVATE_KEY_PATH}.pub")"
  fi

  export SSH_PRIVATE_KEY_PATH
  export AKS_FLEX_AGENT_POOL_NAME
  export AKS_FLEX_NODE_VERSION
  export TF_VAR_anyscale_enabled
  export TF_VAR_anyscale_release_train
  export TF_VAR_anyscale_control_plane_url
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
    TF_VAR_anyscale_control_plane_url
    TF_VAR_storage_replication_type
    TF_VAR_ampls_ingestion_access_mode
    TF_VAR_ampls_query_access_mode
    TF_VAR_container_insights_data_collection_interval
    TF_VAR_container_insights_namespace_filtering_mode
    TF_VAR_anyscale_operator_identity
    TF_VAR_vnet_address_space
    TF_VAR_subnet_cidrs
    TF_VAR_flex_vnet_address_space
    TF_VAR_flex_subnet_cidr
    TF_VAR_dns_forwarding_rules
    TF_VAR_availability_zones
    TF_VAR_system_node_pool_min_count
    TF_VAR_system_node_pool_max_count
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

  local name
  for name in "${required_vars[@]}"; do
    [[ -n "${!name:-}" ]] || die "Missing required variable ${name} in .env"
  done

  ensure_defaults

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
    --arg anyscale_control_plane_url "${TF_VAR_anyscale_control_plane_url}" \
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
      anyscale_control_plane_url: $anyscale_control_plane_url,
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
      dns_forwarding_rules: $dns_forwarding_rules,
      availability_zones: $availability_zones,
      system_node_pool_min_count: $system_node_pool_min_count,
      system_node_pool_max_count: $system_node_pool_max_count,
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

download_flex_helper() {
  local helper_path="${FLEX_CACHE_DIR}/aks-flex-config"
  mkdir -p "${FLEX_CACHE_DIR}"

  if [[ ! -x "${helper_path}" ]]; then
    if [[ -f "/tmp/AKSFlexNode/scripts/aks-flex-config" ]]; then
      cp "/tmp/AKSFlexNode/scripts/aks-flex-config" "${helper_path}"
    else
      need_cmd curl
      curl -fsSLo "${helper_path}" "https://raw.githubusercontent.com/Azure/AKSFlexNode/main/scripts/aks-flex-config"
    fi
    chmod +x "${helper_path}"
  fi

  printf '%s\n' "${helper_path}"
}

generate_flex_config() {
  local helper_path config_path cluster_rg cluster_name tmp_kubeconfig

  need_cmd az
  need_cmd python3
  need_cmd kubectl
  need_cmd kubelogin
  source_env
  sync_azure_context
  ensure_defaults

  [[ "${TF_VAR_flex_host_enabled}" == "true" ]] || die "TF_VAR_flex_host_enabled must be true in ${ENV_FILE} to generate a Flex host config."

  helper_path="$(download_flex_helper)"
  config_path="${FLEX_CACHE_DIR}/aks-flex-node-config.json"
  cluster_rg="$(resource_group_name)"
  cluster_name="$(aks_cluster_name)"

  mkdir -p "${FLEX_CACHE_DIR}"

  # Ensure kubectl auth is valid for helper RBAC operations.
  az aks get-credentials \
    --resource-group "${cluster_rg}" \
    --name "${cluster_name}" \
    --subscription "${TF_VAR_azure_subscription_id}" \
    --overwrite-existing \
    --only-show-errors >/dev/null
  kubelogin convert-kubeconfig -l azurecli >/dev/null

  # Ensure bootstrap-token RBAC bindings exist. This is idempotent and harmless
  # for identity mode, and it avoids CSR approval dead-ends in mixed auth tests.
  if ! "${helper_path}" setup-node-rbac \
    --resource-group "${cluster_rg}" \
    --cluster-name "${cluster_name}" \
    --subscription "${TF_VAR_azure_subscription_id}"; then
    printf 'warning: setup-node-rbac failed; continuing with config generation\n' >&2
  fi

  "${helper_path}" generate-node-config \
    --resource-group "${cluster_rg}" \
    --cluster-name "${cluster_name}" \
    --subscription "${TF_VAR_azure_subscription_id}" \
    --agent-pool-name "${AKS_FLEX_AGENT_POOL_NAME}" \
    --identity \
    --output "${config_path}"

  # Enhance config with required node.kubelet fields for agent compatibility.
  # Resolve endpoint and CA from a target-cluster kubeconfig (not current context)
  # to avoid stale kubecontext poisoning during repeated lab runs.
  local api_server_url ca_cert dns_ip
  tmp_kubeconfig="$(mktemp)"
  az aks get-credentials \
    --resource-group "${cluster_rg}" \
    --name "${cluster_name}" \
    --subscription "${TF_VAR_azure_subscription_id}" \
    --overwrite-existing \
    --file "${tmp_kubeconfig}" \
    --only-show-errors

  api_server_url=$(KUBECONFIG="${tmp_kubeconfig}" kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https://||;s/:443$//')
  ca_cert=$(KUBECONFIG="${tmp_kubeconfig}" kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  dns_ip=$(KUBECONFIG="${tmp_kubeconfig}" kubectl get svc -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "10.100.0.10")
  rm -f "${tmp_kubeconfig}"

  [[ -n "${api_server_url}" ]] || die "Failed to resolve target AKS API server FQDN for Flex config."
  [[ -n "${ca_cert}" ]] || die "Failed to resolve target AKS CA certificate data for Flex config."

  # Use jq to add/update these fields if they're missing
  jq ".node.kubelet.clusterFQDN |= \"${api_server_url}\" |
      .node.kubelet.caCertData |= \"${ca_cert}\" |
      .networking.dnsServiceIP |= \"${dns_ip}\"" "${config_path}" >"${config_path}.tmp" &&
    mv "${config_path}.tmp" "${config_path}"

  printf 'generated: %s\n' "${config_path}"
}

bootstrap_flex_host() {
  local config_path flex_release_url host_ip admin_user flex_node_name cluster_rg cluster_name ssh_opts

  need_cmd az
  need_cmd kubectl
  need_cmd kubelogin
  need_cmd jq
  need_cmd scp
  need_cmd ssh
  need_cmd terraform
  source_env
  sync_azure_context
  ensure_defaults

  config_path="${FLEX_CACHE_DIR}/aks-flex-node-config.json"
  [[ -f "${config_path}" ]] || die "Missing ${config_path}. Run ./scripts/anyscale-aks.sh flex-config first."

  host_ip="$(terraform_cmd output -raw flex_host_public_ip 2>/dev/null || true)"
  admin_user="$(terraform_cmd output -raw flex_host_admin_username 2>/dev/null || true)"
  flex_node_name="$(terraform_cmd output -raw flex_host_vm_name 2>/dev/null || true)"
  cluster_rg="$(resource_group_name)"
  cluster_name="$(aks_cluster_name)"

  [[ -n "${host_ip}" ]] || die "Missing flex_host_public_ip Terraform output. Deploy with TF_VAR_flex_host_enabled=true and TF_VAR_flex_host_public_ip_enabled=true."
  [[ -n "${admin_user}" ]] || admin_user="${TF_VAR_flex_host_admin_username}"
  [[ -n "${flex_node_name}" ]] || die "Missing flex_host_vm_name Terraform output. Deploy with TF_VAR_flex_host_enabled=true."
  [[ -f "${SSH_PRIVATE_KEY_PATH}" ]] || die "Missing SSH private key at ${SSH_PRIVATE_KEY_PATH}"

  ssh_opts=(-i "${SSH_PRIVATE_KEY_PATH}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
  flex_release_url="https://github.com/Azure/AKSFlexNode/releases/download/${AKS_FLEX_NODE_VERSION}/aks-flex-node-linux-amd64.tar.gz"

  scp "${ssh_opts[@]}" "${config_path}" "${admin_user}@${host_ip}:/tmp/aks-flex-node-config.json"

  # shellcheck disable=SC2029
  ssh "${ssh_opts[@]}" "${admin_user}@${host_ip}" \
    "set -euo pipefail && \
     TARGET_VERSION='${AKS_FLEX_NODE_VERSION}' && \
     CURRENT_VERSION='' && \
     if command -v /usr/local/bin/aks-flex-node >/dev/null 2>&1; then \
       CURRENT_VERSION=\$(/usr/local/bin/aks-flex-node version 2>/dev/null | head -1 | grep -Eo 'v[0-9]+\.[0-9]+\.[^[:space:]]+' || true); \
     fi && \
     if [ \"\${CURRENT_VERSION}\" != \"\${TARGET_VERSION}\" ]; then \
       TMP_DIR=\$(mktemp -d) && \
       curl -fsSLo \"\${TMP_DIR}/aks-flex-node.tgz\" '${flex_release_url}' && \
       tar -xzf \"\${TMP_DIR}/aks-flex-node.tgz\" -C \"\${TMP_DIR}\" && \
       sudo systemctl stop aks-flex-node-agent || true && \
       sudo install -m 0755 \"\${TMP_DIR}/aks-flex-node-linux-amd64\" /usr/local/bin/aks-flex-node && \
       rm -rf \"\${TMP_DIR}\"; \
     fi && \
     sudo install -d -m 0755 /etc/aks-flex-node && \
     sudo install -m 0600 /tmp/aks-flex-node-config.json /etc/aks-flex-node/config.json && \
     sudo /usr/local/bin/aks-flex-node start --config /etc/aks-flex-node/config.json && \
     if sudo systemctl cat aks-flex-node-agent >/dev/null 2>&1; then \
       sudo systemctl status aks-flex-node-agent --no-pager -l || true; \
       sudo systemctl is-active --quiet aks-flex-node-agent || { \
         echo 'aks-flex-node-agent.service is not active after bootstrap' >&2; \
         sudo journalctl -u aks-flex-node-agent -n 200 --no-pager || true; \
         exit 1; \
       }; \
     else \
       echo 'aks-flex-node-agent.service unit was not created by bootstrap' >&2; \
       sudo machinectl list --no-pager || true; \
       sudo journalctl -M kube1 -u kubelet -n 200 --no-pager || true; \
       exit 1; \
     fi"

  az aks get-credentials \
    --resource-group "${cluster_rg}" \
    --name "${cluster_name}" \
    --subscription "${TF_VAR_azure_subscription_id}" \
    --overwrite-existing \
    --only-show-errors >/dev/null
  kubelogin convert-kubeconfig -l azurecli >/dev/null

  kubectl wait --for=condition=Ready "node/${flex_node_name}" --timeout=5m
  kubectl label node "${flex_node_name}" \
    "agentpool=${AKS_FLEX_AGENT_POOL_NAME}" \
    "kubernetes.azure.com/agentpool=${AKS_FLEX_AGENT_POOL_NAME}" \
    "topology.kubernetes.io/region=${TF_VAR_flex_region}" \
    "kubernetes.azure.com/cluster-" \
    --overwrite
  kubectl taint node "${flex_node_name}" aks-flex-node=true:NoSchedule --overwrite

  kubectl -n kube-system get daemonset kube-proxy -o json |
    jq --arg agentpool "${AKS_FLEX_AGENT_POOL_NAME}" '
        del(
          .metadata.annotations["deprecated.daemonset.template.generation"],
          .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"],
          .metadata.creationTimestamp,
          .metadata.generation,
          .metadata.managedFields,
          .metadata.resourceVersion,
          .metadata.uid,
          .status
        )
        | .metadata.name = "kube-proxy-flex"
        | .metadata.labels.component = "kube-proxy-flex"
        | del(.metadata.labels["addonmanager.kubernetes.io/mode"], .metadata.labels["kubernetes.azure.com/managedby"])
        | .spec.selector.matchLabels.component = "kube-proxy-flex"
        | .spec.template.metadata.labels.component = "kube-proxy-flex"
        | del(.spec.template.metadata.labels["kubernetes.azure.com/managedby"])
        | del(.spec.template.spec.affinity)
        | .spec.template.spec.nodeSelector = {"agentpool": $agentpool}
        | .spec.template.spec.tolerations = (
            ((.spec.template.spec.tolerations // [])
              | map(select(.key != "aks-flex-node")))
            + [{"key":"aks-flex-node","operator":"Equal","value":"true","effect":"NoSchedule"}]
          )
      ' |
    kubectl apply -f -
  kubectl -n kube-system rollout status daemonset/kube-proxy-flex --timeout=3m
}

doctor() {
  need_cmd az
  need_cmd jq
  need_cmd terraform
  source_env
  sync_azure_context
  az account show --query '{subscription:id,tenant:tenantId,user:user.name}' -o json --only-show-errors
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

  case "${command}" in
  doctor)
    doctor
    ;;
  status)
    status
    ;;
  render-tfvars)
    need_cmd az
    need_cmd jq
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
    if [[ "${ANYSCALE_RUN_TERRAFORM_TESTS:-false}" == "true" ]]; then
      terraform_cmd test
    fi
    terraform_cmd apply -auto-approve
    ;;
  destroy)
    need_cmd az
    need_cmd jq
    source_env
    sync_azure_context
    render_tfvars
    terraform_cmd init
    terraform_cmd destroy -auto-approve
    ;;
  output)
    terraform_cmd output
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
