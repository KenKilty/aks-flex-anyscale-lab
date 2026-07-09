output "cluster_id" {
  value = azurerm_kubernetes_cluster.this.id
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "api_server_fqdn" {
  value = azurerm_kubernetes_cluster.this.fqdn
}

output "kubelet_identity_object_id" {
  value = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

output "cluster_contract" {
  value = {
    private_cluster_enabled            = false
    app_routing_istio_enabled          = local.app_routing_istio_enabled
    app_routing_istio_gateway_class    = local.app_routing_istio_gateway_class
    managed_gateway_api_installation   = local.managed_gateway_api_installation
    network_plugin                     = azurerm_kubernetes_cluster.this.network_profile[0].network_plugin
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
