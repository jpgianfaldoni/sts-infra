module "workspace" {
  count                        = var.features.workspace ? 1 : 0
  source                       = "../../modules/azure/databricks-workspace"
  location                     = var.location
  workspace_name               = var.workspace_name
  resource_prefix              = "${var.name_prefix}-workspace"
  vnet_cidr                    = var.workspace_network.vnet_cidr
  host_subnet_cidr             = var.workspace_network.host_subnet_cidr
  container_subnet_cidr        = var.workspace_network.container_subnet_cidr
  private_endpoint_subnet_cidr = var.workspace_network.private_endpoint_subnet_cidr
  tags                         = var.tags
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
