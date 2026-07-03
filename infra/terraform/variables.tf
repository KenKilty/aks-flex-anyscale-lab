variable "azure_subscription_id" {
  type = string
}

variable "azure_tenant_id" {
  type = string
}

variable "project" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9]{2,12}$", var.project))
    error_message = "project must be 2-12 lowercase alphanumeric characters."
  }
}

variable "environment" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9]{2,6}$", var.environment))
    error_message = "environment must be 2-6 lowercase alphanumeric characters."
  }
}

variable "azure_location" {
  type = string
}

variable "region_short" {
  type = string
}

variable "flex_region" {
  type = string
}

variable "flex_region_short" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "assign_current_principal_cluster_access" {
  type    = bool
  default = true
}

variable "aks_cluster_admin_principal_ids" {
  type    = map(string)
  default = {}
}

variable "aks_cluster_user_principal_ids" {
  type    = map(string)
  default = {}
}

variable "vnet_address_space" {
  type = list(string)
}

variable "subnet_cidrs" {
  type = object({
    firewall          = string
    bastion           = string
    aks_apiserver     = string
    dns_resolver_in   = string
    dns_resolver_out  = string
    private_endpoints = string
    aks_nodes         = string
    jump_host         = optional(string)
    browser_jump_host = optional(string)
  })
}

variable "flex_vnet_address_space" {
  type = list(string)
}

variable "flex_subnet_cidr" {
  type = string
}

variable "dns_forwarding_rules" {
  type = map(object({
    domain_name = string
    target_dns_servers = list(object({
      ip_address = string
      port       = number
    }))
  }))
}

variable "service_cidr" {
  type = string
}

variable "dns_service_ip" {
  type = string
}

variable "system_vm_size" {
  type = string
}

variable "availability_zones" {
  type    = list(string)
  default = ["1", "2", "3"]
}

variable "aks_sku_tier" {
  type    = string
  default = "Standard"
}

variable "system_node_pool_min_count" {
  type = number
}

variable "system_node_pool_max_count" {
  type = number
}

variable "cpu_vm_size" {
  type = string
}

variable "gpu_pool_configs" {
  type = map(object({
    name               = string
    vm_size            = string
    product_name       = string
    gpu_count          = string
    min_count          = number
    max_count          = number
    availability_zones = optional(list(string), [])
  }))
}

variable "kubernetes_version" {
  type     = string
  nullable = true
}

variable "anyscale_operator_namespace" {
  type = string
}

variable "anyscale_operator_serviceaccount" {
  type = string
}

variable "flex_host_enabled" {
  type    = bool
  default = false
}

variable "flex_host_vm_size" {
  type    = string
  default = "Standard_NC16as_T4_v3"
}

variable "flex_host_admin_username" {
  type    = string
  default = "azureoperator"
}

variable "flex_host_admin_ssh_public_key" {
  type    = string
  default = ""
}

variable "flex_host_public_ip_enabled" {
  type    = bool
  default = true
}

variable "flex_host_os_disk_size_gb" {
  type    = number
  default = 256
}

variable "flex_host_source_image_reference" {
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  default = {
    publisher = "microsoft-dsvm"
    offer     = "ubuntu-hpc"
    sku       = "2204"
    version   = "latest"
  }
}

variable "anyscale_operator_identity" {
  type = object({
    mode                = optional(string, "create")
    id                  = optional(string)
    client_id           = optional(string)
    principal_id        = optional(string)
    name                = optional(string)
    manage_storage_rbac = optional(bool)
  })
}

variable "storage_cors_rule" {
  type = object({
    allowed_headers    = list(string)
    allowed_methods    = list(string)
    allowed_origins    = list(string)
    expose_headers     = list(string)
    max_age_in_seconds = number
  })
}

variable "storage_replication_type" {
  type = string
}

variable "acr_zone_redundancy_enabled" {
  type = bool
}

variable "log_analytics_retention_days" {
  type = number
}

variable "log_analytics_internet_ingestion_enabled" {
  type = bool
}

variable "log_analytics_internet_query_enabled" {
  type = bool
}

variable "ampls_enabled" {
  type = bool
}

variable "ampls_ingestion_access_mode" {
  type = string
}

variable "ampls_query_access_mode" {
  type = string
}

variable "container_insights_v2_enabled" {
  type = bool
}

variable "container_insights_streams" {
  type = list(string)
}

variable "container_insights_data_collection_interval" {
  type = string
}

variable "container_insights_namespace_filtering_mode" {
  type = string
}

variable "container_insights_namespaces" {
  type = list(string)
}

variable "terraform_managed_diagnostic_settings_enabled" {
  type = bool
}

variable "anyscale_enabled" {
  description = "Enable Anyscale operator provisioning via AKS marketplace extension"
  type        = bool
  default     = false
}

variable "anyscale_release_train" {
  description = "Release train for Anyscale operator (Stable or Preview)"
  type        = string
  default     = "Stable"
}
