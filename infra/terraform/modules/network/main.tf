###############################################################################
# Virtual Network
###############################################################################
resource "azurerm_virtual_network" "this" {
  name                = var.vnet_name
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = var.vnet_address_space
  tags                = var.tags
}

###############################################################################
# Subnets
# - AzureFirewallSubnet / AzureBastionSubnet names are reserved by Azure.
###############################################################################
resource "azurerm_subnet" "aks_nodes" {
  name                 = var.subnet_names.aks_nodes
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_cidrs.aks_nodes]
}

resource "azurerm_subnet" "dns_resolver_in" {
  name                 = var.subnet_names.dns_resolver_in
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_cidrs.dns_resolver_in]

  delegation {
    name = "dns-resolver-inbound-delegation"
    service_delegation {
      name    = "Microsoft.Network/dnsResolvers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "dns_resolver_out" {
  name                 = var.subnet_names.dns_resolver_out
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_cidrs.dns_resolver_out]

  delegation {
    name = "dns-resolver-outbound-delegation"
    service_delegation {
      name    = "Microsoft.Network/dnsResolvers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "firewall" {
  name                 = var.subnet_names.firewall # must be "AzureFirewallSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_cidrs.firewall]
}

resource "azurerm_subnet" "bastion" {
  name                 = var.subnet_names.bastion # must be "AzureBastionSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_cidrs.bastion]
}

###############################################################################
# NSGs (workload subnets only — AzureFirewall/Bastion subnets must NOT have NSGs
# in the case of AzureFirewallSubnet, and AzureBastionSubnet has NSG rules
# that are managed by the Bastion service / can be added separately).
###############################################################################
resource "azurerm_network_security_group" "aks_nodes" {
  name                = var.nsg_aks_nodes_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "aks_nodes" {
  subnet_id                 = azurerm_subnet.aks_nodes.id
  network_security_group_id = azurerm_network_security_group.aks_nodes.id
}

###############################################################################
# Jump-host subnets used by the lab foundation.
###############################################################################
resource "azurerm_subnet" "jump_host" {
  count = try(var.subnet_cidrs.jump_host, null) == null ? 0 : 1

  name                 = var.subnet_names.jump_host
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_cidrs.jump_host]
}

resource "azurerm_network_security_group" "jump_host" {
  count = try(var.subnet_cidrs.jump_host, null) == null ? 0 : 1

  name                = var.nsg_jump_host_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "jump_host" {
  count = try(var.subnet_cidrs.jump_host, null) == null ? 0 : 1

  subnet_id                 = azurerm_subnet.jump_host[0].id
  network_security_group_id = azurerm_network_security_group.jump_host[0].id
}

resource "azurerm_subnet" "browser_jump_host" {
  count = try(var.subnet_cidrs.browser_jump_host, null) == null ? 0 : 1

  name                 = var.subnet_names.browser_jump_host
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_cidrs.browser_jump_host]
}

resource "azurerm_network_security_group" "browser_jump_host" {
  count = try(var.subnet_cidrs.browser_jump_host, null) == null ? 0 : 1

  name                = var.nsg_browser_jump_host_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "browser_jump_host" {
  count = try(var.subnet_cidrs.browser_jump_host, null) == null ? 0 : 1

  subnet_id                 = azurerm_subnet.browser_jump_host[0].id
  network_security_group_id = azurerm_network_security_group.browser_jump_host[0].id
}
