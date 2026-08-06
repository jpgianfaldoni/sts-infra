output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "subnet_ids" {
  value = aws_subnet.database[*].id
}

output "subnet_availability_zones" {
  value = aws_subnet.database[*].availability_zone
}

output "route_table_ids" {
  value = [aws_route_table.database.id]
}

output "db_subnet_group_name" {
  value = aws_db_subnet_group.this.name
}
