output "id" {
  value = azurerm_key_vault.this.id
}

output "name" {
  value = azurerm_key_vault.this.name
}

output "uri" {
  value = azurerm_key_vault.this.vault_uri
}

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "secret_names" {
  value = var.secret_names
}

output "databricks_secret_scope" {
  value = try(databricks_secret_scope.this[0].name, null)
}
