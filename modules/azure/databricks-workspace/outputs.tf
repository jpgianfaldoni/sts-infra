output "workspace_id" {
  value = azurerm_databricks_workspace.this.workspace_id
}
output "workspace_url" {
  value = "https://${azurerm_databricks_workspace.this.workspace_url}"
}
output "azure_resource_id" {
  value = azurerm_databricks_workspace.this.id
}
output "resource_group_name" {
  value = var.resource_group_name
}
output "vnet_id" {
  value = var.vnet_id
}
output "backend_private_endpoint_id" {
  description = "Deprecated alias of ui_api_private_endpoint_id; removed in the next release."
  value       = azurerm_private_endpoint.backend.id
}

output "ui_api_private_endpoint_id" {
  description = "The databricks_ui_api private endpoint, created with every workspace. It carries front-end (UI/API) and back-end traffic."
  value       = azurerm_private_endpoint.backend.id
}

output "browser_authentication_enabled" {
  value = var.browser_authentication_enabled
}

output "browser_authentication_private_endpoint_id" {
  value = try(azurerm_private_endpoint.browser_authentication[0].id, null)
}

output "public_network_access_enabled" {
  value = azurerm_databricks_workspace.this.public_network_access_enabled
}
