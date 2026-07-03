variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "name" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "public_ip_name" {
  type = string
}

variable "public_ip_enabled" {
  type    = bool
  default = true
}

variable "vm_size" {
  type = string
}

variable "admin_username" {
  type    = string
  default = "azureoperator"
}

variable "admin_ssh_public_key" {
  type = string
}

variable "os_disk_size_gb" {
  type    = number
  default = 256
}

variable "os_disk_storage_account_type" {
  type    = string
  default = "Premium_LRS"
}

variable "source_image_reference" {
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
}

variable "boot_diagnostics_enabled" {
  type    = bool
  default = true
}
