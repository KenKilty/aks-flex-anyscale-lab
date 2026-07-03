resource "azurerm_user_assigned_identity" "aks_control_plane" {
  name                = "id-${var.cluster_name}-cp"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

data "azurerm_client_config" "current" {}

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.dns_prefix
  kubernetes_version  = var.kubernetes_version
  sku_tier            = var.sku_tier
  tags                = var.tags

  oidc_issuer_enabled               = true
  workload_identity_enabled         = true
  role_based_access_control_enabled = true
  local_account_disabled            = var.local_account_disabled
  azure_policy_enabled              = var.azure_policy_enabled
  automatic_upgrade_channel         = var.automatic_upgrade_channel
  node_os_upgrade_channel           = var.node_os_upgrade_channel

  azure_active_directory_role_based_access_control {
    tenant_id          = var.azure_tenant_id
    azure_rbac_enabled = true
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "azure"
    outbound_type     = "loadBalancer"
    service_cidr      = var.service_cidr
    dns_service_ip    = var.dns_service_ip
    load_balancer_sku = "standard"
  }

  default_node_pool {
    name                         = "sys"
    vm_size                      = var.system_vm_size
    vnet_subnet_id               = var.nodes_subnet_id
    os_disk_size_gb              = 64
    type                         = "VirtualMachineScaleSets"
    auto_scaling_enabled         = true
    min_count                    = var.system_node_pool_min_count
    max_count                    = var.system_node_pool_max_count
    zones                        = var.availability_zones
    only_critical_addons_enabled = true
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks_control_plane.id]
  }

  dynamic "microsoft_defender" {
    for_each = var.defender_enabled ? [1] : []
    content {
      log_analytics_workspace_id = var.log_analytics_workspace_id
    }
  }

  dynamic "key_vault_secrets_provider" {
    for_each = var.key_vault_secrets_provider_enabled ? [1] : []
    content {
      secret_rotation_enabled = true
    }
  }

  oms_agent {
    log_analytics_workspace_id      = var.log_analytics_workspace_id
    msi_auth_for_monitoring_enabled = true
  }

  lifecycle {
    ignore_changes = [
      default_node_pool[0].upgrade_settings,
      kubernetes_version,
      microsoft_defender,
    ]
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "cpu" {
  name                  = "cpu"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.cpu_vm_size
  mode                  = "User"
  vnet_subnet_id        = var.nodes_subnet_id
  os_disk_size_gb       = 128
  zones                 = var.availability_zones

  auto_scaling_enabled = true
  min_count            = 0
  max_count            = 4

  tags = var.tags

  lifecycle {
    ignore_changes = [upgrade_settings]
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "gpu" {
  for_each              = var.gpu_pool_configs
  name                  = each.value.name
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = each.value.vm_size
  mode                  = "User"
  vnet_subnet_id        = var.nodes_subnet_id
  os_disk_size_gb       = 128
  gpu_driver            = "Install"
  zones                 = each.value.availability_zones

  auto_scaling_enabled = true
  min_count            = each.value.min_count
  max_count            = each.value.max_count

  node_labels = {
    "nvidia.com/gpu.product" = each.value.product_name
    "nvidia.com/gpu.count"   = each.value.gpu_count
  }

  node_taints = [
    "node.anyscale.com/capacity-type=ON_DEMAND:NoSchedule",
    "nvidia.com/gpu=present:NoSchedule",
    "node.anyscale.com/accelerator-type=GPU:NoSchedule",
  ]

  tags = var.tags

  lifecycle {
    ignore_changes = [upgrade_settings]
  }
}

locals {
  container_insights_streams           = var.container_insights_v2_enabled ? distinct(concat(var.container_insights_streams, ["Microsoft-ContainerLogV2"])) : var.container_insights_streams
  container_insights_extension_streams = ["Microsoft-ContainerInsights-Group-Default"]
  ci_dcr_name                          = "MSCI-${var.location}-${var.cluster_name}"
  ci_config_dce_name_full              = "MSCI-config-${var.location}-${var.cluster_name}"
  ci_config_dce_name_trimmed           = substr(local.ci_config_dce_name_full, 0, 43)
  ci_config_dce_name                   = endswith(local.ci_config_dce_name_trimmed, "-") ? substr(local.ci_config_dce_name_trimmed, 0, 42) : local.ci_config_dce_name_trimmed
}

resource "azurerm_monitor_data_collection_endpoint" "container_insights_config" {
  count = var.ampls_enabled ? 1 : 0

  name                          = local.ci_config_dce_name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  kind                          = "Linux"
  public_network_access_enabled = false
  tags                          = var.tags
}

resource "azurerm_monitor_data_collection_rule" "container_insights" {
  name                = local.ci_dcr_name
  resource_group_name = var.resource_group_name
  location            = var.location
  description         = "DCR for AKS Container Insights with ContainerLogV2 enabled."
  tags                = var.tags

  destinations {
    log_analytics {
      workspace_resource_id = var.log_analytics_workspace_id
      name                  = "ciworkspace"
    }
  }

  data_flow {
    streams      = local.container_insights_extension_streams
    destinations = ["ciworkspace"]
  }

  data_sources {
    extension {
      streams        = local.container_insights_extension_streams
      extension_name = "ContainerInsights"
      extension_json = jsonencode({
        dataCollectionSettings = {
          interval               = var.container_insights_data_collection_interval
          namespaceFilteringMode = var.container_insights_namespace_filtering_mode
          namespaces             = var.container_insights_namespaces
          enableContainerLogV2   = var.container_insights_v2_enabled
        }
      })
      name = "ContainerInsightsExtension"
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "container_insights" {
  name                    = "ContainerInsightsExtension"
  target_resource_id      = azurerm_kubernetes_cluster.this.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.container_insights.id
  description             = "Association of Container Insights data collection rule."
}

resource "azurerm_monitor_data_collection_rule_association" "container_insights_config" {
  count = var.ampls_enabled ? 1 : 0

  name                        = "configurationAccessEndpoint"
  target_resource_id          = azurerm_kubernetes_cluster.this.id
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.container_insights_config[0].id
  description                 = "Private configuration endpoint association for Container Insights."
}

resource "azurerm_monitor_private_link_scoped_service" "container_insights_config_dce" {
  count = var.ampls_enabled ? 1 : 0

  name                = "${local.ci_config_dce_name}-connection"
  resource_group_name = var.ampls_resource_group_name
  scope_name          = var.ampls_scope_name
  linked_resource_id  = azurerm_monitor_data_collection_endpoint.container_insights_config[0].id
}

resource "azurerm_federated_identity_credential" "anyscale_operator" {
  name                      = "fic-anyscale-operator-${var.cluster_name}"
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.this.oidc_issuer_url
  user_assigned_identity_id = var.anyscale_operator_identity_id
  subject                   = "system:serviceaccount:${var.anyscale_operator_namespace}:${var.anyscale_operator_serviceaccount}"
}

resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

resource "azurerm_role_assignment" "current_principal_cluster_user" {
  count = var.assign_current_principal_cluster_access ? 1 : 0

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "current_principal_cluster_admin" {
  count = var.assign_current_principal_cluster_access ? 1 : 0

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "cluster_user" {
  for_each = var.cluster_user_principal_ids

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = each.value
}

resource "azurerm_role_assignment" "cluster_admin" {
  for_each = var.cluster_admin_principal_ids

  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = each.value
}

resource "azurerm_monitor_diagnostic_setting" "aks" {
  count = var.diagnostic_settings_enabled ? 1 : 0

  name                       = "diag-${var.cluster_name}"
  target_resource_id         = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "cluster-autoscaler"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
