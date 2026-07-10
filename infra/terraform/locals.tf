locals {
  suffix      = "${var.project}-${var.environment}-${var.region_short}"
  suffix_alt  = "${var.project}${var.environment}${var.region_short}"
  flex_suffix = "${var.project}-${var.environment}-${var.flex_region_short}"

  names = {
    resource_group             = "rg-${local.suffix}"
    vnet                       = "vnet-${local.suffix}"
    subnet_aks_nodes           = "snet-aks-nodes-${local.suffix}"
    subnet_dns_resolver_in     = "snet-dnspr-in-${local.suffix}"
    subnet_dns_resolver_out    = "snet-dnspr-out-${local.suffix}"
    subnet_firewall            = "AzureFirewallSubnet"
    subnet_bastion             = "AzureBastionSubnet"
    nsg_aks_nodes              = "nsg-aks-nodes-${local.suffix}"
    route_table_aks_nodes      = "rt-aks-nodes-${local.suffix}"
    aks                        = "aks-${local.suffix}"
    aks_dns_prefix             = "aks-${local.suffix}"
    log_analytics              = "log-${local.suffix}"
    ampls                      = "ampls-${local.suffix}"
    user_assigned_id           = "id-anyscale-operator-${local.suffix}"
    storage_account            = substr("st${local.suffix_alt}", 0, 24)
    acr                        = substr("cr${local.suffix_alt}", 0, 50)
    flex_vnet                  = "vnet-${local.flex_suffix}"
    flex_subnet                = "snet-flex-hosts-${local.flex_suffix}"
    flex_nsg                   = "nsg-flex-hosts-${local.flex_suffix}"
    flex_host                  = "vm-flex-${local.flex_suffix}"
    flex_host_public_ip        = "pip-flex-${local.flex_suffix}"
    anyscale_gateway_public_ip = "pip-anyscale-gateway-${local.suffix}"
  }
}
