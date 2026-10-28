subscription_id       = "00000000-0000-0000-0000-000000000000"
databricks_account_id = "00000000-0000-0000-0000-000000000000"
location              = "westus2"

features = {
  workspace    = true
  test_vm      = true
  sql_database = true
}

# Serverless compute reaches Azure SQL through an NCC private endpoint rule.
# Approve the Databricks-managed endpoint with ./infra endpoints azure approve.
connectivity = {
  sql_database = {
    serverless = "private_link"
  }
}

# Classic compute and the test VM reach the server over VNet peering.
sql_database = {
  workspace_peering_enabled = true
}

test_vm = {
  # Restrict this to the public IPv4 address from which you will run Azure CLI.
  allowed_ssh_source_cidr = "203.0.113.10/32"
}

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
  Owner       = "platform-team"
  Scenario    = "azure-sql-serverless-private-link"
}
