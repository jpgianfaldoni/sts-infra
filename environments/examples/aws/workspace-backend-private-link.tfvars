# Scenario: Classic workspace whose compute reaches the control plane over back-end PrivateLink
databricks_account_id = "00000000-0000-0000-0000-000000000000"

features = {
  workspace     = true
  unity_catalog = false
}

workspace_network = {
  vpc_cidr             = "10.40.0.0/18"
  private_subnet_cidrs = ["10.40.0.0/20", "10.40.16.0/20"]
  public_subnet_cidr   = "10.40.32.0/24"
}

# Back-end control-plane traffic uses PrivateLink. Public access remains on so
# users can reach the workspace UI and APIs without a separate front-end VPC.
workspace_backend_private_link = {
  enabled               = true
  endpoint_subnet_cidrs = ["10.40.34.0/27", "10.40.34.32/27"]
  public_access_enabled = true
}

# Disposable lab: destroy may empty versioned buckets, lift database deletion
# protection, and skip final snapshots. Set false to keep data on destroy.
allow_destructive_demo_cleanup = true
