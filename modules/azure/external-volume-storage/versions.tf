terraform {
  required_version = ">= 1.11.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    databricks = {
      source                = "databricks/databricks"
      version               = "~> 1.100"
      configuration_aliases = [databricks.account, databricks.workspace]
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
