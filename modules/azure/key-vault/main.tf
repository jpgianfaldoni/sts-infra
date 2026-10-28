resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  # Key Vault names: 3-24 characters, letters, digits, and single hyphens,
  # starting with a letter.
  name_stem = trim(substr(replace(replace(lower(var.name_prefix), "/[^0-9a-z-]/", "-"), "/-+/", "-"), 0, 13), "-")
  name      = "kv-${local.name_stem == "" ? "sts" : local.name_stem}-${random_string.suffix.result}"
}

resource "azurerm_resource_group" "this" {
  name     = "${var.name_prefix}-secrets-rg"
  location = var.location
  tags     = var.tags
}

# RBAC-mode vault. Public network access stays enabled so Terraform on the
# operator machine can write secrets; access is controlled by Entra RBAC.
resource "azurerm_key_vault" "this" {
  name                          = local.name
  location                      = var.location
  resource_group_name           = azurerm_resource_group.this.name
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = false
  soft_delete_retention_days    = 7
  public_network_access_enabled = true
  tags                          = var.tags
}

resource "azurerm_role_assignment" "operator" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.operator_object_id
}

# New data-plane role assignments take a short time to become effective.
resource "time_sleep" "rbac_propagation" {
  create_duration = "60s"

  triggers = {
    role_assignment_id = azurerm_role_assignment.operator.id
  }
}

resource "azurerm_key_vault_secret" "this" {
  for_each = toset(var.secret_names)

  name         = each.key
  value        = var.secrets[each.key]
  key_vault_id = azurerm_key_vault.this.id
  content_type = "text/plain"
  tags         = var.tags

  depends_on = [time_sleep.rbac_propagation]
}

# The AzureDatabricks first-party application reads Key Vault-backed secret
# scopes on behalf of the workspace.
data "azuread_service_principal" "azure_databricks" {
  count     = var.databricks_secret_scope_enabled ? 1 : 0
  client_id = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
}

resource "azurerm_role_assignment" "azure_databricks" {
  count = var.databricks_secret_scope_enabled ? 1 : 0

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = data.azuread_service_principal.azure_databricks[0].object_id
}

resource "databricks_secret_scope" "this" {
  count    = var.databricks_secret_scope_enabled ? 1 : 0
  provider = databricks.workspace

  name = var.secret_scope_name

  keyvault_metadata {
    resource_id = azurerm_key_vault.this.id
    dns_name    = azurerm_key_vault.this.vault_uri
  }

  depends_on = [azurerm_role_assignment.azure_databricks]
}
