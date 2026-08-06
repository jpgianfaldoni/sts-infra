output "writer_endpoint" {
  value = aws_rds_cluster.this.endpoint
}
output "reader_endpoint" {
  value = aws_rds_cluster.this.reader_endpoint
}
output "proxy_read_write_endpoint" {
  value = try(aws_db_proxy.this[0].endpoint, null)
}
output "proxy_read_only_endpoint" {
  value = try(aws_db_proxy_endpoint.read_only[0].endpoint, null)
}
output "port" {
  value = local.port
}
output "database_name" {
  value = var.database_name
}
output "master_username" {
  value = var.master_username
}
output "master_secret_arn" {
  value = aws_rds_cluster.this.master_user_secret[0].secret_arn
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
output "proxy_security_group_id" {
  value = try(aws_security_group.proxy[0].id, null)
}
output "endpoint_service_name" {
  value = try(aws_vpc_endpoint_service.this[0].service_name, null)
}
