data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  availability_zones = var.availability_zones != null ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 2)

  # Names derived from the deployment ID must satisfy the strictest consumers:
  # lowercase letters, digits, and single hyphens (S3, RDS), a leading letter
  # (RDS identifiers), and room for the longest suffix within 63 characters.
  deployment_name = var.deployment_id == null ? "" : trim(substr(trim(replace(lower(var.deployment_id), "/[^a-z0-9]+/", "-"), "-"), 0, 24), "-")
  derived_prefix  = local.deployment_name == "" ? null : (can(regex("^[a-z]", local.deployment_name)) ? local.deployment_name : "d-${local.deployment_name}")
  name_prefix     = coalesce(var.name_prefix, local.derived_prefix, "demo")
  workspace_name  = coalesce(var.workspace_name, "${local.name_prefix}-classic")
}

module "workspace" {
  count  = var.features.workspace ? 1 : 0
  source = "../../modules/aws/databricks-workspace"
  providers = { databricks.mws = databricks.mws
  }

  databricks_account_id          = var.databricks_account_id
  region                         = var.region
  workspace_name                 = local.workspace_name
  resource_prefix                = local.name_prefix
  vpc_cidr                       = var.workspace_network.vpc_cidr
  availability_zones             = local.availability_zones
  private_subnet_cidrs           = var.workspace_network.private_subnet_cidrs
  public_subnet_cidr             = var.workspace_network.public_subnet_cidr
  backend_private_link           = var.workspace_backend_private_link
  force_destroy_root_bucket      = var.allow_destructive_demo_cleanup
  tags                           = var.tags
  network_connectivity_config_id = local.network_connectivity_config_id
}

# Workspace-level modules wait for the second stage of a new deployment; see
# var.workspace_resources_enabled.
module "unity_catalog" {
  count  = var.features.unity_catalog && var.workspace_resources_enabled ? 1 : 0
  source = "../../modules/aws/unity-catalog"
  providers = { databricks.mws = databricks.mws
    databricks.workspace = databricks.workspace
  }

  databricks_account_id   = var.databricks_account_id
  workspace_id            = module.workspace[0].workspace_id
  region                  = var.region
  resource_prefix         = local.name_prefix
  metastore_mode          = var.unity_catalog.existing_metastore_name != null ? "existing" : var.unity_catalog.metastore_mode
  existing_metastore_name = var.unity_catalog.existing_metastore_name
  create_initial_catalog  = var.unity_catalog.create_initial_catalog
  catalog_name            = var.initial_catalog_name
  force_destroy           = var.allow_destructive_demo_cleanup
  tags                    = var.tags
}

module "glue_federation" {
  count  = var.features.glue_federation ? 1 : 0
  source = "../../modules/aws/glue-federation"
  providers = {
    databricks.workspace = databricks.workspace
  }

  name_prefix                        = local.name_prefix
  region                             = var.region
  databricks_connectivity_enabled    = var.glue_federation.databricks_connectivity_enabled && var.workspace_resources_enabled
  databricks_metastore_assignment_id = try(module.unity_catalog[0].metastore_assignment_id, null)
  databricks_unity_catalog_iam_arn   = var.glue_federation.databricks_unity_catalog_iam_arn
  service_credential_external_id     = var.glue_federation.service_credential_external_id
  storage_credential_external_id     = var.glue_federation.storage_credential_external_id
  force_destroy                      = var.allow_destructive_demo_cleanup
  tags                               = var.tags
}

module "rds_postgres" {
  count                          = var.features.rds_postgres ? 1 : 0
  source                         = "../../modules/aws/rds-postgres"
  name_prefix                    = "${local.name_prefix}-postgres"
  region                         = var.region
  vpc_cidr                       = var.database_networks.rds_postgres
  engine_version                 = var.rds_postgres.engine_version
  lakeflow_connect_enabled       = var.rds_postgres.lakeflow_connect_enabled
  enable_classic_private_link    = var.connectivity.rds_postgres.classic == "private_link"
  enable_serverless_private_link = var.connectivity.rds_postgres.serverless == "private_link"
  deletion_protection            = !var.allow_destructive_demo_cleanup
  skip_final_snapshot            = var.allow_destructive_demo_cleanup
  tags                           = var.tags
}

