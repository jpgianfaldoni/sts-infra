databricks_account_id = "00000000-0000-0000-0000-000000000000"

features = {
  workspace       = true
  unity_catalog   = true
  rds_postgres    = true
  rds_sql_server  = true
  aurora_postgres = true
  aurora_proxy    = true
  rabbitmq        = true
  kafka           = true
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
  kafka = {
    classic    = "private_link"
    serverless = "private_link"
  }
}

# Broker passwords are written only to Secrets Manager and never stored in state.
kafka = {
  ephemeral_credentials = true
}
rabbitmq = {
  ephemeral_credentials = true
}

# Disposable environments only. This enables force-delete and skips final snapshots.
allow_destructive_demo_cleanup = true

# Reuse the account's metastore in the region when one exists; otherwise create one.
unity_catalog = {
  metastore_mode = "auto"
}
