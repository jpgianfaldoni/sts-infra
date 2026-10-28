# Build your Databricks infrastructure scenario

This project creates disposable, customizable Databricks environments for
learning, testing, and demonstrations. Choose the cloud resources and
network paths you need, then deploy the complete scenario with Terraform.

## Why this project exists

Many Databricks scenarios require more than configuring a workspace. They also
require networking between different compute types and private data
sources, for example:

- classic compute connecting to a database in the same cloud environment;
- serverless compute connecting to a private cloud resource;
- classic or serverless compute connecting to an on-premises network;
- Lakeflow Connect using CDC or query-based ingestion over one of those paths;
- workspace setup and migration from classic to serverless compute.

These scenarios are difficult to study or demonstrate without access to an
environment that resembles the target architecture. Building one manually
is slow, inconsistent, and easy to get wrong. Reusing an existing environment
can also hide important setup steps or create conflicts between exercises.

## The solution

This repository is a **build-your-own-scenario** toolkit. Its modular Terraform
creates the Databricks workspace, source systems, cloud networking, and private
connectivity needed to reproduce the desired architecture in a disposable lab.

An environment file answers three questions:

1. Which cloud should host the lab?
2. Which resources should be created?
3. How should Databricks compute reach each resource?

Feature flags enable resources such as PostgreSQL, SQL Server, RabbitMQ, Kafka,
and a simulated on-premises network. Connectivity settings independently select the
path for classic and serverless compute. Supporting resources such as VPC
peering, load balancers, endpoint services, Network Connectivity
Configurations (NCCs), private endpoints, or Transit Gateway are derived from
those choices.

Terraform provisions the infrastructure and network path. Some
application-level steps—such as enabling database CDC, creating source objects,
or creating the Lakeflow connection and pipeline—are completed afterward using
the supplied assets and guides.

## Example scenarios

| Goal | Example deployment result |
| --- | --- |
| Demonstrate Lakeflow Connect SQL Server CDC on AWS | Databricks workspace + private RDS SQL Server + classic VPC peering; use the supplied SQL seed asset to finish the CDC setup |
| Train on serverless connectivity to PostgreSQL on AWS | Databricks workspace + private RDS PostgreSQL + internal NLB + endpoint service + NCC private endpoint |
| Stream synthetic Kafka events from classic and serverless compute | Databricks workspace + single private Kafka broker + continuous producer + classic peering or PrivateLink + serverless NCC private endpoint |
| Demonstrate Lakeflow Connect PostgreSQL query-based ingestion on AWS | Databricks workspace + private PostgreSQL + selected classic or serverless network path; create the connection and pipeline after deployment |
| Reproduce classic access to an on-premises service | Databricks workspace + isolated test-host VPC + Transit Gateway, attachments, routes, and security rules |
| Compare classic and serverless access to the same private service | Classic path through peering or Transit Gateway plus a separate serverless path through PrivateLink and an NCC |
| Practice Azure serverless Private Link | VNet-injected Azure Databricks workspace + private Azure SQL; follow the guide to add the NCC-managed serverless endpoint |

## What can be deployed

### AWS

| Component | What it creates |
| --- | --- |
| `workspace` | Databricks workspace in a dedicated VPC, private classic-compute subnets, NAT, root S3 storage, and cross-account IAM |
| `unity_catalog` | Unity Catalog metastore, storage root, storage credential, external location, and initial catalog |
| `glue_federation` | Private S3 sample data, Glue database and table, IAM roles, and optional Unity Catalog credentials, external location, connection, and foreign catalog |
| `rds_postgres` | Private Amazon RDS for PostgreSQL |
| `rds_sql_server` | Private Amazon RDS for SQL Server, suitable for Lakeflow Connect CDC labs |
| `aurora_postgres` | Private Aurora PostgreSQL cluster with writer and reader endpoints |
| `aurora_proxy` | RDS Proxy for Aurora PostgreSQL |
| `rabbitmq` | Private self-managed RabbitMQ on EC2 |
| `kafka` | Private single-broker Kafka lab on EC2 with SASL credentials and a continuous synthetic event producer |
| `simulated_on_prem` | Isolated private network and HTTP test host representing an on-premises environment |

