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
