output "host" {
  value = aws_db_instance.this.address
}
output "port" {
  value = local.port
}
output "master_username" {
  value = var.master_username
}
output "master_secret_arn" {
  value = aws_db_instance.this.master_user_secret[0].secret_arn
}
output "vpc_id" {
  value = module.network.vpc_id
}
output "vpc_cidr" {
  value = module.network.vpc_cidr
}
output "route_table_ids" {
  value = module.network.route_table_ids
}
output "security_group_id" {
  value = aws_security_group.database.id
}
output "endpoint_service_name" {
  value = try(aws_vpc_endpoint_service.this[0].service_name, null)
}
