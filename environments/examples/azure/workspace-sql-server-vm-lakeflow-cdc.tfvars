# Scenario: Workspace and a SQL Server VM prepared for Lakeflow Connect CDC from inside the VM, with no network path between them
subscription_id       = "00000000-0000-0000-0000-000000000000"
databricks_account_id = "00000000-0000-0000-0000-000000000000"
location              = "westus2"

# The VNet-injected workspace also runs serverless compute. The SQL Server VM
# lives in its own VNet with no peering, private endpoint, or public address.
features = {
  workspace     = true
  sql_server_vm = true
}

# Azure VM Run Command prepares the source from inside the VM: sample tables
# in the demo database, SQL Server Agent, a dedicated ingestion login (password
# in Key Vault), the Lakeflow Connect utility objects, and CDC on
# dbo.customers and dbo.orders. Setup needs no network path to the database.
sql_server_vm = {
  lakeflow_connect_enabled = true
}

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
  Owner       = "platform-team"
  Scenario    = "azure-sql-server-vm-lakeflow-cdc"
}

# Disposable lab: destroy may empty versioned buckets, lift database deletion
# protection, and skip final snapshots. Set false to keep data on destroy.
allow_destructive_demo_cleanup = true
