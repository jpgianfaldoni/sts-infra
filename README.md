# sts-infra: disposable Databricks labs on AWS and Azure

Describe the lab you need, for example "an AWS workspace and a private Postgres
database with sample data that serverless compute reaches privately", and this
project builds it, proves every network path works, and tears it down when you
are done.

Each lab is a Databricks workspace plus the data sources and private network
paths you choose: databases (PostgreSQL, SQL Server, MySQL, Oracle), Kafka,
RabbitMQ, a simulated on-premises network, and the peering, PrivateLink, NCC,
or Transit Gateway pieces that connect them to classic or serverless compute.
Databases come loaded with sample tables, and the ones that support it are
prepared for Lakeflow Connect CDC.

You can use it two ways, and they run the same steps:

- **[Ask an agent](#use-it-with-an-agent)** in plain English. The agent picks a
  template, explains what will be built, deploys it, and checks it. You do the
  browser logins and approve what it runs.
- **[Run the commands](#use-it-with-commands)** yourself. Everything goes
  through one CLI, `./infra`.

## Requirements

- Terraform 1.11 or newer, the Databricks CLI, and Python 3.9 or newer.
- AWS: AWS CLI v2 and an IAM Identity Center (SSO) login to the account.
- Azure: the Azure CLI and access to the subscription.
- A Databricks account where you can create workspaces (account admin).

`./infra doctor <aws|azure>` checks the tools.

## Use it with an agent

Open the repository in a coding agent, such as Claude Code, and say what you
want:

> I need an Azure workspace and a SQL Server on a VM, set up for Lakeflow
> Connect CDC, with no network path between them.

> Build an AWS lab where serverless compute reads a private MySQL database over
> PrivateLink.

> Tear down my MySQL lab.

The agent follows [`AGENTS.md`](AGENTS.md). In Claude Code, the
`deploy-scenario` skill and the permission rules in `.claude/` also apply. The
agent:

1. Picks the closest template and asks only what it cannot infer (which
   account, classic or serverless compute, region), offering a default for
   each.
2. Shows you what will be built, each network path, the build time, and the
   cost tier.
3. Starts the browser logins and waits for you to finish them.
4. Shows the plan summary, including every resource that would be replaced or
   deleted, before applying or destroying.
5. Deploys, approves the private endpoints this lab requested, and runs the
   checks that prove each path works.

What you do:

- **Log in when a browser window opens** (AWS SSO, Databricks OAuth, or
  `az login`). Credentials stay in those CLIs; the agent never sees them.
- **Approve the commands that change things.** Read-only commands (`doctor`,
  `explain`, `plan`, `status`) run without asking. `setup`, `apply`, `verify`,
  and `destroy` ask first.
- **Ask for the teardown** when you are done. Labs bill by the hour.

To save questions later, tell the agent once which account and Unity Catalog
metastore your labs use; it stores them as a named target. You can also ask
"what labs do I have running?" or "is my lab still healthy?" at any time.

## Use it with commands

Every step below is what the agent runs for you. Run each command from the
repository root.

### 1. Name your account once

A target stores the non-secret IDs of an account, so lab files refer to it by
name:

```bash
./infra targets add my-aws --cloud aws \
  --aws-account-id 123456789012 --databricks-account-id <uuid> --region us-west-2 \
  --sso-start-url https://<org>.awsapps.com/start --sso-region us-east-1 --sso-role-name <role> \
  --metastore <shared-metastore>
./infra targets add my-azure --cloud azure \
  --subscription-id <uuid> --databricks-account-id <uuid> --location westus2
```

Targets live in `~/.config/sts-infra/targets.json`. `--metastore` is optional;
use it when the account has several metastores in the region.

### 2. Create a lab from a template

```bash
./infra templates                                        # list every template
./infra new aws my-lab --template serverless-postgres --target my-aws
./infra explain aws environments/local/my-lab.tfvars     # what gets built, and any problems
```

`new` copies the template to `environments/local/my-lab.tfvars`. Git ignores
that folder, so edit the file freely. A lab file turns components on and picks
a path for each kind of compute:

```hcl
target = "my-aws"

features = {
  workspace    = true
  rds_postgres = true
}

connectivity = {
  rds_postgres = {
    classic    = "peering"       # none | peering | private_link
    serverless = "private_link"  # none | private_link
  }
}
```

Set both paths to `none` for a lab where you build the connection yourself.

### 3. Log in

```bash
./infra doctor aws environments/local/my-lab.tfvars       # what is missing
./infra setup aws environments/local/my-lab.tfvars --yes  # opens the browser logins
```

`setup` reuses or creates the AWS SSO and Databricks OAuth profiles and saves
only profile names and account IDs. Other labs in the same accounts need no
more setup. On Azure, one `az login` covers the subscription, the Databricks
account, and the workspace.

### 4. Deploy

```bash
./infra plan aws environments/local/my-lab.tfvars    # review the summary, every replace: and delete: line
./infra apply aws environments/local/my-lab.tfvars
```

`apply` runs only the plan you reviewed. It refuses if the lab file, the code,
or your login changed since the plan. After apply, it approves exactly the
serverless private endpoints this lab requested.

A new AWS workspace deploys in two stages, because Unity Catalog and the lab
check job need a login to a workspace that does not exist yet. After the first
apply, `./infra` prints the next three commands: `setup` (workspace login),
`plan`, and `apply`. Azure deploys in one stage.

### 5. Check every path

```bash
./infra verify aws environments/local/my-lab.tfvars
```

`verify` loads the sample tables `customers` and `orders`, and runs a check
from each compute type over each path. It prepares Lakeflow Connect CDC where
enabled and prints one line per path:

```text
[pass] rds_postgres from serverless compute over private_link: sample data customers=3, orders=5
```

A failed check names the stage that failed (`dns`, `tcp`, `login`, `cdc`, and
so on) and suggests a fix. Serverless private endpoints can take about 10
minutes after approval before traffic flows, so rerun `verify` if a fresh lab
fails at `tcp`.

### 6. Tear it down

```bash
./infra destroy-plan aws environments/local/my-lab.tfvars   # review what will be deleted
./infra destroy aws environments/local/my-lab.tfvars --confirm destroy-aws
```

`./infra ls` lists every local lab and how long it has existed.

### Other commands

| Command | What it does |
| --- | --- |
| `./infra status <cloud> <tfvars>` | Where a lab stands and the next command to run |
| `./infra output <cloud> <tfvars> --json` | Hostnames, IDs, and other outputs, with secrets redacted |
| `./infra endpoints <cloud> status <tfvars>` | Serverless private endpoints and their approval state |
| `./infra vm-setup-status azure <tfvars>` | Setup result of each database VM, including the failure line when one failed |
| `./infra state-forget <cloud> <tfvars> <address> --confirm forget-<cloud>-<id>` | Drop a resource the cloud already deleted from the lab's state |

Run `./infra` with no arguments for the full list. Reporting commands such as
`doctor`, `explain`, `status`, `ls`, and `verify` take `--json`, and the exit
codes are stable: `0` ok, `10` browser login needed, `11` wrong account or
profile, `12` missing tool, `13` a check failed.

## What you can build

`./infra templates` lists the starting points:

| Cloud | Template | Scenario |
| --- | --- | --- |
| AWS | `workspace-postgres` | Classic compute reads a private PostgreSQL database over VPC peering |
| AWS | `serverless-postgres` | Serverless compute reads a private PostgreSQL database over PrivateLink |
| AWS | `serverless-sql-server` | Serverless compute reads a private RDS SQL Server database over PrivateLink |
| AWS | `serverless-mysql` | Serverless compute reads private RDS for MySQL, prepared for Lakeflow Connect |
| AWS | `serverless-oracle` | Serverless compute reads private RDS for Oracle, prepared for Lakeflow Connect |
| AWS | `workspace-kafka-streaming` | Kafka streaming from classic (peering) and serverless (PrivateLink) compute |
| AWS | `all-services-private-link` | Every AWS data source, from classic and serverless compute over PrivateLink |
| AWS | `glue-federation-with-databricks` | Glue catalog federation end to end, including the Unity Catalog foreign catalog |
| AWS | `glue-federation` | S3 sample data and a Glue catalog only, for a manual federation exercise |
| AWS | `workspace-backend-private-link` | Classic compute reaches the control plane over back-end PrivateLink |
| AWS | `workspace-postgres-no-connectivity` | Workspace and PostgreSQL in disconnected VPCs, to build the path yourself |
| AWS | `workspace-simulated-on-prem-transit-gateway` | Classic compute reaches a simulated on-premises service through Transit Gateway |
| AWS | `workspace-simulated-on-prem-serverless-private-link` | Serverless compute reaches a simulated on-premises service over PrivateLink |
| AWS | `workspace-simulated-on-prem-disconnected` | Workspace and a simulated on-premises network, not connected |
| Azure | `serverless-sql` | Serverless compute reads a private Azure SQL database over Private Link |
| Azure | `serverless-mysql` | Serverless compute reads private Azure Database for MySQL, prepared for Lakeflow Connect |
| Azure | `workspace-sql-serverless-private-link` | Azure SQL from serverless (Private Link) and classic (peering) compute, plus a test VM |
| Azure | `workspace-sql-server-vm-lakeflow-cdc` | SQL Server on a VM, prepared for Lakeflow Connect CDC, with no network path |
| Azure | `workspace-mysql-vm-lakeflow-cdc` | MySQL on a VM, prepared for Lakeflow Connect, with no network path |
| Azure | `workspace-oracle-vm-lakeflow-cdc` | Oracle Database Free on a VM, prepared for Lakeflow Connect, with no network path |
| Azure | `workspace-sql` | Workspace and a private Azure SQL database, not connected |
| Azure | `workspace-front-end-private-link` | Workspace UI/API and browser login over front-end Private Link, tested from a VM |
| Azure | `workspace-private-storage-volume` | External volume on locked-down ADLS Gen2 storage |
| Azure | `workspace-custom-dns` | Workspace VNet that resolves names through a custom DNS server VM |

Templates are combinations of components you can mix freely in a lab file:

| Cloud | Components |
| --- | --- |
| AWS | `workspace`, `unity_catalog`, `glue_federation`, `rds_postgres`, `rds_sql_server`, `rds_mysql`, `rds_oracle`, `aurora_postgres`, `aurora_proxy`, `rabbitmq`, `kafka`, `simulated_on_prem` |
| Azure | `workspace`, `test_vm`, `external_volume_storage`, `custom_dns`, `sql_database`, `sql_server_vm`, `mysql_flexible_server`, `mysql_vm`, `oracle_vm` |

Every source starts disconnected; it gets a path only when the lab file asks
for one. The networking pieces (peering, PrivateLink endpoint services, NCC
rules, Transit Gateway, Key Vault) and the lab check job are added
automatically from the paths you choose.
[`components.json`](components.json) describes each component, its network
paths, build time, and cost.

## Good to know

- **Labs cost money.** Destroy them when you are done. Templates set
  `allow_destructive_demo_cleanup = true`, so destroy also empties buckets and
  skips final database snapshots.
- **Nothing secret is stored here.** Passwords live in AWS Secrets Manager or
  Azure Key Vault, logins in the AWS, Azure, and Databricks CLIs, and lab files
  and state stay out of Git.
- **Each lab is isolated.** It has its own state under
  `.state/<cloud>/<lab name>`, and resource names come from the lab name, so
  two labs from the same template do not collide.
- **AWS labs must name their account** (through a target or `aws_account_id`),
  so nothing is deployed to the wrong one.

## Learn more

- [Guides index](guides/README.md): networking concepts and step-by-step
  tutorials for each path.
- [Deployment workflow](guides/operations/deployment.md): metastore selection,
  seeding locked-down Azure storage, and the destroy checklist.
- [Authentication](guides/operations/authentication.md): profiles, overrides,
  and automation.
- [`AGENTS.md`](AGENTS.md): the rules agents follow, plus a troubleshooting
  table.

Project layout:

- `deployments/` holds the AWS and Azure Terraform roots.
- `modules/` holds the components, with `modules/shared` for those both clouds
  use.
- `environments/examples/` holds the templates.
- `lib/` holds the `./infra` CLI (Python standard library only).
- `tests/` holds the CLI and documentation checks that `./infra validate` runs.
