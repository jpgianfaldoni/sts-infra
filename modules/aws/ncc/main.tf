resource "databricks_mws_network_connectivity_config" "this" {
  provider = databricks.mws
  name     = var.name
  region   = var.region
}

resource "databricks_mws_ncc_private_endpoint_rule" "this" {
  for_each = var.private_endpoint_rules
  provider = databricks.mws

  network_connectivity_config_id = databricks_mws_network_connectivity_config.this.network_connectivity_config_id
  endpoint_service               = each.value.endpoint_service
  domain_names                   = each.value.domain_names
}

resource "databricks_mws_ncc_binding" "this" {
  provider = databricks.mws

  network_connectivity_config_id = databricks_mws_network_connectivity_config.this.network_connectivity_config_id
  workspace_id                   = var.workspace_id
  depends_on                     = [databricks_mws_ncc_private_endpoint_rule.this]
}
