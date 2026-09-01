databricks_account_id = "00000000-0000-0000-0000-000000000000"
name_prefix           = "acme-glue-test"
workspace_name        = "unused-for-aws-only-glue-test"

features = {
  workspace       = false
  unity_catalog   = false
  glue_federation = true
}

# AWS-only mode is the default. It creates S3, sample data, Glue metadata, and
# IAM roles without creating anything in Databricks. For a manual Databricks
# setup, keep the external IDs at 0000 for the first apply, create the service
# and storage credentials with validation skipped, then set their generated
# external IDs here and apply again to finalize both role trust policies.
glue_federation = {
  databricks_connectivity_enabled = false
  service_credential_external_id  = "0000"
  storage_credential_external_id  = "0000"
}

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
  Purpose     = "glue-federation"
}
