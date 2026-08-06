output "workspace_url" {
  value = try(module.workspace[0].workspace_url, null)
}
output "sql_database" {
  value = try({ host = module.sql_database[0].host
    port     = module.sql_database[0].port
    database = module.sql_database[0].database_name
    username = module.sql_database[0].admin_username
  }, null)
}
output "sql_database_password" {
  value     = try(module.sql_database[0].admin_password, null)
  sensitive = true
}
output "sql_server_vm" {
  value = try({ host = module.sql_server_vm[0].host
    port     = module.sql_server_vm[0].port
    username = module.sql_server_vm[0].sql_username
  }, null)
}
output "sql_server_vm_password" {
  value     = try(module.sql_server_vm[0].sql_password, null)
  sensitive = true
}
