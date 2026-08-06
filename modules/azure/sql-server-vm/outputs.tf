output "host" {
  value = azurerm_network_interface.vm.private_ip_address
}
output "port" {
  value = 1433
}
output "sql_username" {
  value = var.sql_admin_username
}
output "sql_password" {
  value     = random_password.sql.result
  sensitive = true
}
output "vm_username" {
  value = var.vm_admin_username
}
output "vm_password" {
  value     = random_password.vm.result
  sensitive = true
}
output "resource_group_name" {
  value = azurerm_resource_group.this.name
}
output "vnet_id" {
  value = azurerm_virtual_network.this.id
}
output "private_link_service_subnet_id" {
  value = azurerm_subnet.private_link_service.id
}
