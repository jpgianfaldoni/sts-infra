# Scenario: SQL Server VM in a separate VNet, reached from classic compute through VNet peering and from serverless compute through a private network gateway
subscription_id       = "00000000-0000-0000-0000-000000000000"
databricks_account_id = "00000000-0000-0000-0000-000000000000"
location              = "westus2"

features = {
  workspace     = true
  sql_server_vm = true
}

# Classic compute runs in the workspace VNet and uses the peering and the
# linked private DNS zone. Serverless compute enters the same VNet through the
# private network gateway, then follows the same peering to the VM.
sql_server_vm = {
  workspace_peering_enabled = true
  private_dns_name          = "sqlserver.lab.exampledomain.com"
  lakeflow_connect_enabled  = true
}

connectivity = {
  sql_server_vm = {
    serverless = "private_network_gateway"
  }
}

# Public Preview. Databricks bills the gateway by bandwidth tier (10, 30, 50,
# or 100 Gbps) while it exists; the subnet is workspace_network.gateway_subnet_cidr.
private_network_gateway = {
  bandwidth_tier_gbps = 10
}

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
  Owner       = "platform-team"
  Scenario    = "azure-sql-server-vm-private-network-gateway"
}

# Disposable lab: resource groups can be removed even if Azure Policy adds resources.
allow_destructive_demo_cleanup = true
