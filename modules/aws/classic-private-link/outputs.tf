output "endpoint_id" {
  value = aws_vpc_endpoint.this.id
}

output "dns_name" {
  value = aws_vpc_endpoint.this.dns_entry[0].dns_name
}

output "host" {
  value = coalesce(var.private_dns_name, aws_vpc_endpoint.this.dns_entry[0].dns_name)
}

output "connection_state" {
  value = aws_vpc_endpoint.this.state
}
