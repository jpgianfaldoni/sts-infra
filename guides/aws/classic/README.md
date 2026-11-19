# AWS classic compute guides

Classic compute runs in the workspace VPC, so each guide connects that VPC to
the VPC of a private service.

## Workspace control-plane connectivity

- [Back-end PrivateLink](workspace-back-end-private-link.md)

## Data sources

The three guides use Aurora PostgreSQL as the target.

- [VPC peering](aurora-postgres/vpc-peering.md)
- [PrivateLink](aurora-postgres/private-link.md)
- [Transit Gateway](aurora-postgres/transit-gateway.md)

For other databases the network steps are the same. Adjust these points:

| Target | Port | Notes |
| --- | --- | --- |
| RDS PostgreSQL | `5432` | Use the instance endpoint. With PrivateLink, the load balancer target is the instance's current private IP, which can change on failover or replacement. |
| RDS SQL Server | `1433` | Same as RDS PostgreSQL. |

## Other targets

- [Kafka](../kafka/overview.md): needs a listener for each path.
- [On-premises-style network through Transit Gateway](simulated-on-prem/overview.md)