module "rds_sql_server" {
  count                          = var.features.rds_sql_server ? 1 : 0
  source                         = "../../modules/aws/rds-sql-server"
  name_prefix                    = "${local.name_prefix}-sqlserver"
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
  name_prefix                    = "${local.name_prefix}-aurora"
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
  name_prefix                    = "${local.name_prefix}-rabbitmq"
  region                         = var.region
  vpc_cidr                       = var.database_networks.rabbitmq
  enable_classic_private_link    = var.connectivity.rabbitmq.classic == "private_link"
  enable_serverless_private_link = var.connectivity.rabbitmq.serverless == "private_link"
  ephemeral_credentials          = var.rabbitmq.ephemeral_credentials
  tags                           = var.tags
}

module "kafka" {
  count                          = var.features.kafka ? 1 : 0
  source                         = "../../modules/aws/kafka"
  name_prefix                    = "${local.name_prefix}-kafka"
  region                         = var.region
  vpc_cidr                       = var.database_networks.kafka
  instance_type                  = var.kafka.instance_type
  kafka_image                    = var.kafka.image
  topic_name                     = var.kafka.topic_name
  producer_interval_seconds      = var.kafka.producer_interval_seconds
  ephemeral_credentials          = var.kafka.ephemeral_credentials
  enable_classic_private_link    = var.connectivity.kafka.classic == "private_link"
  enable_serverless_private_link = var.connectivity.kafka.serverless == "private_link"
  tags                           = var.tags
}

module "simulated_on_prem" {
  count  = var.features.simulated_on_prem ? 1 : 0
  source = "../../modules/aws/simulated-on-prem"

  name_prefix                    = local.name_prefix
  region                         = var.region
  availability_zone              = local.availability_zones[0]
  vpc_cidr                       = var.simulated_on_prem.vpc_cidr
  workload_subnet_cidr           = var.simulated_on_prem.workload_subnet_cidr
  instance_type                  = var.simulated_on_prem.instance_type
  service_port                   = var.simulated_on_prem.service_port
  enable_serverless_private_link = var.connectivity.simulated_on_prem.serverless == "private_link"
  tags                           = var.tags
}

locals {
  workspace_vpc_start = sum([
    for index, octet in split(".", try(cidrhost(var.workspace_network.vpc_cidr, 0), "0.0.0.0")) :
    tonumber(octet) * pow(256, 3 - index)
  ])
  workspace_vpc_end = local.workspace_vpc_start + pow(2, 32 - try(tonumber(split("/", var.workspace_network.vpc_cidr)[1]), 32)) - 1

  simulated_on_prem_vpc_start = sum([
    for index, octet in split(".", try(cidrhost(var.simulated_on_prem.vpc_cidr, 0), "0.0.0.0")) :
    tonumber(octet) * pow(256, 3 - index)
  ])
  simulated_on_prem_vpc_end = local.simulated_on_prem_vpc_start + pow(2, 32 - try(tonumber(split("/", var.simulated_on_prem.vpc_cidr)[1]), 32)) - 1
}

resource "terraform_data" "simulated_on_prem_network_validation" {
  count = var.features.simulated_on_prem && var.connectivity.simulated_on_prem.classic == "transit_gateway" ? 1 : 0

  lifecycle {
    precondition {
      condition = (
        local.workspace_vpc_end < local.simulated_on_prem_vpc_start ||
        local.simulated_on_prem_vpc_end < local.workspace_vpc_start
      )
      error_message = "The workspace and simulated on-premises VPC CIDRs must not overlap."
    }
  }
}

module "simulated_on_prem_transit_gateway" {
  count  = var.features.simulated_on_prem && var.connectivity.simulated_on_prem.classic == "transit_gateway" ? 1 : 0
  source = "../../modules/aws/transit-gateway"

