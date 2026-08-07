# AWS connectivity choices

Every enabled service is deployed in its own VPC. Deploying a service does not automatically make it reachable from Databricks. The `classic` and `serverless` settings select connectivity independently for each service.

| Compute | Mode | Resources created |
| --- | --- | --- |
| Classic | `none` | No connection between the workspace VPC and service VPC |
| Classic | `peering` | VPC peering, routes, and port-specific security group rules |
| Classic | `private_link` | Service NLB and endpoint service, plus an interface endpoint in the workspace VPC |
| Serverless | `none` | No NCC private endpoint rule |
| Serverless | `private_link` | Service NLB and endpoint service, plus an NCC, workspace binding, and private endpoint rule |
| Classic to simulated on-premises | `none` | Private test VPC and EC2 host with no workspace route |
| Classic to simulated on-premises | `transit_gateway` | TGW hub, two VPC attachments, reciprocal routes, and a TCP 8080 security path |

NCC is derived automatically: Terraform creates one NCC when at least one service uses `serverless = "private_link"`. All serverless PrivateLink rules are placed in that NCC because a workspace can be bound to only one NCC.

## Configuration

Configure each enabled service with this shape:

```hcl
connectivity = {
  rds_postgres = {
    classic    = "peering"
    serverless = "private_link"
  }
}
```

This example gives classic clusters a peered path while serverless compute uses NCC and PrivateLink. Other useful combinations are:

```hcl
# Workspace and RDS in different VPCs, intentionally disconnected.
rds_postgres = {
  classic    = "none"
  serverless = "none"
}

# Classic clusters only, through VPC peering.
rds_postgres = {
  classic    = "peering"
  serverless = "none"
}

# Classic clusters only, through NLB and PrivateLink.
rds_postgres = {
  classic    = "private_link"
  serverless = "none"
}

# Serverless only, through NCC, NLB, and PrivateLink.
rds_postgres = {
  classic    = "none"
  serverless = "private_link"
}

# Both compute types use the same NLB endpoint service through separate consumers.
rds_postgres = {
  classic    = "private_link"
  serverless = "private_link"
}
```

The same shape applies to `rds_sql_server`, `aurora_postgres`, and `rabbitmq`. Classic supports `none`, `peering`, and `private_link`; serverless supports `none` and `private_link`.

The simulated on-premises feature has a classic-only setting:

```hcl
connectivity = {
  simulated_on_prem = {
    classic = "transit_gateway" # or "none"
  }
}
```

Transit Gateway models a routed hybrid hub. The simulated VPC is still an AWS
VPC rather than a literal data center, so this option does not create a VPN,
Direct Connect gateway, or BGP session. See the [simulated on-premises
guide](classic/simulated-on-prem/overview.md).

## Connection endpoints

After apply, inspect the non-sensitive connection map:

```bash
./infra output aws environments/local/my-aws.tfvars
```

The `connectivity` output reports each selected mode and its client-facing host. Peering uses the service's original hostname. Classic PrivateLink uses the interface endpoint DNS name because customer endpoint services cannot enable private DNS for AWS-owned RDS hostnames. If the client verifies TLS hostnames, configure the driver so the original service hostname remains the TLS server name while the interface endpoint DNS name is used for the network connection.

Serverless PrivateLink continues to use the original service hostname listed in the NCC rule.

## Endpoint acceptance

Endpoint services require acceptance. Serverless NCC endpoints are cross-account and remain unusable until the expected Databricks-created endpoint is explicitly accepted. Check both classic endpoint IDs and NCC rule states with:

```bash
./infra endpoints aws status environments/local/my-aws.tfvars
```

After reviewing the service and endpoint IDs, accept only the expected connection:

```bash
./infra endpoints aws accept environments/local/my-aws.tfvars \
  --service-id vpce-svc-... \
  --endpoint-id vpce-...
```

Acceptance changes external state and is not performed by validation or planning.
