output "network_connectivity_config_id" {
  value = var.network_connectivity_config_id
}
output "rules" {
  value = {
    for key, rule in merge(
      { for rule in databricks_mws_ncc_private_endpoint_rule.rds_postgres : "rds_postgres" => rule },
      { for rule in databricks_mws_ncc_private_endpoint_rule.rds_sql_server : "rds_sql_server" => rule },
      { for rule in databricks_mws_ncc_private_endpoint_rule.rds_mysql : "rds_mysql" => rule },
      { for rule in databricks_mws_ncc_private_endpoint_rule.rds_oracle : "rds_oracle" => rule },
      { for rule in databricks_mws_ncc_private_endpoint_rule.aurora_postgres : "aurora_postgres" => rule },
      { for rule in databricks_mws_ncc_private_endpoint_rule.rabbitmq : "rabbitmq" => rule },
      { for rule in databricks_mws_ncc_private_endpoint_rule.kafka : "kafka" => rule },
      { for rule in databricks_mws_ncc_private_endpoint_rule.simulated_on_prem : "simulated_on_prem" => rule },
      ) : key => {
      rule_id          = rule.rule_id
      endpoint_id      = rule.vpc_endpoint_id
      connection_state = rule.connection_state
    }
  }
}
