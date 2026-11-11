# Scenario: Serverless compute reads a private RDS for Oracle database with sample data over PrivateLink, prepared for Lakeflow Connect
databricks_account_id = "00000000-0000-0000-0000-000000000000"

features = {
  workspace     = true
  unity_catalog = true
  rds_oracle    = true
}

# Serverless compute reaches Oracle through an NCC private endpoint rule to an
# internal NLB and endpoint service; ./infra accepts the connection after apply.
connectivity = {
  rds_oracle = {
    classic    = "none"
    serverless = "private_link"
  }
}

# Non-multitenant Standard Edition 2, license-included. ./infra verify loads the
# sample data into the LAB schema, turns on supplemental logging and 48-hour
# archive log retention, and creates the LAKEFLOW user with the Databricks
# Oracle setup package (password in Secrets Manager).
rds_oracle = {
  engine                   = "oracle-se2"
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
