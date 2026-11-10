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
output "lakeflow_username" {
  value = var.lakeflow_connect_enabled ? var.lakeflow_username : null
}
output "lakeflow_password" {
  value     = try(random_password.lakeflow[0].result, null)
  sensitive = true
}
output "lakeflow_cdc" {
  description = "Lakeflow Connect CDC source setup reported by the VM, or null when disabled."
  value = var.lakeflow_connect_enabled ? {
    database = local.lakeflow_database
    tables   = split(",", local.lakeflow_tables)
    result   = try(jsondecode(regex("LAKEFLOW_CDC_SETUP_RESULT (\\{.*\\})", azurerm_virtual_machine_run_command.lakeflow_cdc_setup[0].instance_view[0].output)[0]), null)
  } : null
}
output "hostname" {
  description = "Private hostname that resolves to SQL Server inside the SQL VNet, or null when private_dns_name is unset."
  value       = var.private_dns_name
}
output "private_dns_zone" {
  value = var.private_dns_name == null ? null : { name = local.private_dns_zone, id = azurerm_private_dns_zone.sql[0].id }
}
