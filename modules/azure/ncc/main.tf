# Each rule makes Databricks create a private endpoint that stays Pending until
# the resource owner approves it (./infra endpoints azure approve).
resource "databricks_mws_ncc_private_endpoint_rule" "this" {
  for_each = var.private_endpoint_rules
  provider = databricks.account

  network_connectivity_config_id = var.network_connectivity_config_id
  resource_id                    = each.value.resource_id
  group_id                       = each.value.group_id
}

resource "databricks_mws_ncc_binding" "this" {
  provider = databricks.account

  network_connectivity_config_id = var.network_connectivity_config_id
  workspace_id                   = var.workspace_id
  depends_on                     = [databricks_mws_ncc_private_endpoint_rule.this]
}
