provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  features {
    resource_group {
      # Azure Policy can inject resources (for example DNS security policies)
      # into lab resource groups; disposable labs may delete them with the group.
      prevent_deletion_if_contains_resources = !var.allow_destructive_demo_cleanup
    }
  }
}

provider "azurerm" {
  alias           = "storage_control_plane"
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  features {
    resource_group {
      prevent_deletion_if_contains_resources = !var.allow_destructive_demo_cleanup
    }
    storage {
      # Storage containers are managed through ARM/AzAPI in this deployment.
      # Avoid shared-key data-plane probes because shared keys are disabled.
      data_plane_available = false
    }
  }
}

provider "azapi" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}

# Used only to look up the AzureDatabricks first-party service principal for
# Key Vault-backed secret scopes.
provider "azuread" {
  tenant_id = var.tenant_id
}

# Without a profile, both Databricks providers authenticate with the same Azure
# identity as azurerm (./infra selects azure-cli for local sessions), so a
# single `az login` covers account- and workspace-level resources.
provider "databricks" {
  alias           = "account"
  host            = "https://accounts.azuredatabricks.net"
  account_id      = var.databricks_account_id
  profile         = var.databricks_account_profile
  auth_type       = var.databricks_account_profile == null ? var.databricks_auth_type : null
  azure_tenant_id = var.databricks_account_profile == null ? var.tenant_id : null
}

provider "databricks" {
  alias                       = "workspace"
  host                        = try(module.workspace[0].workspace_url, "https://workspace-not-created.invalid")
  azure_workspace_resource_id = try(module.workspace[0].azure_resource_id, null)
  profile                     = var.databricks_workspace_profile
  auth_type                   = var.databricks_workspace_profile == null ? var.databricks_auth_type : null
  azure_tenant_id             = var.databricks_workspace_profile == null ? var.tenant_id : null
}
