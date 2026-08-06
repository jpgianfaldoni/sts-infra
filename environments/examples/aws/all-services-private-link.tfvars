databricks_account_id        = "00000000-0000-0000-0000-000000000000"
aws_profile                  = "your-aws-profile"
databricks_profile           = "your-databricks-account-profile"
databricks_workspace_profile = "your-databricks-workspace-profile"
name_prefix                  = "acme-lab"
workspace_name               = "acme-lab-classic"

features = {
  workspace       = true
  unity_catalog   = true
  rds_postgres    = true
  rds_sql_server  = true
  aurora_postgres = true
  aurora_proxy    = true
  rabbitmq        = true
}

connectivity = {
  rds_postgres = {
    classic    = "private_link"
    serverless = "private_link"
  }
  rds_sql_server = {
    classic    = "private_link"
    serverless = "private_link"
  }
  aurora_postgres = {
    classic    = "private_link"
    serverless = "private_link"
  }
  rabbitmq = {
    classic    = "private_link"
    serverless = "private_link"
  }
}

# Disposable environments only. This enables force-delete and skips final snapshots.
allow_destructive_demo_cleanup = true
