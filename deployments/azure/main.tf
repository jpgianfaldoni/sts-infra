module "workspace_network" {
  count                        = var.features.workspace ? 1 : 0
  source                       = "../../modules/azure/workspace-network"
  location                     = var.location
  resource_prefix              = "${var.name_prefix}-workspace"
  vnet_cidr                    = var.workspace_network.vnet_cidr
  host_subnet_cidr             = var.workspace_network.host_subnet_cidr
  container_subnet_cidr        = var.workspace_network.container_subnet_cidr
  private_endpoint_subnet_cidr = var.workspace_network.private_endpoint_subnet_cidr
  dns_subnet_cidr              = var.workspace_network.dns_subnet_cidr
  dns_server_ip                = var.features.custom_dns ? var.workspace_network.dns_server_ip : null
  tags                         = var.tags
}

module "custom_dns" {
  count               = var.features.workspace && var.features.custom_dns ? 1 : 0
  source              = "../../modules/azure/custom-dns"
  location            = var.location
  resource_group_name = module.workspace_network[0].resource_group_name
  resource_prefix     = "${var.name_prefix}-workspace"
  subnet_id           = module.workspace_network[0].dns_subnet_id
  private_ip          = var.workspace_network.dns_server_ip
  tags                = var.tags

  depends_on = [module.workspace_network]
}

module "workspace" {
  count                        = var.features.workspace ? 1 : 0
  source                       = "../../modules/azure/databricks-workspace"
  location                     = var.location
  workspace_name               = var.workspace_name
  resource_prefix              = "${var.name_prefix}-workspace"
  resource_group_name          = module.workspace_network[0].resource_group_name
  vnet_id                      = module.workspace_network[0].vnet_id
  host_subnet_name             = module.workspace_network[0].host_subnet_name
  container_subnet_name        = module.workspace_network[0].container_subnet_name
  host_nsg_association_id      = module.workspace_network[0].host_nsg_association_id
  container_nsg_association_id = module.workspace_network[0].container_nsg_association_id
  private_endpoint_subnet_id   = module.workspace_network[0].private_endpoint_subnet_id
  tags                         = var.tags

  depends_on = [module.workspace_network, module.custom_dns]
}

module "sql_database" {
  count                            = var.features.sql_database ? 1 : 0
  source                           = "../../modules/azure/sql-database"
  name_prefix                      = "${var.name_prefix}-sqldb"
  location                         = var.location
  vnet_address_space               = var.sql_database_network.vnet_address_space
  private_endpoint_subnet_prefixes = var.sql_database_network.private_endpoint_subnet_prefixes
  tags                             = var.tags
}

module "sql_server_vm" {
  count                                = var.features.sql_server_vm ? 1 : 0
  source                               = "../../modules/azure/sql-server-vm"
  name_prefix                          = "${var.name_prefix}-sqlvm"
  location                             = var.location
  vnet_address_space                   = var.sql_vm_network.vnet_address_space
  vm_subnet_prefixes                   = var.sql_vm_network.vm_subnet_prefixes
  private_link_service_subnet_prefixes = var.sql_vm_network.private_link_service_subnet_prefixes
  vm_private_ip                        = var.sql_vm_network.vm_private_ip
  tags                                 = var.tags
}
