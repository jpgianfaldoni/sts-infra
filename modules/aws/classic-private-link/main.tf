resource "aws_security_group" "endpoint" {
  name        = "${var.name}-endpoint"
  description = "PrivateLink endpoint for Databricks classic compute"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-endpoint" })
}

resource "aws_vpc_security_group_ingress_rule" "from_classic_compute" {
  security_group_id            = aws_security_group.endpoint.id
  referenced_security_group_id = var.client_security_group_id
  from_port                    = var.service_port
  to_port                      = var.service_port
  ip_protocol                  = "tcp"
  description                  = "Databricks classic compute to PrivateLink endpoint"
}

resource "aws_vpc_security_group_egress_rule" "classic_compute_to_endpoint" {
  security_group_id            = var.client_security_group_id
  referenced_security_group_id = aws_security_group.endpoint.id
  from_port                    = var.service_port
  to_port                      = var.service_port
  ip_protocol                  = "tcp"
  description                  = "Databricks classic compute to ${var.name}"
}

resource "aws_vpc_endpoint" "this" {
  vpc_id              = var.vpc_id
  service_name        = var.endpoint_service_name
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.endpoint.id]
  private_dns_enabled = false
  tags                = merge(var.tags, { Name = "${var.name}-endpoint" })
}
