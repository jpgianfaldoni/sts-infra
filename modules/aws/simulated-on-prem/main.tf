locals {
  name = "${var.name_prefix}-sim-on-prem"

  vpc_start = sum([
    for index, octet in split(".", cidrhost(var.vpc_cidr, 0)) :
    tonumber(octet) * pow(256, 3 - index)
  ])
  vpc_end = local.vpc_start + pow(2, 32 - tonumber(split("/", var.vpc_cidr)[1])) - 1

  workload_start = sum([
    for index, octet in split(".", cidrhost(var.workload_subnet_cidr, 0)) :
    tonumber(octet) * pow(256, 3 - index)
  ])
  workload_end = local.workload_start + pow(2, 32 - tonumber(split("/", var.workload_subnet_cidr)[1])) - 1
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  lifecycle {
    precondition {
      condition     = local.workload_start >= local.vpc_start && local.workload_end <= local.vpc_end
      error_message = "The simulated on-premises workload subnet must be contained in its VPC CIDR."
    }
  }

  tags = merge(var.tags, {
    Name = "${local.name}-vpc"
  })
}

resource "aws_subnet" "workload" {
  vpc_id                  = aws_vpc.this.id
  availability_zone       = var.availability_zone
  cidr_block              = var.workload_subnet_cidr
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${local.name}-workload"
  })
}

resource "aws_route_table" "workload" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${local.name}-workload-rt"
  })
}

resource "aws_route_table_association" "workload" {
  subnet_id      = aws_subnet.workload.id
  route_table_id = aws_route_table.workload.id
}

resource "aws_security_group" "host" {
  name        = "${local.name}-host"
  description = "Private simulated on-premises test host"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${local.name}-host"
  })
}

resource "aws_security_group" "ssm_endpoints" {
  name        = "${local.name}-ssm-endpoints"
  description = "Private Systems Manager endpoints for the simulated on-premises host"
  vpc_id      = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${local.name}-ssm-endpoints"
  })
}

resource "aws_vpc_security_group_ingress_rule" "ssm_from_host" {
  security_group_id            = aws_security_group.ssm_endpoints.id
  referenced_security_group_id = aws_security_group.host.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "HTTPS from the private test host"
}

resource "aws_vpc_security_group_egress_rule" "host_to_ssm" {
  security_group_id            = aws_security_group.host.id
  referenced_security_group_id = aws_security_group.ssm_endpoints.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "HTTPS to private Systems Manager endpoints"
}

resource "aws_vpc_security_group_egress_rule" "host_dns_udp" {
  security_group_id = aws_security_group.host.id
  cidr_ipv4         = "${cidrhost(var.vpc_cidr, 2)}/32"
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
  description       = "DNS to the VPC resolver"
}

resource "aws_vpc_security_group_egress_rule" "host_dns_tcp" {
  security_group_id = aws_security_group.host.id
  cidr_ipv4         = "${cidrhost(var.vpc_cidr, 2)}/32"
  from_port         = 53
  to_port           = 53
  ip_protocol       = "tcp"
  description       = "TCP DNS fallback to the VPC resolver"
}

resource "aws_vpc_endpoint" "ssm" {
  for_each = toset(["ssm", "ssmmessages", "ec2messages"])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.workload.id]
  security_group_ids  = [aws_security_group.ssm_endpoints.id]

  tags = merge(var.tags, {
    Name = "${local.name}-${each.value}"
  })
}

resource "aws_iam_role" "host" {
  name = "${local.name}-host"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "host" {
  name = "${local.name}-host"
  role = aws_iam_role.host.name
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

resource "aws_instance" "host" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.workload.id
  vpc_security_group_ids      = [aws_security_group.host.id]
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.host.name
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 8
  }

  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail

    install -d -m 0755 /opt/simulated-on-prem
    tee /opt/simulated-on-prem/server.py >/dev/null <<'PYTHON'
    import json
    import socket
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


    class HealthHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/health":
                self.send_error(404)
                return

            payload = json.dumps({
                "status": "ok",
                "network": "simulated-on-prem",
                "hostname": socket.gethostname(),
            }).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, format, *args):
            return


    ThreadingHTTPServer(("0.0.0.0", ${var.service_port}), HealthHandler).serve_forever()
    PYTHON

    tee /etc/systemd/system/simulated-on-prem.service >/dev/null <<'UNIT'
    [Unit]
    Description=Simulated on-premises HTTP health service
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=simple
    ExecStart=/usr/bin/python3 /opt/simulated-on-prem/server.py
    Restart=always
    RestartSec=3

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable --now simulated-on-prem.service
  EOT

  depends_on = [
    aws_iam_role_policy_attachment.ssm,
    aws_route_table_association.workload,
    aws_vpc_endpoint.ssm,
  ]

  tags = merge(var.tags, {
    Name = "${local.name}-host"
  })
}
