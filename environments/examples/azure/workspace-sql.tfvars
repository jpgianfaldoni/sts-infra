subscription_id = "00000000-0000-0000-0000-000000000000"
name_prefix     = "acme-demo"
workspace_name  = "acme-demo-azure-classic"

features = {
  workspace    = true
  sql_database = true
}

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
  Owner       = "platform-team"
}
