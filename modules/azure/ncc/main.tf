# Databricks rejects concurrent updates to one NCC ("ABORTED: incoming
# resourceVersion is not equal to existing resourceVersion"), so rules are
# created one at a time: one resource per source, each waiting for the one
# before it. A source's rule keeps its address when other sources change.

resource "databricks_mws_ncc_private_endpoint_rule" "sql_database" {
  count    = contains(keys(var.private_endpoint_rules), "sql_database") ? 1 : 0
  provider = databricks.account

  network_connectivity_config_id = var.network_connectivity_config_id
  resource_id                    = var.private_endpoint_rules["sql_database"].resource_id
  group_id                       = var.private_endpoint_rules["sql_database"].group_id
}

resource "databricks_mws_ncc_private_endpoint_rule" "mysql_flexible_server" {
  count    = contains(keys(var.private_endpoint_rules), "mysql_flexible_server") ? 1 : 0
  provider = databricks.account

  network_connectivity_config_id = var.network_connectivity_config_id
  resource_id                    = var.private_endpoint_rules["mysql_flexible_server"].resource_id
  group_id                       = var.private_endpoint_rules["mysql_flexible_server"].group_id

  depends_on = [databricks_mws_ncc_private_endpoint_rule.sql_database]
}

moved {
  from = databricks_mws_ncc_private_endpoint_rule.this["sql_database"]
  to   = databricks_mws_ncc_private_endpoint_rule.sql_database[0]
}

moved {
  from = databricks_mws_ncc_private_endpoint_rule.this["mysql_flexible_server"]
  to   = databricks_mws_ncc_private_endpoint_rule.mysql_flexible_server[0]
}

resource "databricks_mws_ncc_binding" "this" {
  provider = databricks.account

  network_connectivity_config_id = var.network_connectivity_config_id
  workspace_id                   = var.workspace_id
  depends_on                     = [databricks_mws_ncc_private_endpoint_rule.sql_database, databricks_mws_ncc_private_endpoint_rule.mysql_flexible_server]
}