AWS data sources are created in dedicated VPCs. Enabling a source does not
implicitly connect it to Databricks.

| Compute | Connectivity choices |
| --- | --- |
| Classic to cloud data sources | `none`, `peering`, `private_link` |
| Serverless to cloud data sources | `none`, `private_link` |
| Classic to simulated on-premises | `none`, `transit_gateway` |
| Serverless to simulated on-premises | `none`, `private_link` |

### Azure

| Component | What it creates |
| --- | --- |
| `workspace` | Premium VNet-injected Azure Databricks workspace with secure cluster connectivity, NAT, and a back-end private endpoint |
| `test_vm` | Entra-accessible Linux VM in the workspace VNet for private DNS and front-end Private Link tests |
| `external_volume_storage` | ADLS Gen2 storage, an access connector, configurable Unity Catalog metastore assignment, and an external volume |
| `custom_dns` | A DNS forwarder VM (forwarding to Azure DNS) in a dedicated subnet, set as the workspace VNet's custom DNS server |
| `sql_database` | Private Azure SQL logical server and database with a private endpoint and private DNS |
| `sql_server_vm` | Private SQL Server 2022 VM and a network prepared for an Azure Private Link Service exercise |

Azure components currently deploy the base resources independently. Follow the
[Azure serverless SQL guide](guides/azure/serverless/sql-database/private-link.md)
to configure the NCC and serverless Private Link path.

## Customize a scenario

Copy the closest template from `environments/examples` into the Git-ignored
`environments/local` directory. Do not edit the example files directly.

```bash
mkdir -p environments/local
cp environments/examples/aws/workspace-postgres.tfvars \
  environments/local/my-scenario.tfvars
```

Then select the components and connectivity in the local file. This example
creates one PostgreSQL instance that classic compute reaches through VPC
peering and serverless compute reaches through an NCC private endpoint:

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

Set both modes to `none` when you want the workspace and database to remain
disconnected for a networking exercise. On AWS, setting `region` is normally
enough; the deployment derives two available zones unless you provide them
explicitly.

