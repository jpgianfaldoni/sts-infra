# Scenario: Workspace and a MySQL VM prepared for Lakeflow Connect from inside the VM, with no network path between them
subscription_id       = "00000000-0000-0000-0000-000000000000"
databricks_account_id = "00000000-0000-0000-0000-000000000000"
location              = "westus2"

# The VNet-injected workspace also runs serverless compute. The MySQL VM lives
# in its own VNet with no peering, private endpoint, or public address.
features = {
  workspace = true
  mysql_vm  = true
}

# Azure VM Run Command prepares MySQL from inside the VM: row-based binary
# logging with seven-day retention, the sample tables in the demo database,
# and a lakeflow replication user (password in Key Vault).
mysql_vm = {
  lakeflow_connect_enabled = true
  # Hostname for the Unity Catalog connection; resolves inside the VM's VNet.
  private_dns_name = "mysql.lab.internal"
}

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
  Owner       = "platform-team"
  Scenario    = "azure-mysql-vm-lakeflow-cdc"
}

# Disposable lab: destroy may empty versioned buckets, lift database deletion
# protection, and skip final snapshots. Set false to keep data on destroy.
allow_destructive_demo_cleanup = true
