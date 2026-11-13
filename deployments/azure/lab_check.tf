# Sample data and network path checks, run with ./infra verify. The Azure SQL
# credentials come from the Key Vault-backed secret scope; without that scope
# the checks only test TCP reachability.
locals {
  sql_database_classic_mode = var.sql_database.workspace_peering_enabled ? "peering" : "none"
  lab_check_sql_scope       = var.features.workspace && local.key_vault_enabled && var.key_vault.databricks_secret_scope_enabled ? var.key_vault.secret_scope_name : null

  lab_check_sources = merge(
    var.features.sql_database ? {
      sql_database = {
        engine       = local.lab_check_sql_scope == null ? "tcp" : "sqlserver"
        classic      = local.sql_database_classic_mode
        serverless   = var.connectivity.sql_database.serverless
        host         = module.sql_database[0].host
        port         = module.sql_database[0].port
        database     = module.sql_database[0].database_name
        seed_file    = local.lab_check_sql_scope == null ? null : module.sql_database[0].seed_file
        secret_scope = local.lab_check_sql_scope
        username_key = "sql-database-admin-username"
        password_key = "sql-database-admin-password"
        # Lakeflow Connect source setup; the ingestion login lives in Key Vault.
        cdc_method = local.lab_check_sql_scope != null && local.sql_database_lakeflow && local.key_vault_enabled ? "sqlserver_ct" : null
        # Key Vault secret names allow hyphens but not underscores.
        cdc_username_key = "sql-database-lakeflow-username"
        cdc_password_key = "sql-database-lakeflow-password"
      }
    } : {},
    var.features.mysql_flexible_server ? {
      mysql_flexible_server = {
        engine       = local.lab_check_sql_scope == null ? "tcp" : "mysql"
        classic      = var.mysql_flexible_server.workspace_peering_enabled ? "peering" : "none"
        serverless   = var.connectivity.mysql_flexible_server.serverless
        host         = module.mysql_flexible_server[0].host
        port         = module.mysql_flexible_server[0].port
        database     = module.mysql_flexible_server[0].database_name
        seed_file    = local.lab_check_sql_scope == null ? null : module.mysql_flexible_server[0].seed_file
        secret_scope = local.lab_check_sql_scope
        username_key = "mysql-flexible-server-admin-username"
        password_key = "mysql-flexible-server-admin-password"
        cdc_method   = local.lab_check_sql_scope != null && local.mysql_flexible_server_lakeflow ? "mysql_binlog" : null
        # Key Vault secret names allow hyphens but not underscores.
        cdc_username_key = "mysql-flexible-server-lakeflow-username"
        cdc_password_key = "mysql-flexible-server-lakeflow-password"
      }
    } : {},
  )

  lab_checks = merge({}, flatten([
    for source, config in local.lab_check_sources : [
      for compute in ["classic", "serverless"] : {
        "${source}_${compute}" = {
          source           = source
          path             = compute
          mode             = config[compute]
          engine           = config.engine
          host             = config.host
          port             = config.port
          database         = config.engine == "tcp" ? null : config.database
          seed_database    = config.engine == "tcp" ? null : config.database
          seed_file        = config.seed_file
          secret_scope     = config.engine == "tcp" ? null : config.secret_scope
          username_key     = config.engine == "tcp" ? null : config.username_key
          password_key     = config.engine == "tcp" ? null : config.password_key
          run_after        = compute == "serverless" && config.classic != "none" ? "${source}_classic" : null
          cdc_method       = config.cdc_method
          cdc_username_key = config.cdc_method == null ? null : config.cdc_username_key
          cdc_password_key = config.cdc_method == null ? null : config.cdc_password_key
        }
      } if config[compute] != "none"
    ]
  ])...)

  lab_check_enabled = var.features.workspace && var.lab_check.enabled && length(local.lab_checks) > 0
}

module "lab_check" {
  count  = local.lab_check_enabled ? 1 : 0
  source = "../../modules/shared/lab-check"
  providers = {
    databricks = databricks.workspace
  }

  cloud             = "azure"
  name_prefix       = local.name_prefix
  checks            = local.lab_checks
  classic_node_type = var.lab_check.classic_node_type

  # The module's data sources call the workspace API, so they wait for the
  # workspace (deferred to apply time when it is new), and the Key
  # Vault-backed scope must exist before a run reads it.
  depends_on = [module.workspace, module.key_vault]
}