Resource names derive from the deployment ID (the tfvars file name) unless you
set `name_prefix`, so two copies of the same template get distinct names.
Examples use `metastore_mode = "auto"`, which reuses the only metastore in the
region or creates one; see
[metastore selection](guides/operations/deployment.md#metastore-selection) for
shared accounts with many metastores. Kafka and RabbitMQ examples set
`ephemeral_credentials = true` so broker passwords are written only to Secrets
Manager and never to Terraform state.

Available templates include:

| Template | Scenario |
| --- | --- |
| `aws/workspace-postgres.tfvars` | Workspace, Unity Catalog, and PostgreSQL through classic VPC peering |
| `aws/glue-federation.tfvars` | AWS-only S3, Glue catalog, sample table, and credential roles for a manual federation setup |
| `aws/glue-federation-with-databricks.tfvars` | End-to-end Glue federation including the workspace and Unity Catalog connectivity resources |
| `aws/workspace-backend-private-link.tfvars` | Classic workspace whose compute plane reaches the Databricks control plane through back-end PrivateLink |
| `aws/workspace-postgres-no-connectivity.tfvars` | Workspace and PostgreSQL in disconnected VPCs |
| `aws/all-services-private-link.tfvars` | All AWS data sources through PrivateLink for classic and serverless compute |
| `aws/workspace-kafka-streaming.tfvars` | Kafka streaming from classic compute through peering and serverless compute through NCC PrivateLink |
| `aws/workspace-simulated-on-prem-disconnected.tfvars` | Workspace and simulated on-premises network without connectivity |
| `aws/workspace-simulated-on-prem-transit-gateway.tfvars` | Classic compute connected to simulated on-premises through Transit Gateway |
| `aws/workspace-simulated-on-prem-serverless-private-link.tfvars` | Serverless compute connected to simulated on-premises through an NCC private endpoint |
| `azure/workspace-sql.tfvars` | VNet-injected Azure workspace and private Azure SQL Database |
| `azure/workspace-front-end-private-link.tfvars` | Serverless-capable workspace, test VM, and UI/API plus browser-authentication private endpoints |
| `azure/workspace-private-storage-volume.tfvars` | Workspace and external volume backed by locked-down ADLS Gen2 storage, intentionally without a compute network path |
| `azure/workspace-custom-dns.tfvars` | VNet-injected workspace whose VNet resolves names through a custom DNS server VM |

## Deploy the scenario

Terraform 1.11 or newer is required. Use `./infra` for validation, planning,
deployment, endpoint operations, and destruction. It validates authentication
and applies only the exact saved plan that was reviewed.

```bash
# Check authentication; fix anything missing with a browser login.
./infra doctor aws environments/local/my-scenario.tfvars
./infra setup aws environments/local/my-scenario.tfvars --yes

./infra validate aws
./infra plan aws environments/local/my-scenario.tfvars
# Review the saved-plan summary before continuing.
./infra apply aws environments/local/my-scenario.tfvars
```

`setup --yes` asks no questions. It reuses or creates the AWS IAM Identity
Center and Databricks OAuth profiles, opens the browser logins that are needed,
and writes only account identifiers and profile names to
`~/.config/sts-infra/auth.json`. Credentials stay in the CLI caches. A new
environment in an account you have already set up needs no further setup. On
Azure, a single `az login` covers the subscription, the Databricks account, and
the workspace.

`./infra doctor <cloud> <tfvars> --json` reports each identity with a stable
exit code (`0` ready, `10` browser login needed, `11` wrong account or profile,
`12` missing tool), which makes the workflow straightforward for coding agents.
See [authentication](guides/operations/authentication.md) for details, SSO
profile creation, overrides, and automation.

To seed a locked-down Azure external volume, use the temporary-access workflow:

```bash
./infra seed-access-plan azure environments/local/my-azure.tfvars
./infra seed-access-apply azure environments/local/my-azure.tfvars
./infra seed azure environments/local/my-azure.tfvars --source ./sample-data
# Review the lockdown plan created by seed, then apply it.
./infra apply azure environments/local/my-azure.tfvars
```

The temporary plan enables the public endpoint only for the operator's `/32`
address and grants the signed-in Azure principal Blob Data Contributor. `seed`
uploads with Azure OAuth, records and verifies SHA-256 metadata, then creates a
normal saved plan that removes the operator role and restores the configured
network lockdown. See the [deployment workflow](guides/operations/deployment.md#seed-a-locked-down-azure-external-volume).

AWS PrivateLink endpoint services require explicit endpoint acceptance:

```bash
./infra endpoints aws status environments/local/my-scenario.tfvars
./infra endpoints aws accept environments/local/my-scenario.tfvars \
  --service-id vpce-svc-... \
  --endpoint-id vpce-...
```

## Destroy the scenario

These labs create billable cloud resources. Destroy them when the exercise is
finished:

```bash
./infra destroy-plan aws environments/local/my-scenario.tfvars
# Review the saved destroy-plan summary before continuing.
./infra destroy aws environments/local/my-scenario.tfvars --confirm destroy-aws
```

Before an AWS destroy, configure workspace authentication so `./infra` can
terminate active clusters. Active serverless endpoint connections must be
rejected explicitly. Disposable environments that need automatic cleanup of
versioned buckets must set `allow_destructive_demo_cleanup = true`. See the
[deployment workflow](guides/operations/deployment.md#destroy) for the complete
checklist.

## Safety and project structure

- Never commit local environment files, credentials, secrets, Terraform state,
  or saved plans.
- Local deployments use isolated state under
  `.state/<cloud>/<deployment-id>`.
- `components.json` is the machine-readable catalog of components and supported
  connectivity modes.
- `AGENTS.md` defines the guardrails for infrastructure agents, and
  `.claude/` holds the matching Claude Code permissions and the
  `deploy-scenario` skill.
- `modules/` contains the reusable cloud components.
- `guides/` contains networking explanations, tutorials, authentication, state,
  and deployment procedures.

Start with the [guides index](guides/README.md), the
[AWS connectivity guide](guides/aws/connectivity.md), or the
[deployment workflow](guides/operations/deployment.md).
