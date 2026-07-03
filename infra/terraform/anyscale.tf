# Anyscale operator and cloud configuration
# Manages the AKS marketplace extension for Anyscale and ARM-level cloud resource

# AKS Marketplace Extension for Anyscale Operator
# Installs anyscale-controller-manager and webhook in anyscale-operator namespace
resource "azurerm_kubernetes_cluster_extension" "anyscale_operator" {
  count = var.anyscale_enabled ? 1 : 0

  cluster_id     = module.aks.cluster_id
  extension_type = "Microsoft.Anyscale.operator"
  name           = "anyscale-operator"
  release_train  = var.anyscale_release_train
  version        = null # Use release_train; set version to null to avoid conflicts

  configuration_settings = {
    "anyscale-operator.namespace"      = var.anyscale_operator_namespace
    "anyscale-operator.serviceaccount" = var.anyscale_operator_serviceaccount
  }

  depends_on = [
    module.aks,
    module.identity,
  ]
}

# Output: Anyscale operator status
output "anyscale_operator_installed" {
  description = "Whether the Anyscale operator extension was installed"
  value       = var.anyscale_enabled
}

output "anyscale_operator_namespace" {
  description = "Kubernetes namespace where Anyscale operator runs"
  value       = var.anyscale_operator_namespace
  depends_on = [
    azurerm_kubernetes_cluster_extension.anyscale_operator,
  ]
}
