terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    databricks = {
      source                = "databricks/databricks"
      version               = "~> 1.100"
      configuration_aliases = [databricks.workspace]
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
