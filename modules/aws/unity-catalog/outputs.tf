output "metastore_id" {
  value = local.metastore_id
}
output "auto_metastore_conflicts" {
  description = "Names of the regional metastores auto mode could not choose between; empty unless the choice is ambiguous."
  value       = local.auto_metastore_ambiguous ? sort(keys(local.regional_metastores)) : []
}
output "metastore_created" {
  description = "True when this module manages the metastore; false when it assigns an existing one."
  value       = local.create_metastore
}
output "metastore_assignment_id" {
  value = databricks_metastore_assignment.this.id
}
output "catalog_name" {
  value = try(databricks_catalog.initial[0].name, null)
}
output "storage_credential_name" {
  value = try(databricks_storage_credential.catalog[0].name, null)
}
output "external_location_name" {
  value = try(databricks_external_location.catalog[0].name, null)
}
output "bucket_name" {
  value = try(aws_s3_bucket.catalog[0].bucket, null)
}
