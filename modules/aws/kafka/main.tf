resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "random_password" "broker" {
  count = var.ephemeral_credentials ? 0 : 1

  length  = 32
  special = false
}

# With ephemeral credentials the password exists only while Terraform runs: it
# is written once to Secrets Manager through a write-only attribute and never
# stored in state. The broker reads it from Secrets Manager at boot.
ephemeral "random_password" "broker" {
  count = var.ephemeral_credentials ? 1 : 0

  length  = 32
  special = false
}

moved {
  from = random_password.broker
  to   = random_password.broker[0]
}

locals {
  name                = "${var.name_prefix}-${random_string.suffix.result}"
  local_port          = 19092
  internal_port       = 9092
  private_link_port   = 9094
  enable_private_link = var.enable_classic_private_link || var.enable_serverless_private_link
  private_link_host   = local.enable_private_link ? aws_lb.this[0].dns_name : "127.0.0.1"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
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

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(var.tags, { Name = "${local.name}-vpc" })
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 1)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = merge(var.tags, { Name = "${local.name}-private-${count.index + 1}" })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 101)
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false
  tags                    = merge(var.tags, { Name = "${local.name}-public" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${local.name}-igw" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${local.name}-public" })
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
  tags   = merge(var.tags, { Name = "${local.name}-private" })
}

resource "aws_route" "private" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "broker" {
  name        = "${local.name}-broker"
  description = "Private single-node Kafka lab broker"
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
  secret_string = var.ephemeral_credentials ? null : jsonencode({
    username = var.broker_username
    password = one(random_password.broker[*].result)
    topic    = var.topic_name
  })
  secret_string_wo = var.ephemeral_credentials ? jsonencode({
    username = var.broker_username
    password = one(ephemeral.random_password.broker[*].result)
    topic    = var.topic_name
  }) : null
  secret_string_wo_version = var.ephemeral_credentials ? 1 : null
}

resource "aws_iam_role" "broker" {
  name = "${local.name}-broker"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "secret" {
  name = "read-kafka-secret"
  role = aws_iam_role.broker.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
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

resource "aws_security_group" "nlb" {
  count = local.enable_private_link ? 1 : 0

  name        = "${local.name}-nlb"
  description = "PrivateLink NLB for the Kafka lab broker"
  vpc_id      = aws_vpc.this.id
  tags        = var.tags
}

resource "aws_vpc_security_group_egress_rule" "nlb" {
  count = local.enable_private_link ? 1 : 0

  security_group_id            = aws_security_group.nlb[0].id
  referenced_security_group_id = aws_security_group.broker.id
  from_port                    = local.private_link_port
  to_port                      = local.private_link_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "broker_from_nlb" {
  count = local.enable_private_link ? 1 : 0

  security_group_id            = aws_security_group.broker.id
  referenced_security_group_id = aws_security_group.nlb[0].id
  from_port                    = local.private_link_port
  to_port                      = local.private_link_port
  ip_protocol                  = "tcp"
}

resource "aws_lb" "this" {
  count = local.enable_private_link ? 1 : 0

  name                                                         = trimsuffix(substr("${local.name}-pl", 0, 32), "-")
  internal                                                     = true
  load_balancer_type                                           = "network"
  subnets                                                      = aws_subnet.private[*].id
  security_groups                                              = [aws_security_group.nlb[0].id]
  enable_cross_zone_load_balancing                             = true
  enforce_security_group_inbound_rules_on_private_link_traffic = "off"
  tags                                                         = var.tags
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
    volume_size = 30
  }

  user_data = templatefile("${path.module}/assets/user_data.sh.tftpl", {
    region                    = var.region
    secret_arn                = aws_secretsmanager_secret.broker.arn
    kafka_image               = var.kafka_image
    topic_name                = var.topic_name
    producer_interval_seconds = var.producer_interval_seconds
    local_port                = local.local_port
    internal_port             = local.internal_port
    private_link_port         = local.private_link_port
    private_link_host         = local.private_link_host
  })

  depends_on = [
    aws_iam_role_policy.secret,
    aws_iam_role_policy_attachment.ssm,
    aws_route.private,
    aws_secretsmanager_secret_version.broker,
  ]

  tags = merge(var.tags, { Name = "${local.name}-broker" })

  # A newer Amazon Linux image must not replace a running lab broker.
  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_lb_target_group" "this" {
  count = local.enable_private_link ? 1 : 0

  name               = trimsuffix(substr("${local.name}-kafka", 0, 32), "-")
  port               = local.private_link_port
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
  count = local.enable_private_link ? 1 : 0

  target_group_arn = aws_lb_target_group.this[0].arn
  target_id        = aws_instance.broker.id
  port             = local.private_link_port
}

resource "aws_lb_listener" "this" {
  count = local.enable_private_link ? 1 : 0

  load_balancer_arn = aws_lb.this[0].arn
  port              = local.private_link_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[0].arn
  }
}

resource "aws_vpc_endpoint_service" "this" {
  count = local.enable_private_link ? 1 : 0

  acceptance_required        = true
  network_load_balancer_arns = [aws_lb.this[0].arn]
  tags                       = var.tags
}

resource "aws_vpc_endpoint_service_allowed_principal" "classic" {
  count = var.enable_classic_private_link ? 1 : 0

  vpc_endpoint_service_id = aws_vpc_endpoint_service.this[0].id
  principal_arn           = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
}

resource "aws_vpc_endpoint_service_allowed_principal" "serverless" {
  count = var.enable_serverless_private_link ? 1 : 0

  vpc_endpoint_service_id = aws_vpc_endpoint_service.this[0].id
  principal_arn           = "arn:${data.aws_partition.current.partition}:iam::565502421330:role/private-connectivity-role-${var.region}"
}
