variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" {
  type = map(string)
}

variable "vnet_name" { type = string }
variable "vnet_address_space" { type = list(string) }

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

variable "subnet_names" {
  type = object({
    aks_nodes         = string
    dns_resolver_in   = string
    dns_resolver_out  = string
    firewall          = string
    bastion           = string
    jump_host         = optional(string, "snet-jump-host")
    browser_jump_host = optional(string, "snet-browser-jump-host")
  })
}

variable "nsg_aks_nodes_name" { type = string }
variable "nsg_jump_host_name" {
  type    = string
  default = "nsg-jump-host"
}
variable "nsg_browser_jump_host_name" {
  type    = string
  default = "nsg-browser-jump-host"
}
