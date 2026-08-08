output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "vnet_name" {
  value = azurerm_virtual_network.this.name
}

output "subnet_ids" {
  value = {
    aks_nodes         = azurerm_subnet.aks_nodes.id
    dns_resolver_in   = azurerm_subnet.dns_resolver_in.id
    dns_resolver_out  = azurerm_subnet.dns_resolver_out.id
    firewall          = azurerm_subnet.firewall.id
    bastion           = azurerm_subnet.bastion.id
    jump_host         = one(azurerm_subnet.jump_host[*].id)
    browser_jump_host = one(azurerm_subnet.browser_jump_host[*].id)
  }
}
