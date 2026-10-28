# Scenario: Workspace and PostgreSQL in disconnected VPCs, for building the path yourself
databricks_account_id = "00000000-0000-0000-0000-000000000000"

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

# Disposable lab: destroy may empty versioned buckets, lift database deletion
# protection, and skip final snapshots. Set false to keep data on destroy.
allow_destructive_demo_cleanup = true
