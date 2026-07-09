output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "aks_cluster_name" {
  value = module.aks.cluster_name
}

output "aks_cluster_id" {
  value = module.aks.cluster_id
}

output "aks_api_server_fqdn" {
  value = module.aks.api_server_fqdn
}

output "aks_oidc_issuer_url" {
  value = module.aks.oidc_issuer_url
}

output "home_vnet_id" {
  value = module.network.vnet_id
}

output "home_subnet_ids" {
  value = module.network.subnet_ids
}

output "flex_vnet_id" {
  value = azurerm_virtual_network.flex.id
}

output "flex_subnet_id" {
  value = azurerm_subnet.flex_hosts.id
}

output "flex_host_vm_name" {
  value = var.flex_host_enabled ? module.flex_host[0].vm_name : null
}

output "flex_host_private_ip" {
  value = var.flex_host_enabled ? module.flex_host[0].private_ip_address : null
}

output "flex_host_network_interface_id" {
  value = var.flex_host_enabled ? module.flex_host[0].network_interface_id : null
}

output "flex_host_ip_configurations" {
  value = var.flex_host_enabled ? module.flex_host[0].ip_configurations : []
}

output "flex_host_public_ip" {
  value = var.flex_host_enabled ? module.flex_host[0].public_ip_address : null
}

output "flex_host_admin_username" {
  value = var.flex_host_enabled ? module.flex_host[0].admin_username : null
}

output "flex_host_identity_principal_id" {
  value = var.flex_host_enabled ? module.flex_host[0].principal_id : null
}

output "storage_account_name" {
  value = module.storage.storage_account_name
}

output "acr_login_server" {
  value = module.acr.login_server
}

output "log_analytics_workspace_id" {
  value = module.observability.log_analytics_workspace_id
}

output "anyscale_operator_identity" {
  value = {
    id           = module.identity.id
    client_id    = module.identity.client_id
    principal_id = module.identity.principal_id
  }
}

output "foundation_contract" {
  value = {
    rg                   = azurerm_resource_group.this.name
    home_region          = var.azure_location
    flex_region          = var.flex_region
    public_aks           = true
    home_vnet            = module.network.vnet_name
    flex_vnet            = azurerm_virtual_network.flex.name
    flex_peering_enabled = true
    flex_host_enabled    = var.flex_host_enabled
    private_endpoints    = false
    ampls_enabled        = var.ampls_enabled
    storage_private_mode = module.storage.private_mode
    acr_private_mode     = module.acr.private_mode
    aks_contract         = module.aks.cluster_contract
  }
}

output "flex_join_contract" {
  value = {
    enabled           = var.flex_host_enabled
    helper_command    = "./scripts/anyscale-aks.sh flex-config"
    bootstrap_command = "./scripts/anyscale-aks.sh flex-bootstrap"
    agent_pool_name   = "aksflexnodes"
    vm_name           = var.flex_host_enabled ? module.flex_host[0].vm_name : null
    public_ip         = var.flex_host_enabled ? module.flex_host[0].public_ip_address : null
    private_ip        = var.flex_host_enabled ? module.flex_host[0].private_ip_address : null
    nic_id            = var.flex_host_enabled ? module.flex_host[0].network_interface_id : null
  }
}
