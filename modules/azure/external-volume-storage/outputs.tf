output "storage_account_name" {
  value = azurerm_storage_account.this.name
}

output "metastore_id" {
  value = local.metastore_id
}

output "container_name" {
  value = var.container_name
}

output "public_network_access_enabled" {
  value = azurerm_storage_account.this.public_network_access_enabled
}

output "bootstrap_access_enabled" {
  value = var.bootstrap_access_enabled
}

output "connectivity_status" {
  value = var.bootstrap_access_enabled ? "bootstrap" : (var.public_network_access_enabled ? "public" : "metadata_only")
}

output "external_location_url" {
  value = local.external_location_url
}

output "metastore_mode" {
  value = var.metastore_mode
}

output "metastore_resolution" {
  description = "create, existing, or for auto mode the decision taken: create (none, or the managed metastore, in the region), reuse (exactly one other), or ambiguous (several others; nothing is assigned)."
  value       = var.metastore_mode == "auto" ? local.auto_metastore_decision : var.metastore_mode
}

output "other_regional_metastore_count" {
  description = "Metastores in the workspace region other than the managed one (auto mode only)."
  value       = length(local.other_regional_metastore_ids)
}

output "metastore_created" {
  description = "Whether this deployment manages its own metastore (create mode, or auto mode when the region had none)."
  value       = local.create_metastore
}

output "external_location_name" {
  value = databricks_external_location.this.name
}

output "volume_path" {
  value = databricks_volume.this.volume_path
}
