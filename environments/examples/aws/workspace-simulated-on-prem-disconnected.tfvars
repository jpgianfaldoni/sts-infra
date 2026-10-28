# Scenario: Workspace and a simulated on-premises network without connectivity
databricks_account_id = "00000000-0000-0000-0000-000000000000"

features = {
  workspace         = true
  unity_catalog     = false
  simulated_on_prem = true
}

# The simulated on-premises VPC and test host are deployed without a route to
# the Databricks workspace VPC.
connectivity = {
  simulated_on_prem = {
    classic = "none"
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
