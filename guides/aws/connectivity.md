# AWS connectivity choices

A database or service in its own VPC is not reachable from Databricks until
you build a network path to it. The right path depends on which compute type
needs to connect, because the two run in different networks.

| Compute | Where it runs | What a private path needs |
| --- | --- | --- |
| Classic | The workspace VPC in your AWS account | A route or an endpoint from the workspace VPC to the service |
| Serverless | A Databricks-managed network | A Network Connectivity Configuration (NCC) with a private endpoint rule to an endpoint service you publish |

A path built for one compute type does nothing for the other. To serve both,
build one of each.

## Options for classic compute

| Option | How it works | Choose it when | Guide |
| --- | --- | --- | --- |
| VPC peering | A direct route between the workspace VPC and the service VPC | Two VPCs with non-overlapping address ranges, and you want the simplest path | [VPC peering](classic/aurora-postgres/vpc-peering.md) |
| PrivateLink | A Network Load Balancer and endpoint service in the service VPC, and an interface endpoint in the workspace VPC | Address ranges overlap, or the service owner must expose one port and nothing else | [PrivateLink](classic/aurora-postgres/private-link.md) |
| Transit Gateway | A routing hub that both VPCs attach to | Many VPCs, or on-premises networks behind a VPN or Direct Connect | [Transit Gateway](classic/aurora-postgres/transit-gateway.md) |

The three guides use Aurora PostgreSQL as the target. The network steps are
the same for any TCP service; change the port and the target address.

## Option for serverless compute

Serverless compute has one private option: PrivateLink through an NCC.

1. Put a Network Load Balancer in front of the service and publish it as a
   VPC endpoint service.
2. Add a private endpoint rule for that service to an NCC, and attach the NCC
   to the workspace.
3. Accept the endpoint connection that Databricks requests.

Guides: [RDS SQL Server](serverless/rds-sql-server/private-link.md) and
[RabbitMQ on EC2](serverless/rabbitmq/private-link.md). A workspace uses one
NCC, so every serverless destination of that workspace goes on the same NCC.

## Hostnames and TLS

Which hostname the client uses depends on the path.

| Path | Hostname to connect to |
| --- | --- |
| VPC peering or Transit Gateway | The service's own hostname. Enable DNS resolution across the peering so that it resolves to private addresses. |
| Classic PrivateLink | The interface endpoint's DNS name. An endpoint service you own cannot enable private DNS for an AWS-owned name such as an RDS hostname. |
| Serverless PrivateLink | The service's own hostname, listed as a domain name on the NCC rule. |

With classic PrivateLink, a client that verifies the server certificate sees a
name mismatch, because it connected to the endpoint name. Configure the driver
to connect to the endpoint name while it validates the certificate against
the service's own hostname.

## Endpoint acceptance

An endpoint service that requires acceptance does not carry traffic until its
owner accepts each connection.

- **Classic interface endpoints** are in your own account. Accept them under
  **VPC > Endpoint services > Endpoint connections**.
- **Serverless NCC endpoints** come from a Databricks account. Before you
  accept one, check that its endpoint ID matches the one shown on the NCC
  rule, so that you accept the request your NCC made and no other.

AWS does not delete an endpoint service while a consumer endpoint is still
connected. To remove a path, reject or delete the endpoint connections first,
and delete the NCC rule in Databricks.

## Moving targets

A Network Load Balancer forwards to IP addresses, and the private IP of a
managed database can change during failover, maintenance, or replacement. For
anything longer-lived than a test, automate the update of the target group
from the database's DNS name. The PrivateLink guides describe this limitation.
