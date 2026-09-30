output "internal_host" {
  description = "Broker private IP used by classic compute over VPC peering."
  value       = aws_instance.broker.private_ip
}

output "internal_port" {
  value = local.internal_port
}

output "private_link_host" {
  description = "NLB hostname advertised by the Kafka PrivateLink listener and bound by endpoint DNS."
  value       = local.enable_private_link ? aws_lb.this[0].dns_name : null
}

output "private_link_port" {
  value = local.private_link_port
}

output "topic_name" {
  value = var.topic_name
}

output "secret_arn" {
  value = aws_secretsmanager_secret.broker.arn
}

output "instance_id" {
  value = aws_instance.broker.id
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
output "endpoint_service_id" {
  value = try(aws_vpc_endpoint_service.this[0].id, null)
}
