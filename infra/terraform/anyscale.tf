locals {
  anyscale_cloud_name               = "${var.project}-${var.environment}-${var.region_short}"
  anyscale_cloud_control_plane_name = "/subscriptions/${var.azure_subscription_id}/resourcegroups/${azurerm_resource_group.this.name}/providers/anyscale.platform/clouds/${local.anyscale_cloud_name}"
  anyscale_cloud_arm_id             = "${azurerm_resource_group.this.id}/providers/Anyscale.Platform/clouds/${local.anyscale_cloud_name}"
  anyscale_subscription_scope       = "/subscriptions/${var.azure_subscription_id}"
  anyscale_extension_release_train  = contains(["stable", "preview"], lower(var.anyscale_release_train)) ? title(lower(var.anyscale_release_train)) : var.anyscale_release_train
  anyscale_gateway_address          = var.anyscale_gateway_hostname != "" ? var.anyscale_gateway_hostname : one(azurerm_public_ip.anyscale_gateway[*].ip_address)
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
    address     = local.anyscale_gateway_address
  }
  anyscale_platform_role_name_aliases = {
    "Anyscale Platform Administrator" = "Anyscale Platform Administrator Role"
    "Anyscale Platform Contributor"   = "Anyscale Platform Contributor Role"
    "Anyscale Platform Reader"        = "Anyscale Platform Reader Role"
  }
  anyscale_platform_role_scopes = {
    subscription   = local.anyscale_subscription_scope
    resource_group = azurerm_resource_group.this.id
    cloud          = local.anyscale_cloud_arm_id
  }
  anyscale_platform_default_admin_role_assignment = var.anyscale_platform_default_admin_assignment.enabled ? {
    current_principal_admin = {
      principal_id         = data.azurerm_client_config.current.object_id
      principal_type       = var.anyscale_platform_default_admin_assignment.principal_type
      role_definition_id   = var.anyscale_platform_default_admin_assignment.role_definition_id
      role_definition_name = var.anyscale_platform_default_admin_assignment.role_definition_name
      scope                = var.anyscale_platform_default_admin_assignment.scope
      custom_scope         = var.anyscale_platform_default_admin_assignment.custom_scope
    }
  } : {}
  anyscale_platform_explicit_role_assignments = {
    for key, assignment in var.anyscale_platform_role_assignments : key => {
      principal_id         = assignment.principal_id
      principal_type       = assignment.principal_type
      role_definition_id   = assignment.role_definition_id
      role_definition_name = assignment.role_definition_name
      scope                = assignment.scope
      custom_scope         = assignment.custom_scope
    }
  }
  anyscale_platform_legacy_admin_role_assignments = {
    for key, assignment in var.anyscale_platform_admin_role_assignments : "legacy_${key}" => {
      principal_id         = assignment.principal_id
      principal_type       = assignment.principal_type
      role_definition_id   = assignment.role_definition_id
      role_definition_name = assignment.role_definition_name
      scope                = "cloud"
      custom_scope         = null
    }
  }
  anyscale_platform_effective_role_assignments = merge(
    local.anyscale_platform_default_admin_role_assignment,
    local.anyscale_platform_explicit_role_assignments,
    local.anyscale_platform_legacy_admin_role_assignments,
  )
  anyscale_platform_resolved_role_assignments = {
    for key, assignment in local.anyscale_platform_effective_role_assignments : key => merge(assignment, {
      effective_role_definition_name = assignment.role_definition_name == null ? null : lookup(local.anyscale_platform_role_name_aliases, assignment.role_definition_name, assignment.role_definition_name)
      effective_scope                = assignment.scope == "custom" ? assignment.custom_scope : local.anyscale_platform_role_scopes[assignment.scope]
    })
  }
}

data "azurerm_client_config" "current" {}

resource "azurerm_public_ip" "anyscale_gateway" {
  count = var.anyscale_enabled && var.anyscale_gateway_hostname == "" ? 1 : 0

  name                = local.names.anyscale_gateway_public_ip
  resource_group_name = module.aks.node_resource_group
  location            = var.azure_location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags

  depends_on = [module.aks.aks_provisioning_validation]
}

resource "azurerm_network_security_rule" "anyscale_gateway_ingress" {
  count = var.anyscale_enabled && var.anyscale_gateway_hostname == "" ? 1 : 0

  name                        = "allow-anyscale-gateway-ingress"
  priority                    = 320
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["80", "443"]
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = local.names.nsg_aks_nodes

  depends_on = [module.network]
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

resource "azurerm_role_assignment" "anyscale_platform" {
  for_each = var.anyscale_enabled ? local.anyscale_platform_resolved_role_assignments : {}

  scope                = each.value.effective_scope
  role_definition_id   = try(each.value.role_definition_id, null)
  role_definition_name = try(each.value.role_definition_id, null) == null ? each.value.effective_role_definition_name : null
  principal_id         = each.value.principal_id
  principal_type       = each.value.principal_type

  depends_on = [azapi_resource.anyscale_platform]
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
    "networking.gateway.hostname"      = local.anyscale_gateway_configuration.address
    "networking.gateway.ip"            = local.anyscale_gateway_configuration.address
  }

  timeouts {
    create = "45m"
    update = "45m"
    delete = "30m"
  }

  depends_on = [
    azapi_resource.anyscale_platform,
    azurerm_role_assignment.anyscale_platform,
    azurerm_public_ip.anyscale_gateway,
    module.aks.aks_provisioning_validation,
  ]
}

