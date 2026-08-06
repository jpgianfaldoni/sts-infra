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
  description = "Private Aurora PostgreSQL"
  vpc_id      = module.network.vpc_id
  tags        = var.tags
}

resource "aws_rds_cluster" "this" {
  cluster_identifier              = "${local.name}-postgres"
  engine                          = "aurora-postgresql"
  engine_mode                     = "provisioned"
  engine_version                  = var.engine_version
  database_name                   = var.database_name
  master_username                 = var.master_username
  manage_master_user_password     = true
  port                            = local.port
  db_subnet_group_name            = module.network.db_subnet_group_name
  vpc_security_group_ids          = [aws_security_group.database.id]
  storage_encrypted               = true
  backup_retention_period         = 7
  copy_tags_to_snapshot           = true
  deletion_protection             = var.deletion_protection
  skip_final_snapshot             = var.skip_final_snapshot
  final_snapshot_identifier       = var.skip_final_snapshot ? null : "${local.name}-aurora-final"
  enabled_cloudwatch_logs_exports = ["postgresql"]
  tags                            = var.tags
}

resource "aws_rds_cluster_instance" "this" {
  count                = var.instance_count
  identifier           = "${local.name}-postgres-${count.index + 1}"
  cluster_identifier   = aws_rds_cluster.this.id
  instance_class       = var.instance_class
  engine               = aws_rds_cluster.this.engine
  engine_version       = aws_rds_cluster.this.engine_version
  availability_zone    = module.network.subnet_availability_zones[count.index % length(module.network.subnet_availability_zones)]
  db_subnet_group_name = module.network.db_subnet_group_name
  publicly_accessible  = false
  promotion_tier       = count.index
  tags                 = var.tags
}

data "aws_iam_policy_document" "proxy_assume" {
  count = var.enable_proxy ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "proxy" {
  count              = var.enable_proxy ? 1 : 0
  name               = "${local.name}-proxy"
  assume_role_policy = data.aws_iam_policy_document.proxy_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "proxy" {
  count = var.enable_proxy ? 1 : 0
  name  = "${local.name}-proxy-secret"
  role  = aws_iam_role.proxy[0].id
  policy = jsonencode({ Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_rds_cluster.this.master_user_secret[0].secret_arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${var.region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_security_group" "proxy" {
  count       = var.enable_proxy ? 1 : 0
  name        = "${local.name}-proxy"
  description = "RDS Proxy for Aurora PostgreSQL"
  vpc_id      = module.network.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_egress_rule" "proxy" {
  count                        = var.enable_proxy ? 1 : 0
  security_group_id            = aws_security_group.proxy[0].id
  referenced_security_group_id = aws_security_group.database.id
  from_port                    = local.port
  to_port                      = local.port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "database_from_proxy" {
  count                        = var.enable_proxy ? 1 : 0
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.proxy[0].id
  from_port                    = local.port
  to_port                      = local.port
  ip_protocol                  = "tcp"
}

resource "aws_db_proxy" "this" {
  count                  = var.enable_proxy ? 1 : 0
  name                   = "${local.name}-proxy"
  engine_family          = "POSTGRESQL"
  require_tls            = true
  role_arn               = aws_iam_role.proxy[0].arn
  vpc_security_group_ids = [aws_security_group.proxy[0].id]
  vpc_subnet_ids         = module.network.subnet_ids
  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "DISABLED"
    secret_arn  = aws_rds_cluster.this.master_user_secret[0].secret_arn
  }
  depends_on = [aws_iam_role_policy.proxy]
}

resource "aws_db_proxy_default_target_group" "this" {
  count         = var.enable_proxy ? 1 : 0
  db_proxy_name = aws_db_proxy.this[0].name
  connection_pool_config {
    connection_borrow_timeout    = 120
    max_connections_percent      = 90
    max_idle_connections_percent = 50
  }
}

resource "aws_db_proxy_target" "cluster" {
  count                 = var.enable_proxy ? 1 : 0
  db_cluster_identifier = aws_rds_cluster.this.cluster_identifier
  db_proxy_name         = aws_db_proxy.this[0].name
  target_group_name     = aws_db_proxy_default_target_group.this[0].name
}

resource "aws_db_proxy_endpoint" "read_only" {
  count                  = var.enable_proxy ? 1 : 0
  db_proxy_name          = aws_db_proxy.this[0].name
  db_proxy_endpoint_name = "${local.name}-reader"
  target_role            = "READ_ONLY"
  vpc_security_group_ids = [aws_security_group.proxy[0].id]
  vpc_subnet_ids         = module.network.subnet_ids
  depends_on             = [aws_db_proxy_target.cluster]
}
