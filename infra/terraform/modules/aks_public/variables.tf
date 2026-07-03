variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "azure_tenant_id" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "dns_prefix" {
  type = string
}

variable "kubernetes_version" {
  type     = string
  nullable = true
}

variable "nodes_subnet_id" {
  type = string
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
  type = list(string)
}

variable "sku_tier" {
  type = string
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

variable "log_analytics_workspace_id" {
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

variable "ampls_enabled" {
  type = bool
}

variable "ampls_scope_name" {
  type     = string
  nullable = true
}

variable "ampls_resource_group_name" {
  type     = string
  nullable = true
}

variable "diagnostic_settings_enabled" {
  type    = bool
  default = false
}

variable "anyscale_operator_identity_id" {
  type = string
}

variable "anyscale_operator_namespace" {
  type = string
}

variable "anyscale_operator_serviceaccount" {
  type = string
}

variable "acr_id" {
  type = string
}

variable "azure_policy_enabled" {
  type    = bool
  default = false
}

variable "automatic_upgrade_channel" {
  type    = string
  default = "patch"
}

variable "node_os_upgrade_channel" {
  type    = string
  default = "SecurityPatch"
}

variable "local_account_disabled" {
  type    = bool
  default = true
}

variable "defender_enabled" {
  type    = bool
  default = true
}

variable "key_vault_secrets_provider_enabled" {
  type    = bool
  default = true
}

variable "assign_current_principal_cluster_access" {
  type    = bool
  default = true
}

variable "cluster_admin_principal_ids" {
  type    = map(string)
  default = {}
}

variable "cluster_user_principal_ids" {
  type    = map(string)
  default = {}
}
