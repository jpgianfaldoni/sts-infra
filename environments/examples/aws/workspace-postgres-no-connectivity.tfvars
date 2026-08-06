databricks_account_id = "00000000-0000-0000-0000-000000000000"
aws_profile           = "your-aws-profile"
databricks_profile    = "your-databricks-account-profile"
name_prefix           = "acme-isolated"
workspace_name        = "acme-isolated-classic"

features = {
  workspace     = true
  unity_catalog = false
  rds_postgres  = true
}

# The workspace and PostgreSQL instance are created in different VPCs with no
# routes, interface endpoints, endpoint service, or NCC between them.
connectivity = {
  rds_postgres = {
    classic    = "none"
    serverless = "none"
  }
}

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
  Owner       = "platform-team"
}
