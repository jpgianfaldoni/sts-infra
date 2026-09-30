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

# The endpoint service requires acceptance so that serverless NCC connections
# are reviewed explicitly. This classic endpoint is created by the same
# configuration in the same account, so its connection is accepted here.
#
# The service registers a new connection shortly after the endpoint reports
# pendingAcceptance. An earlier accept call is silently ignored and the AWS
# provider then waits 20 minutes, so give the registration time first.
resource "time_sleep" "connection_registration" {
  create_duration = "60s"
  triggers = {
    vpc_endpoint_id = aws_vpc_endpoint.this.id
  }
}

resource "aws_vpc_endpoint_connection_accepter" "this" {
  vpc_endpoint_service_id = var.endpoint_service_id
  vpc_endpoint_id         = time_sleep.connection_registration.triggers["vpc_endpoint_id"]
}

resource "aws_route53_zone" "endpoint" {
  count = var.create_private_dns_alias ? 1 : 0

  name = var.private_dns_name

  vpc {
    vpc_id = var.vpc_id
  }

  tags = merge(var.tags, { Name = "${var.name}-endpoint" })

  lifecycle {
    precondition {
      condition     = var.private_dns_name != null
      error_message = "private_dns_name is required when create_private_dns_alias is true."
    }
  }
}

resource "aws_route53_record" "endpoint" {
  count = var.create_private_dns_alias ? 1 : 0

  zone_id = aws_route53_zone.endpoint[0].zone_id
  name    = var.private_dns_name
  type    = "A"

  alias {
    name                   = aws_vpc_endpoint.this.dns_entry[0].dns_name
    zone_id                = aws_vpc_endpoint.this.dns_entry[0].hosted_zone_id
    evaluate_target_health = false
  }
}
