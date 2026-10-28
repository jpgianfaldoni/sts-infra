locals {
  # The deprecated enabled flag keeps working until browser_authentication_enabled is set.
  browser_authentication_enabled = coalesce(
    var.workspace_front_end_private_link.browser_authentication_enabled,
    var.workspace_front_end_private_link.enabled,
    false
  )
}

locals {
  # ./infra passes the deployment ID; explicit name_prefix/workspace_name win.
  deployment_name = var.deployment_id == null ? "" : trim(substr(replace(replace(lower(var.deployment_id), "/[^0-9a-z-]/", "-"), "/-+/", "-"), 0, 40), "-")
  name_prefix     = coalesce(var.name_prefix, local.deployment_name, "demo")
  workspace_name  = coalesce(var.workspace_name, local.deployment_name, "demo-azure-classic")
}

module "workspace_network" {
  count                        = var.features.workspace ? 1 : 0
  source                       = "../../modules/azure/workspace-network"
  location                     = var.location
  resource_prefix              = "${local.name_prefix}-workspace"
  vnet_cidr                    = var.workspace_network.vnet_cidr
  host_subnet_cidr             = var.workspace_network.host_subnet_cidr
  container_subnet_cidr        = var.workspace_network.container_subnet_cidr
  private_endpoint_subnet_cidr = var.workspace_network.private_endpoint_subnet_cidr
  test_vm_subnet_cidr          = var.features.test_vm ? var.workspace_network.test_vm_subnet_cidr : null
  dns_subnet_cidr              = var.workspace_network.dns_subnet_cidr
  dns_server_ip                = var.features.custom_dns ? var.workspace_network.dns_server_ip : null
  tags                         = var.tags
}

module "custom_dns" {
  count               = var.features.workspace && var.features.custom_dns ? 1 : 0
  source              = "../../modules/azure/custom-dns"
  location            = var.location
  resource_group_name = module.workspace_network[0].resource_group_name
  resource_prefix     = "${local.name_prefix}-workspace"
  subnet_id           = module.workspace_network[0].dns_subnet_id
  private_ip          = var.workspace_network.dns_server_ip
  tags                = var.tags

  depends_on = [module.workspace_network]
}

module "workspace" {
  count                          = var.features.workspace ? 1 : 0
  source                         = "../../modules/azure/databricks-workspace"
  location                       = var.location
  workspace_name                 = local.workspace_name
  resource_prefix                = "${local.name_prefix}-workspace"
  resource_group_name            = module.workspace_network[0].resource_group_name
  vnet_id                        = module.workspace_network[0].vnet_id
  host_subnet_name               = module.workspace_network[0].host_subnet_name
  container_subnet_name          = module.workspace_network[0].container_subnet_name
  host_nsg_association_id        = module.workspace_network[0].host_nsg_association_id
  container_nsg_association_id   = module.workspace_network[0].container_nsg_association_id
  private_endpoint_subnet_id     = module.workspace_network[0].private_endpoint_subnet_id
  browser_authentication_enabled = local.browser_authentication_enabled
  public_network_access_enabled  = var.workspace_front_end_private_link.public_network_access_enabled
  tags                           = var.tags

  # The NCC is also listed so the workspace is destroyed before it; Databricks
  # refuses to delete an NCC that is still attached to a workspace.
  depends_on = [module.workspace_network, module.custom_dns, module.network_connectivity_config]
}

module "test_vm" {
  count  = var.features.workspace && var.features.test_vm ? 1 : 0
  source = "../../modules/azure/test-vm"

  location                  = var.location
  resource_group_name       = module.workspace_network[0].resource_group_name
  resource_prefix           = "${local.name_prefix}-workspace"
  subnet_id                 = module.workspace_network[0].test_vm_subnet_id
  allowed_ssh_source_cidr   = var.test_vm.allowed_ssh_source_cidr
  admin_username            = var.test_vm.admin_username
  admin_ssh_public_key      = var.test_vm.admin_ssh_public_key
  vm_size                   = var.test_vm.vm_size
  admin_principal_object_id = data.azurerm_client_config.current.object_id
  tags                      = var.tags

