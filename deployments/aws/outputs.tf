output "availability_zones" {
  description = "Availability zones selected for workspace and simulated on-premises networking."
  value       = local.availability_zones
}

output "resource_name_prefix" {
  description = "Prefix used for resource names: name_prefix, or a name derived from the deployment ID."
  value       = local.name_prefix
}

output "workspace_url" {
  value = try(module.workspace[0].workspace_url, null)
}
output "workspace_id" {
  description = "Numeric Databricks workspace ID, or null when no workspace is managed."
  value       = try(module.workspace[0].workspace_id, null)
}
output "workspace_backend_private_link" {
  value = {
    enabled                    = var.features.workspace && var.workspace_backend_private_link.enabled
    public_access_enabled      = var.workspace_backend_private_link.public_access_enabled
    general_access_endpoint_id = try(module.workspace[0].backend_private_link.general_access_endpoint_id, null)
    scc_relay_endpoint_id      = try(module.workspace[0].backend_private_link.scc_relay_endpoint_id, null)
  }
}
output "catalog_name" {
  value = try(module.unity_catalog[0].catalog_name, null)
}
output "metastore_id" {
  value = try(module.unity_catalog[0].metastore_id, null)

  # Shared accounts can hold several metastores per region, so auto mode stops
  # instead of attaching the workspace to someone else's metastore.
  precondition {
    condition     = length(try(module.unity_catalog[0].auto_metastore_conflicts, [])) == 0
    error_message = "unity_catalog.metastore_mode = \"auto\" found several metastores in ${var.region} (${join(", ", slice(try(module.unity_catalog[0].auto_metastore_conflicts, []), 0, min(3, length(try(module.unity_catalog[0].auto_metastore_conflicts, [])))))}, ...) and will not guess. Set metastore_mode = \"existing\" with existing_metastore_name, or \"create\" for a dedicated metastore."
  }
}
output "metastore_created" {
  description = "True when this deployment manages its Unity Catalog metastore, false when it reuses one, null without Unity Catalog."
  value       = try(module.unity_catalog[0].metastore_created, null)
}
output "glue_federation" {
  description = "AWS Glue federation resources and optional Databricks Unity Catalog objects."
  value = try({
    bucket_name                     = module.glue_federation[0].bucket_name
    sample_data_uri                 = module.glue_federation[0].sample_data_uri
    catalog_storage_uri             = module.glue_federation[0].catalog_storage_uri
    glue_catalog_id                 = module.glue_federation[0].glue_catalog_id
    glue_database_name              = module.glue_federation[0].glue_database_name
    glue_table_name                 = module.glue_federation[0].glue_table_name
    service_credential_role_arn     = module.glue_federation[0].service_credential_role_arn
    storage_credential_role_arn     = module.glue_federation[0].storage_credential_role_arn
    databricks_connectivity_enabled = module.glue_federation[0].databricks_connectivity_enabled
    service_credential_name         = module.glue_federation[0].service_credential_name
    storage_credential_name         = module.glue_federation[0].storage_credential_name
    external_location_name          = module.glue_federation[0].external_location_name
    connection_name                 = module.glue_federation[0].connection_name
    foreign_catalog_name            = module.glue_federation[0].foreign_catalog_name
    service_trust_finalized         = module.glue_federation[0].service_trust_finalized
    storage_trust_finalized         = module.glue_federation[0].storage_trust_finalized
  }, null)
}
output "rds_postgres" {
  value = try({ host = module.rds_postgres[0].host
    port                            = module.rds_postgres[0].port
    database                        = module.rds_postgres[0].database_name
    username                        = module.rds_postgres[0].master_username
    secret_arn                      = module.rds_postgres[0].master_secret_arn
    lakeflow_replication_secret_arn = module.rds_postgres[0].lakeflow_replication_secret_arn
  }, null)
}
output "rds_sql_server" {
  value = try({ host = module.rds_sql_server[0].host
    port       = module.rds_sql_server[0].port
    username   = module.rds_sql_server[0].master_username
    secret_arn = module.rds_sql_server[0].master_secret_arn
  }, null)
}
output "aurora_postgres" {
  value = try({ reader = module.aurora_postgres[0].reader_endpoint
    proxy_reader = module.aurora_postgres[0].proxy_read_only_endpoint
    port         = module.aurora_postgres[0].port
    database     = module.aurora_postgres[0].database_name
    username     = module.aurora_postgres[0].master_username
    secret_arn   = module.aurora_postgres[0].master_secret_arn
  }, null)
}
output "rabbitmq" {
  value = try({ host = module.rabbitmq[0].host
    port       = module.rabbitmq[0].port
    secret_arn = module.rabbitmq[0].secret_arn
  }, null)
}
output "kafka" {
  value = try({
    topic_name  = module.kafka[0].topic_name
    secret_arn  = module.kafka[0].secret_arn
    instance_id = module.kafka[0].instance_id
    ssm_command = "aws ssm start-session --target ${module.kafka[0].instance_id} --region ${var.region}${local.aws_profile_cli_argument}"
  }, null)
}
output "simulated_on_prem" {
  value = try({
    vpc_id       = module.simulated_on_prem[0].vpc_id
    instance_id  = module.simulated_on_prem[0].instance_id
    private_ip   = module.simulated_on_prem[0].private_ip
    service_port = module.simulated_on_prem[0].service_port
    service_url  = module.simulated_on_prem[0].service_url
    ssm_command  = "aws ssm start-session --target ${module.simulated_on_prem[0].instance_id} --region ${var.region}${local.aws_profile_cli_argument}"
  }, null)
}
output "ncc_rules" {
  value = try(module.ncc[0].rules, {
  })
}

