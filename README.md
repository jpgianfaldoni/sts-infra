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

Terraform provisions the infrastructure and network path, and
`./infra verify` loads sample tables into the databases and proves each
configured path works by running a check from the matching compute type.
Application-level steps such as enabling database CDC or creating the Lakeflow
connection and pipeline are completed afterward using the supplied assets and
guides.

The intended way to use the project is through a coding agent: describe the
lab you want, and the agent picks a template, explains what will be built,
handles the browser logins, deploys, and verifies it. `AGENTS.md` and the
`deploy-scenario` skill define that workflow; every step is also a plain
`./infra` command you can run yourself.

## Example scenarios

| Goal | Example deployment result |
| --- | --- |
| Demonstrate Lakeflow Connect SQL Server CDC on AWS | Databricks workspace + private RDS SQL Server + classic VPC peering; use the supplied SQL seed asset to finish the CDC setup |
| Train on serverless connectivity to PostgreSQL on AWS | Databricks workspace + private RDS PostgreSQL + internal NLB + endpoint service + NCC private endpoint |
| Stream synthetic Kafka events from classic and serverless compute | Databricks workspace + single private Kafka broker + continuous producer + classic peering or PrivateLink + serverless NCC private endpoint |
| Demonstrate Lakeflow Connect PostgreSQL query-based ingestion on AWS | Databricks workspace + private PostgreSQL + selected classic or serverless network path; create the connection and pipeline after deployment |
| Reproduce classic access to an on-premises service | Databricks workspace + isolated test-host VPC + Transit Gateway, attachments, routes, and security rules |
| Compare classic and serverless access to the same private service | Classic path through peering or Transit Gateway plus a separate serverless path through PrivateLink and an NCC |
| Practice Azure serverless Private Link | VNet-injected Azure Databricks workspace + private Azure SQL with sample data + NCC private endpoint, approved automatically |

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

Serverless compute reaches Azure SQL through an NCC private endpoint
(`connectivity.sql_database.serverless = "private_link"`), and classic compute
through VNet peering (`sql_database.workspace_peering_enabled = true`). See the
[Azure serverless SQL guide](guides/azure/serverless/sql-database/private-link.md)
for the design and the manual equivalent.

Both clouds also create a `lab_check` job when a source has at least one
compute path: `./infra verify` runs it to load the sample tables `customers`
and `orders` (PostgreSQL, RDS SQL Server, Azure SQL) and to check every
configured classic and serverless path.

## Customize a scenario

### Name your accounts once

A target records the non-secret identifiers of an account you deploy into, so
environment files refer to it by name instead of repeating IDs:

```bash
./infra targets add field-aws --cloud aws \
  --aws-account-id 123456789012 --databricks-account-id <uuid> --region us-west-2 \
  --sso-start-url https://<org>.awsapps.com/start --sso-region us-east-1 --sso-role-name <role> \
  --description "Field engineering sandbox"
./infra targets add field-azure --cloud azure \
  --subscription-id <uuid> --databricks-account-id <uuid> --location westus2
./infra targets
```

Targets live in `~/.config/sts-infra/targets.json` (override with
`STS_INFRA_TARGETS` to share a team file). AWS environments must pin their
account, through a target or `aws_account_id`, so nothing is deployed to the
wrong one.

### Create the environment

```bash
./infra templates
./infra new aws my-lab --template workspace-postgres --target field-aws
./infra explain aws environments/local/my-lab.tfvars
```

`new` copies the template into the Git-ignored `environments/local`
directory; do not edit the example files directly. `explain` evaluates the
file with Terraform and prints what gets built, each network path, the checks
`verify` will run, the typical build time and cost tier, and any problems.

Then adjust the components and connectivity in the local file. This example
creates one PostgreSQL instance that classic compute reaches through VPC
peering and serverless compute reaches through an NCC private endpoint:

```hcl
target = "field-aws"

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
disconnected for a networking exercise. On AWS, setting `region` (or the
target's region) is normally enough; the deployment derives two available
zones unless you provide them explicitly.

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
| `aws/workspace-postgres.tfvars` | Classic compute reads a private PostgreSQL database with sample data over VPC peering |
| `aws/serverless-postgres.tfvars` | Serverless compute reads a private PostgreSQL database with sample data over PrivateLink |
| `aws/serverless-sql-server.tfvars` | Serverless compute reads a private RDS SQL Server database with sample data over PrivateLink |
| `aws/glue-federation.tfvars` | AWS-only S3, Glue catalog, sample table, and credential roles for a manual federation setup |
| `aws/glue-federation-with-databricks.tfvars` | End-to-end Glue federation including the workspace and Unity Catalog connectivity resources |
| `aws/workspace-backend-private-link.tfvars` | Classic workspace whose compute plane reaches the Databricks control plane through back-end PrivateLink |
| `aws/workspace-postgres-no-connectivity.tfvars` | Workspace and PostgreSQL in disconnected VPCs |
| `aws/all-services-private-link.tfvars` | All AWS data sources through PrivateLink for classic and serverless compute |
| `aws/workspace-kafka-streaming.tfvars` | Kafka streaming from classic compute through peering and serverless compute through NCC PrivateLink |
| `aws/workspace-simulated-on-prem-disconnected.tfvars` | Workspace and simulated on-premises network without connectivity |
| `aws/workspace-simulated-on-prem-transit-gateway.tfvars` | Classic compute connected to simulated on-premises through Transit Gateway |
| `aws/workspace-simulated-on-prem-serverless-private-link.tfvars` | Serverless compute connected to simulated on-premises through an NCC private endpoint |
| `azure/serverless-sql.tfvars` | Serverless compute reads a private Azure SQL database with sample data over Private Link |
| `azure/workspace-sql.tfvars` | VNet-injected Azure workspace and private Azure SQL Database |
| `azure/workspace-sql-serverless-private-link.tfvars` | Azure SQL from serverless (Private Link) and classic compute (peering), plus a test VM |
| `azure/workspace-front-end-private-link.tfvars` | Serverless-capable workspace, test VM, and UI/API plus browser-authentication private endpoints |
| `azure/workspace-private-storage-volume.tfvars` | Workspace and external volume backed by locked-down ADLS Gen2 storage, intentionally without a compute network path |
| `azure/workspace-custom-dns.tfvars` | VNet-injected workspace whose VNet resolves names through a custom DNS server VM |

## Deploy the scenario

Terraform 1.11 or newer is required. Use `./infra` for validation, planning,
deployment, verification, endpoint operations, and destruction. It validates
authentication and applies only the exact saved plan that was reviewed.

```bash
# Check authentication; fix anything missing with a browser login.
./infra doctor aws environments/local/my-lab.tfvars
./infra setup aws environments/local/my-lab.tfvars --yes

