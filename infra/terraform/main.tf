resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = var.azure_location
  tags     = var.tags
}

module "network" {
  source = "./modules/network"

  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags

  vnet_name          = local.names.vnet
  vnet_address_space = var.vnet_address_space
  subnet_cidrs       = var.subnet_cidrs
  subnet_names = {
    aks_nodes        = local.names.subnet_aks_nodes
    dns_resolver_in  = local.names.subnet_dns_resolver_in
    dns_resolver_out = local.names.subnet_dns_resolver_out
    firewall         = local.names.subnet_firewall
    bastion          = local.names.subnet_bastion
  }

  nsg_aks_nodes_name = local.names.nsg_aks_nodes
}

module "observability" {
  source = "./modules/observability"

  resource_group_name         = azurerm_resource_group.this.name
  location                    = azurerm_resource_group.this.location
  log_analytics_name          = local.names.log_analytics
  ampls_name                  = local.names.ampls
  retention_in_days           = var.log_analytics_retention_days
  internet_ingestion_enabled  = var.log_analytics_internet_ingestion_enabled
  internet_query_enabled      = var.log_analytics_internet_query_enabled
  ampls_enabled               = var.ampls_enabled
  ampls_ingestion_access_mode = var.ampls_ingestion_access_mode
  ampls_query_access_mode     = var.ampls_query_access_mode
  tags                        = var.tags
}

module "storage" {
  source = "./modules/storage"

  resource_group_name  = azurerm_resource_group.this.name
  location             = azurerm_resource_group.this.location
  storage_account_name = local.names.storage_account
  subscription_id      = var.azure_subscription_id
  tenant_id            = var.azure_tenant_id
  container_name       = "${var.project}-${var.environment}-blob"
  replication_type     = var.storage_replication_type
  cors_rule            = var.storage_cors_rule

  log_analytics_workspace_id  = module.observability.log_analytics_workspace_id
  diagnostic_settings_enabled = var.terraform_managed_diagnostic_settings_enabled
  tags                        = var.tags
}

module "identity" {
  source = "./modules/identity"

  resource_group_name   = azurerm_resource_group.this.name
  location              = azurerm_resource_group.this.location
  name                  = local.names.user_assigned_id
  operator_identity     = var.anyscale_operator_identity
  storage_data_scope_id = module.storage.container_id
  tags                  = var.tags
}

module "acr" {
  source = "./modules/acr"

  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags

  name                        = local.names.acr
  zone_redundancy_enabled     = var.acr_zone_redundancy_enabled
  log_analytics_workspace_id  = module.observability.log_analytics_workspace_id
  diagnostic_settings_enabled = var.terraform_managed_diagnostic_settings_enabled
}

module "aks" {
  source = "./modules/aks_public"

  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = var.tags

  azure_tenant_id = var.azure_tenant_id
  cluster_name    = local.names.aks
  dns_prefix      = local.names.aks_dns_prefix

  nodes_subnet_id            = module.network.subnet_ids.aks_nodes
  service_cidr               = var.service_cidr
  dns_service_ip             = var.dns_service_ip
  kubernetes_version         = var.kubernetes_version
  system_vm_size             = var.system_vm_size
  availability_zones         = var.availability_zones
  sku_tier                   = var.aks_sku_tier
  system_node_pool_min_count = var.system_node_pool_min_count
  system_node_pool_max_count = var.system_node_pool_max_count
  cpu_vm_size                = var.cpu_vm_size
  gpu_pool_configs           = var.gpu_pool_configs

