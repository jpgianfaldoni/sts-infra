output "private_ip" {
  value = azurerm_network_interface.this.private_ip_address
}

output "vm_id" {
  value = azurerm_linux_virtual_machine.this.id
}

output "verification_extension_id" {
  value = azurerm_virtual_machine_extension.verify_dns.id
}
