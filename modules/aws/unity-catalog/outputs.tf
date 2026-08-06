output "metastore_id" {
  value = databricks_metastore.this.id
}
output "catalog_name" {
  value = databricks_catalog.initial.name
}
output "storage_credential_name" {
  value = databricks_storage_credential.catalog.name
}
output "external_location_name" {
  value = databricks_external_location.catalog.name
}
output "bucket_name" {
  value = aws_s3_bucket.catalog.bucket
}
