output "vm_id" {
  value = azurerm_linux_virtual_machine.this.id
}

output "vm_name" {
  value = azurerm_linux_virtual_machine.this.name
}

output "private_ip_address" {
  value = azurerm_network_interface.this.private_ip_address
}

output "network_interface_id" {
  value = azurerm_network_interface.this.id
}

output "ip_configurations" {
  value = azurerm_network_interface.this.ip_configuration
}

output "public_ip_address" {
  value = var.public_ip_enabled ? azurerm_public_ip.this[0].ip_address : null
}

output "principal_id" {
  value = azurerm_linux_virtual_machine.this.identity[0].principal_id
}

output "admin_username" {
  value = var.admin_username
}
