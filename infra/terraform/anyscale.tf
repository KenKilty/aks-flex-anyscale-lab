locals {
  anyscale_cloud_name               = "${var.project}-${var.environment}-${var.region_short}"
  anyscale_cloud_control_plane_name = "/subscriptions/${var.azure_subscription_id}/resourcegroups/${azurerm_resource_group.this.name}/providers/anyscale.platform/clouds/${local.anyscale_cloud_name}"
  anyscale_extension_release_train  = contains(["stable", "preview"], lower(var.anyscale_release_train)) ? title(lower(var.anyscale_release_train)) : var.anyscale_release_train
  anyscale_platform_deployments = {
    top_level    = "dep-anyscale-${var.project}-${var.environment}-${var.region_short}"
    blob         = "dep-anyblob-${var.project}-${var.environment}-${var.region_short}"
    fic          = "dep-anyfic-${var.project}-${var.environment}-${var.region_short}"
    storage_rbac = "dep-anystoragerbac-${var.project}-${var.environment}-${var.region_short}"
    acr_rbac     = "dep-anyacrrbac-${var.project}-${var.environment}-${var.region_short}"
  }
  anyscale_gateway_configuration = {
    enabled     = "true"
    name        = var.anyscale_gateway_name
    class_name  = "approuting-istio"
    namespace   = var.anyscale_operator_namespace
    api_version = "gateway.networking.k8s.io/v1"
    hostname    = var.anyscale_gateway_hostname
  }
}

# Azure-native Anyscale cloud resource path. This mirrors the proven private-sample
# pattern and exports cloudResourceId for the AKS extension binding.
resource "azapi_resource" "anyscale_platform" {
  count = var.anyscale_enabled ? 1 : 0

  type                      = "Microsoft.Resources/deployments@2022-09-01"
  name                      = local.anyscale_platform_deployments.top_level
  parent_id                 = azurerm_resource_group.this.id
  schema_validation_enabled = false
  response_export_values = {
    cloud_deployment_id = "properties.outputs.cloudResourceId.value"
    provisioning_state  = "properties.provisioningState"
  }
  body = {
    properties = {
      mode     = "Incremental"
      template = jsondecode(file("${path.module}/templates/anyscale-platform-cloud.template.json"))
      parameters = {
        location = {
          value = azurerm_resource_group.this.location
        }
        cloudName = {
          value = local.anyscale_cloud_name
        }
        storageAccountName = {
          value = module.storage.storage_account_name
        }
        storageMode = {
          value = "existing"
        }
        storageAccountResourceId = {
          value = module.storage.storage_account_id
        }
        storageContainerName = {
          value = module.storage.container_name
        }
        workloadIdentityName = {
          value = module.identity.name
        }
        identityMode = {
          value = "existing"
        }
        identityResourceId = {
          value = module.identity.id
        }
        tagsByResource = {
          value = {}
        }
        acrMode = {
          value = "existing"
        }
        acrName = {
          value = module.acr.acr_name
        }
        acrResourceId = {
          value = module.acr.acr_id
        }
        aksKubeletPrincipalId = {
          value = module.aks.kubelet_identity_object_id
        }
        manageAksKubeletAcrPullRoleAssignment = {
          value = false
        }
        aksClusterResourceId = {
          value = module.aks.cluster_id
        }
        kubernetesServiceAccountNamespace = {
          value = var.anyscale_operator_namespace
        }
        kubernetesServiceAccountName = {
          value = var.anyscale_operator_serviceaccount
        }
        storageBlobServiceDeploymentName = {
          value = local.anyscale_platform_deployments.blob
        }
        federatedIdentityDeploymentName = {
          value = local.anyscale_platform_deployments.fic
        }
        storageRoleAssignmentDeploymentName = {
          value = local.anyscale_platform_deployments.storage_rbac
        }
        acrRoleAssignmentsDeploymentName = {
          value = local.anyscale_platform_deployments.acr_rbac
        }
      }
    }
  }

  depends_on = [
    module.aks,
    module.storage,
    module.identity,
    module.acr,
  ]
}

# AKS Marketplace Extension for Anyscale Operator
# Installs anyscale-controller-manager and webhook in anyscale-operator namespace.
resource "azurerm_kubernetes_cluster_extension" "anyscale_operator" {
  count = var.anyscale_enabled ? 1 : 0

  cluster_id     = module.aks.cluster_id
  extension_type = lower(var.anyscale_release_train) == "preview" ? "preview.anyscale.aks.operator" : "anyscale.aks.operator"
  name           = "anyscale-operator"
  release_train  = var.anyscale_release_train
  version        = null

  plan {
    name      = lower(var.anyscale_release_train) == "preview" ? "preview" : "anyscale-operator"
    product   = "anyscale-operator-aks"
    publisher = "anyscale1750870039553"
  }

  configuration_settings = {
    "anyscale-operator.namespace"      = var.anyscale_operator_namespace
    "anyscale-operator.serviceaccount" = var.anyscale_operator_serviceaccount
    "global.cloudDeploymentId"         = azapi_resource.anyscale_platform[0].output.cloud_deployment_id
    "global.controlPlaneURL"           = var.anyscale_control_plane_url
    "global.auth.iamIdentity"          = module.identity.client_id
    "global.auth.audience"             = var.anyscale_auth_audience
    "workloads.serviceAccount.name"    = var.anyscale_operator_serviceaccount
    "networking.gateway.enabled"       = local.anyscale_gateway_configuration.enabled
    "networking.gateway.name"          = local.anyscale_gateway_configuration.name
    "networking.gateway.className"     = local.anyscale_gateway_configuration.class_name
    "networking.gateway.namespace"     = local.anyscale_gateway_configuration.namespace
    "networking.gateway.apiVersion"    = local.anyscale_gateway_configuration.api_version
    "networking.gateway.hostname"      = local.anyscale_gateway_configuration.hostname
  }

  timeouts {
    create = "45m"
    update = "45m"
    delete = "30m"
  }

  depends_on = [
    azapi_resource.anyscale_platform,
    module.aks.aks_provisioning_validation,
  ]
}

# Output: Anyscale operator desired-state flag. Live health must be verified
# against Azure extension provisioning state and operator pod readiness.
output "anyscale_operator_enabled" {
  description = "Whether the Anyscale operator is enabled in Terraform configuration"
  value       = var.anyscale_enabled
}

output "anyscale_operator_namespace" {
  description = "Kubernetes namespace where Anyscale operator runs"
  value       = var.anyscale_operator_namespace
  depends_on = [
    azurerm_kubernetes_cluster_extension.anyscale_operator,
  ]
}

output "anyscale_cloud_name" {
  description = "Canonical Anyscale cloud name in Azure-native control-plane format"
  value       = local.anyscale_cloud_control_plane_name
}

output "anyscale_cloud_deployment_id" {
  description = "Cloud deployment identifier emitted by Azure-native Anyscale resource deployment"
  value       = var.anyscale_enabled ? azapi_resource.anyscale_platform[0].output.cloud_deployment_id : null
}
