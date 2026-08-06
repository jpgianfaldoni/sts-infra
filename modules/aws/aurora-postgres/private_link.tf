resource "aws_security_group" "nlb" {
  count       = local.enable_private_link ? 1 : 0
  name        = "${local.name}-nlb"
  description = "PrivateLink NLB for Aurora readers"
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
resource "aws_vpc_security_group_ingress_rule" "database_from_nlb" {
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
resource "aws_lb_target_group" "readers" {
  count              = local.enable_private_link ? 1 : 0
  name               = substr("${local.name}-reader", 0, 32)
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
resource "aws_lb_listener" "this" {
  count             = local.enable_private_link ? 1 : 0
  load_balancer_arn = aws_lb.this[0].arn
  port              = local.port
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.readers[0].arn
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

data "archive_file" "reader_sync" {
  count       = local.enable_private_link ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/sync_aurora_readers.py"
  output_path = "${path.module}/lambda/sync_aurora_readers.zip"
}
resource "aws_iam_role" "reader_sync" {
  count = local.enable_private_link ? 1 : 0
  name  = "${local.name}-reader-sync"
  assume_role_policy = jsonencode({ Version = "2012-10-17"
    Statement = [{ Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}
resource "aws_iam_role_policy_attachment" "reader_sync_logs" {
  count      = local.enable_private_link ? 1 : 0
  role       = aws_iam_role.reader_sync[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy" "reader_sync" {
  count = local.enable_private_link ? 1 : 0
  name  = "reader-target-sync"
  role  = aws_iam_role.reader_sync[0].id
  policy = jsonencode({ Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["rds:DescribeDBClusters", "rds:DescribeDBInstances", "elasticloadbalancing:DescribeTargetHealth"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:RegisterTargets", "elasticloadbalancing:DeregisterTargets"]
        Resource = aws_lb_target_group.readers[0].arn
      }
    ]
  })
}
resource "aws_lambda_function" "reader_sync" {
  count            = local.enable_private_link ? 1 : 0
  function_name    = "${local.name}-reader-sync"
  role             = aws_iam_role.reader_sync[0].arn
  handler          = "sync_aurora_readers.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.reader_sync[0].output_path
  source_code_hash = data.archive_file.reader_sync[0].output_base64sha256
  environment {
    variables = { CLUSTER_IDENTIFIER = aws_rds_cluster.this.cluster_identifier
      TARGET_GROUP_ARN = aws_lb_target_group.readers[0].arn
      PORT             = tostring(local.port)
    }
  }
  depends_on = [aws_iam_role_policy.reader_sync, aws_iam_role_policy_attachment.reader_sync_logs, aws_rds_cluster_instance.this]
}
resource "aws_cloudwatch_event_rule" "reader_sync" {
  count               = local.enable_private_link ? 1 : 0
  name                = "${local.name}-reader-sync"
  schedule_expression = "rate(1 minute)"
}
resource "aws_cloudwatch_event_target" "reader_sync" {
  count = local.enable_private_link ? 1 : 0
  rule  = aws_cloudwatch_event_rule.reader_sync[0].name
  arn   = aws_lambda_function.reader_sync[0].arn
}
resource "aws_lambda_permission" "reader_sync" {
  count         = local.enable_private_link ? 1 : 0
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reader_sync[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.reader_sync[0].arn
}