./infra plan aws environments/local/my-lab.tfvars
# Review the saved-plan summary before continuing.
./infra apply aws environments/local/my-lab.tfvars
./infra verify aws environments/local/my-lab.tfvars
```

`setup --yes` asks no questions. It reuses or creates the AWS IAM Identity
Center and Databricks OAuth profiles, opens the browser logins that are needed,
and writes only account identifiers and profile names to
`~/.config/sts-infra/auth.json`. Credentials stay in the CLI caches. A new
environment in an account you have already set up needs no further setup. On
Azure, a single `az login` covers the subscription, the Databricks account, and
the workspace.

**A new AWS workspace deploys in two stages.** The workspace-level resources
(Unity Catalog, Glue catalogs, the lab check job) need a login to the
workspace, which cannot exist before the workspace does. The first plan reports
`Deployment stage: foundation (1 of 2)`; after its apply, `./infra` prints the
`setup` command for the workspace login, and the next plan and apply add the
rest. Nothing needs to be toggled in the tfvars.

**Serverless endpoints are approved automatically.** After apply, `./infra`
approves exactly the serverless private endpoint connections the deployment
requested (AWS endpoint-service connections, Azure private endpoint
connections). Set `endpoint_approval = "manual"` to leave them pending and
practice the step with `./infra endpoints`.

**`verify` proves the paths.** It copies the database credentials into a
Databricks secret scope (AWS Secrets Manager values flow through pipes and are
never printed or stored in Terraform state; Azure uses the Key Vault-backed
scope), waits for serverless endpoint rules to become `ESTABLISHED`, runs the
lab check job, and prints one line per path with the sample-data row counts.
It exits `13` when a check fails, with the failing stage and a hint.

`./infra doctor <cloud> <tfvars> --json` reports each identity with a stable
exit code (`0` ready, `10` browser login needed, `11` wrong account, profile,
or target, or an unpinned AWS account, `12` missing tool), which makes the
workflow straightforward for coding agents. `./infra status <cloud> <tfvars>
--json` returns the next step for a deployment, and `./infra ls` lists every
local deployment with its age. See
[authentication](guides/operations/authentication.md) for details, SSO profile
creation, overrides, and automation.

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

With `endpoint_approval = "manual"`, review and approve serverless endpoint
connections yourself:

```bash
./infra endpoints aws status environments/local/my-lab.tfvars
./infra endpoints aws accept environments/local/my-lab.tfvars \
  --service-id vpce-svc-... \
  --endpoint-id vpce-...
./infra endpoints azure status environments/local/my-azure.tfvars
./infra endpoints azure approve environments/local/my-azure.tfvars --connection-id <id>
```

## Destroy the scenario

These labs create billable cloud resources. Destroy them when the exercise is
finished:

```bash
./infra ls
./infra destroy-plan aws environments/local/my-lab.tfvars
# Review the saved destroy-plan summary before continuing.
./infra destroy aws environments/local/my-lab.tfvars --confirm destroy-aws
```

Before an AWS destroy, configure workspace authentication so `./infra` can
terminate active clusters. With `endpoint_approval = "auto"`, the confirmed
destroy also rejects the serverless endpoint connections on the deployment's
own endpoint services so AWS can delete them; with `"manual"`, reject them
yourself first. The templates set `allow_destructive_demo_cleanup = true`
because labs are disposable: destroy empties versioned buckets, lifts database
deletion protection, and skips final snapshots. See the
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
- `modules/` contains the reusable cloud components; `modules/shared` holds
  the ones both clouds use, such as the lab check job.
- `lib/infra_scenario.py` implements `templates`, `new`, `explain`, `ls`, and
  `status` (Python standard library only).
- `guides/` contains networking explanations, tutorials, authentication, state,
  and deployment procedures.

Start with the [guides index](guides/README.md), the
[AWS connectivity guide](guides/aws/connectivity.md), or the
[deployment workflow](guides/operations/deployment.md).