output "connectivity" {
  description = "Connection modes and client-facing endpoints for Databricks classic and serverless compute."
  value = {
    rds_postgres = {
      classic = {
        mode                = var.connectivity.rds_postgres.classic
        host                = var.connectivity.rds_postgres.classic == "private_link" ? try(module.rds_postgres_classic_private_link[0].dns_name, null) : var.connectivity.rds_postgres.classic == "peering" ? try(module.rds_postgres[0].host, null) : null
        endpoint_id         = try(module.rds_postgres_classic_private_link[0].endpoint_id, null)
        endpoint_service_id = var.connectivity.rds_postgres.classic == "private_link" ? try(module.rds_postgres[0].endpoint_service_id, null) : null
      }
      serverless = {
        mode                = var.connectivity.rds_postgres.serverless
        endpoint_service_id = var.connectivity.rds_postgres.serverless == "private_link" ? try(module.rds_postgres[0].endpoint_service_id, null) : null
        host                = var.connectivity.rds_postgres.serverless == "private_link" ? try(module.rds_postgres[0].host, null) : null
      }
    }
    rds_sql_server = {
      classic = {
        mode                = var.connectivity.rds_sql_server.classic
        host                = var.connectivity.rds_sql_server.classic == "private_link" ? try(module.rds_sql_server_classic_private_link[0].dns_name, null) : var.connectivity.rds_sql_server.classic == "peering" ? try(module.rds_sql_server[0].host, null) : null
        endpoint_id         = try(module.rds_sql_server_classic_private_link[0].endpoint_id, null)
        endpoint_service_id = var.connectivity.rds_sql_server.classic == "private_link" ? try(module.rds_sql_server[0].endpoint_service_id, null) : null
      }
      serverless = {
        mode                = var.connectivity.rds_sql_server.serverless
        endpoint_service_id = var.connectivity.rds_sql_server.serverless == "private_link" ? try(module.rds_sql_server[0].endpoint_service_id, null) : null
        host                = var.connectivity.rds_sql_server.serverless == "private_link" ? try(module.rds_sql_server[0].host, null) : null
      }
    }
    aurora_postgres = {
      classic = {
        mode                = var.connectivity.aurora_postgres.classic
        host                = var.connectivity.aurora_postgres.classic == "private_link" ? try(module.aurora_postgres_classic_private_link[0].dns_name, null) : var.connectivity.aurora_postgres.classic == "peering" ? try(module.aurora_postgres[0].reader_endpoint, null) : null
        endpoint_id         = try(module.aurora_postgres_classic_private_link[0].endpoint_id, null)
        endpoint_service_id = var.connectivity.aurora_postgres.classic == "private_link" ? try(module.aurora_postgres[0].endpoint_service_id, null) : null
      }
      serverless = {
        mode                = var.connectivity.aurora_postgres.serverless
        endpoint_service_id = var.connectivity.aurora_postgres.serverless == "private_link" ? try(module.aurora_postgres[0].endpoint_service_id, null) : null
        host                = var.connectivity.aurora_postgres.serverless == "private_link" ? try(module.aurora_postgres[0].reader_endpoint, null) : null
      }
    }
    rabbitmq = {
      classic = {
        mode                = var.connectivity.rabbitmq.classic
        host                = var.connectivity.rabbitmq.classic == "private_link" ? try(module.rabbitmq_classic_private_link[0].dns_name, null) : var.connectivity.rabbitmq.classic == "peering" ? try(module.rabbitmq[0].host, null) : null
        endpoint_id         = try(module.rabbitmq_classic_private_link[0].endpoint_id, null)
        endpoint_service_id = var.connectivity.rabbitmq.classic == "private_link" ? try(module.rabbitmq[0].endpoint_service_id, null) : null
      }
      serverless = {
        mode                = var.connectivity.rabbitmq.serverless
        endpoint_service_id = var.connectivity.rabbitmq.serverless == "private_link" ? try(module.rabbitmq[0].endpoint_service_id, null) : null
        host                = var.connectivity.rabbitmq.serverless == "private_link" ? try(module.rabbitmq[0].host, null) : null
      }
    }
    kafka = {
      classic = {
        mode                = var.connectivity.kafka.classic
        host                = var.connectivity.kafka.classic == "private_link" ? try(module.kafka_classic_private_link[0].host, null) : var.connectivity.kafka.classic == "peering" ? try(module.kafka[0].internal_host, null) : null
        port                = var.connectivity.kafka.classic == "private_link" ? try(module.kafka[0].private_link_port, null) : var.connectivity.kafka.classic == "peering" ? try(module.kafka[0].internal_port, null) : null
        endpoint_id         = try(module.kafka_classic_private_link[0].endpoint_id, null)
        endpoint_service_id = var.connectivity.kafka.classic == "private_link" ? try(module.kafka[0].endpoint_service_id, null) : null
      }
      serverless = {
        mode                = var.connectivity.kafka.serverless
        endpoint_service_id = var.connectivity.kafka.serverless == "private_link" ? try(module.kafka[0].endpoint_service_id, null) : null
        host                = var.connectivity.kafka.serverless == "private_link" ? try(module.kafka[0].private_link_host, null) : null
        port                = var.connectivity.kafka.serverless == "private_link" ? try(module.kafka[0].private_link_port, null) : null
      }
    }
    simulated_on_prem = {
      classic = {
        mode               = var.connectivity.simulated_on_prem.classic
        service_url        = var.connectivity.simulated_on_prem.classic == "transit_gateway" ? try(module.simulated_on_prem[0].service_url, null) : null
        transit_gateway_id = try(module.simulated_on_prem_transit_gateway[0].transit_gateway_id, null)
      }
      serverless = {
        mode                = var.connectivity.simulated_on_prem.serverless
        endpoint_service    = var.connectivity.simulated_on_prem.serverless == "private_link" ? try(module.simulated_on_prem[0].endpoint_service_name, null) : null
        endpoint_service_id = var.connectivity.simulated_on_prem.serverless == "private_link" ? try(module.simulated_on_prem[0].endpoint_service_id, null) : null
        host                = var.connectivity.simulated_on_prem.serverless == "private_link" ? try(module.simulated_on_prem[0].nlb_dns_name, null) : null
      }
    }
  }
}

