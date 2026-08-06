mock_provider "azurerm" {}
mock_provider "random" {}

run "all_features_disabled" {
  command = plan
  variables {
    subscription_id = "00000000-0000-0000-0000-000000000000"
    features = {
      workspace     = false
      sql_database  = false
      sql_server_vm = false
    }
  }
  assert {
    condition     = output.workspace_url == null
    error_message = "The workspace must not be composed when its feature is disabled."
  }
}
