resource "databricks_mws_ncc_private_endpoint_rule" "this" {
  for_each = var.private_endpoint_rules
  provider = databricks.mws

  network_connectivity_config_id = var.network_connectivity_config_id
  endpoint_service               = each.value.endpoint_service
  domain_names                   = each.value.domain_names
}
