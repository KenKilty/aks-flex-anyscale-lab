###############################################################################
# Storage account — public access disabled, AAD-only auth, TLS 1.2+
# Hierarchical namespace enabled to support both blob (HTTPS) and dfs (ABFS)
# endpoints needed by the Anyscale operator.
# Docs:
# - https://learn.microsoft.com/azure/storage/common/storage-network-security
# - https://learn.microsoft.com/azure/storage/common/storage-private-endpoints
###############################################################################
resource "azurerm_storage_account" "this" {
  name                = var.storage_account_name
  resource_group_name = var.resource_group_name
  location            = var.location

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = var.replication_type

  is_hns_enabled                  = true
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true
  # Anyscale on AKS uses Entra ID / workload identity for the default storage
  # account, so shared keys should stay disabled.
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true

  blob_properties {
    cors_rule {
      allowed_headers    = var.cors_rule.allowed_headers
      allowed_methods    = var.cors_rule.allowed_methods
      allowed_origins    = var.cors_rule.allowed_origins
      exposed_headers    = var.cors_rule.expose_headers
      max_age_in_seconds = var.cors_rule.max_age_in_seconds
    }
  }

  tags = var.tags
}

locals {
  container_id = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.Storage/storageAccounts/${var.storage_account_name}/blobServices/default/containers/${var.container_name}"
}

###############################################################################
# Container — Anyscale cloud storage bucket equivalent
###############################################################################
resource "azurerm_storage_container" "blob" {
  name                  = var.container_name
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

###############################################################################
# Diagnostic settings — Storage account metrics and Blob service logs/metrics.
###############################################################################
resource "azurerm_monitor_diagnostic_setting" "storage_account" {
  count = var.diagnostic_settings_enabled ? 1 : 0

  name                           = "tfdiag-${var.storage_account_name}"
  target_resource_id             = azurerm_storage_account.this.id
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  log_analytics_destination_type = "Dedicated"

  enabled_metric {
    category = "Transaction"
  }

  # azurerm does not echo log_analytics_destination_type back for storage
  # diagnostic settings, so it perpetually re-plans this already-correct static
  # value. Ignore it to keep the deploy idempotent.
  lifecycle {
    ignore_changes = [log_analytics_destination_type]
  }
}

resource "azurerm_monitor_diagnostic_setting" "blob_service" {
  count = var.diagnostic_settings_enabled ? 1 : 0

  name                           = "tfdiag-${var.storage_account_name}-blob"
  target_resource_id             = "${azurerm_storage_account.this.id}/blobServices/default"
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "StorageRead"
  }

  enabled_log {
    category = "StorageWrite"
  }

  enabled_log {
    category = "StorageDelete"
  }

  enabled_metric {
    category = "Transaction"
  }

  # azurerm does not echo log_analytics_destination_type back for storage blob
  # service diagnostic settings, so it perpetually re-plans this already-correct
  # static value. Ignore it to keep the deploy idempotent.
  lifecycle {
    ignore_changes = [log_analytics_destination_type]
  }
}
