output "workspace_id" {
  value = azurerm_databricks_workspace.this.workspace_id
}
output "workspace_url" {
  value = "https://${azurerm_databricks_workspace.this.workspace_url}"
}
output "resource_group_name" {
  value = azurerm_resource_group.this.name
}
output "vnet_id" {
  value = azurerm_virtual_network.this.id
}
output "backend_private_endpoint_id" {
  value = azurerm_private_endpoint.backend.id
}
