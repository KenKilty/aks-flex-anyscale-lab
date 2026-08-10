output "cluster_id" {
  value = azurerm_kubernetes_cluster.this.id
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "node_resource_group" {
  value = azurerm_kubernetes_cluster.this.node_resource_group
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "api_server_fqdn" {
  value = azurerm_kubernetes_cluster.this.fqdn
}

output "kubelet_identity_object_id" {
  value = try(azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id, "00000000-0000-0000-0000-000000000000")
}

output "cluster_contract" {
  value = {
    private_cluster_enabled            = false
    network_plugin                     = azurerm_kubernetes_cluster.this.network_profile[0].network_plugin
    network_plugin_mode                = azurerm_kubernetes_cluster.this.network_profile[0].network_plugin_mode
    network_data_plane                 = azurerm_kubernetes_cluster.this.network_profile[0].network_data_plane
    pod_cidr                           = azurerm_kubernetes_cluster.this.network_profile[0].pod_cidr
    network_policy                     = azurerm_kubernetes_cluster.this.network_profile[0].network_policy
    outbound_type                      = azurerm_kubernetes_cluster.this.network_profile[0].outbound_type
    sku_tier                           = azurerm_kubernetes_cluster.this.sku_tier
    oidc_issuer_enabled                = azurerm_kubernetes_cluster.this.oidc_issuer_enabled
    workload_identity_enabled          = azurerm_kubernetes_cluster.this.workload_identity_enabled
    azure_rbac_enabled                 = azurerm_kubernetes_cluster.this.azure_active_directory_role_based_access_control[0].azure_rbac_enabled
    automatic_upgrade_channel          = azurerm_kubernetes_cluster.this.automatic_upgrade_channel
    node_os_upgrade_channel            = azurerm_kubernetes_cluster.this.node_os_upgrade_channel
    local_account_disabled             = azurerm_kubernetes_cluster.this.local_account_disabled
    defender_enabled                   = length(azurerm_kubernetes_cluster.this.microsoft_defender) > 0
    key_vault_secrets_provider_enabled = length(azurerm_kubernetes_cluster.this.key_vault_secrets_provider) > 0
    gpu_pool_availability_zones        = { for key, pool in var.gpu_pool_configs : key => pool.availability_zones }
  }
}

output "aks_provisioning_validation" {
  value       = null_resource.aks_provisioning_validation.id
  description = "Reference to provisioning validation check (prevents downstream resource deployment if cluster fails)"
}

output "container_insights" {
  description = "Container Insights DCR/DCE settings used by root terraform tests."
  value = {
    dcr_id                           = azurerm_monitor_data_collection_rule.container_insights.id
    dcr_name                         = azurerm_monitor_data_collection_rule.container_insights.name
    association_name                 = azurerm_monitor_data_collection_rule_association.container_insights.name
    streams                          = local.container_insights_streams
    container_log_v2_enabled         = var.container_insights_v2_enabled
    data_collection_interval         = var.container_insights_data_collection_interval
    namespace_filtering_mode         = var.container_insights_namespace_filtering_mode
    namespaces                       = var.container_insights_namespaces
    ampls_enabled                    = var.ampls_enabled
    config_dce_id                    = var.ampls_enabled ? azurerm_monitor_data_collection_endpoint.container_insights_config[0].id : null
    config_dce_public_network_access = var.ampls_enabled ? azurerm_monitor_data_collection_endpoint.container_insights_config[0].public_network_access_enabled : null
    config_dce_scoped_service_id     = var.ampls_enabled ? azurerm_monitor_private_link_scoped_service.container_insights_config_dce[0].id : null
  }
}
