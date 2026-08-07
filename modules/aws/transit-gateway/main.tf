locals {
  workspace_vpc_start = sum([
    for index, octet in split(".", try(cidrhost(var.workspace_vpc_cidr, 0), "0.0.0.0")) :
    tonumber(octet) * pow(256, 3 - index)
  ])
  workspace_vpc_end = local.workspace_vpc_start + pow(2, 32 - try(tonumber(split("/", var.workspace_vpc_cidr)[1]), 32)) - 1

  on_prem_vpc_start = sum([
    for index, octet in split(".", try(cidrhost(var.on_prem_vpc_cidr, 0), "0.0.0.0")) :
    tonumber(octet) * pow(256, 3 - index)
  ])
  on_prem_vpc_end = local.on_prem_vpc_start + pow(2, 32 - try(tonumber(split("/", var.on_prem_vpc_cidr)[1]), 32)) - 1

  workspace_ranges = [
    for cidr in concat(var.workspace_existing_subnet_cidrs, var.workspace_attachment_subnet_cidrs) : {
      start = sum([
        for index, octet in split(".", try(cidrhost(cidr, 0), "0.0.0.0")) :
        tonumber(octet) * pow(256, 3 - index)
      ])
      end = sum([
        for index, octet in split(".", try(cidrhost(cidr, 0), "0.0.0.0")) :
        tonumber(octet) * pow(256, 3 - index)
      ]) + pow(2, 32 - try(tonumber(split("/", cidr)[1]), 32)) - 1
    }
  ]

  on_prem_ranges = [
    for cidr in concat(var.on_prem_existing_subnet_cidrs, var.on_prem_attachment_subnet_cidrs) : {
      start = sum([
        for index, octet in split(".", try(cidrhost(cidr, 0), "0.0.0.0")) :
        tonumber(octet) * pow(256, 3 - index)
      ])
      end = sum([
        for index, octet in split(".", try(cidrhost(cidr, 0), "0.0.0.0")) :
        tonumber(octet) * pow(256, 3 - index)
      ]) + pow(2, 32 - try(tonumber(split("/", cidr)[1]), 32)) - 1
    }
  ]

  workspace_subnets_contained = alltrue([
    for subnet in local.workspace_ranges :
    subnet.start >= local.workspace_vpc_start && subnet.end <= local.workspace_vpc_end
  ])
  on_prem_subnets_contained = alltrue([
    for subnet in local.on_prem_ranges :
    subnet.start >= local.on_prem_vpc_start && subnet.end <= local.on_prem_vpc_end
  ])

  workspace_subnets_non_overlapping = alltrue(flatten([
    for left_index in range(length(local.workspace_ranges)) : [
      for right_index in range(length(local.workspace_ranges)) :
      local.workspace_ranges[left_index].end < local.workspace_ranges[right_index].start ||
      local.workspace_ranges[right_index].end < local.workspace_ranges[left_index].start
      if left_index < right_index
    ]
  ]))
  on_prem_subnets_non_overlapping = alltrue(flatten([
    for left_index in range(length(local.on_prem_ranges)) : [
      for right_index in range(length(local.on_prem_ranges)) :
      local.on_prem_ranges[left_index].end < local.on_prem_ranges[right_index].start ||
      local.on_prem_ranges[right_index].end < local.on_prem_ranges[left_index].start
      if left_index < right_index
    ]
  ]))
}

resource "aws_ec2_transit_gateway" "this" {
  description                     = "${var.name} simulated hybrid-network hub"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  auto_accept_shared_attachments  = "disable"
  dns_support                     = "enable"
  vpn_ecmp_support                = "enable"

  lifecycle {
    precondition {
      condition = (
        can(cidrnetmask(var.workspace_vpc_cidr)) &&
        can(cidrnetmask(var.on_prem_vpc_cidr)) &&
        !strcontains(var.workspace_vpc_cidr, ":") &&
        !strcontains(var.on_prem_vpc_cidr, ":")
      )
      error_message = "Transit Gateway connectivity supports valid IPv4 VPC CIDRs only."
    }
    precondition {
      condition     = local.workspace_subnets_contained && local.on_prem_subnets_contained
      error_message = "Every existing and attachment subnet must be contained in its VPC CIDR."
    }
    precondition {
      condition     = local.workspace_subnets_non_overlapping && local.on_prem_subnets_non_overlapping
      error_message = "Transit Gateway attachment subnets must not overlap existing or other attachment subnets."
    }
  }

  tags = merge(var.tags, {
    Name = var.name
  })
}

