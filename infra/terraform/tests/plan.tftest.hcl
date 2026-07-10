mock_provider "azurerm" {
  mock_resource "azurerm_kubernetes_cluster" {
    defaults = {
      fqdn                = "aks-tftest-ci-wus3.example.azmk8s.io"
      kubelet_identity    = [{ object_id = "11111111-1111-1111-1111-111111111111" }]
      node_resource_group = "MC_rg-tftest-ci-wus3_aks-tftest-ci-wus3_westus3"
      oidc_issuer_url     = "https://issuer.example.test/"
    }
  }
}

mock_provider "azapi" {}

variables {
  azure_subscription_id = "00000000-0000-0000-0000-000000000000"
  azure_tenant_id       = "00000000-0000-0000-0000-000000000000"
  project               = "tftest"
  environment           = "ci"
  azure_location        = "westus3"
  region_short          = "wus3"
  flex_region           = "westus2"
  flex_region_short     = "wus2"

  vnet_address_space = ["10.50.0.0/16"]
  subnet_cidrs = {
    firewall         = "10.50.0.0/26"
    bastion          = "10.50.0.128/26"
    dns_resolver_in  = "10.50.1.16/28"
    dns_resolver_out = "10.50.1.32/28"
    aks_nodes        = "10.50.4.0/22"
  }
  flex_vnet_address_space = ["10.60.0.0/16"]
  flex_subnet_cidr        = "10.60.1.0/24"
  dns_forwarding_rules    = {}

  system_vm_size             = "Standard_D4s_v5"
  cpu_vm_size                = "Standard_D16s_v5"
  availability_zones         = ["1", "2", "3"]
  aks_sku_tier               = "Standard"
  system_node_pool_min_count = 1
  system_node_pool_max_count = 3
  kubernetes_version         = "1.34.6"
  service_cidr               = "10.100.0.0/16"
  dns_service_ip             = "10.100.0.10"
  gpu_pool_configs = {
    T4 = {
      name               = "gput4"
      vm_size            = "Standard_NC16as_T4_v3"
      product_name       = "NVIDIA-T4"
      gpu_count          = "1"
      min_count          = 1
      max_count          = 2
      availability_zones = []
    }
  }

  anyscale_operator_namespace      = "anyscale-operator"
  anyscale_operator_serviceaccount = "anyscale-operator"
  anyscale_operator_identity = {
    mode = "create"
  }

  storage_cors_rule = {
    allowed_headers    = ["*"]
    allowed_methods    = ["GET", "POST", "PUT", "HEAD", "DELETE"]
    allowed_origins    = ["https://*.anyscale.com"]
    expose_headers     = ["Accept-Ranges", "Content-Range", "Content-Length"]
    max_age_in_seconds = 0
  }
  storage_replication_type                      = "ZRS"
  acr_zone_redundancy_enabled                   = true
  log_analytics_retention_days                  = 30
  log_analytics_internet_ingestion_enabled      = true
  log_analytics_internet_query_enabled          = true
  ampls_enabled                                 = false
  ampls_ingestion_access_mode                   = "Open"
  ampls_query_access_mode                       = "Open"
  container_insights_v2_enabled                 = true
  container_insights_streams                    = ["Microsoft-ContainerLogV2", "Microsoft-KubeEvents", "Microsoft-KubePodInventory"]
  container_insights_data_collection_interval   = "1m"
  container_insights_namespace_filtering_mode   = "Off"
  container_insights_namespaces                 = []
  terraform_managed_diagnostic_settings_enabled = true
  assign_current_principal_cluster_access       = true
  aks_cluster_admin_principal_ids               = {}
  aks_cluster_user_principal_ids                = {}

  tags = {
    Project     = "tftest"
    Environment = "ci"
    ManagedBy   = "terraform"
    Owner       = "terraform-test"
  }
}

run "foundation_plan_contract" {
  command = plan

  assert {
    condition     = output.resource_group_name == "rg-tftest-ci-wus3"
    error_message = "Resource group naming contract failed."
  }

  assert {
    condition     = output.aks_cluster_name == "aks-tftest-ci-wus3"
    error_message = "AKS cluster naming contract failed."
  }

  assert {
    condition     = output.foundation_contract.public_aks == true && output.foundation_contract.flex_peering_enabled == true
    error_message = "Foundation contract must describe a public AKS cluster with flex peering enabled."
  }

  assert {
    condition     = output.foundation_contract.aks_contract.private_cluster_enabled == false
    error_message = "AKS contract must be public for this sample."
  }

  assert {
    condition     = output.foundation_contract.storage_private_mode.public_network_access_enabled == true && output.foundation_contract.acr_private_mode.public_network_access_enabled == true
    error_message = "Storage and ACR must be public-network enabled for this lab scenario."
  }
}
