databricks_account_id = "00000000-0000-0000-0000-000000000000"
name_prefix           = "acme-hybrid-lab"
workspace_name        = "acme-hybrid-lab-classic"

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
