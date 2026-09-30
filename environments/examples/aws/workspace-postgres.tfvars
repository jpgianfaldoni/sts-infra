databricks_account_id = "00000000-0000-0000-0000-000000000000"

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

# Reuse the account's metastore in the region when one exists; otherwise create one.
unity_catalog = {
  metastore_mode = "auto"
}