  depends_on = [module.workspace, module.workspace_network]
}

data "azurerm_client_config" "current" {
}

module "external_volume_storage" {
  count  = var.features.workspace && var.features.external_volume_storage ? 1 : 0
  source = "../../modules/azure/external-volume-storage"
  providers = {
    azurerm              = azurerm.storage_control_plane
    databricks.account   = databricks.account
    databricks.workspace = databricks.workspace
  }

  location                      = var.location
  resource_group_name           = module.workspace[0].resource_group_name
  resource_prefix               = local.name_prefix
  workspace_id                  = module.workspace[0].workspace_id
  seed_principal_object_id      = data.azurerm_client_config.current.object_id
  public_network_access_enabled = var.external_volume_storage.public_network_access_enabled
  bootstrap_access_enabled      = var.external_volume_bootstrap_access_enabled
  bootstrap_operator_cidr       = var.external_volume_bootstrap_operator_cidr
  container_name                = var.external_volume_storage.container_name
  catalog_name                  = var.external_volume_storage.catalog_name
  schema_name                   = var.external_volume_storage.schema_name
  volume_name                   = var.external_volume_storage.volume_name
  volume_storage_path           = var.external_volume_storage.volume_storage_path
  metastore_mode                = var.external_volume_storage.metastore_mode
  existing_metastore_id         = var.external_volume_storage.metastore_id
  allow_force_destroy           = var.external_volume_storage.allow_force_destroy
  tags                          = var.tags

  # No module-level depends_on: it would defer the metastore lookup data sources
  # to apply time. workspace_id, the resource group, and the workspace provider
  # host already order this module after the workspace.
}

module "sql_database" {
  count                            = var.features.sql_database ? 1 : 0
  source                           = "../../modules/azure/sql-database"
  name_prefix                      = "${local.name_prefix}-sqldb"
  location                         = var.location
  vnet_address_space               = var.sql_database_network.vnet_address_space
  private_endpoint_subnet_prefixes = var.sql_database_network.private_endpoint_subnet_prefixes
  entra_admin = var.sql_database.entra_admin_enabled ? {
    login_username = "sts-infra-deployer"
    object_id      = data.azurerm_client_config.current.object_id
    tenant_id      = data.azurerm_client_config.current.tenant_id
  } : null
  tags = var.tags
}

module "sql_database_workspace_peering" {
  count  = var.features.workspace && var.features.sql_database && var.sql_database.workspace_peering_enabled ? 1 : 0
  source = "../../modules/azure/vnet-peering"

  name = "${local.name_prefix}-sqldb"
  local_vnet = {
    id                  = module.workspace_network[0].vnet_id
    name                = module.workspace_network[0].vnet_name
    resource_group_name = module.workspace_network[0].resource_group_name
  }
  remote_vnet = {
    id                  = module.sql_database[0].vnet_id
    name                = module.sql_database[0].vnet_name
    resource_group_name = module.sql_database[0].resource_group_name
  }
  private_dns_zone_links = {
    sql = {
      private_dns_zone_name = module.sql_database[0].private_dns_zone_name
      resource_group_name   = module.sql_database[0].resource_group_name
      virtual_network_id    = module.workspace_network[0].vnet_id
    }
  }
  tags = var.tags
}

module "sql_server_vm" {
  count                                = var.features.sql_server_vm ? 1 : 0
  source                               = "../../modules/azure/sql-server-vm"
  name_prefix                          = "${local.name_prefix}-sqlvm"
  location                             = var.location
  vnet_address_space                   = var.sql_vm_network.vnet_address_space
  vm_subnet_prefixes                   = var.sql_vm_network.vm_subnet_prefixes
  private_link_service_subnet_prefixes = var.sql_vm_network.private_link_service_subnet_prefixes
  vm_private_ip                        = var.sql_vm_network.vm_private_ip
  tags                                 = var.tags
}

