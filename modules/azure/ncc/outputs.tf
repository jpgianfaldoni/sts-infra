output "network_connectivity_config_id" {
  value = var.network_connectivity_config_id
}

output "rules" {
  value = {
    for key, rule in merge(
      { for rule in databricks_mws_ncc_private_endpoint_rule.sql_database : "sql_database" => rule },
      { for rule in databricks_mws_ncc_private_endpoint_rule.mysql_flexible_server : "mysql_flexible_server" => rule },
      ) : key => {
      rule_id          = rule.rule_id
      resource_id      = rule.resource_id
      group_id         = rule.group_id
      endpoint_name    = rule.endpoint_name
      connection_state = rule.connection_state
    }
  }
}
