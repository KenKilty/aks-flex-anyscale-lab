###############################################################################
# Azure Container Registry — Premium SKU (required for Private Link),
# public network access disabled, accessed via private endpoint only.
# Docs: https://learn.microsoft.com/azure/container-registry/container-registry-private-link
###############################################################################
resource "azurerm_container_registry" "this" {
  name                          = var.name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  sku                           = "Premium"
  admin_enabled                 = false
  public_network_access_enabled = true
  zone_redundancy_enabled       = var.zone_redundancy_enabled
  tags                          = var.tags
}

###############################################################################
# Diagnostic settings — registry login/repository events and metrics.
###############################################################################
resource "azurerm_monitor_diagnostic_setting" "acr" {
  count = var.diagnostic_settings_enabled ? 1 : 0

  name                       = "tfdiag-${var.name}"
  target_resource_id         = azurerm_container_registry.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "ContainerRegistryLoginEvents"
  }

  enabled_log {
    category = "ContainerRegistryRepositoryEvents"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
