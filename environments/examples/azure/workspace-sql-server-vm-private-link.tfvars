# Scenario: SQL Server VM in a separate VNet, ready for Lakeflow Connect CDC and reached privately from classic and serverless compute
subscription_id       = "00000000-0000-0000-0000-000000000000"
databricks_account_id = "00000000-0000-0000-0000-000000000000"
location              = "westus2"

features = {
  workspace     = true
  sql_server_vm = true
}

# Classic compute uses peering and private DNS. Serverless compute resolves
# this exact hostname through its NCC rule to the VM's Private Link Service.
sql_server_vm = {
  workspace_peering_enabled = true
  private_dns_name          = "sqlserver.lab.exampledomain.com"
  lakeflow_connect_enabled  = true
}

connectivity = {
  sql_server_vm = {
    serverless = "private_link"
  }
}

endpoint_approval = "auto"

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
  Owner       = "platform-team"
  Scenario    = "azure-sql-server-vm-private-link"
}

# Disposable lab: resource groups can be removed even if Azure Policy adds resources.
allow_destructive_demo_cleanup = true
