module "workspace" {
  count  = var.features.workspace ? 1 : 0
  source = "../../modules/aws/databricks-workspace"
  providers = { databricks.mws = databricks.mws
  }

  databricks_account_id     = var.databricks_account_id
  region                    = var.region
  workspace_name            = var.workspace_name
  resource_prefix           = var.name_prefix
  vpc_cidr                  = var.workspace_network.vpc_cidr
  availability_zones        = var.availability_zones
  private_subnet_cidrs      = var.workspace_network.private_subnet_cidrs
  public_subnet_cidr        = var.workspace_network.public_subnet_cidr
  force_destroy_root_bucket = var.allow_destructive_demo_cleanup
  tags                      = var.tags
}

module "unity_catalog" {
  count  = var.features.unity_catalog ? 1 : 0
  source = "../../modules/aws/unity-catalog"
  providers = { databricks.mws = databricks.mws
    databricks.workspace = databricks.workspace
  }

  databricks_account_id = var.databricks_account_id
  workspace_id          = module.workspace[0].workspace_id
  region                = var.region
  resource_prefix       = var.name_prefix
  catalog_name          = var.initial_catalog_name
  force_destroy         = var.allow_destructive_demo_cleanup
  tags                  = var.tags
}

module "rds_postgres" {
  count                          = var.features.rds_postgres ? 1 : 0
  source                         = "../../modules/aws/rds-postgres"
  name_prefix                    = "${var.name_prefix}-postgres"
  region                         = var.region
  vpc_cidr                       = var.database_networks.rds_postgres
  enable_classic_private_link    = var.connectivity.rds_postgres.classic == "private_link"
  enable_serverless_private_link = var.connectivity.rds_postgres.serverless == "private_link"
  deletion_protection            = !var.allow_destructive_demo_cleanup
  skip_final_snapshot            = var.allow_destructive_demo_cleanup
  tags                           = var.tags
}

module "rds_sql_server" {
  count                          = var.features.rds_sql_server ? 1 : 0
  source                         = "../../modules/aws/rds-sql-server"
  name_prefix                    = "${var.name_prefix}-sqlserver"
  region                         = var.region
  vpc_cidr                       = var.database_networks.rds_sql_server
  enable_classic_private_link    = var.connectivity.rds_sql_server.classic == "private_link"
  enable_serverless_private_link = var.connectivity.rds_sql_server.serverless == "private_link"
  deletion_protection            = !var.allow_destructive_demo_cleanup
  skip_final_snapshot            = var.allow_destructive_demo_cleanup
  tags                           = var.tags
}

module "aurora_postgres" {
  count                          = var.features.aurora_postgres ? 1 : 0
  source                         = "../../modules/aws/aurora-postgres"
  name_prefix                    = "${var.name_prefix}-aurora"
  region                         = var.region
  vpc_cidr                       = var.database_networks.aurora_postgres
  enable_proxy                   = var.features.aurora_proxy
  enable_classic_private_link    = var.connectivity.aurora_postgres.classic == "private_link"
  enable_serverless_private_link = var.connectivity.aurora_postgres.serverless == "private_link"
  deletion_protection            = !var.allow_destructive_demo_cleanup
  skip_final_snapshot            = var.allow_destructive_demo_cleanup
  tags                           = var.tags
}

module "rabbitmq" {
  count                          = var.features.rabbitmq ? 1 : 0
  source                         = "../../modules/aws/rabbitmq"
  name_prefix                    = "${var.name_prefix}-rabbitmq"
  region                         = var.region
  vpc_cidr                       = var.database_networks.rabbitmq
  enable_classic_private_link    = var.connectivity.rabbitmq.classic == "private_link"
  enable_serverless_private_link = var.connectivity.rabbitmq.serverless == "private_link"
  tags                           = var.tags
}

module "rds_postgres_classic_private_link" {
  count  = var.features.rds_postgres && var.connectivity.rds_postgres.classic == "private_link" ? 1 : 0
  source = "../../modules/aws/classic-private-link"

