resource "aws_vpc_peering_connection" "this" {
  vpc_id      = var.client_vpc_id
  peer_vpc_id = var.service_vpc_id
  auto_accept = true
  tags = merge(var.tags, { Name = var.name
  })
}

resource "aws_vpc_peering_connection_options" "this" {
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id

  requester {
    allow_remote_vpc_dns_resolution = true
  }

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
}

resource "aws_route" "client_to_service" {
  count = length(var.client_route_table_ids)

  route_table_id            = var.client_route_table_ids[count.index]
  destination_cidr_block    = var.service_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

resource "aws_route" "service_to_client" {
  count = length(var.service_route_table_ids)

  route_table_id            = var.service_route_table_ids[count.index]
  destination_cidr_block    = var.client_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

resource "aws_vpc_security_group_egress_rule" "client_to_service" {
  security_group_id = var.client_security_group_id
  cidr_ipv4         = var.service_vpc_cidr
  from_port         = var.service_port
  to_port           = var.service_port
  ip_protocol       = "tcp"
  description       = "${var.name}: client to service"
}

resource "aws_vpc_security_group_ingress_rule" "service_from_client" {
  security_group_id = var.service_security_group_id
  cidr_ipv4         = var.client_vpc_cidr
  from_port         = var.service_port
  to_port           = var.service_port
  ip_protocol       = "tcp"
  description       = "${var.name}: service from client"
}