locals {
  aws_profile_cli_argument = var.aws_profile == null ? "" : " --profile ${var.aws_profile}"

  endpoint_service_ids = {
    rds_postgres      = try(module.rds_postgres[0].endpoint_service_id, null)
    rds_sql_server    = try(module.rds_sql_server[0].endpoint_service_id, null)
    aurora_postgres   = try(module.aurora_postgres[0].endpoint_service_id, null)
    rabbitmq          = try(module.rabbitmq[0].endpoint_service_id, null)
    kafka             = try(module.kafka[0].endpoint_service_id, null)
    simulated_on_prem = try(module.simulated_on_prem[0].endpoint_service_id, null)
  }

  # Classic endpoints are accepted by Terraform (classic-private-link module);
  # only serverless NCC connections need an explicit review.
  endpoint_connections = [
    for component, rule in try(module.ncc[0].rules, {}) : {
      component   = component
      kind        = "serverless"
      service_id  = lookup(local.endpoint_service_ids, component, null)
      endpoint_id = rule.endpoint_id
      state       = rule.connection_state
    }
  ]
}

output "pending_endpoint_acceptances" {
  description = "Serverless NCC endpoint connections that are not yet established. Classic endpoints are accepted automatically. Pass service_id and endpoint_id to ./infra endpoints aws accept after review."
  value = [
    for connection in local.endpoint_connections : connection
    if !contains(["available", "ESTABLISHED"], coalesce(connection.state, "unknown"))
  ]
}