  log_analytics_workspace_id                  = module.observability.log_analytics_workspace_id
  container_insights_v2_enabled               = var.container_insights_v2_enabled
  container_insights_streams                  = var.container_insights_streams
  container_insights_data_collection_interval = var.container_insights_data_collection_interval
  container_insights_namespace_filtering_mode = var.container_insights_namespace_filtering_mode
  container_insights_namespaces               = var.container_insights_namespaces
  ampls_enabled                               = var.ampls_enabled
  ampls_scope_name                            = module.observability.ampls_scope_name
  ampls_resource_group_name                   = azurerm_resource_group.this.name
  diagnostic_settings_enabled                 = var.terraform_managed_diagnostic_settings_enabled
  anyscale_operator_identity_id               = module.identity.id
  anyscale_operator_namespace                 = var.anyscale_operator_namespace
  anyscale_operator_serviceaccount            = var.anyscale_operator_serviceaccount
  acr_id                                      = module.acr.acr_id
  azure_policy_enabled                        = false
  automatic_upgrade_channel                   = "patch"
  node_os_upgrade_channel                     = "SecurityPatch"
  local_account_disabled                      = true
  defender_enabled                            = true
  key_vault_secrets_provider_enabled          = true
  assign_current_principal_cluster_access     = var.assign_current_principal_cluster_access
  cluster_admin_principal_ids                 = var.aks_cluster_admin_principal_ids
  cluster_user_principal_ids                  = var.aks_cluster_user_principal_ids
}

module "flex_host" {
  count  = var.flex_host_enabled ? 1 : 0
  source = "./modules/flex_host"

  resource_group_name = azurerm_resource_group.this.name
  location            = var.flex_region
  tags                = var.tags

  name                        = local.names.flex_host
  subnet_id                   = azurerm_subnet.flex_hosts.id
  public_ip_name              = local.names.flex_host_public_ip
  public_ip_enabled           = var.flex_host_public_ip_enabled
  vm_size                     = var.flex_host_vm_size
  admin_username              = var.flex_host_admin_username
  admin_ssh_public_key        = var.flex_host_admin_ssh_public_key
  os_disk_size_gb             = var.flex_host_os_disk_size_gb
  source_image_reference      = var.flex_host_source_image_reference
  secondary_ip_configurations = var.flex_host_secondary_ip_configurations
  user_assigned_identity_ids  = var.flex_host_user_assigned_identity_ids

  depends_on = [
    azurerm_virtual_network_peering.aks_to_flex,
    azurerm_virtual_network_peering.flex_to_aks,
  ]
}

resource "azurerm_role_assignment" "flex_host_cluster_user" {
  count = var.flex_host_enabled ? 1 : 0

  scope                = module.aks.cluster_id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = module.flex_host[0].principal_id
}

resource "azurerm_role_assignment" "flex_host_cluster_rbac_admin" {
  count = var.flex_host_enabled ? 1 : 0

  scope                = module.aks.cluster_id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = module.flex_host[0].principal_id
}

resource "azurerm_virtual_network" "flex" {
  name                = local.names.flex_vnet
  resource_group_name = azurerm_resource_group.this.name
  location            = var.flex_region
  address_space       = var.flex_vnet_address_space
  tags                = var.tags
}

resource "azurerm_subnet" "flex_hosts" {
  name                 = local.names.flex_subnet
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.flex.name
  address_prefixes     = [var.flex_subnet_cidr]
}

resource "azurerm_network_security_group" "flex_hosts" {
  name                = local.names.flex_nsg
  resource_group_name = azurerm_resource_group.this.name
  location            = var.flex_region
  tags                = var.tags
}

resource "azurerm_network_security_rule" "flex_hosts_ssh" {
  name                        = "allow-ssh"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.flex_hosts.name
}

resource "azurerm_subnet_network_security_group_association" "flex_hosts" {
  subnet_id                 = azurerm_subnet.flex_hosts.id
  network_security_group_id = azurerm_network_security_group.flex_hosts.id
}

resource "azurerm_virtual_network_peering" "aks_to_flex" {
  name                         = "aks-to-flex"
  resource_group_name          = azurerm_resource_group.this.name
  virtual_network_name         = module.network.vnet_name
  remote_virtual_network_id    = azurerm_virtual_network.flex.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true

  depends_on = [
    azurerm_subnet_network_security_group_association.flex_hosts,
  ]
}

resource "azurerm_virtual_network_peering" "flex_to_aks" {
  name                         = "flex-to-aks"
  resource_group_name          = azurerm_resource_group.this.name
  virtual_network_name         = azurerm_virtual_network.flex.name
  remote_virtual_network_id    = module.network.vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true

  depends_on = [
    azurerm_subnet_network_security_group_association.flex_hosts,
  ]
}