locals {
  key_vault_enabled = var.key_vault.enabled && (var.features.sql_database || var.features.sql_server_vm)
  key_vault_secret_names = concat(
    var.features.sql_database ? ["sql-database-admin-username", "sql-database-admin-password"] : [],
    var.features.sql_server_vm ? ["sql-server-vm-sql-username", "sql-server-vm-sql-password", "sql-server-vm-admin-username", "sql-server-vm-admin-password"] : [],
  )
  key_vault_secrets = merge(
    var.features.sql_database ? {
      "sql-database-admin-username" = module.sql_database[0].admin_username
      "sql-database-admin-password" = module.sql_database[0].admin_password
    } : {},
    var.features.sql_server_vm ? {
      "sql-server-vm-sql-username"   = module.sql_server_vm[0].sql_username
      "sql-server-vm-sql-password"   = module.sql_server_vm[0].sql_password
      "sql-server-vm-admin-username" = module.sql_server_vm[0].vm_username
      "sql-server-vm-admin-password" = module.sql_server_vm[0].vm_password
    } : {},
  )
}

module "key_vault" {
  count  = local.key_vault_enabled ? 1 : 0
  source = "../../modules/azure/key-vault"
  providers = {
    databricks.workspace = databricks.workspace
  }

  name_prefix                     = local.name_prefix
  location                        = var.location
  tenant_id                       = data.azurerm_client_config.current.tenant_id
  operator_object_id              = data.azurerm_client_config.current.object_id
  secret_names                    = local.key_vault_secret_names
  secrets                         = local.key_vault_secrets
  databricks_secret_scope_enabled = var.features.workspace && var.key_vault.databricks_secret_scope_enabled
  secret_scope_name               = var.key_vault.secret_scope_name
  tags                            = var.tags

  depends_on = [module.workspace]
}

locals {
  serverless_private_endpoint_rules = merge(
    var.features.workspace && var.features.sql_database && var.connectivity.sql_database.serverless == "private_link" ? {
      sql_database = {
        resource_id = module.sql_database[0].server_id
        group_id    = "sqlServer"
      }
    } : {},
  )
}

# Derived from variables only: the workspace waits for the NCC, so the NCC must
# not depend on anything that depends on the workspace.
locals {
  serverless_private_link_enabled = (
    var.features.workspace && var.features.sql_database &&
    var.connectivity.sql_database.serverless == "private_link"
  )
  network_connectivity_config_id = !local.serverless_private_link_enabled ? null : (
    var.existing_network_connectivity_config_id != null
    ? var.existing_network_connectivity_config_id
    : module.network_connectivity_config[0].network_connectivity_config_id
  )
}

# Created before the workspace and destroyed after it: Databricks refuses to
# delete an NCC that is still attached to a workspace.
module "network_connectivity_config" {
  count  = local.serverless_private_link_enabled && var.existing_network_connectivity_config_id == null ? 1 : 0
  source = "../../modules/azure/network-connectivity-config"
  providers = {
    databricks.account = databricks.account
  }

  name   = "${local.name_prefix}-ncc"
  region = var.location
}

module "ncc" {
  count  = length(local.serverless_private_endpoint_rules) > 0 ? 1 : 0
  source = "../../modules/azure/ncc"
  providers = {
    databricks.account = databricks.account
  }

  network_connectivity_config_id = local.network_connectivity_config_id
  workspace_id                   = tonumber(module.workspace[0].workspace_id)
  private_endpoint_rules         = local.serverless_private_endpoint_rules

  depends_on = [module.sql_database]
}

moved {
  from = module.ncc[0].databricks_mws_network_connectivity_config.this[0]
  to   = module.network_connectivity_config[0].databricks_mws_network_connectivity_config.this
}
