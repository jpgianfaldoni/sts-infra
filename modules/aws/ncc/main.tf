
# Databricks rejects concurrent updates to one NCC ("ABORTED: incoming
# resourceVersion is not equal to existing resourceVersion"), so rules are
# created one at a time: one resource per source, each waiting for the one
# before it. A source's rule keeps its address when other sources change.

resource "databricks_mws_ncc_private_endpoint_rule" "rds_postgres" {
  count    = contains(keys(var.private_endpoint_rules), "rds_postgres") ? 1 : 0
  provider = databricks.mws

  network_connectivity_config_id = var.network_connectivity_config_id
  endpoint_service               = var.private_endpoint_rules["rds_postgres"].endpoint_service
  domain_names                   = var.private_endpoint_rules["rds_postgres"].domain_names
}

resource "databricks_mws_ncc_private_endpoint_rule" "rds_sql_server" {
  count    = contains(keys(var.private_endpoint_rules), "rds_sql_server") ? 1 : 0
  provider = databricks.mws

  network_connectivity_config_id = var.network_connectivity_config_id
  endpoint_service               = var.private_endpoint_rules["rds_sql_server"].endpoint_service
  domain_names                   = var.private_endpoint_rules["rds_sql_server"].domain_names

  depends_on = [databricks_mws_ncc_private_endpoint_rule.rds_postgres]
}

resource "databricks_mws_ncc_private_endpoint_rule" "rds_mysql" {
  count    = contains(keys(var.private_endpoint_rules), "rds_mysql") ? 1 : 0
  provider = databricks.mws

  network_connectivity_config_id = var.network_connectivity_config_id
  endpoint_service               = var.private_endpoint_rules["rds_mysql"].endpoint_service
  domain_names                   = var.private_endpoint_rules["rds_mysql"].domain_names

  depends_on = [databricks_mws_ncc_private_endpoint_rule.rds_sql_server]
}

resource "databricks_mws_ncc_private_endpoint_rule" "rds_oracle" {
  count    = contains(keys(var.private_endpoint_rules), "rds_oracle") ? 1 : 0
  provider = databricks.mws

  network_connectivity_config_id = var.network_connectivity_config_id
  endpoint_service               = var.private_endpoint_rules["rds_oracle"].endpoint_service
  domain_names                   = var.private_endpoint_rules["rds_oracle"].domain_names

  depends_on = [databricks_mws_ncc_private_endpoint_rule.rds_mysql]
}

resource "databricks_mws_ncc_private_endpoint_rule" "aurora_postgres" {
  count    = contains(keys(var.private_endpoint_rules), "aurora_postgres") ? 1 : 0
  provider = databricks.mws

  network_connectivity_config_id = var.network_connectivity_config_id
  endpoint_service               = var.private_endpoint_rules["aurora_postgres"].endpoint_service
  domain_names                   = var.private_endpoint_rules["aurora_postgres"].domain_names

  depends_on = [databricks_mws_ncc_private_endpoint_rule.rds_oracle]
}

resource "databricks_mws_ncc_private_endpoint_rule" "rabbitmq" {
  count    = contains(keys(var.private_endpoint_rules), "rabbitmq") ? 1 : 0
  provider = databricks.mws

  network_connectivity_config_id = var.network_connectivity_config_id
  endpoint_service               = var.private_endpoint_rules["rabbitmq"].endpoint_service
  domain_names                   = var.private_endpoint_rules["rabbitmq"].domain_names

  depends_on = [databricks_mws_ncc_private_endpoint_rule.aurora_postgres]
}

resource "databricks_mws_ncc_private_endpoint_rule" "kafka" {
  count    = contains(keys(var.private_endpoint_rules), "kafka") ? 1 : 0
  provider = databricks.mws

  network_connectivity_config_id = var.network_connectivity_config_id
  endpoint_service               = var.private_endpoint_rules["kafka"].endpoint_service
  domain_names                   = var.private_endpoint_rules["kafka"].domain_names

  depends_on = [databricks_mws_ncc_private_endpoint_rule.rabbitmq]
}

resource "databricks_mws_ncc_private_endpoint_rule" "simulated_on_prem" {
  count    = contains(keys(var.private_endpoint_rules), "simulated_on_prem") ? 1 : 0
  provider = databricks.mws

  network_connectivity_config_id = var.network_connectivity_config_id
  endpoint_service               = var.private_endpoint_rules["simulated_on_prem"].endpoint_service
  domain_names                   = var.private_endpoint_rules["simulated_on_prem"].domain_names

  depends_on = [databricks_mws_ncc_private_endpoint_rule.kafka]
}

moved {
  from = databricks_mws_ncc_private_endpoint_rule.this["rds_postgres"]
  to   = databricks_mws_ncc_private_endpoint_rule.rds_postgres[0]
}

moved {
  from = databricks_mws_ncc_private_endpoint_rule.this["rds_sql_server"]
  to   = databricks_mws_ncc_private_endpoint_rule.rds_sql_server[0]
}

moved {
  from = databricks_mws_ncc_private_endpoint_rule.this["rds_mysql"]
  to   = databricks_mws_ncc_private_endpoint_rule.rds_mysql[0]
}

moved {
  from = databricks_mws_ncc_private_endpoint_rule.this["rds_oracle"]
  to   = databricks_mws_ncc_private_endpoint_rule.rds_oracle[0]
}

moved {
  from = databricks_mws_ncc_private_endpoint_rule.this["aurora_postgres"]
  to   = databricks_mws_ncc_private_endpoint_rule.aurora_postgres[0]
}

moved {
  from = databricks_mws_ncc_private_endpoint_rule.this["rabbitmq"]
  to   = databricks_mws_ncc_private_endpoint_rule.rabbitmq[0]
}

moved {
  from = databricks_mws_ncc_private_endpoint_rule.this["kafka"]
  to   = databricks_mws_ncc_private_endpoint_rule.kafka[0]
}

moved {
  from = databricks_mws_ncc_private_endpoint_rule.this["simulated_on_prem"]
  to   = databricks_mws_ncc_private_endpoint_rule.simulated_on_prem[0]
}
