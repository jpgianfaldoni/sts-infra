output "workspace_url" {
  value = try(module.workspace[0].workspace_url, null)
}
output "workspace_id" {
  description = "Databricks workspace ID, or null when no workspace is managed."
  value       = try(module.workspace[0].workspace_id, null)
}
output "workspace_front_end_private_link" {
  description = "Workspace inbound access. The databricks_ui_api endpoint always exists; the browser_authentication endpoint is created only when browser_authentication_enabled is true."
  value = var.features.workspace ? {
    public_network_access_enabled              = try(module.workspace[0].public_network_access_enabled, null)
    ui_api_private_endpoint_id                 = try(module.workspace[0].ui_api_private_endpoint_id, null)
    browser_authentication_enabled             = local.browser_authentication_enabled
    browser_authentication_private_endpoint_id = try(module.workspace[0].browser_authentication_private_endpoint_id, null)
  } : null
}
output "test_vm" {
  value = var.features.workspace && var.features.test_vm ? {
    name                = try(module.test_vm[0].name, null)
    resource_group_name = try(module.test_vm[0].resource_group_name, null)
    public_ip           = try(module.test_vm[0].public_ip, null)
    private_ip          = try(module.test_vm[0].private_ip, null)
    admin_username      = var.test_vm.admin_username
    azure_cli_command   = try(module.test_vm[0].azure_cli_command, null)
    # Direct SSH when test_vm.admin_ssh_public_key is set; null otherwise.
    ssh_command                     = try(module.test_vm[0].ssh_command, null)
    password_authentication_enabled = var.test_vm.admin_ssh_public_key == null
  } : null
}
output "external_volume_storage" {
  value = var.features.workspace && var.features.external_volume_storage ? {
    storage_account_name          = try(module.external_volume_storage[0].storage_account_name, null)
    metastore_id                  = try(module.external_volume_storage[0].metastore_id, null)
    metastore_mode                = try(module.external_volume_storage[0].metastore_mode, null)
    metastore_created             = try(module.external_volume_storage[0].metastore_created, null)
    metastore_resolution          = try(module.external_volume_storage[0].metastore_resolution, null)
    container_name                = var.external_volume_storage.container_name
    public_network_access_enabled = try(module.external_volume_storage[0].public_network_access_enabled, null)
    bootstrap_access_enabled      = try(module.external_volume_storage[0].bootstrap_access_enabled, null)
    connectivity_status           = try(module.external_volume_storage[0].connectivity_status, null)
    external_location_url         = try(module.external_volume_storage[0].external_location_url, null)
    external_location_name        = try(module.external_volume_storage[0].external_location_name, null)
    volume_path                   = try(module.external_volume_storage[0].volume_path, null)
  } : null

  precondition {
    condition     = try(module.external_volume_storage[0].metastore_resolution, "") != "ambiguous"
    error_message = "external_volume_storage.metastore_mode = \"auto\" found ${try(module.external_volume_storage[0].other_regional_metastore_count, 0)} metastores in ${var.location} and cannot choose one. Set metastore_mode = \"existing\" with metastore_id, or metastore_mode = \"create\"."
  }
}
output "custom_dns" {
  value = try({
    private_ip = module.custom_dns[0].private_ip
    vm_id      = module.custom_dns[0].vm_id
  }, null)
}
output "sql_database" {
  value = var.features.sql_database ? {
    host                      = try(module.sql_database[0].host, null)
    port                      = try(module.sql_database[0].port, null)
    database                  = try(module.sql_database[0].database_name, null)
    username                  = try(module.sql_database[0].admin_username, null)
    server_id                 = try(module.sql_database[0].server_id, null)
    entra_admin_object_id     = try(module.sql_database[0].entra_admin_object_id, null)
    workspace_peering_enabled = length(module.sql_database_workspace_peering) > 0
    password_secret_name      = local.key_vault_enabled ? "sql-database-admin-password" : null
  } : null
}
output "sql_database_password" {
  description = "Deprecated: read the password from the Key Vault named in the key_vault output instead. Removed in the next release."
  value       = try(module.sql_database[0].admin_password, null)
  sensitive   = true
}
output "sql_server_vm" {
  value = try({ host = module.sql_server_vm[0].host
    port     = module.sql_server_vm[0].port
    username = module.sql_server_vm[0].sql_username
  }, null)
}
output "sql_server_vm_password" {
  description = "Deprecated: read the password from the Key Vault named in the key_vault output instead. Removed in the next release."
  value       = try(module.sql_server_vm[0].sql_password, null)
  sensitive   = true
}
output "key_vault" {
  description = "Key Vault holding the generated SQL credentials (names only), and the Key Vault-backed Databricks secret scope when one exists."
  value = local.key_vault_enabled ? {
    name                    = try(module.key_vault[0].name, null)
    uri                     = try(module.key_vault[0].uri, null)
    id                      = try(module.key_vault[0].id, null)
    resource_group_name     = try(module.key_vault[0].resource_group_name, null)
    secret_names            = local.key_vault_secret_names
    databricks_secret_scope = var.features.workspace && var.key_vault.databricks_secret_scope_enabled ? var.key_vault.secret_scope_name : null
  } : null
}
output "serverless_connectivity" {
  description = "NCC used for serverless Private Link, with one entry per private endpoint rule."
  value = length(local.serverless_private_endpoint_rules) > 0 ? {
    network_connectivity_config_id = try(module.ncc[0].network_connectivity_config_id, null)
    rules                          = try(module.ncc[0].rules, {})
  } : null
}
output "pending_endpoint_approvals" {
  description = "Databricks-managed private endpoints not yet established. After review, approve each on its target resource with ./infra endpoints azure approve."
  value = [
    for component, rule in try(module.ncc[0].rules, {}) : {
      component        = component
      resource_id      = rule.resource_id
      group_id         = rule.group_id
      rule_id          = rule.rule_id
      endpoint_name    = rule.endpoint_name
      connection_state = rule.connection_state
    }
    if coalesce(rule.connection_state, "UNKNOWN") != "ESTABLISHED"
  ]
}
