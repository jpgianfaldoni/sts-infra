output "workspace_id" {
  value = databricks_mws_workspaces.this.workspace_id
}

output "workspace_url" {
  value = "https://${trimprefix(trimprefix(databricks_mws_workspaces.this.workspace_url, "https://"), "http://")}"
}

output "workspace_status" {
  value = databricks_mws_workspaces.this.workspace_status
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "private_route_table_ids" {
  value = [aws_route_table.private.id]
}

output "security_group_id" {
  value = aws_security_group.workspace.id
}

output "root_bucket_name" {
  value = aws_s3_bucket.root.bucket
}

output "network_id" {
  value = databricks_mws_networks.this.network_id
}

output "backend_private_link" {
  description = "Back-end PrivateLink configuration and endpoint IDs."
  value = {
    enabled                    = var.backend_private_link.enabled
    public_access_enabled      = var.backend_private_link.public_access_enabled
    general_access_endpoint_id = try(aws_vpc_endpoint.general_access[0].id, null)
    scc_relay_endpoint_id      = try(aws_vpc_endpoint.scc_relay[0].id, null)
  }
}
