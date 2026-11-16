output "id" {
  value = azurerm_private_link_service.this.id
}
output "frontend_ip" {
  value = azurerm_lb.this.frontend_ip_configuration[0].private_ip_address
}
