# Scenario: VNet-injected workspace and a private Azure SQL database without a compute path
subscription_id = "00000000-0000-0000-0000-000000000000"

features = {
  workspace    = true
  sql_database = true
}

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
  Owner       = "platform-team"
}

# Disposable lab: destroy may empty versioned buckets, lift database deletion
# protection, and skip final snapshots. Set false to keep data on destroy.
allow_destructive_demo_cleanup = true