  name                              = "${local.name_prefix}-sim-on-prem"
  availability_zones                = local.availability_zones
  workspace_vpc_id                  = module.workspace[0].vpc_id
  workspace_vpc_cidr                = module.workspace[0].vpc_cidr
  workspace_attachment_subnet_cidrs = var.workspace_network.tgw_attachment_subnet_cidrs
  workspace_existing_subnet_cidrs   = concat(var.workspace_network.private_subnet_cidrs, [var.workspace_network.public_subnet_cidr])
  workspace_route_table_ids         = module.workspace[0].private_route_table_ids
  workspace_security_group_id       = module.workspace[0].security_group_id
  on_prem_vpc_id                    = module.simulated_on_prem[0].vpc_id
  on_prem_vpc_cidr                  = module.simulated_on_prem[0].vpc_cidr
  on_prem_attachment_subnet_cidrs   = var.simulated_on_prem.tgw_attachment_subnet_cidrs
  on_prem_existing_subnet_cidrs     = [var.simulated_on_prem.workload_subnet_cidr]
  on_prem_route_table_ids           = module.simulated_on_prem[0].workload_route_table_ids
  on_prem_security_group_id         = module.simulated_on_prem[0].host_security_group_id
  service_port                      = module.simulated_on_prem[0].service_port
  tags                              = var.tags

  depends_on = [terraform_data.simulated_on_prem_network_validation]
}

module "rds_postgres_classic_private_link" {
  count  = var.features.rds_postgres && var.connectivity.rds_postgres.classic == "private_link" ? 1 : 0
  source = "../../modules/aws/classic-private-link"

  name                     = "${local.name_prefix}-postgres-classic"
  vpc_id                   = module.workspace[0].vpc_id
  subnet_ids               = module.workspace[0].private_subnet_ids
  client_security_group_id = module.workspace[0].security_group_id
  endpoint_service_name    = module.rds_postgres[0].endpoint_service_name
  endpoint_service_id      = module.rds_postgres[0].endpoint_service_id
  service_port             = module.rds_postgres[0].port
  tags                     = var.tags
  depends_on               = [module.rds_postgres]
}

module "rds_sql_server_classic_private_link" {
  count  = var.features.rds_sql_server && var.connectivity.rds_sql_server.classic == "private_link" ? 1 : 0
  source = "../../modules/aws/classic-private-link"

  name                     = "${local.name_prefix}-sqlserver-classic"
  vpc_id                   = module.workspace[0].vpc_id
  subnet_ids               = module.workspace[0].private_subnet_ids
  client_security_group_id = module.workspace[0].security_group_id
  endpoint_service_name    = module.rds_sql_server[0].endpoint_service_name
  endpoint_service_id      = module.rds_sql_server[0].endpoint_service_id
  service_port             = module.rds_sql_server[0].port
  tags                     = var.tags
  depends_on               = [module.rds_sql_server]
}

module "aurora_postgres_classic_private_link" {
  count  = var.features.aurora_postgres && var.connectivity.aurora_postgres.classic == "private_link" ? 1 : 0
  source = "../../modules/aws/classic-private-link"

  name                     = "${local.name_prefix}-aurora-classic"
  vpc_id                   = module.workspace[0].vpc_id
  subnet_ids               = module.workspace[0].private_subnet_ids
  client_security_group_id = module.workspace[0].security_group_id
  endpoint_service_name    = module.aurora_postgres[0].endpoint_service_name
  endpoint_service_id      = module.aurora_postgres[0].endpoint_service_id
  service_port             = module.aurora_postgres[0].port
  tags                     = var.tags
  depends_on               = [module.aurora_postgres]
}

module "rabbitmq_classic_private_link" {
  count  = var.features.rabbitmq && var.connectivity.rabbitmq.classic == "private_link" ? 1 : 0
  source = "../../modules/aws/classic-private-link"

  name                     = "${local.name_prefix}-rabbitmq-classic"
  vpc_id                   = module.workspace[0].vpc_id
  subnet_ids               = module.workspace[0].private_subnet_ids
  client_security_group_id = module.workspace[0].security_group_id
  endpoint_service_name    = module.rabbitmq[0].endpoint_service_name
  endpoint_service_id      = module.rabbitmq[0].endpoint_service_id
  service_port             = module.rabbitmq[0].port
  tags                     = var.tags
  depends_on               = [module.rabbitmq]
}

module "kafka_classic_private_link" {
  count  = var.features.kafka && var.connectivity.kafka.classic == "private_link" ? 1 : 0
  source = "../../modules/aws/classic-private-link"

