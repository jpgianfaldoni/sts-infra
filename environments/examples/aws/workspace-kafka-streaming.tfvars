# Scenario: Kafka streaming from classic compute (peering) and serverless compute (PrivateLink)
databricks_account_id = "00000000-0000-0000-0000-000000000000"

features = {
  workspace       = true
  unity_catalog   = true
  rds_postgres    = false
  rds_sql_server  = false
  aurora_postgres = false
  aurora_proxy    = false
  rabbitmq        = false
  kafka           = true
}

# Classic compute uses the direct routed listener. Serverless compute uses the
# broker's NLB listener through an NCC-managed private endpoint.
connectivity = {
  kafka = {
    classic    = "peering"
    serverless = "private_link"
  }
}

kafka = {
  topic_name                = "demo-events"
  producer_interval_seconds = 1
  # The broker password is written only to Secrets Manager, never to state.
  ephemeral_credentials = true
}

allow_destructive_demo_cleanup = true

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
}

# Reuse the account's metastore in the region when one exists; otherwise create one.
unity_catalog = {
  metastore_mode = "auto"
}
