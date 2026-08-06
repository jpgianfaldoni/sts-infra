resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}
locals {
  name                = "${var.name_prefix}-${random_string.suffix.result}"
  port                = 5432
  enable_private_link = var.enable_classic_private_link || var.enable_serverless_private_link
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

module "network" {
  source        = "../private-database-network"
  resource_name = local.name
  vpc_cidr      = var.vpc_cidr
}

resource "aws_security_group" "database" {
  name        = "${local.name}-database"
  description = "Private RDS PostgreSQL"
  vpc_id      = module.network.vpc_id
  tags        = var.tags
}

resource "aws_db_instance" "this" {
  identifier                  = "${local.name}-postgres"
  engine                      = "postgres"
  engine_version              = var.engine_version
  instance_class              = var.instance_class
  allocated_storage           = 20
  storage_type                = "gp3"
  storage_encrypted           = true
  db_name                     = var.database_name
  username                    = var.master_username
  manage_master_user_password = true
  port                        = local.port
  db_subnet_group_name        = module.network.db_subnet_group_name
  vpc_security_group_ids      = [aws_security_group.database.id]
  publicly_accessible         = false
  multi_az                    = false
  backup_retention_period     = 7
  copy_tags_to_snapshot       = true
  deletion_protection         = var.deletion_protection
  skip_final_snapshot         = var.skip_final_snapshot
  final_snapshot_identifier   = var.skip_final_snapshot ? null : "${local.name}-postgres-final"
  tags                        = var.tags
}

data "aws_network_interface" "database" {
  count = local.enable_private_link ? 1 : 0
  filter {
    name   = "group-name"
    values = [aws_security_group.database.name]
  }
  filter {
    name   = "description"
    values = ["RDSNetworkInterface"]
  }
  filter {
    name   = "status"
    values = ["in-use"]
  }
  depends_on = [aws_db_instance.this]
}

resource "aws_security_group" "nlb" {
  count       = local.enable_private_link ? 1 : 0
  name        = "${local.name}-nlb"
  description = "PrivateLink NLB for PostgreSQL"
  vpc_id      = module.network.vpc_id
  tags        = var.tags
}
resource "aws_vpc_security_group_egress_rule" "nlb" {
  count                        = local.enable_private_link ? 1 : 0
  security_group_id            = aws_security_group.nlb[0].id
  referenced_security_group_id = aws_security_group.database.id
  from_port                    = local.port
  to_port                      = local.port
  ip_protocol                  = "tcp"
}
resource "aws_vpc_security_group_ingress_rule" "database" {
  count                        = local.enable_private_link ? 1 : 0
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.nlb[0].id
  from_port                    = local.port
  to_port                      = local.port
  ip_protocol                  = "tcp"
}
resource "aws_lb" "this" {
  count                                                        = local.enable_private_link ? 1 : 0
  name                                                         = substr("${local.name}-pl", 0, 32)
  internal                                                     = true
  load_balancer_type                                           = "network"
  subnets                                                      = module.network.subnet_ids
  security_groups                                              = [aws_security_group.nlb[0].id]
  enable_cross_zone_load_balancing                             = true
  enforce_security_group_inbound_rules_on_private_link_traffic = "off"
  tags                                                         = var.tags
}
resource "aws_lb_target_group" "this" {
  count              = local.enable_private_link ? 1 : 0
  name               = substr("${local.name}-pg", 0, 32)
  port               = local.port
  protocol           = "TCP"
  target_type        = "ip"
  vpc_id             = module.network.vpc_id
  preserve_client_ip = false
  health_check {
    protocol = "TCP"
    port     = "traffic-port"
  }
}
resource "aws_lb_target_group_attachment" "this" {
  count            = local.enable_private_link ? 1 : 0
  target_group_arn = aws_lb_target_group.this[0].arn
  target_id        = data.aws_network_interface.database[0].private_ip
  port             = local.port
}
resource "aws_lb_listener" "this" {
  count             = local.enable_private_link ? 1 : 0
  load_balancer_arn = aws_lb.this[0].arn
  port              = local.port
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[0].arn
  }
}
resource "aws_vpc_endpoint_service" "this" {
  count                      = local.enable_private_link ? 1 : 0
  acceptance_required        = true
  network_load_balancer_arns = [aws_lb.this[0].arn]
  tags                       = var.tags
}
resource "aws_vpc_endpoint_service_allowed_principal" "classic" {
  count                   = var.enable_classic_private_link ? 1 : 0
  vpc_endpoint_service_id = aws_vpc_endpoint_service.this[0].id
  principal_arn           = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
}
resource "aws_vpc_endpoint_service_allowed_principal" "serverless" {
  count                   = var.enable_serverless_private_link ? 1 : 0
  vpc_endpoint_service_id = aws_vpc_endpoint_service.this[0].id
  principal_arn           = "arn:${data.aws_partition.current.partition}:iam::565502421330:role/private-connectivity-role-${var.region}"
}
