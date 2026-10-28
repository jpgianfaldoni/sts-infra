output "name" {
  value = azurerm_linux_virtual_machine.this.name
}

output "resource_group_name" {
  value = var.resource_group_name
}

output "public_ip" {
  value = azurerm_public_ip.this.ip_address
}

output "private_ip" {
  value = azurerm_linux_virtual_machine.this.private_ip_address
}

output "admin_username" {
  value = var.admin_username
}

output "password_authentication_enabled" {
  value = var.admin_ssh_public_key == null
}

output "ssh_command" {
  description = "Direct SSH command when an admin SSH public key is configured; null otherwise."
  value       = var.admin_ssh_public_key == null ? null : "ssh ${var.admin_username}@${azurerm_public_ip.this.ip_address}"
}

output "azure_cli_command" {
  value = "az ssh vm --resource-group ${var.resource_group_name} --name ${azurerm_linux_virtual_machine.this.name}"
}
