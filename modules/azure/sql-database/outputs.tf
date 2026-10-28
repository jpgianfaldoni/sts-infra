output "host" {
  value = azurerm_mssql_server.this.fully_qualified_domain_name
}
output "port" {
  value = 1433
}
output "database_name" {
  value = azurerm_mssql_database.this.name
}
output "admin_username" {
  value = azurerm_mssql_server.this.administrator_login
}
output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}
output "resource_group_name" {
  value = azurerm_resource_group.this.name
}
output "private_endpoint_id" {
  value = azurerm_private_endpoint.sql.id
}
output "server_id" {
  description = "ARM ID of the Azure SQL logical server, used as the NCC private endpoint target."
  value       = azurerm_mssql_server.this.id
}
output "server_name" {
  value = azurerm_mssql_server.this.name
}
output "vnet_id" {
  value = azurerm_virtual_network.this.id
}
output "vnet_name" {
  value = azurerm_virtual_network.this.name
}
output "private_dns_zone_name" {
  value = azurerm_private_dns_zone.sql.name
}
output "entra_admin_object_id" {
  value = try(var.entra_admin.object_id, null)
}
