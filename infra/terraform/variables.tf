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
    dns_resolver_in   = string
    dns_resolver_out  = string
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

variable "flex_pod_cidr" {
  type    = string
  default = "10.244.0.0/16"
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

variable "aks_defender_enabled" {
  type    = bool
  default = false
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

variable "flex_host_secondary_ip_configurations" {
  type = list(object({
    name                          = string
    private_ip_address            = optional(string)
    private_ip_address_allocation = optional(string, "Dynamic")
  }))
  default = []

  validation {
    condition = alltrue([
      for config in var.flex_host_secondary_ip_configurations :
      config.name != "ipconfig" &&
      contains(["Dynamic", "Static"], config.private_ip_address_allocation) &&
      (config.private_ip_address_allocation != "Static" || try(length(config.private_ip_address) > 0, false))
    ])
    error_message = "flex_host_secondary_ip_configurations must not use name ipconfig, allocation must be Dynamic or Static, and Static configs must include private_ip_address."
  }
}

variable "flex_host_user_assigned_identity_ids" {
  type    = list(string)
  default = []
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

variable "anyscale_control_plane_url" {
  description = "Anyscale control plane URL used by the AKS extension (maps to global.controlPlaneURL)"
  type        = string
  default     = "https://console.azure.anyscale.com"
}

variable "anyscale_auth_audience" {
  description = "Audience used by Anyscale operator Azure auth flow (maps to global.auth.audience)"
  type        = string
  default     = "api://086bc555-6989-4362-ba30-fded273e432b/.default"
}

variable "anyscale_gateway_name" {
  description = "Gateway API Gateway name used by the Anyscale operator"
  type        = string
  default     = "anyscale-gateway"
}

variable "anyscale_gateway_hostname" {
  description = "Hostname or address published by the Anyscale Gateway API Gateway"
  type        = string
  default     = ""
}

variable "anyscale_platform_admin_role_assignments" {
  description = <<-EOT
    Legacy Azure RBAC role assignments scoped to the Anyscale Platform cloud ARM resource.

    Prefer anyscale_platform_role_assignments for new configuration because the
    Anyscale Platform Administrator role is only effective at subscription scope
    during public preview.
  EOT
  type = map(object({
    principal_id         = string
    principal_type       = optional(string, "User")
    role_definition_id   = optional(string)
    role_definition_name = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for assignment in values(var.anyscale_platform_admin_role_assignments) : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", assignment.principal_id))])
    error_message = "anyscale_platform_admin_role_assignments principal_id values must be Entra object IDs."
  }

  validation {
    condition     = alltrue([for assignment in values(var.anyscale_platform_admin_role_assignments) : contains(["User", "Group", "ServicePrincipal", "ForeignGroup", "Device"], assignment.principal_type)])
    error_message = "anyscale_platform_admin_role_assignments principal_type must be User, Group, ServicePrincipal, ForeignGroup, or Device."
  }

  validation {
    condition = alltrue([for assignment in values(var.anyscale_platform_admin_role_assignments) : (
      (try(trimspace(assignment.role_definition_id), "") != "") != (try(trimspace(assignment.role_definition_name), "") != "")
    )])
    error_message = "Each anyscale_platform_admin_role_assignments entry must set exactly one of role_definition_id or role_definition_name."
  }

  validation {
    condition = alltrue([for assignment in values(var.anyscale_platform_admin_role_assignments) : (
      try(trimspace(assignment.role_definition_id), "") == "" || can(regex("^/subscriptions/[0-9a-fA-F-]{36}/providers/Microsoft\\.Authorization/roleDefinitions/[0-9a-fA-F-]{36}$", assignment.role_definition_id))
    )])
    error_message = "anyscale_platform_admin_role_assignments role_definition_id values must be full subscription role definition IDs."
  }
}

variable "anyscale_platform_default_admin_assignment" {
  description = <<-EOT
    Default Anyscale Platform Administrator assignment for the current Terraform principal.

    This gives the deploying Entra principal org-owner-style Anyscale access by
    assigning the built-in Anyscale Platform Administrator role at subscription
    scope. Disable it or override the role/scope when running non-interactively.
  EOT
  type = object({
    enabled              = optional(bool, true)
    principal_type       = optional(string, "User")
    role_definition_id   = optional(string)
    role_definition_name = optional(string, "Anyscale Platform Administrator")
    scope                = optional(string, "subscription")
    custom_scope         = optional(string)
  })
  default = {}

  validation {
    condition     = contains(["User", "Group", "ServicePrincipal", "ForeignGroup", "Device"], var.anyscale_platform_default_admin_assignment.principal_type)
    error_message = "anyscale_platform_default_admin_assignment.principal_type must be User, Group, ServicePrincipal, ForeignGroup, or Device."
  }

  validation {
    condition     = contains(["subscription", "resource_group", "cloud", "custom"], var.anyscale_platform_default_admin_assignment.scope)
    error_message = "anyscale_platform_default_admin_assignment.scope must be subscription, resource_group, cloud, or custom."
  }

  validation {
    condition = !var.anyscale_platform_default_admin_assignment.enabled || (
      (try(trimspace(var.anyscale_platform_default_admin_assignment.role_definition_id), "") != "") != (try(trimspace(var.anyscale_platform_default_admin_assignment.role_definition_name), "") != "")
    )
    error_message = "anyscale_platform_default_admin_assignment must set exactly one of role_definition_id or role_definition_name when enabled."
  }

  validation {
    condition = (
      var.anyscale_platform_default_admin_assignment.scope != "custom" ||
      try(trimspace(var.anyscale_platform_default_admin_assignment.custom_scope), "") != ""
    )
    error_message = "anyscale_platform_default_admin_assignment.custom_scope must be set when scope is custom."
  }
}

variable "anyscale_platform_role_assignments" {
  description = <<-EOT
    Azure RBAC role assignments for Anyscale Platform built-in roles.

    Assign Anyscale Platform Administrator at subscription scope for default
    org-owner-style console access. Assign Contributor or Reader at cloud or
    narrower scopes for day-to-day users.
  EOT
  type = map(object({
    principal_id         = string
    principal_type       = optional(string, "User")
    role_definition_id   = optional(string)
    role_definition_name = optional(string)
    scope                = optional(string, "cloud")
    custom_scope         = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for assignment in values(var.anyscale_platform_role_assignments) : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", assignment.principal_id))])
    error_message = "anyscale_platform_role_assignments principal_id values must be Entra object IDs."
  }

  validation {
    condition     = alltrue([for assignment in values(var.anyscale_platform_role_assignments) : contains(["User", "Group", "ServicePrincipal", "ForeignGroup", "Device"], assignment.principal_type)])
    error_message = "anyscale_platform_role_assignments principal_type must be User, Group, ServicePrincipal, ForeignGroup, or Device."
  }

  validation {
    condition     = alltrue([for assignment in values(var.anyscale_platform_role_assignments) : contains(["subscription", "resource_group", "cloud", "custom"], assignment.scope)])
    error_message = "anyscale_platform_role_assignments scope must be subscription, resource_group, cloud, or custom."
  }

  validation {
    condition = alltrue([for assignment in values(var.anyscale_platform_role_assignments) : (
      (try(trimspace(assignment.role_definition_id), "") != "") != (try(trimspace(assignment.role_definition_name), "") != "")
    )])
    error_message = "Each anyscale_platform_role_assignments entry must set exactly one of role_definition_id or role_definition_name."
  }

  validation {
    condition = alltrue([for assignment in values(var.anyscale_platform_role_assignments) : (
      try(trimspace(assignment.role_definition_id), "") == "" || can(regex("^/subscriptions/[0-9a-fA-F-]{36}/providers/Microsoft\\.Authorization/roleDefinitions/[0-9a-fA-F-]{36}$", assignment.role_definition_id))
    )])
    error_message = "anyscale_platform_role_assignments role_definition_id values must be full subscription role definition IDs."
  }

  validation {
    condition = alltrue([for assignment in values(var.anyscale_platform_role_assignments) : (
      assignment.scope != "custom" || try(trimspace(assignment.custom_scope), "") != ""
    )])
    error_message = "anyscale_platform_role_assignments custom_scope must be set when scope is custom."
  }
}
