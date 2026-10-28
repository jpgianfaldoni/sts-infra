resource "databricks_mws_storage_configurations" "this" {
  provider                   = databricks.mws
  account_id                 = var.databricks_account_id
  storage_configuration_name = "${var.resource_prefix}-storage"
  bucket_name                = aws_s3_bucket.root.bucket
  depends_on                 = [aws_s3_bucket_policy.root]
}

resource "databricks_mws_credentials" "this" {
  provider         = databricks.mws
  credentials_name = "${var.resource_prefix}-credentials"
  role_arn         = aws_iam_role.cross_account.arn
  depends_on       = [time_sleep.iam_propagation]
}

resource "databricks_mws_networks" "this" {
  provider           = databricks.mws
  account_id         = var.databricks_account_id
  network_name       = "${var.resource_prefix}-network"
  vpc_id             = aws_vpc.this.id
  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.workspace.id]

  dynamic "vpc_endpoints" {
    for_each = var.backend_private_link.enabled ? [true] : []
    content {
      dataplane_relay = [databricks_mws_vpc_endpoint.scc_relay[0].vpc_endpoint_id]
      rest_api        = [databricks_mws_vpc_endpoint.general_access[0].vpc_endpoint_id]
    }
  }

  depends_on = [
    aws_route.private_nat,
    aws_route_table_association.private,
    aws_vpc_endpoint.s3,
    aws_vpc_security_group_ingress_rule.self,
    aws_vpc_security_group_egress_rule.self,
    aws_vpc_security_group_egress_rule.control_plane,
    aws_vpc_endpoint.general_access,
    aws_vpc_endpoint.kinesis,
    aws_vpc_endpoint.scc_relay,
    aws_vpc_endpoint.sts,
  ]
}

resource "databricks_mws_workspaces" "this" {
  provider                       = databricks.mws
  network_connectivity_config_id = var.network_connectivity_config_id
  account_id                     = var.databricks_account_id
  aws_region                     = var.region
  workspace_name                 = var.workspace_name
  pricing_tier                   = var.pricing_tier
  credentials_id                 = databricks_mws_credentials.this.credentials_id
  storage_configuration_id       = databricks_mws_storage_configurations.this.storage_configuration_id
  network_id                     = databricks_mws_networks.this.network_id
  private_access_settings_id     = var.backend_private_link.enabled ? databricks_mws_private_access_settings.this[0].private_access_settings_id : null

  timeouts {
    create = "30m"
    read   = "10m"
    update = "20m"
  }
}
