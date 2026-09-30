terraform {
  required_version = ">= 1.11.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = { source = "Azure/azapi"
      version = "~> 2.0"
    }
    azuread = { source = "hashicorp/azuread"
      version = "~> 3.0"
    }
    databricks = { source = "databricks/databricks"
      version = "~> 1.100"
    }
    random = { source = "hashicorp/random"
      version = "~> 3.6"
    }
    # Used for Key Vault RBAC propagation and retained for the former storage RBAC sleep.
    time = { source = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
