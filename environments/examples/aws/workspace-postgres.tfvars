databricks_account_id        = "00000000-0000-0000-0000-000000000000"
aws_profile                  = "your-aws-profile"
databricks_profile           = "your-databricks-account-profile"
databricks_workspace_profile = "your-databricks-workspace-profile"
name_prefix                  = "acme-demo"
workspace_name               = "acme-demo-classic"

features = {
  workspace     = true
  unity_catalog = true
  rds_postgres  = true
}

connectivity = {
  rds_postgres = {
    classic    = "peering"
    serverless = "none"
  }
}

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
  Owner       = "platform-team"
}
