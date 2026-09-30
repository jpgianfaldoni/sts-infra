locals {
  databricks_general_access_service = {
    ap-northeast-1 = "com.amazonaws.vpce.ap-northeast-1.vpce-svc-02691fd610d24fd64"
    ap-northeast-2 = "com.amazonaws.vpce.ap-northeast-2.vpce-svc-0babb9bde64f34d7e"
    ap-south-1     = "com.amazonaws.vpce.ap-south-1.vpce-svc-0dbfe5d9ee18d6411"
    ap-southeast-1 = "com.amazonaws.vpce.ap-southeast-1.vpce-svc-02535b257fc253ff4"
    ap-southeast-2 = "com.amazonaws.vpce.ap-southeast-2.vpce-svc-0b87155ddd6954974"
    ap-southeast-3 = "com.amazonaws.vpce.ap-southeast-3.vpce-svc-07a698e7e9ccfd04a"
    ca-central-1   = "com.amazonaws.vpce.ca-central-1.vpce-svc-0205f197ec0e28d65"
    eu-central-1   = "com.amazonaws.vpce.eu-central-1.vpce-svc-081f78503812597f7"
    eu-west-1      = "com.amazonaws.vpce.eu-west-1.vpce-svc-0da6ebf1461278016"
    eu-west-2      = "com.amazonaws.vpce.eu-west-2.vpce-svc-01148c7cdc1d1326c"
    eu-west-3      = "com.amazonaws.vpce.eu-west-3.vpce-svc-008b9368d1d011f37"
    sa-east-1      = "com.amazonaws.vpce.sa-east-1.vpce-svc-0bafcea8cdfe11b66"
    us-east-1      = "com.amazonaws.vpce.us-east-1.vpce-svc-09143d1e626de2f04"
    us-east-2      = "com.amazonaws.vpce.us-east-2.vpce-svc-041dc2b4d7796b8d3"
    us-west-1      = "com.amazonaws.vpce.us-west-1.vpce-svc-09bb6ca26208063f2"
    us-west-2      = "com.amazonaws.vpce.us-west-2.vpce-svc-0129f463fcfbc46c5"
  }

  databricks_scc_relay_service = {
    ap-northeast-1 = "com.amazonaws.vpce.ap-northeast-1.vpce-svc-02aa633bda3edbec0"
    ap-northeast-2 = "com.amazonaws.vpce.ap-northeast-2.vpce-svc-0dc0e98a5800db5c4"
    ap-south-1     = "com.amazonaws.vpce.ap-south-1.vpce-svc-03fd4d9b61414f3de"
    ap-southeast-1 = "com.amazonaws.vpce.ap-southeast-1.vpce-svc-0557367c6fc1a0c5c"
    ap-southeast-2 = "com.amazonaws.vpce.ap-southeast-2.vpce-svc-0b4a72e8f825495f6"
    ap-southeast-3 = "com.amazonaws.vpce.ap-southeast-3.vpce-svc-025ca447c232c6a1b"
    ca-central-1   = "com.amazonaws.vpce.ca-central-1.vpce-svc-0c4e25bdbcbfbb684"
    eu-central-1   = "com.amazonaws.vpce.eu-central-1.vpce-svc-08e5dfca9572c85c4"
    eu-west-1      = "com.amazonaws.vpce.eu-west-1.vpce-svc-09b4eb2bc775f4e8c"
    eu-west-2      = "com.amazonaws.vpce.eu-west-2.vpce-svc-05279412bf5353a45"
    eu-west-3      = "com.amazonaws.vpce.eu-west-3.vpce-svc-005b039dd0b5f857d"
    sa-east-1      = "com.amazonaws.vpce.sa-east-1.vpce-svc-0e61564963be1b43f"
    us-east-1      = "com.amazonaws.vpce.us-east-1.vpce-svc-00018a8c3ff62ffdf"
    us-east-2      = "com.amazonaws.vpce.us-east-2.vpce-svc-090a8fab0d73e39a6"
    us-west-1      = "com.amazonaws.vpce.us-west-1.vpce-svc-04cb91f9372b792fe"
    us-west-2      = "com.amazonaws.vpce.us-west-2.vpce-svc-0158114c0c730c3bb"
  }
}

resource "aws_subnet" "private_link" {
  count = var.backend_private_link.enabled ? 2 : 0

  vpc_id                  = aws_vpc.this.id
  availability_zone       = var.availability_zones[count.index]
  cidr_block              = var.backend_private_link.endpoint_subnet_cidrs[count.index]
  map_public_ip_on_launch = false
  tags = merge(var.tags, {
    Name = "${var.resource_prefix}-privatelink-${var.availability_zones[count.index]}"
  })
}

resource "aws_route_table" "private_link" {
  count = var.backend_private_link.enabled ? 1 : 0

  vpc_id = aws_vpc.this.id
  tags = merge(var.tags, {
    Name = "${var.resource_prefix}-privatelink-rt"
  })
}

