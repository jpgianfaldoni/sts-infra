# Scenario: Serverless compute reads a private RDS for MySQL database with sample data over PrivateLink, prepared for Lakeflow Connect
databricks_account_id = "00000000-0000-0000-0000-000000000000"

features = {
  workspace     = true
  unity_catalog = true
  rds_mysql     = true
}

# Serverless compute reaches MySQL through an NCC private endpoint rule to an
# internal NLB and endpoint service; ./infra accepts the connection after apply.
connectivity = {
  rds_mysql = {
    classic    = "none"
    serverless = "private_link"
  }
}

# ./infra verify loads the sample data, sets seven-day binary log retention,
# and creates the lakeflow replication user (password in Secrets Manager).
rds_mysql = {
  lakeflow_connect_enabled = true
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
