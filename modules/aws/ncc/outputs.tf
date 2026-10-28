output "network_connectivity_config_id" {
  value = var.network_connectivity_config_id
}
output "rules" {
  value = {
    for key, rule in databricks_mws_ncc_private_endpoint_rule.this : key => {
      rule_id          = rule.rule_id
      endpoint_id      = rule.vpc_endpoint_id
      connection_state = rule.connection_state
    }
  }
}
