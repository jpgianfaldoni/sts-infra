subscription_id       = "00000000-0000-0000-0000-000000000000"
databricks_account_id = "00000000-0000-0000-0000-000000000000"
location              = "westus2"

features = {
  workspace               = true
  external_volume_storage = true
}

external_volume_storage = {
  public_network_access_enabled = false
  allow_unreachable_storage     = true
  container_name                = "external-volume"
  catalog_name                  = "azure_storage_demo"
  schema_name                   = "demo"
  volume_name                   = "private_json"
  volume_storage_path           = "volume"
  # auto reuses the only metastore in the region, or creates one when there is none.
  metastore_mode = "auto"
}

tags = {
  ManagedBy   = "terraform"
  Environment = "demo"
  Owner       = "platform-team"
}