  name                     = "${var.name_prefix}-postgres-classic"
  vpc_id                   = module.workspace[0].vpc_id
  subnet_ids               = module.workspace[0].private_subnet_ids
  client_security_group_id = module.workspace[0].security_group_id
  endpoint_service_name    = module.rds_postgres[0].endpoint_service_name
  service_port             = module.rds_postgres[0].port
  tags                     = var.tags
  depends_on               = [module.rds_postgres]
}

module "rds_sql_server_classic_private_link" {
  count  = var.features.rds_sql_server && var.connectivity.rds_sql_server.classic == "private_link" ? 1 : 0
  source = "../../modules/aws/classic-private-link"

  name                     = "${var.name_prefix}-sqlserver-classic"
  vpc_id                   = module.workspace[0].vpc_id
  subnet_ids               = module.workspace[0].private_subnet_ids
  client_security_group_id = module.workspace[0].security_group_id
  endpoint_service_name    = module.rds_sql_server[0].endpoint_service_name
  service_port             = module.rds_sql_server[0].port
  tags                     = var.tags
  depends_on               = [module.rds_sql_server]
}

module "aurora_postgres_classic_private_link" {
  count  = var.features.aurora_postgres && var.connectivity.aurora_postgres.classic == "private_link" ? 1 : 0
  source = "../../modules/aws/classic-private-link"

  name                     = "${var.name_prefix}-aurora-classic"
  vpc_id                   = module.workspace[0].vpc_id
  subnet_ids               = module.workspace[0].private_subnet_ids
  client_security_group_id = module.workspace[0].security_group_id
  endpoint_service_name    = module.aurora_postgres[0].endpoint_service_name
  service_port             = module.aurora_postgres[0].port
  tags                     = var.tags
  depends_on               = [module.aurora_postgres]
}

module "rabbitmq_classic_private_link" {
  count  = var.features.rabbitmq && var.connectivity.rabbitmq.classic == "private_link" ? 1 : 0
  source = "../../modules/aws/classic-private-link"

  name                     = "${var.name_prefix}-rabbitmq-classic"
  vpc_id                   = module.workspace[0].vpc_id
  subnet_ids               = module.workspace[0].private_subnet_ids
  client_security_group_id = module.workspace[0].security_group_id
  endpoint_service_name    = module.rabbitmq[0].endpoint_service_name
  service_port             = module.rabbitmq[0].port
  tags                     = var.tags
  depends_on               = [module.rabbitmq]
}

locals {
  ncc_rules = merge(
    var.features.rds_postgres && var.connectivity.rds_postgres.serverless == "private_link" ? { rds_postgres = { endpoint_service = module.rds_postgres[0].endpoint_service_name
      domain_names = [module.rds_postgres[0].host]
      }
      } : {
    },
    var.features.rds_sql_server && var.connectivity.rds_sql_server.serverless == "private_link" ? { rds_sql_server = { endpoint_service = module.rds_sql_server[0].endpoint_service_name
      domain_names = [module.rds_sql_server[0].host]
      }
      } : {
    },
    var.features.aurora_postgres && var.connectivity.aurora_postgres.serverless == "private_link" ? { aurora_postgres = { endpoint_service = module.aurora_postgres[0].endpoint_service_name
      domain_names = [module.aurora_postgres[0].reader_endpoint]
      }
      } : {
    },
    var.features.rabbitmq && var.connectivity.rabbitmq.serverless == "private_link" ? { rabbitmq = { endpoint_service = module.rabbitmq[0].endpoint_service_name
      domain_names = [module.rabbitmq[0].host]
      }
      } : {
    }
  )
}