resource "aws_ec2_transit_gateway_route_table" "this" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id

  tags = merge(var.tags, {
    Name = "${var.name}-routes"
  })
}

resource "aws_subnet" "workspace_attachment" {
  count = length(var.availability_zones)

  vpc_id                  = var.workspace_vpc_id
  availability_zone       = var.availability_zones[count.index]
  cidr_block              = var.workspace_attachment_subnet_cidrs[count.index]
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name}-workspace-tgw-${var.availability_zones[count.index]}"
  })
}

resource "aws_route_table" "workspace_attachment" {
  count = length(var.availability_zones)

  vpc_id = var.workspace_vpc_id

  tags = merge(var.tags, {
    Name = "${var.name}-workspace-tgw-${var.availability_zones[count.index]}-rt"
  })
}

resource "aws_route_table_association" "workspace_attachment" {
  count = length(var.availability_zones)

  subnet_id      = aws_subnet.workspace_attachment[count.index].id
  route_table_id = aws_route_table.workspace_attachment[count.index].id
}

resource "aws_subnet" "on_prem_attachment" {
  count = length(var.availability_zones)

  vpc_id                  = var.on_prem_vpc_id
  availability_zone       = var.availability_zones[count.index]
  cidr_block              = var.on_prem_attachment_subnet_cidrs[count.index]
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name}-on-prem-tgw-${var.availability_zones[count.index]}"
  })
}

resource "aws_route_table" "on_prem_attachment" {
  count = length(var.availability_zones)

  vpc_id = var.on_prem_vpc_id

  tags = merge(var.tags, {
    Name = "${var.name}-on-prem-tgw-${var.availability_zones[count.index]}-rt"
  })
}

resource "aws_route_table_association" "on_prem_attachment" {
  count = length(var.availability_zones)

  subnet_id      = aws_subnet.on_prem_attachment[count.index].id
  route_table_id = aws_route_table.on_prem_attachment[count.index].id
}

resource "aws_ec2_transit_gateway_vpc_attachment" "workspace" {
  subnet_ids                                      = aws_subnet.workspace_attachment[*].id
  transit_gateway_id                              = aws_ec2_transit_gateway.this.id
  vpc_id                                          = var.workspace_vpc_id
  dns_support                                     = "enable"
  ipv6_support                                    = "disable"
  appliance_mode_support                          = "disable"
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = merge(var.tags, {
    Name = "${var.name}-workspace"
  })
}

resource "aws_ec2_transit_gateway_vpc_attachment" "on_prem" {
  subnet_ids                                      = aws_subnet.on_prem_attachment[*].id
  transit_gateway_id                              = aws_ec2_transit_gateway.this.id
  vpc_id                                          = var.on_prem_vpc_id
  dns_support                                     = "enable"
  ipv6_support                                    = "disable"
  appliance_mode_support                          = "disable"
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = merge(var.tags, {
    Name = "${var.name}-on-prem"
  })
}

resource "aws_ec2_transit_gateway_route_table_association" "workspace" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.workspace.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this.id
}

resource "aws_ec2_transit_gateway_route_table_association" "on_prem" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.on_prem.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "workspace" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.workspace.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "on_prem" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.on_prem.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.this.id
}

resource "aws_route" "workspace_to_on_prem" {
  count = length(var.workspace_route_table_ids)

  route_table_id         = var.workspace_route_table_ids[count.index]
  destination_cidr_block = var.on_prem_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.workspace]
}

resource "aws_route" "on_prem_to_workspace" {
  count = length(var.on_prem_route_table_ids)

  route_table_id         = var.on_prem_route_table_ids[count.index]
  destination_cidr_block = var.workspace_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.on_prem]
}

resource "aws_vpc_security_group_egress_rule" "workspace_to_on_prem" {
  security_group_id = var.workspace_security_group_id
  cidr_ipv4         = var.on_prem_vpc_cidr
  from_port         = var.service_port
  to_port           = var.service_port
  ip_protocol       = "tcp"
  description       = "${var.name}: classic compute to simulated on-premises"
}

resource "aws_vpc_security_group_ingress_rule" "on_prem_from_workspace" {
  security_group_id = var.on_prem_security_group_id
  cidr_ipv4         = var.workspace_vpc_cidr
  from_port         = var.service_port
  to_port           = var.service_port
  ip_protocol       = "tcp"
  description       = "${var.name}: simulated on-premises from classic compute"
}
