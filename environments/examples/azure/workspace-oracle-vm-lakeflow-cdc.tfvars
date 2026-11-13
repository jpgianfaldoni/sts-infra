# Scenario: Workspace and an Oracle Database Free VM prepared for Lakeflow Connect from inside the VM, with no network path between them
subscription_id       = "00000000-0000-0000-0000-000000000000"
databricks_account_id = "00000000-0000-0000-0000-000000000000"
location              = "westus2"

# The VNet-injected workspace also runs serverless compute. The Oracle VM lives
# in its own VNet with no peering, private endpoint, or public address.
features = {
  workspace = true
  oracle_vm = true
}

# Azure VM Run Command installs Oracle Database Free 23ai and prepares it from
# inside the VM: ARCHIVELOG mode, supplemental logging, the sample tables in
# FREEPDB1, and a C##LAKEFLOW common user created with the Databricks Oracle
# setup package (password in Key Vault). Setup takes 20 to 40 minutes.
oracle_vm = {
  lakeflow_connect_enabled = true
  # Hostname for the Unity Catalog connection; resolves inside the VM's VNet.
  private_dns_name = "oracle.lab.internal"
}

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
  Owner       = "platform-team"
  Scenario    = "azure-oracle-vm-lakeflow-cdc"
}

# Disposable lab: destroy may empty versioned buckets, lift database deletion
# protection, and skip final snapshots. Set false to keep data on destroy.
allow_destructive_demo_cleanup = true
