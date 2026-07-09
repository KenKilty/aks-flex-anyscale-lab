resource "azurerm_public_ip" "this" {
  count = var.public_ip_enabled ? 1 : 0

  name                = var.public_ip_name
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "this" {
  name                  = "nic-${var.name}"
  resource_group_name   = var.resource_group_name
  location              = var.location
  ip_forwarding_enabled = true
  tags                  = var.tags

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    primary                       = true
    public_ip_address_id          = var.public_ip_enabled ? azurerm_public_ip.this[0].id : null
  }

  dynamic "ip_configuration" {
    for_each = var.secondary_ip_configurations
    content {
      name                          = ip_configuration.value.name
      subnet_id                     = var.subnet_id
      private_ip_address_allocation = ip_configuration.value.private_ip_address_allocation
      private_ip_address            = try(ip_configuration.value.private_ip_address, null)
      primary                       = false
    }
  }
}

resource "azurerm_linux_virtual_machine" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  size                = var.vm_size
  admin_username      = var.admin_username
  tags                = var.tags

  network_interface_ids           = [azurerm_network_interface.this.id]
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  identity {
    type         = length(var.user_assigned_identity_ids) > 0 ? "SystemAssigned, UserAssigned" : "SystemAssigned"
    identity_ids = length(var.user_assigned_identity_ids) > 0 ? var.user_assigned_identity_ids : null
  }

  os_disk {
    name                 = "osdisk-${var.name}"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_storage_account_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = var.source_image_reference.publisher
    offer     = var.source_image_reference.offer
    sku       = var.source_image_reference.sku
    version   = var.source_image_reference.version
  }

  dynamic "boot_diagnostics" {
    for_each = var.boot_diagnostics_enabled ? [1] : []
    content {
      storage_account_uri = null
    }
  }
}
