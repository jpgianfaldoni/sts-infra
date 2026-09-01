output "bucket_name" {
  value = aws_s3_bucket.this.bucket
}

output "sample_data_uri" {
  value = local.sample_data_uri
}

output "catalog_storage_uri" {
  value = local.catalog_storage_uri
}

output "glue_catalog_id" {
  value = data.aws_caller_identity.current.account_id
}

output "glue_database_name" {
  value = aws_glue_catalog_database.this.name
}

output "glue_table_name" {
  value = aws_glue_catalog_table.sample_orders.name
}

output "service_credential_role_arn" {
  value = aws_iam_role.service_credential.arn
}

output "storage_credential_role_arn" {
  value = aws_iam_role.storage_credential.arn
}

output "databricks_connectivity_enabled" {
  value = var.databricks_connectivity_enabled
}

output "service_credential_name" {
  value = try(databricks_credential.service[0].name, null)
}

output "storage_credential_name" {
  value = try(databricks_storage_credential.data[0].name, null)
}

output "external_location_name" {
  value = try(databricks_external_location.data[0].name, null)
}

output "connection_name" {
  value = try(databricks_connection.glue[0].name, null)
}

output "foreign_catalog_name" {
  value = try(databricks_catalog.glue[0].name, null)
}

output "service_trust_finalized" {
  value = var.databricks_connectivity_enabled || var.service_credential_external_id != "0000"
}

output "storage_trust_finalized" {
  value = var.databricks_connectivity_enabled || var.storage_credential_external_id != "0000"
}
