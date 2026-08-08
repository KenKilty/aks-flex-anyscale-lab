provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  subscription_id                 = var.azure_subscription_id
  resource_provider_registrations = "none"
  storage_use_azuread             = true
}

provider "azapi" {
  subscription_id = var.azure_subscription_id
}
