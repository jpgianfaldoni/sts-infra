resource "aws_security_group" "workspace" {
  name        = "${var.resource_prefix}-databricks-sg"
  description = "Databricks classic compute plane traffic"
  vpc_id      = aws_vpc.this.id
  tags = merge(var.tags, { Name = "${var.resource_prefix}-databricks-sg"
  })
}

resource "aws_vpc_security_group_ingress_rule" "self" {
  security_group_id            = aws_security_group.workspace.id
  referenced_security_group_id = aws_security_group.workspace.id
  ip_protocol                  = "-1"
  description                  = "Allow all traffic among cluster nodes"
}

resource "aws_vpc_security_group_egress_rule" "self" {
  security_group_id            = aws_security_group.workspace.id
  referenced_security_group_id = aws_security_group.workspace.id
  ip_protocol                  = "-1"
  description                  = "Allow all traffic among cluster nodes"
}

resource "aws_vpc_security_group_egress_rule" "control_plane" {
  for_each = {
    https     = [443, 443]
    relay     = [2443, 2443]
    metastore = [3306, 3306]
    postgres  = [5432, 5432]
    future    = [8443, 8451]
  }

  security_group_id = aws_security_group.workspace.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = each.value[0]
  to_port           = each.value[1]
  ip_protocol       = "tcp"
  description       = "Databricks ${each.key} egress"
}
