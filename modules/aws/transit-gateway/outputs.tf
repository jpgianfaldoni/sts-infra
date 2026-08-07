output "transit_gateway_id" {
  value = aws_ec2_transit_gateway.this.id
}

output "route_table_id" {
  value = aws_ec2_transit_gateway_route_table.this.id
}

output "workspace_attachment_id" {
  value = aws_ec2_transit_gateway_vpc_attachment.workspace.id
}

output "on_prem_attachment_id" {
  value = aws_ec2_transit_gateway_vpc_attachment.on_prem.id
}
