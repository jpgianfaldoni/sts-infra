output "workspace_url" {
  value = try(module.workspace[0].workspace_url, null)
}
output "catalog_name" {
  value = try(module.unity_catalog[0].catalog_name, null)
}
output "rds_postgres" {
  value = try({ host = module.rds_postgres[0].host
    port       = module.rds_postgres[0].port
    database   = module.rds_postgres[0].database_name
    username   = module.rds_postgres[0].master_username
    secret_arn = module.rds_postgres[0].master_secret_arn
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
output "simulated_on_prem" {
  value = try({
    vpc_id       = module.simulated_on_prem[0].vpc_id
    instance_id  = module.simulated_on_prem[0].instance_id
    private_ip   = module.simulated_on_prem[0].private_ip
    service_port = module.simulated_on_prem[0].service_port
    service_url  = module.simulated_on_prem[0].service_url
    ssm_command  = "aws ssm start-session --target ${module.simulated_on_prem[0].instance_id} --region ${var.region}"
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
        mode        = var.connectivity.rds_postgres.classic
        host        = var.connectivity.rds_postgres.classic == "private_link" ? try(module.rds_postgres_classic_private_link[0].dns_name, null) : var.connectivity.rds_postgres.classic == "peering" ? try(module.rds_postgres[0].host, null) : null
        endpoint_id = try(module.rds_postgres_classic_private_link[0].endpoint_id, null)
      }
      serverless = {
        mode = var.connectivity.rds_postgres.serverless
        host = var.connectivity.rds_postgres.serverless == "private_link" ? try(module.rds_postgres[0].host, null) : null
      }
    }
    rds_sql_server = {
      classic = {
        mode        = var.connectivity.rds_sql_server.classic
        host        = var.connectivity.rds_sql_server.classic == "private_link" ? try(module.rds_sql_server_classic_private_link[0].dns_name, null) : var.connectivity.rds_sql_server.classic == "peering" ? try(module.rds_sql_server[0].host, null) : null
        endpoint_id = try(module.rds_sql_server_classic_private_link[0].endpoint_id, null)
      }
      serverless = {
        mode = var.connectivity.rds_sql_server.serverless
        host = var.connectivity.rds_sql_server.serverless == "private_link" ? try(module.rds_sql_server[0].host, null) : null
      }
    }
    aurora_postgres = {
      classic = {
        mode        = var.connectivity.aurora_postgres.classic
        host        = var.connectivity.aurora_postgres.classic == "private_link" ? try(module.aurora_postgres_classic_private_link[0].dns_name, null) : var.connectivity.aurora_postgres.classic == "peering" ? try(module.aurora_postgres[0].reader_endpoint, null) : null
        endpoint_id = try(module.aurora_postgres_classic_private_link[0].endpoint_id, null)
      }
      serverless = {
        mode = var.connectivity.aurora_postgres.serverless
        host = var.connectivity.aurora_postgres.serverless == "private_link" ? try(module.aurora_postgres[0].reader_endpoint, null) : null
      }
    }
    rabbitmq = {
      classic = {
        mode        = var.connectivity.rabbitmq.classic
        host        = var.connectivity.rabbitmq.classic == "private_link" ? try(module.rabbitmq_classic_private_link[0].dns_name, null) : var.connectivity.rabbitmq.classic == "peering" ? try(module.rabbitmq[0].host, null) : null
        endpoint_id = try(module.rabbitmq_classic_private_link[0].endpoint_id, null)
      }
      serverless = {
        mode = var.connectivity.rabbitmq.serverless
        host = var.connectivity.rabbitmq.serverless == "private_link" ? try(module.rabbitmq[0].host, null) : null
      }
    }
    simulated_on_prem = {
      classic = {
        mode               = var.connectivity.simulated_on_prem.classic
        service_url        = var.connectivity.simulated_on_prem.classic == "transit_gateway" ? try(module.simulated_on_prem[0].service_url, null) : null
        transit_gateway_id = try(module.simulated_on_prem_transit_gateway[0].transit_gateway_id, null)
      }
    }
  }
}
