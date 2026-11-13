# Scenario: Serverless compute reads a private Azure Database for MySQL with sample data over Private Link, prepared for Lakeflow Connect
subscription_id       = "00000000-0000-0000-0000-000000000000"
databricks_account_id = "00000000-0000-0000-0000-000000000000"
location              = "westus2"

features = {
  workspace             = true
  mysql_flexible_server = true
}

# Serverless compute reaches the flexible server through an NCC private
# endpoint rule; ./infra approves the Databricks-managed endpoint after apply.
connectivity = {
  mysql_flexible_server = {
    serverless = "private_link"
  }
}

# Seven-day binary log retention and full row images. ./infra verify loads the
# sample data and creates the lakeflow replication user (password in Key Vault).
mysql_flexible_server = {
  lakeflow_connect_enabled = true
}

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
  Owner       = "platform-team"
  Scenario    = "azure-serverless-mysql"
}

# Disposable lab: destroy may empty versioned buckets, lift database deletion
# protection, and skip final snapshots. Set false to keep data on destroy.
allow_destructive_demo_cleanup = true
