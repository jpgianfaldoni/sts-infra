# Sample data and network path checks, run with ./infra verify. Databases keep
# their credentials in RDS-managed Secrets Manager secrets, which rotate;
# ./infra verify copies them into the managed secret scope before every run,
# so no database password is stored in Terraform state.
locals {
  lab_check_secret_scope = "${local.name_prefix}-lab-check"

  # One entry per enabled source: the engine and the host and port each
  # compute path uses. Hosts match the connectivity output.
  lab_check_sources = merge(
    var.features.rds_postgres ? {
      rds_postgres = {
        engine          = "postgresql"
        classic         = var.connectivity.rds_postgres.classic
        serverless      = var.connectivity.rds_postgres.serverless
        classic_host    = var.connectivity.rds_postgres.classic == "private_link" ? try(module.rds_postgres_classic_private_link[0].dns_name, null) : module.rds_postgres[0].host
        classic_port    = module.rds_postgres[0].port
        serverless_host = module.rds_postgres[0].host
        serverless_port = module.rds_postgres[0].port
        database        = module.rds_postgres[0].database_name
        seed_database   = module.rds_postgres[0].database_name
        seed_file       = module.rds_postgres[0].seed_file
        secret_arn      = module.rds_postgres[0].master_secret_arn
      }
    } : {},
    var.features.rds_sql_server ? {
      rds_sql_server = {
        engine          = "sqlserver"
        classic         = var.connectivity.rds_sql_server.classic
        serverless      = var.connectivity.rds_sql_server.serverless
        classic_host    = var.connectivity.rds_sql_server.classic == "private_link" ? try(module.rds_sql_server_classic_private_link[0].dns_name, null) : module.rds_sql_server[0].host
        classic_port    = module.rds_sql_server[0].port
        serverless_host = module.rds_sql_server[0].host
        serverless_port = module.rds_sql_server[0].port
        database        = "demo"
        seed_database   = "master"
        seed_file       = module.rds_sql_server[0].seed_file
        secret_arn      = module.rds_sql_server[0].master_secret_arn
      }
    } : {},
    # Aurora is reached through its reader endpoint, which is read-only, so its
    # checks only connect and run a query.
    var.features.aurora_postgres ? {
      aurora_postgres = {
        engine          = "postgresql"
        classic         = var.connectivity.aurora_postgres.classic
        serverless      = var.connectivity.aurora_postgres.serverless
        classic_host    = var.connectivity.aurora_postgres.classic == "private_link" ? try(module.aurora_postgres_classic_private_link[0].dns_name, null) : module.aurora_postgres[0].reader_endpoint
        classic_port    = module.aurora_postgres[0].port
        serverless_host = module.aurora_postgres[0].reader_endpoint
        serverless_port = module.aurora_postgres[0].port
        database        = module.aurora_postgres[0].database_name
        seed_database   = null
        seed_file       = null
        secret_arn      = module.aurora_postgres[0].master_secret_arn
      }
    } : {},
    var.features.rabbitmq ? {
      rabbitmq = {
        engine          = "tcp"
        classic         = var.connectivity.rabbitmq.classic
        serverless      = var.connectivity.rabbitmq.serverless
        classic_host    = var.connectivity.rabbitmq.classic == "private_link" ? try(module.rabbitmq_classic_private_link[0].dns_name, null) : module.rabbitmq[0].host
        classic_port    = module.rabbitmq[0].port
        serverless_host = module.rabbitmq[0].host
        serverless_port = module.rabbitmq[0].port
        database        = null
        seed_database   = null
        seed_file       = null
        secret_arn      = null
      }
    } : {},
    var.features.kafka ? {
      kafka = {
        engine          = "tcp"
        classic         = var.connectivity.kafka.classic
        serverless      = var.connectivity.kafka.serverless
        classic_host    = var.connectivity.kafka.classic == "private_link" ? try(module.kafka_classic_private_link[0].host, null) : module.kafka[0].internal_host
        classic_port    = var.connectivity.kafka.classic == "private_link" ? module.kafka[0].private_link_port : module.kafka[0].internal_port
        serverless_host = module.kafka[0].private_link_host
        serverless_port = module.kafka[0].private_link_port
        database        = null
        seed_database   = null
        seed_file       = null
        secret_arn      = null
      }
    } : {},
    var.features.simulated_on_prem ? {
      simulated_on_prem = {
        engine          = "tcp"
        classic         = var.connectivity.simulated_on_prem.classic
        serverless      = var.connectivity.simulated_on_prem.serverless
        classic_host    = module.simulated_on_prem[0].private_ip
        classic_port    = module.simulated_on_prem[0].service_port
        serverless_host = module.simulated_on_prem[0].nlb_dns_name
        serverless_port = module.simulated_on_prem[0].service_port
        database        = null
        seed_database   = null
        seed_file       = null
        secret_arn      = null
      }
    } : {},
  )

  lab_checks = merge({}, flatten([
    for source, config in local.lab_check_sources : [
      for compute in ["classic", "serverless"] : {
        "${source}_${compute}" = {
          source        = source
          path          = compute
          mode          = config[compute]
          engine        = config.engine
          host          = compute == "classic" ? config.classic_host : config.serverless_host
          port          = compute == "classic" ? config.classic_port : config.serverless_port
          database      = config.database
          seed_database = config.seed_database
          seed_file     = config.seed_file
          secret_scope  = config.engine == "tcp" ? null : local.lab_check_secret_scope
          username_key  = config.engine == "tcp" ? null : "${source}-username"
          password_key  = config.engine == "tcp" ? null : "${source}-password"
          run_after     = compute == "serverless" && config.classic != "none" ? "${source}_classic" : null
        }
      } if config[compute] != "none"
    ]
  ])...)

  # Secrets ./infra verify copies into the scope: one per checked database.
  lab_check_credentials = [
    for source, config in local.lab_check_sources : {
      source       = source
      secret_arn   = config.secret_arn
      username_key = "${source}-username"
      password_key = "${source}-password"
    }
    if config.engine != "tcp" && (config.classic != "none" || config.serverless != "none")
  ]

  lab_check_enabled = var.features.workspace && var.lab_check.enabled && var.workspace_resources_enabled && length(local.lab_checks) > 0

  # Whether anything waits for the second stage of a new deployment.
  workspace_resources_requested = var.features.workspace && (
    var.features.unity_catalog ||
    var.glue_federation.databricks_connectivity_enabled ||
    (var.lab_check.enabled && length(local.lab_checks) > 0)
  )
}

module "lab_check" {
  count  = local.lab_check_enabled ? 1 : 0
  source = "../../modules/shared/lab-check"
  providers = {
    databricks = databricks.workspace
  }

  cloud                = "aws"
  name_prefix          = local.name_prefix
  checks               = local.lab_checks
  managed_secret_scope = local.lab_check_secret_scope
  classic_node_type    = var.lab_check.classic_node_type

  # The module's data sources (current user, runtime, node type) call the
  # workspace API; waiting for the workspace defers them to apply time when
  # the workspace is new, instead of reading them through an unconfigured host.
  depends_on = [module.workspace]
}
