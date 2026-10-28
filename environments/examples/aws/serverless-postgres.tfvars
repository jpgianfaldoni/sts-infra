# Scenario: Serverless compute reads a private PostgreSQL database with sample data over PrivateLink
databricks_account_id = "00000000-0000-0000-0000-000000000000"

features = {
  workspace     = true
  unity_catalog = true
  rds_postgres  = true
}

# Serverless compute reaches PostgreSQL through an NCC private endpoint rule to
# an internal NLB and endpoint service; ./infra accepts the connection after apply.
connectivity = {
  rds_postgres = {
    classic    = "none"
    serverless = "private_link"
  }
}

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
  Owner       = "platform-team"
}

unity_catalog = {
  metastore_mode = "auto"
}

# Disposable lab: destroy may empty versioned buckets, lift database deletion
# protection, and skip final snapshots. Set false to keep data on destroy.
allow_destructive_demo_cleanup = true
