resource "azurerm_virtual_network_peering" "local_to_remote" {
  name                         = "${var.name}-to-remote"
  resource_group_name          = var.local_vnet.resource_group_name
  virtual_network_name         = var.local_vnet.name
  remote_virtual_network_id    = var.remote_vnet.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
}

resource "azurerm_virtual_network_peering" "remote_to_local" {
  name                         = "${var.name}-to-local"
  resource_group_name          = var.remote_vnet.resource_group_name
  virtual_network_name         = var.remote_vnet.name
  remote_virtual_network_id    = var.local_vnet.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
}

# Private DNS zones are linked explicitly: peering alone does not make a zone
# linked to one VNet resolvable from the other.
resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = var.private_dns_zone_links

  name                  = "${var.name}-${each.key}-dns"
  resource_group_name   = each.value.resource_group_name
  private_dns_zone_name = each.value.private_dns_zone_name
  virtual_network_id    = each.value.virtual_network_id
  tags                  = var.tags
}
