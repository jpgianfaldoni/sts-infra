output "host" {
  value = var.vm_private_ip
}
output "hostname" {
  value = var.private_dns_name
}
output "port" {
  value = 1521
}
output "cdb_service_name" {
  description = "CDB$ROOT service name, which the Lakeflow Connect connection uses."
  value       = local.cdb_service
}
output "pdb_service_name" {
  description = "Pluggable database holding the LAB sample schema."
  value       = local.pdb_service
}
output "oracle_username" {
  description = "Administrator; the same password is set for SYS, SYSTEM, and PDBADMIN."
  value       = "SYSTEM"
}
output "oracle_password" {
  value     = random_password.oracle.result
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
  value = var.lakeflow_connect_enabled ? "C##LAKEFLOW" : null
}
output "lakeflow_password" {
  value     = try(random_password.lakeflow[0].result, null)
  sensitive = true
}
output "resource_group_name" {
  value = azurerm_resource_group.this.name
}
output "vm_name" {
  value = azurerm_linux_virtual_machine.oracle.name
}
output "vnet_id" {
  value = azurerm_virtual_network.this.id
}
output "setup" {
  description = "What the setup reported from inside the VM."
  value       = try(jsondecode(regex("LAKEFLOW_CDC_SETUP_RESULT (\\{.*\\})", azurerm_virtual_machine_run_command.setup.instance_view[0].output)[0]), null)
}
