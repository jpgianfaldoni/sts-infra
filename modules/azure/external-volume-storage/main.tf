resource "random_string" "storage_suffix" {
  length  = 8
  upper   = false
  special = false
}

locals {
  storage_name_prefix    = substr(replace(lower(var.resource_prefix), "/[^0-9a-z]/", ""), 0, 16)
  storage_account_name   = "${local.storage_name_prefix}${random_string.storage_suffix.result}"
  external_location_url  = "abfss://${var.container_name}@${azurerm_storage_account.this.name}.dfs.core.windows.net"
  volume_storage_url     = "${local.external_location_url}/${var.volume_storage_path}"
  managed_metastore_name = "${var.resource_prefix}-metastore"
}

# metastore_mode = "auto" resolves the metastore from the account's metastores
# in the workspace region (only names and regions are compared):
#   1. this configuration's managed metastore exists there -> keep managing it;
#   2. otherwise exactly one other metastore exists -> reuse it;
#   3. otherwise none exists -> create the managed metastore;
#   4. otherwise (several others) -> fail and ask for an explicit choice.
data "databricks_metastores" "all" {
  count    = var.metastore_mode == "auto" ? 1 : 0
  provider = databricks.account
}

data "databricks_metastore" "candidate" {
  for_each = var.metastore_mode == "auto" ? try(data.databricks_metastores.all[0].ids, {}) : {}
  provider = databricks.account

  metastore_id = each.value
}

locals {
  normalized_location = lower(replace(var.location, " ", ""))
  regional_metastores = {
    for name, metastore in data.databricks_metastore.candidate : name => metastore.metastore_id
    if lower(replace(try(metastore.metastore_info[0].region, metastore.region, ""), " ", "")) == local.normalized_location
  }
  managed_metastore_in_region = contains(keys(local.regional_metastores), local.managed_metastore_name)
  other_regional_metastore_ids = sort([
    for name, id in local.regional_metastores : id if name != local.managed_metastore_name
  ])
  auto_metastore_decision = (
    local.managed_metastore_in_region ? "create" :
    length(local.other_regional_metastore_ids) == 1 ? "reuse" :
    length(local.other_regional_metastore_ids) == 0 ? "create" :
    "ambiguous"
  )
  create_metastore = var.metastore_mode == "create" || (var.metastore_mode == "auto" && local.auto_metastore_decision == "create")
  metastore_id = (
    local.create_metastore ? databricks_metastore.this[0].id :
    var.metastore_mode == "existing" ? var.existing_metastore_id :
    local.auto_metastore_decision == "reuse" ? local.other_regional_metastore_ids[0] :
    null
  )
}

resource "azurerm_storage_account" "this" {
  name                            = local.storage_account_name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  is_hns_enabled                  = true
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = var.public_network_access_enabled || var.bootstrap_access_enabled
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  tags                            = var.tags

  network_rules {
    default_action = var.bootstrap_access_enabled ? "Deny" : "Allow"
    bypass         = ["None"]
    # AzureRM represents a single-host storage rule as a bare IPv4 address,
    # even though the CLI workflow records the restriction as a /32 CIDR.
    ip_rules = var.bootstrap_access_enabled ? [split("/", var.bootstrap_operator_cidr)[0]] : []
  }
}

resource "azapi_resource" "container" {
  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01"
  name      = var.container_name
  parent_id = "${azurerm_storage_account.this.id}/blobServices/default"

  body = {
    properties = {
      publicAccess = "None"
    }
  }
}

resource "azurerm_databricks_access_connector" "this" {
  name                = "${var.resource_prefix}-access-connector"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "access_connector_storage" {
  scope                            = azurerm_storage_account.this.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = azurerm_databricks_access_connector.this.identity[0].principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "seed_operator_storage" {
  count = var.bootstrap_access_enabled ? 1 : 0

  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.seed_principal_object_id
}

resource "databricks_metastore" "this" {
  count    = local.create_metastore ? 1 : 0
  provider = databricks.account

  name          = local.managed_metastore_name
  region        = var.location
  force_destroy = var.allow_force_destroy
}

moved {
  from = databricks_metastore.this
  to   = databricks_metastore.this[0]
}

# When auto mode finds several metastores in the region nothing is assigned;
# the root external_volume_storage output then fails the plan with guidance.
resource "databricks_metastore_assignment" "this" {
  count    = var.metastore_mode == "auto" && local.auto_metastore_decision == "ambiguous" ? 0 : 1
  provider = databricks.account

  workspace_id = tonumber(var.workspace_id)
  metastore_id = local.metastore_id
}

moved {
  from = databricks_metastore_assignment.this
  to   = databricks_metastore_assignment.this[0]
}

resource "databricks_storage_credential" "this" {
  provider = databricks.workspace

  name            = "${var.resource_prefix}_azure_storage"
  comment         = "Azure managed identity credential managed by Terraform"
  skip_validation = true
  force_destroy   = var.allow_force_destroy

  azure_managed_identity {
    access_connector_id = azurerm_databricks_access_connector.this.id
  }

  depends_on = [
    azurerm_role_assignment.access_connector_storage,
    databricks_metastore_assignment.this,
  ]
}

resource "databricks_external_location" "this" {
  provider = databricks.workspace

  name            = "${var.resource_prefix}_external_location"
  url             = local.external_location_url
  credential_name = databricks_storage_credential.this.name
  comment         = "Private Azure storage location managed by Terraform"
  skip_validation = true
  force_destroy   = var.allow_force_destroy

  depends_on = [azapi_resource.container]
}

resource "databricks_catalog" "this" {
  provider = databricks.workspace

  name          = var.catalog_name
  comment       = "Catalog for the private Azure external volume demo"
  storage_root  = "${local.external_location_url}/catalog-managed"
  force_destroy = var.allow_force_destroy

  depends_on = [
    databricks_external_location.this,
    databricks_metastore_assignment.this,
  ]
}

resource "databricks_schema" "this" {
  provider = databricks.workspace

  catalog_name  = databricks_catalog.this.name
  name          = var.schema_name
  comment       = "Schema for the private Azure external volume demo"
  force_destroy = var.allow_force_destroy
}

resource "databricks_volume" "this" {
  provider = databricks.workspace

  name             = var.volume_name
  catalog_name     = databricks_catalog.this.name
  schema_name      = databricks_schema.this.name
  volume_type      = "EXTERNAL"
  storage_location = local.volume_storage_url
  comment          = "External volume backed by Azure storage with public access disabled"

  depends_on = [databricks_external_location.this]
}
