output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "workload_route_table_ids" {
  value = [aws_route_table.workload.id]
}

output "host_security_group_id" {
  value = aws_security_group.host.id
}

output "instance_id" {
  value = aws_instance.host.id
}

output "private_ip" {
  value = aws_instance.host.private_ip
}

output "service_port" {
  value = var.service_port
}

output "service_url" {
  value = "http://${aws_instance.host.private_ip}:${var.service_port}/health"
}

output "endpoint_service_name" {
  value = try(aws_vpc_endpoint_service.this[0].service_name, null)
}

output "nlb_dns_name" {
  value = try(aws_lb.this[0].dns_name, null)
}
