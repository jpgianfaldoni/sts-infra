output "host" {
  value = var.vm_private_ip
}
output "hostname" {
  value = var.private_dns_name
}
output "port" {
  value = 3306
}
output "database_name" {
  value = local.database_name
}
output "mysql_username" {
  value = var.mysql_admin_username
}
output "mysql_password" {
  value     = random_password.mysql.result
  sensitive = true
}
output "vm_username" {
  value = var.vm_admin_username
}
output "vm_password" {
  value     = random_password.vm.result
  sensitive = true
}
output "lakeflow_username" {
  value = var.lakeflow_connect_enabled ? "lakeflow" : null
}
output "lakeflow_password" {
  value     = try(random_password.lakeflow[0].result, null)
  sensitive = true
}
output "resource_group_name" {
  value = azurerm_resource_group.this.name
}
output "vm_name" {
  value = azurerm_linux_virtual_machine.mysql.name
}
output "vnet_id" {
  value = azurerm_virtual_network.this.id
}
output "setup" {
  description = "What the setup reported from inside the VM."
  value       = try(jsondecode(regex("LAKEFLOW_CDC_SETUP_RESULT (\\{.*\\})", azurerm_virtual_machine_run_command.setup.instance_view[0].output)[0]), null)
}