  name                     = "${local.name_prefix}-kafka-classic"
  vpc_id                   = module.workspace[0].vpc_id
  subnet_ids               = module.workspace[0].private_subnet_ids
  client_security_group_id = module.workspace[0].security_group_id
  endpoint_service_name    = module.kafka[0].endpoint_service_name
  endpoint_service_id      = module.kafka[0].endpoint_service_id
  service_port             = module.kafka[0].private_link_port
  private_dns_name         = module.kafka[0].private_link_host
  create_private_dns_alias = true
  tags                     = var.tags
  depends_on               = [module.kafka]
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
    },
    var.features.kafka && var.connectivity.kafka.serverless == "private_link" ? { kafka = { endpoint_service = module.kafka[0].endpoint_service_name
      domain_names = [module.kafka[0].private_link_host]
      }
      } : {
    },
    var.features.simulated_on_prem && var.connectivity.simulated_on_prem.serverless == "private_link" ? { simulated_on_prem = { endpoint_service = module.simulated_on_prem[0].endpoint_service_name
      domain_names = [module.simulated_on_prem[0].nlb_dns_name]
      }
      } : {
    }
  )
}

# Derived from variables only: the workspace depends on the NCC, so the NCC
# must not depend on anything that depends on the workspace.
locals {
  serverless_private_link_enabled = var.features.workspace && anytrue([
    var.features.rds_postgres && var.connectivity.rds_postgres.serverless == "private_link",
    var.features.rds_sql_server && var.connectivity.rds_sql_server.serverless == "private_link",
    var.features.aurora_postgres && var.connectivity.aurora_postgres.serverless == "private_link",
    var.features.rabbitmq && var.connectivity.rabbitmq.serverless == "private_link",
    var.features.kafka && var.connectivity.kafka.serverless == "private_link",
    var.features.simulated_on_prem && var.connectivity.simulated_on_prem.serverless == "private_link",
  ])
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
  source = "../../modules/aws/network-connectivity-config"
  providers = { databricks.mws = databricks.mws
  }
  name   = "${local.name_prefix}-ncc"
  region = var.region
}

module "ncc" {
  count  = length(local.ncc_rules) > 0 ? 1 : 0
  source = "../../modules/aws/ncc"
  providers = { databricks.mws = databricks.mws
  }
  network_connectivity_config_id = local.network_connectivity_config_id
  private_endpoint_rules         = local.ncc_rules
  depends_on                     = [module.rds_postgres, module.rds_sql_server, module.aurora_postgres, module.rabbitmq, module.kafka, module.simulated_on_prem]
}

moved {
  from = module.ncc[0].databricks_mws_network_connectivity_config.this[0]
  to   = module.network_connectivity_config[0].databricks_mws_network_connectivity_config.this
}

# The workspace's network_connectivity_config_id now attaches the NCC. Deleting
# a binding does not detach it, so forget the old binding resource.
removed {
  from = module.ncc.databricks_mws_ncc_binding.this
  lifecycle {
    destroy = false
  }
}

module "postgres_peering" {
  count                     = var.features.rds_postgres && var.connectivity.rds_postgres.classic == "peering" ? 1 : 0
  source                    = "../../modules/aws/vpc-peering"
  name                      = "${local.name_prefix}-postgres"
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
  name                      = "${local.name_prefix}-sqlserver"
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
  name                      = "${local.name_prefix}-aurora"
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
  name                      = "${local.name_prefix}-rabbitmq"
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

module "kafka_peering" {
  count                     = var.features.kafka && var.connectivity.kafka.classic == "peering" ? 1 : 0
  source                    = "../../modules/aws/vpc-peering"
  name                      = "${local.name_prefix}-kafka"
  client_vpc_id             = module.workspace[0].vpc_id
  client_vpc_cidr           = module.workspace[0].vpc_cidr
  client_route_table_ids    = module.workspace[0].private_route_table_ids
  client_security_group_id  = module.workspace[0].security_group_id
  service_vpc_id            = module.kafka[0].vpc_id
  service_vpc_cidr          = module.kafka[0].vpc_cidr
  service_route_table_ids   = module.kafka[0].route_table_ids
  service_security_group_id = module.kafka[0].security_group_id
  service_port              = module.kafka[0].internal_port
  tags                      = var.tags
}
