resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}
resource "random_password" "broker" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+"
}
locals {
  name                = "${var.name_prefix}-${random_string.suffix.result}"
  port                = 5672
  enable_private_link = var.enable_classic_private_link || var.enable_serverless_private_link
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = merge(var.tags, { Name = "${local.name}-vpc"
  })
}
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 1)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = merge(var.tags, { Name = "${local.name}-private-${count.index + 1}"
  })
}
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 101)
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false
  tags = merge(var.tags, { Name = "${local.name}-public"
  })
}
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags = merge(var.tags, { Name = "${local.name}-igw"
  })
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags = merge(var.tags, { Name = "${local.name}-public"
  })
}
resource "aws_route" "public" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = var.tags
}
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  depends_on    = [aws_internet_gateway.this]
  tags          = var.tags
}
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags = merge(var.tags, { Name = "${local.name}-private"
  })
}
resource "aws_route" "private" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}
resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "broker" {
  name        = "${local.name}-broker"
  description = "Private RabbitMQ host"
  vpc_id      = aws_vpc.this.id
  tags        = var.tags
}
resource "aws_vpc_security_group_egress_rule" "broker" {
  security_group_id = aws_security_group.broker.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
resource "aws_secretsmanager_secret" "broker" {
  name_prefix             = "${local.name}-credentials-"
  recovery_window_in_days = 7
  tags                    = var.tags
}
resource "aws_secretsmanager_secret_version" "broker" {
  secret_id = aws_secretsmanager_secret.broker.id
  secret_string = jsonencode({ username = var.broker_username
    password = random_password.broker.result
  })
}
resource "aws_iam_role" "broker" {
  name = "${local.name}-broker"
  assume_role_policy = jsonencode({ Version = "2012-10-17"
    Statement = [{ Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}
resource "aws_iam_role_policy" "secret" {
  name = "read-rabbitmq-secret"
  role = aws_iam_role.broker.id
  policy = jsonencode({ Version = "2012-10-17"
    Statement = [{ Effect = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.broker.arn
    }]
  })
}
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.broker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_instance_profile" "broker" {
  name = "${local.name}-broker"
  role = aws_iam_role.broker.name
}
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["137112412989"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}
resource "aws_instance" "broker" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private[0].id
  vpc_security_group_ids      = [aws_security_group.broker.id]
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.broker.name
  user_data_replace_on_change = true
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 20
  }
  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    dnf install -y docker jq
    systemctl enable --now docker
    secret_json=$(aws secretsmanager get-secret-value --region ${var.region
  } --secret-id ${aws_secretsmanager_secret.broker.arn
  } --query SecretString --output text)
    username=$(printf '%s' "$secret_json" | jq -r .username)
    password=$(printf '%s' "$secret_json" | jq -r .password)
    docker run -d --name rabbitmq --restart unless-stopped -e RABBITMQ_DEFAULT_USER="$username" -e RABBITMQ_DEFAULT_PASS="$password" -p ${local.port
  }:${local.port
  } ${var.rabbitmq_image
}
    unset secret_json username password
  EOT
depends_on = [aws_iam_role_policy.secret, aws_iam_role_policy_attachment.ssm, aws_route.private, aws_secretsmanager_secret_version.broker]
tags = merge(var.tags, { Name = "${local.name}-broker"
})
}

resource "aws_security_group" "nlb" {
  count       = local.enable_private_link ? 1 : 0
  name        = "${local.name}-nlb"
  description = "PrivateLink NLB for RabbitMQ"
  vpc_id      = aws_vpc.this.id
  tags        = var.tags
}
resource "aws_vpc_security_group_egress_rule" "nlb" {
  count                        = local.enable_private_link ? 1 : 0
  security_group_id            = aws_security_group.nlb[0].id
  referenced_security_group_id = aws_security_group.broker.id
  from_port                    = local.port
  to_port                      = local.port
  ip_protocol                  = "tcp"
}
resource "aws_vpc_security_group_ingress_rule" "broker_from_nlb" {
  count                        = local.enable_private_link ? 1 : 0
  security_group_id            = aws_security_group.broker.id
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
  subnets                                                      = aws_subnet.private[*].id
  security_groups                                              = [aws_security_group.nlb[0].id]
  enable_cross_zone_load_balancing                             = true
  enforce_security_group_inbound_rules_on_private_link_traffic = "off"
  tags                                                         = var.tags
}
resource "aws_lb_target_group" "this" {
  count              = local.enable_private_link ? 1 : 0
  name               = substr("${local.name}-amqp", 0, 32)
  port               = local.port
  protocol           = "TCP"
  target_type        = "instance"
  vpc_id             = aws_vpc.this.id
  preserve_client_ip = false
  health_check {
    protocol = "TCP"
    port     = "traffic-port"
  }
}
resource "aws_lb_target_group_attachment" "this" {
  count            = local.enable_private_link ? 1 : 0
  target_group_arn = aws_lb_target_group.this[0].arn
  target_id        = aws_instance.broker.id
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
