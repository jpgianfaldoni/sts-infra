output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "vnet_name" {
  value = azurerm_virtual_network.this.name
}

output "host_subnet_name" {
  value = azurerm_subnet.host.name
}

output "container_subnet_name" {
  value = azurerm_subnet.container.name
}

output "host_nsg_association_id" {
  value = azurerm_subnet_network_security_group_association.host.id
}

output "container_nsg_association_id" {
  value = azurerm_subnet_network_security_group_association.container.id
}

output "private_endpoint_subnet_id" {
  value = azurerm_subnet.private_endpoint.id
}

output "dns_subnet_id" {
  value = azurerm_subnet.dns.id
}

output "dns_nat_association_id" {
  value = azurerm_subnet_nat_gateway_association.dns.id
}