module "ncc" {
  count  = length(local.ncc_rules) > 0 ? 1 : 0
  source = "../../modules/aws/ncc"
  providers = { databricks.mws = databricks.mws
  }
  name                   = "${var.name_prefix}-ncc"
  region                 = var.region
  workspace_id           = module.workspace[0].workspace_id
  private_endpoint_rules = local.ncc_rules
  depends_on             = [module.rds_postgres, module.rds_sql_server, module.aurora_postgres, module.rabbitmq]
}

module "postgres_peering" {
  count                     = var.features.rds_postgres && var.connectivity.rds_postgres.classic == "peering" ? 1 : 0
  source                    = "../../modules/aws/vpc-peering"
  name                      = "${var.name_prefix}-postgres"
  client_vpc_id             = module.workspace[0].vpc_id
  client_vpc_cidr           = module.workspace[0].vpc_cidr
  client_route_table_ids    = module.workspace[0].private_route_table_ids
  client_security_group_id  = module.workspace[0].security_group_id
  service_vpc_id            = module.rds_postgres[0].vpc_id
  service_vpc_cidr          = module.rds_postgres[0].vpc_cidr
  service_route_table_ids   = module.rds_postgres[0].route_table_ids
  service_security_group_id = module.rds_postgres[0].security_group_id
  service_port              = module.rds_postgres[0].port
  tags                      = var.tags
}

module "sqlserver_peering" {
  count                     = var.features.rds_sql_server && var.connectivity.rds_sql_server.classic == "peering" ? 1 : 0
  source                    = "../../modules/aws/vpc-peering"
  name                      = "${var.name_prefix}-sqlserver"
  client_vpc_id             = module.workspace[0].vpc_id
  client_vpc_cidr           = module.workspace[0].vpc_cidr
  client_route_table_ids    = module.workspace[0].private_route_table_ids
  client_security_group_id  = module.workspace[0].security_group_id
  service_vpc_id            = module.rds_sql_server[0].vpc_id
  service_vpc_cidr          = module.rds_sql_server[0].vpc_cidr
  service_route_table_ids   = module.rds_sql_server[0].route_table_ids
  service_security_group_id = module.rds_sql_server[0].security_group_id
  service_port              = module.rds_sql_server[0].port
  tags                      = var.tags
}

module "aurora_peering" {
  count                     = var.features.aurora_postgres && var.connectivity.aurora_postgres.classic == "peering" ? 1 : 0
  source                    = "../../modules/aws/vpc-peering"
  name                      = "${var.name_prefix}-aurora"
  client_vpc_id             = module.workspace[0].vpc_id
  client_vpc_cidr           = module.workspace[0].vpc_cidr
  client_route_table_ids    = module.workspace[0].private_route_table_ids
  client_security_group_id  = module.workspace[0].security_group_id
  service_vpc_id            = module.aurora_postgres[0].vpc_id
  service_vpc_cidr          = module.aurora_postgres[0].vpc_cidr
  service_route_table_ids   = module.aurora_postgres[0].route_table_ids
  service_security_group_id = coalesce(module.aurora_postgres[0].proxy_security_group_id, module.aurora_postgres[0].security_group_id)
  service_port              = module.aurora_postgres[0].port
  tags                      = var.tags
}

module "rabbitmq_peering" {
  count                     = var.features.rabbitmq && var.connectivity.rabbitmq.classic == "peering" ? 1 : 0
  source                    = "../../modules/aws/vpc-peering"
  name                      = "${var.name_prefix}-rabbitmq"
  client_vpc_id             = module.workspace[0].vpc_id
  client_vpc_cidr           = module.workspace[0].vpc_cidr
  client_route_table_ids    = module.workspace[0].private_route_table_ids
  client_security_group_id  = module.workspace[0].security_group_id
  service_vpc_id            = module.rabbitmq[0].vpc_id
  service_vpc_cidr          = module.rabbitmq[0].vpc_cidr
  service_route_table_ids   = module.rabbitmq[0].route_table_ids
  service_security_group_id = module.rabbitmq[0].security_group_id
  service_port              = module.rabbitmq[0].port
  tags                      = var.tags
}
