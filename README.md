# STS infrastructure labs

Modular Terraform for Databricks infrastructure and private-connectivity labs on AWS and Azure. Feature flags select the resources to deploy, while AWS connectivity settings independently control how classic and serverless compute reach each data source.

## Available features

### AWS

| Feature flag | Deploys | Notes |
| --- | --- | --- |
| `workspace` | Databricks workspace in a customer-managed VPC | Private subnets, no public IPs on classic compute, NAT egress, root S3 bucket, cross-account IAM, and an S3 gateway endpoint |
| `unity_catalog` | Unity Catalog metastore and initial catalog | Requires `workspace`; includes an S3 storage root, IAM role, storage credential, and external location |
| `rds_postgres` | Private Amazon RDS for PostgreSQL | Dedicated VPC; RDS manages the master password in AWS Secrets Manager |
| `rds_sql_server` | Private Amazon RDS for SQL Server | Dedicated VPC; suitable for SQL Server and Lakeflow Connect demonstrations |
| `aurora_postgres` | Private Aurora PostgreSQL cluster | Dedicated VPC with writer and reader endpoints |
| `aurora_proxy` | RDS Proxy for Aurora PostgreSQL | Requires `aurora_postgres`; adds a read-only proxy endpoint |
| `rabbitmq` | Self-managed RabbitMQ on private EC2 | Dedicated VPC, Secrets Manager credentials, and NAT for bootstrap traffic |

Terraform derives two supporting features automatically:

- Classic PrivateLink interface endpoints are created when a data source uses `classic = "private_link"`.
- One regional Network Connectivity Configuration (NCC) is created and attached to the workspace when any data source uses `serverless = "private_link"`.

### Azure

| Feature flag | Deploys | Notes |
| --- | --- | --- |
| `workspace` | Premium VNet-injected Azure Databricks workspace | Delegated host/container subnets, secure cluster connectivity, NAT egress, and a back-end private endpoint; public workspace access remains enabled |
| `sql_database` | Private Azure SQL logical server and database | Public database access disabled; includes a private endpoint and private DNS zone |
| `sql_server_vm` | Private SQL Server 2022 VM | Includes a dedicated VNet, NAT, NSG, and a subnet prepared for an Azure Private Link Service; the load balancer and Private Link Service are completed as a tutorial exercise |

## AWS networking options

Every enabled data source is deployed in its own VPC. Deployment alone does not connect it to Databricks. Select classic and serverless connectivity independently for each source:

| Compute type | Mode | Network path created |
| --- | --- | --- |
| Classic | `none` | No route between the workspace VPC and data-source VPC |
| Classic | `peering` | VPC peering, routes in both VPCs, and port-specific security-group rules |
| Classic | `private_link` | Internal NLB and endpoint service in the data-source VPC, plus an interface endpoint in the workspace VPC |
| Serverless | `none` | No NCC private endpoint rule |
| Serverless | `private_link` | Internal NLB and endpoint service, NCC workspace attachment, hostname rule, and a Databricks-managed interface endpoint |

All AWS data sources support the same mode combinations:

| Data source | Port | Classic modes | Serverless modes |
| --- | ---: | --- | --- |
| RDS PostgreSQL | `5432` | `none`, `peering`, `private_link` | `none`, `private_link` |
| RDS SQL Server | `1433` | `none`, `peering`, `private_link` | `none`, `private_link` |
| Aurora PostgreSQL | `5432` | `none`, `peering`, `private_link` | `none`, `private_link` |
| RabbitMQ | `5672` | `none`, `peering`, `private_link` | `none`, `private_link` |

For example, the same PostgreSQL instance can be reached from classic clusters through peering and from serverless compute through NCC and PrivateLink:

```hcl
features = {
  workspace     = true
  unity_catalog = true
  rds_postgres  = true
}

connectivity = {
  rds_postgres = {
    classic    = "peering"
    serverless = "private_link"
  }
}
```

Use `none` for both values to deploy a workspace and data source in separate VPCs with no network path between them. A data source can also be deployed without a workspace when its connectivity modes are both `none`.

PrivateLink endpoint services require explicit endpoint acceptance. Inspect the pending IDs before accepting them:

```bash
./infra endpoints aws status
./infra endpoints aws accept --service-id vpce-svc-... --endpoint-id vpce-...
```

See the [AWS connectivity guide](guides/aws/connectivity.md) for endpoint behavior, TLS considerations, and additional combinations.

## Azure networking

Azure feature flags currently deploy the base resources independently; there is no Azure `connectivity` map yet.

- The workspace uses VNet injection for classic compute and includes its Databricks back-end private endpoint.
- Azure SQL Database uses its own VNet, private endpoint, and `privatelink.database.windows.net` private DNS zone.
- Serverless access to Azure SQL or SQL Server on a VM is configured with an NCC and Azure Private Link by following the [Azure serverless SQL tutorial](guides/azure/serverless/sql-database/private-link.md).

## Configure an environment

Files under `environments/examples` are templates with placeholder values. Do not edit them in place. Copy the closest example into the Git-ignored `environments/local` directory and replace the placeholders there.

Available examples:

| Example | Scenario |
| --- | --- |
| `environments/examples/aws/workspace-postgres.tfvars` | AWS workspace, Unity Catalog, and RDS PostgreSQL through classic VPC peering |
| `environments/examples/aws/workspace-postgres-no-connectivity.tfvars` | AWS workspace and RDS PostgreSQL in separate, disconnected VPCs |
| `environments/examples/aws/all-services-private-link.tfvars` | All AWS data sources through PrivateLink for classic and serverless compute |
| `environments/examples/azure/workspace-sql.tfvars` | Azure VNet-injected workspace and private Azure SQL Database |

For example:

```bash
mkdir -p environments/local
cp environments/examples/aws/workspace-postgres.tfvars environments/local/my-aws.tfvars
```

## Deploy safely

Authenticate, validate, save a plan, review it, and then apply that exact plan:

```bash
./infra list
./infra auth aws environments/local/my-aws.tfvars
./infra validate aws
./infra plan aws environments/local/my-aws.tfvars
./infra apply aws environments/local/my-aws.tfvars
```

`apply` accepts only the saved plan produced for the same cloud and tfvars file. Endpoint acceptance, deployment, and destruction are separate external changes.

Destruction also requires a saved plan and typed confirmation:

```bash
./infra destroy-plan aws environments/local/my-aws.tfvars
./infra destroy aws environments/local/my-aws.tfvars --confirm destroy-aws
```

This repository uses local Terraform state only. State, plans, local environment files, credentials, and generated secrets are ignored by Git and must never be committed.

## Documentation

Start at the [guides index](guides/README.md). Tutorials are organized by cloud, compute type, and data source. Cross-cutting references cover [authentication](guides/operations/authentication.md), the [deployment workflow](guides/operations/deployment.md), and [local Terraform state](guides/operations/state.md).

`components.json` is the machine-readable feature catalog. `AGENTS.md` defines the repository guardrails for infrastructure agents.
