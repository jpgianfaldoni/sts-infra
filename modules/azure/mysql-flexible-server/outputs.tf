output "host" {
  value = azurerm_mysql_flexible_server.this.fqdn
}
output "port" {
  value = 3306
}
output "database_name" {
  value = azurerm_mysql_flexible_database.this.name
}
output "admin_username" {
  value = azurerm_mysql_flexible_server.this.administrator_login
}
output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}
output "lakeflow_username" {
  value = var.lakeflow_connect_enabled ? "lakeflow" : null
}
output "lakeflow_password" {
  value     = try(random_password.lakeflow[0].result, null)
  sensitive = true
}
output "server_id" {
  description = "ARM ID of the flexible server, used as the NCC private endpoint target."
  value       = azurerm_mysql_flexible_server.this.id
}
output "resource_group_name" {
  value = azurerm_resource_group.this.name
}
output "vnet_id" {
  value = azurerm_virtual_network.this.id
}
output "vnet_name" {
  value = azurerm_virtual_network.this.name
}
output "private_dns_zone_name" {
  value = azurerm_private_dns_zone.mysql.name
}
output "seed_file" {
  description = "Idempotent sample-data script that the lab check job runs."
  value       = "${path.module}/assets/seed.sql"
}