resource "null_resource" "anyscale_gateway_static_ip" {
  count = var.anyscale_enabled && var.anyscale_gateway_hostname == "" ? 1 : 0

  triggers = {
    extension_id             = azurerm_kubernetes_cluster_extension.anyscale_operator[0].id
    gateway_address          = local.anyscale_gateway_address
    gateway_name             = var.anyscale_gateway_name
    gateway_namespace        = var.anyscale_operator_namespace
    public_ip_name           = azurerm_public_ip.anyscale_gateway[0].name
    public_ip_resource_group = azurerm_public_ip.anyscale_gateway[0].resource_group_name
    tls_secret_name          = "anyscale-${replace(azapi_resource.anyscale_platform[0].output.cloud_deployment_id, "_", "-")}-certificate"
  }

  provisioner "local-exec" {
    environment = {
      GATEWAY_IP               = self.triggers.gateway_address
      GATEWAY_NAME             = self.triggers.gateway_name
      GATEWAY_NAMESPACE        = self.triggers.gateway_namespace
      PUBLIC_IP_NAME           = self.triggers.public_ip_name
      PUBLIC_IP_RESOURCE_GROUP = self.triggers.public_ip_resource_group
      TLS_SECRET_NAME          = self.triggers.tls_secret_name
    }

    command = <<-EOT
      set -eu

      az aks get-credentials \
        --resource-group ${azurerm_resource_group.this.name} \
        --name ${module.aks.cluster_name} \
        --overwrite-existing >/dev/null

      FOUND=0
      ATTEMPT=1
      while [ "$ATTEMPT" -le 60 ]; do
        if kubectl get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" >/dev/null 2>&1; then
          FOUND=1
          break
        fi
        sleep 5
        ATTEMPT=$((ATTEMPT + 1))
      done

      if [ "$FOUND" != "1" ]; then
        echo "Gateway $GATEWAY_NAMESPACE/$GATEWAY_NAME was not created by the Anyscale extension."
        exit 1
      fi

      FOUND=0
      ATTEMPT=1
      while [ "$ATTEMPT" -le 60 ]; do
        if kubectl get secret "$TLS_SECRET_NAME" -n "$GATEWAY_NAMESPACE" >/dev/null 2>&1; then
          FOUND=1
          break
        fi
        sleep 5
        ATTEMPT=$((ATTEMPT + 1))
      done

      if [ "$FOUND" != "1" ]; then
        echo "TLS secret $GATEWAY_NAMESPACE/$TLS_SECRET_NAME was not created by the Anyscale extension."
        exit 1
      fi

      PATCH=$(printf '{"spec":{"addresses":[{"type":"IPAddress","value":"%s"}],"infrastructure":{"annotations":{"service.beta.kubernetes.io/azure-pip-name":"%s","service.beta.kubernetes.io/azure-load-balancer-resource-group":"%s"}},"listeners":[{"name":"http","port":80,"protocol":"HTTP","allowedRoutes":{"namespaces":{"from":"All"}}},{"name":"https","port":443,"protocol":"HTTPS","tls":{"mode":"Terminate","certificateRefs":[{"group":"","kind":"Secret","name":"%s"}]},"allowedRoutes":{"namespaces":{"from":"All"}}}]}}' "$GATEWAY_IP" "$PUBLIC_IP_NAME" "$PUBLIC_IP_RESOURCE_GROUP" "$TLS_SECRET_NAME")
      kubectl patch gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" --type merge -p "$PATCH"

      ATTEMPT=1
      while [ "$ATTEMPT" -le 60 ]; do
        GATEWAY_STATUS_IP=$(kubectl get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
        GATEWAY_HTTPS_PORT=$(kubectl get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" -o jsonpath='{.spec.listeners[?(@.name=="https")].port}' 2>/dev/null || true)
        SERVICE_NAME=$(kubectl get svc -n "$GATEWAY_NAMESPACE" -l "gateway.networking.k8s.io/gateway-name=$GATEWAY_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        SERVICE_IP=""
        SERVICE_HTTPS_PORT=""

        if [ -n "$SERVICE_NAME" ]; then
          SERVICE_IP=$(kubectl get svc "$SERVICE_NAME" -n "$GATEWAY_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
          SERVICE_HTTPS_PORT=$(kubectl get svc "$SERVICE_NAME" -n "$GATEWAY_NAMESPACE" -o jsonpath='{.spec.ports[?(@.port==443)].port}' 2>/dev/null || true)
        fi

        if [ "$GATEWAY_STATUS_IP" = "$GATEWAY_IP" ] && [ "$SERVICE_IP" = "$GATEWAY_IP" ] && [ "$GATEWAY_HTTPS_PORT" = "443" ] && [ "$SERVICE_HTTPS_PORT" = "443" ]; then
          echo "Anyscale Gateway $GATEWAY_NAMESPACE/$GATEWAY_NAME is programmed at $GATEWAY_IP."
          exit 0
        fi

        if [ -n "$SERVICE_NAME" ] && [ -n "$SERVICE_IP" ] && [ "$SERVICE_IP" != "$GATEWAY_IP" ]; then
          kubectl delete svc "$SERVICE_NAME" -n "$GATEWAY_NAMESPACE"
        fi

        sleep 10
        ATTEMPT=$((ATTEMPT + 1))
      done

      kubectl get gateway "$GATEWAY_NAME" -n "$GATEWAY_NAMESPACE" -o wide
      kubectl get svc -n "$GATEWAY_NAMESPACE" -l "gateway.networking.k8s.io/gateway-name=$GATEWAY_NAME" -o wide
      echo "Anyscale Gateway did not program the Terraform-managed static IP $GATEWAY_IP."
      exit 1
    EOT
  }

  depends_on = [
    azurerm_kubernetes_cluster_extension.anyscale_operator,
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

output "anyscale_gateway_address" {
  description = "Gateway address passed to the Anyscale AKS extension"
  value       = var.anyscale_enabled ? local.anyscale_gateway_configuration.address : null
}
