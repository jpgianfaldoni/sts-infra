output "host" {
  value = try(aws_lb.this[0].dns_name, aws_instance.broker.private_dns)
}
output "port" {
  value = local.port
}
output "secret_arn" {
  value = aws_secretsmanager_secret.broker.arn
}
output "vpc_id" {
  value = aws_vpc.this.id
}
output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}
output "route_table_ids" {
  value = [aws_route_table.private.id]
}
output "security_group_id" {
  value = aws_security_group.broker.id
}
output "endpoint_service_name" {
  value = try(aws_vpc_endpoint_service.this[0].service_name, null)
}