resource "aws_route_table_association" "private_link" {
  count = var.backend_private_link.enabled ? 2 : 0

  subnet_id      = aws_subnet.private_link[count.index].id
  route_table_id = aws_route_table.private_link[0].id
}

resource "aws_security_group" "private_link" {
  count = var.backend_private_link.enabled ? 1 : 0

  name        = "${var.resource_prefix}-privatelink-sg"
  description = "Databricks back-end PrivateLink endpoints"
  vpc_id      = aws_vpc.this.id
  tags = merge(var.tags, {
    Name = "${var.resource_prefix}-privatelink-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "private_link" {
  for_each = var.backend_private_link.enabled ? {
    https            = [443, 443]
    compliance_relay = [2443, 2443]
    lakebase         = [5432, 5432]
    scc_relay        = [6666, 6666]
    services         = [8443, 8451]
  } : {}

  security_group_id            = aws_security_group.private_link[0].id
  referenced_security_group_id = aws_security_group.workspace.id
  from_port                    = each.value[0]
  to_port                      = each.value[1]
  ip_protocol                  = "tcp"
  description                  = "Databricks ${each.key} to PrivateLink endpoints"
}

resource "aws_vpc_endpoint" "general_access" {
  count = var.backend_private_link.enabled ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = lookup(local.databricks_general_access_service, var.region, "unsupported")
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.private_link[0].id]
  subnet_ids          = aws_subnet.private_link[*].id
  private_dns_enabled = true
  tags = merge(var.tags, {
    Name = "${var.resource_prefix}-databricks-general-access"
  })

  depends_on = [
    aws_route_table_association.private_link,
    aws_vpc_security_group_ingress_rule.private_link,
  ]

  lifecycle {
    precondition {
      condition     = contains(keys(local.databricks_general_access_service), var.region)
      error_message = "Back-end PrivateLink is not configured for region ${var.region}."
    }
  }
}

resource "aws_vpc_endpoint" "scc_relay" {
  count = var.backend_private_link.enabled ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = lookup(local.databricks_scc_relay_service, var.region, "unsupported")
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.private_link[0].id]
  subnet_ids          = aws_subnet.private_link[*].id
  private_dns_enabled = true
  tags = merge(var.tags, {
    Name = "${var.resource_prefix}-databricks-scc-relay"
  })

  depends_on = [
    aws_route_table_association.private_link,
    aws_vpc_security_group_ingress_rule.private_link,
  ]

  lifecycle {
    precondition {
      condition     = contains(keys(local.databricks_scc_relay_service), var.region)
      error_message = "Back-end PrivateLink is not configured for region ${var.region}."
    }
  }
}

resource "aws_vpc_endpoint" "sts" {
  count = var.backend_private_link.enabled ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.sts"
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.private_link[0].id]
  subnet_ids          = aws_subnet.private_link[*].id
  private_dns_enabled = true
  tags = merge(var.tags, {
    Name = "${var.resource_prefix}-sts-endpoint"
  })

  depends_on = [
    aws_route_table_association.private_link,
    aws_vpc_security_group_ingress_rule.private_link,
  ]
}

resource "aws_vpc_endpoint" "kinesis" {
  count = var.backend_private_link.enabled ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.kinesis-streams"
  vpc_endpoint_type   = "Interface"
  security_group_ids  = [aws_security_group.private_link[0].id]
  subnet_ids          = aws_subnet.private_link[*].id
  private_dns_enabled = true
  tags = merge(var.tags, {
    Name = "${var.resource_prefix}-kinesis-endpoint"
  })

  depends_on = [
    aws_route_table_association.private_link,
    aws_vpc_security_group_ingress_rule.private_link,
  ]
}

resource "databricks_mws_vpc_endpoint" "general_access" {
  count = var.backend_private_link.enabled ? 1 : 0

  provider            = databricks.mws
  account_id          = var.databricks_account_id
  aws_vpc_endpoint_id = aws_vpc_endpoint.general_access[0].id
  vpc_endpoint_name   = "${var.resource_prefix}-general-access"
  region              = var.region
}

resource "databricks_mws_vpc_endpoint" "scc_relay" {
  count = var.backend_private_link.enabled ? 1 : 0

  provider            = databricks.mws
  account_id          = var.databricks_account_id
  aws_vpc_endpoint_id = aws_vpc_endpoint.scc_relay[0].id
  vpc_endpoint_name   = "${var.resource_prefix}-scc-relay"
  region              = var.region
}

resource "databricks_mws_private_access_settings" "this" {
  count = var.backend_private_link.enabled ? 1 : 0

  provider                     = databricks.mws
  private_access_settings_name = "${var.resource_prefix}-private-access"
  region                       = var.region
  public_access_enabled        = var.backend_private_link.public_access_enabled

  lifecycle {
    precondition {
      condition     = var.pricing_tier == "ENTERPRISE"
      error_message = "Databricks back-end PrivateLink requires the ENTERPRISE pricing tier."
    }
  }
}
