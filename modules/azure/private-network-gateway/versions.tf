terraform {
  required_version = ">= 1.11.0"
  required_providers {
    databricks = {
      source = "databricks/databricks"
      # databricks_private_network_gateway first shipped in 1.137.0.
      version               = "~> 1.137"
      configuration_aliases = [databricks.account]
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
