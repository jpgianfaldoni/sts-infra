# Scenario: Serverless compute reads a private Azure SQL database with sample data over Private Link
subscription_id       = "00000000-0000-0000-0000-000000000000"
databricks_account_id = "00000000-0000-0000-0000-000000000000"
location              = "westus2"

features = {
  workspace    = true
  sql_database = true
}

# Serverless compute reaches Azure SQL through an NCC private endpoint rule;
# ./infra approves the Databricks-managed endpoint after apply.
connectivity = {
  sql_database = {
    serverless = "private_link"
  }
}

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
  Owner       = "platform-team"
  Scenario    = "azure-serverless-sql"
}

# Disposable lab: destroy may empty versioned buckets, lift database deletion
# protection, and skip final snapshots. Set false to keep data on destroy.
allow_destructive_demo_cleanup = true
