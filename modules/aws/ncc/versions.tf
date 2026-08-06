terraform {
  required_version = ">= 1.6.0"
  required_providers {
    databricks = {
      source                = "databricks/databricks"
      version               = "~> 1.100"
      configuration_aliases = [databricks.mws]
    }
  }
}
