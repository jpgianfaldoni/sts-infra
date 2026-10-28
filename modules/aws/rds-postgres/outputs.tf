output "host" {
  value = aws_db_instance.this.address
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
  value = aws_db_instance.this.master_user_secret[0].secret_arn
}
output "lakeflow_replication_secret_arn" {
  value = try(aws_secretsmanager_secret.lakeflow_replication[0].arn, null)
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
output "endpoint_service_id" {
  value = try(aws_vpc_endpoint_service.this[0].id, null)
}
output "seed_file" {
  description = "Idempotent sample-data script that the lab check job runs."
  value       = "${path.module}/assets/seed.sql"
}
