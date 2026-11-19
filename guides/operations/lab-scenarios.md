# Lab scenarios with ./infra

The guides under [AWS](../aws/README.md) and [Azure](../azure/README.md) explain
how to build each network path by hand. This page describes what `./infra`
builds for the same scenarios, the settings that select each path, and how to
check a deployed lab. Use it together with the
[deployment workflow](deployment.md).

## AWS

### Connectivity settings

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

#### Configuration

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

The same shape applies to `rds_sql_server`, `aurora_postgres`, `rabbitmq`, and
`kafka`. Classic supports `none`, `peering`, and `private_link`; serverless
supports `none` and `private_link`. Kafka uses separate advertised listener
ports for direct peering (`9092`) and PrivateLink (`9094`) so broker metadata
always returns an address reachable through the selected path. See the
[Kafka streaming lab](#kafka-streaming-lab).

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
network](#simulated-on-premises-network).

#### Connection endpoints

After apply, inspect the non-sensitive connection map:

```bash
./infra output aws environments/local/my-aws.tfvars
```

The `connectivity` output reports each selected mode and its client-facing host. Peering uses the service's original hostname. Classic PrivateLink uses the interface endpoint DNS name because customer endpoint services cannot enable private DNS for AWS-owned RDS hostnames. If the client verifies TLS hostnames, configure the driver so the original service hostname remains the TLS server name while the interface endpoint DNS name is used for the network connection.

Serverless PrivateLink continues to use the original service hostname listed in the NCC rule.

#### Endpoint acceptance

Endpoint services require acceptance. Classic interface endpoints are created
by the same Terraform configuration in the same AWS account, so Terraform
accepts their connections automatically (`aws_vpc_endpoint_connection_accepter`
in the `classic-private-link` module). Serverless NCC endpoints are
cross-account and remain unusable until the expected Databricks-created
endpoint is accepted. With `endpoint_approval = "auto"` (the default),
`./infra apply` accepts exactly the connections the deployment requested. With
`endpoint_approval = "manual"`, list the connections that still need a
decision with:

```bash
./infra endpoints aws status environments/local/my-aws.tfvars
```

Each `pending_endpoint_acceptances` entry contains the `service_id` and
`endpoint_id` to review. After reviewing them, accept only the expected
connection:

```bash
./infra endpoints aws accept environments/local/my-aws.tfvars \
  --service-id vpce-svc-... \
  --endpoint-id vpce-...
```

Acceptance changes external state and is not performed by validation or planning.

AWS will not delete an endpoint service while an active consumer endpoint
remains. With `endpoint_approval = "auto"`, the confirmed `./infra destroy`
rejects the serverless connections on the deployment's endpoint services
before Terraform runs. Otherwise reject them yourself first:

```bash
./infra endpoints aws reject environments/local/my-aws.tfvars \
  --service-id vpce-svc-... \
  --endpoint-id vpce-... \
  --confirm reject-aws-endpoint
```

Review the IDs with `endpoints aws status` first. Rejection is an explicit
external state change and disconnects serverless traffic immediately.


### Aurora PostgreSQL

Creates an encrypted Aurora PostgreSQL cluster with one writer and at least one reader. Optional features are independent:

- `enable_proxy` adds RDS Proxy and a read-only proxy endpoint. The proxy uses Aurora subnet IPs; it is not a separate VPC.
- `enable_classic_private_link` or `enable_serverless_private_link` adds an NLB endpoint service and a scheduled Lambda that synchronizes current Aurora reader IPs into the target group.
- Composition-level `peering` connects classic-compute route tables and security groups directly to the selected Aurora or proxy security group.

Use `modules/aws/aurora-postgres/notebooks/test_classic_connectivity.py` with either the Aurora reader endpoint or the proxy read-only endpoint. The notebook verifies DNS, TCP, authentication, and read-replica routing.


### RDS PostgreSQL

Creates encrypted, private RDS PostgreSQL in a dedicated VPC. RDS manages the master password in AWS Secrets Manager. The composition root can add VPC peering for classic compute or an NLB endpoint service plus NCC for serverless.

The PrivateLink target is the current RDS ENI IP. Automate target synchronization for production because maintenance, failover, or replacement can change it.


### RDS SQL Server

This module creates a private SQL Server Standard Edition RDS instance. SQL Server Standard supports the CDC configuration required by Lakeflow Connect; database-level CDC and the dedicated ingestion login must still be created with the SQL in `modules/aws/rds-sql-server/assets/seed.sql` after deployment.

Credentials are generated by RDS and stored in AWS Secrets Manager. Retrieve them without committing or printing them into automation logs:

```bash
aws secretsmanager get-secret-value --secret-id <master-secret-arn> --query SecretString --output text
```

Connectivity is selected at the AWS composition root:

- `none`: database only, no client path.
- `peering`: bidirectional routes and security-group rules between classic compute and the database VPC.
- `private_link`: NLB, endpoint service, NCC rule, and workspace binding for serverless.

The NLB target is the current RDS ENI private IP. RDS IPs can change during replacement or failover, so production use requires a DNS-to-target synchronization mechanism equivalent to the Aurora module's reader-sync Lambda.


### RabbitMQ

Creates RabbitMQ on a private EC2 instance. The host has no public IP; a NAT gateway is used only for outbound bootstrap traffic. Generated credentials are stored in AWS Secrets Manager and read by the instance through its IAM role.

With either `enable_classic_private_link` or `enable_serverless_private_link`, the module adds an internal NLB and endpoint service. The composition root creates the matching classic interface endpoint, serverless NCC rule, or both. For production, use AMQPS on 5671 and a customer-owned DNS name whose certificate matches the NCC domain.

See the [NCC and PrivateLink guide](../aws/serverless/rabbitmq/private-link.md) for the manual steps and `modules/aws/rabbitmq/notebooks/test_serverless_connectivity.py` for validation.


### Kafka streaming lab

The Kafka feature creates a disposable, single-broker Apache Kafka lab in a
dedicated AWS VPC. It is intended for connectivity and Structured Streaming
exercises, not production workloads.

The broker runs in KRaft combined broker/controller mode on a private EC2
instance. A systemd service continuously sends one synthetic purchase event to
the `demo-events` topic every second by default. Kafka retains the events for 24
hours.

```text
Synthetic producer -> Kafka topic -> Databricks Structured Streaming -> Delta
```

The producer runs on the broker host, so data begins entering Kafka after the
instance finishes bootstrapping. Databricks is a Kafka consumer: it pulls the
events rather than receiving a push from the broker.

#### Connectivity

Kafka clients first contact a bootstrap address and then use the broker address
returned in Kafka metadata. This module has distinct advertised listeners so
both paths return an address that the client can actually reach:

| Compute path | Listener | Network path |
| --- | --- | --- |
| Classic `peering` | Broker private IP on `9092` | Workspace VPC peering and routes |
| Classic `private_link` | NLB hostname on `9094` | Workspace interface endpoint and private Route 53 alias |
| Serverless `private_link` | NLB hostname on `9094` | NCC-managed interface endpoint |

The classic and serverless PrivateLink consumers share the same internal NLB
and endpoint service, which requires acceptance. Terraform accepts the classic
endpoint it creates in the same account; the serverless NCC connection must be
reviewed and accepted explicitly.

#### Deploy the example

Copy the example into the ignored local environment directory, then let
`./infra` select and verify the AWS and Databricks profiles:

```bash
cp environments/examples/aws/workspace-kafka-streaming.tfvars \
  environments/local/my-kafka.tfvars

./infra setup aws environments/local/my-kafka.tfvars --yes
./infra validate aws
./infra plan aws environments/local/my-kafka.tfvars
# Review and authorize the saved plan before applying it.
./infra apply aws environments/local/my-kafka.tfvars
```

The example uses classic VPC peering and serverless PrivateLink. After apply,
inspect the output and approve the expected serverless endpoint connection:

```bash
./infra output aws environments/local/my-kafka.tfvars
./infra endpoints aws status environments/local/my-kafka.tfvars
```

Endpoint acceptance is an external state change. Follow the reviewed-ID
workflow in the [endpoint acceptance](#endpoint-acceptance) section.

#### Credentials

The generated SASL/PLAIN username and password are stored in AWS Secrets
Manager. Terraform outputs only the secret ARN. Copy the two values into a
Databricks secret scope as keys named `username` and `password`; do not place
them directly in a notebook or commit them to Git.

SASL/PLAIN authenticates the lab client but does not encrypt Kafka payloads.
The traffic remains on the selected private network path. Production designs
should use TLS (`SASL_SSL`) and a multi-broker managed service such as Amazon
MSK.

#### Stream from Databricks

Import `modules/aws/kafka/notebooks/stream_from_kafka.py` into the workspace.
Set its `bootstrap_servers` widget from the matching `connectivity.kafka`
output:

- classic peering: `<classic.host>:9092`;
- classic PrivateLink: `<classic.host>:9094`;
- serverless PrivateLink: `<serverless.host>:9094`.

The notebook reads the live events with Spark Structured Streaming. To persist
them, replace its final `display(events)` with a checkpointed Delta sink:

```python
(
    events.writeStream
    .option("checkpointLocation", "/Volumes/main/default/checkpoints/kafka")
    .toTable("main.default.kafka_events")
)
```

Use a different checkpoint for each independent consumer.

#### Operational notes

- The EC2 instance has no public IP and is managed through Systems Manager.
- A NAT gateway is used for Docker image installation and is billable.
- This is a single point of failure with replication factor `1`.
- The synthetic producer restarts automatically with systemd.
- Destroy the lab when finished to stop EC2, NAT gateway, and NLB charges.


### Simulated on-premises network

This lab creates a private AWS VPC that represents an on-premises network. A
small EC2 instance runs an HTTP health service, while Systems Manager interface
endpoints provide administrative access without SSH, a public IP, NAT, or an
internet gateway.

The connected option uses AWS Transit Gateway:

```text
Classic Databricks cluster
        |
Workspace private route table
        |
Workspace TGW attachment
        |
Transit Gateway route table
        |
Simulated-on-prem TGW attachment
        |
Private EC2 host :8080
```

This accurately demonstrates hub-and-spoke routing and security controls. It is
not a full physical on-premises simulation because the second VPC attaches
directly to the TGW; a production data center would normally reach AWS through
Site-to-Site VPN or Direct Connect and might exchange routes with BGP.

#### Deployment options

Copy one of these templates into `environments/local`:

- `workspace-simulated-on-prem-disconnected.tfvars` deploys both VPCs without a
  network path between them.
- `workspace-simulated-on-prem-transit-gateway.tfvars` creates the TGW, two VPC
  attachments, routes, and TCP `8080` security-group rules.

The essential configuration is:

```hcl
features = {
  workspace         = true
  simulated_on_prem = true
}

connectivity = {
  simulated_on_prem = {
    classic = "transit_gateway" # or "none"
  }
}
```

Use the guarded deployment workflow:

```bash
./infra validate aws
./infra plan aws environments/local/my-hybrid-lab.tfvars
./infra apply aws environments/local/my-hybrid-lab.tfvars
```

Review the saved plan and explicitly authorize apply before the final command.

#### Verify the private host

Inspect the output without printing credentials:

```bash
./infra output aws environments/local/my-hybrid-lab.tfvars
```

The `simulated_on_prem.ssm_command` output is the complete command, including
the region and the AWS profile that `./infra` selected. It has this form:

```bash
aws ssm start-session \
  --target i-0123456789abcdef0 \
  --region us-west-2 \
  --profile <profile-from-./infra-setup>
```

Inside the host, verify the service with:

```bash
curl http://127.0.0.1:8080/health
```

#### Verify from classic Databricks compute

Attach a Python notebook to a classic cluster and use the `service_url` from
`connectivity.simulated_on_prem.classic`:

```python
import json
import urllib.request

url = "http://10.60.0.10:8080/health"  # Replace with the Terraform output.

with urllib.request.urlopen(url, timeout=10) as response:
    assert response.status == 200
    payload = json.load(response)

assert payload["status"] == "ok"
assert payload["network"] == "simulated-on-prem"
print(payload)
```

The disconnected configuration should time out because it has no TGW, routes,
or cross-VPC security-group rules. Serverless compute cannot use this path
because it does not run in the workspace VPC; use NCC and PrivateLink for
serverless connectivity.

#### Cost notes

The lab creates one EC2 instance, three interface endpoints, one Transit Gateway
and two TGW VPC attachments when connected. All can incur hourly charges. The
dedicated `/28` attachment subnets contain only TGW network interfaces and have
local-only route tables.


## Azure

### Front-end Private Link lab

This lab creates a Premium Azure Databricks workspace that can use serverless
compute, a single VNet, `databricks_ui_api` and `browser_authentication`
private endpoints, and an Ubuntu test VM. Public workspace access is disabled
in the example so workspace UI and API traffic must use Private Link.

The `databricks_ui_api` endpoint is created with every workspace. The example
adds the browser SSO endpoint with
`workspace_front_end_private_link.browser_authentication_enabled = true` and
disables public access with `public_network_access_enabled = false`. The older
`workspace_front_end_private_link.enabled` flag is deprecated and has no
effect; remove it from existing environment files (plans print a warning while
it is set).

The `browser_authentication` endpoint is hosted on the lab workspace. Azure
Databricks supports this for disposable tests, but recommends a dedicated
private web authentication workspace for production because only one browser
authentication endpoint should serve a region and private DNS zone.

#### Deploy

Copy the example into the ignored local environment directory, replace the
subscription and operator `/32`, then use the repository harness. Resource
names derive from the environment file name unless you set `name_prefix` and
`workspace_name`:

```bash
cp environments/examples/azure/workspace-front-end-private-link.tfvars \
  environments/local/my-front-end-private-link.tfvars
./infra setup azure environments/local/my-front-end-private-link.tfvars --yes
./infra doctor azure environments/local/my-front-end-private-link.tfvars
./infra validate azure
./infra plan azure environments/local/my-front-end-private-link.tfvars
./infra apply azure environments/local/my-front-end-private-link.tfvars
```

Review the saved plan summary before applying it.

#### Connect to the test VM

The deployment installs Microsoft Entra SSH and grants the deploying Azure
principal the `Virtual Machine Administrator Login` role on the VM. `az ssh vm`
needs the Azure CLI SSH extension once per machine:

```bash
az extension add --name ssh
```

Obtain the connection command without exposing any password:

```bash
./infra output azure environments/local/my-front-end-private-link.tfvars --json
```

Run the `test_vm.azure_cli_command` value, for example
`az ssh vm --resource-group <rg> --name <vm>`.

To use plain SSH instead, set `test_vm.admin_ssh_public_key` to the contents of
your public key (for example `~/.ssh/id_ed25519.pub`) before applying. The VM
then disables password authentication, and `test_vm.ssh_command` is
`ssh <admin>@<public-ip>`. Adding a key to an existing VM replaces the VM.

From the VM, verify that the workspace hostname resolves to the private IP of
the `databricks_ui_api` endpoint:

```bash
nslookup <workspace-host>.azuredatabricks.net
curl -I https://<workspace-host>.azuredatabricks.net
```

To test browser SSO from the local machine, open a SOCKS proxy through the test
VM and keep it running:

```bash
# Microsoft Entra SSH (default):
az ssh vm --resource-group <rg> --name <vm> -- -N -D 1080

# Or, with test_vm.admin_ssh_public_key configured:
ssh -N -D 1080 <admin>@<public-ip>
```

Then point a browser at the proxy with remote DNS, so names resolve inside the
VNet. For example, start a separate Chrome profile:

```bash
google-chrome --user-data-dir="$(mktemp -d)" \
  --proxy-server="socks5://127.0.0.1:1080" \
  --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1"
```

In Firefox, set a manual SOCKS v5 proxy `127.0.0.1:1080` and enable **Proxy DNS
when using SOCKS v5**. The workspace URL and the regional
`pl-auth.azuredatabricks.net` callback then resolve inside the lab VNet through
the linked `privatelink.azuredatabricks.net` private DNS zone.

#### Cleanup

This lab contains billable resources. Destroy it when testing is complete:

```bash
./infra destroy-plan azure environments/local/my-front-end-private-link.tfvars
./infra destroy azure environments/local/my-front-end-private-link.tfvars --confirm destroy-azure
```


### Azure SQL Database

`features.sql_database` creates an Azure SQL logical server and database with
public access disabled, plus a private endpoint and a
`privatelink.database.windows.net` private DNS zone in a dedicated VNet.

#### Credentials

Terraform generates the SQL administrator password and, by default
(`key_vault.enabled = true`), stores it in an RBAC-mode Azure Key Vault created
in its own `<name_prefix>-secrets-rg` resource group:

| Secret | Contents |
| --- | --- |
| `sql-database-admin-username` / `sql-database-admin-password` | SQL authentication administrator |
| `sql-server-vm-sql-username` / `sql-server-vm-sql-password` | SQL Server VM login (when `features.sql_server_vm` is enabled) |
| `sql-server-vm-admin-username` / `sql-server-vm-admin-password` | SQL Server VM Windows administrator |

The deploying principal receives **Key Vault Secrets Officer** on the vault.
The `key_vault` output lists the vault name, URI, and secret names, never the
values. Read a value in an authorized terminal with:

```bash
az keyvault secret show --vault-name <key_vault.name> --name sql-database-admin-password --query value -o tsv
```

The vault keeps public network access enabled so Terraform on the operator
machine can write the secrets; access is controlled by Microsoft Entra RBAC.
It uses the minimum 7-day soft-delete retention without purge protection, and
Terraform purges it on destroy. The password still exists in Terraform state,
so use an encrypted remote backend with restricted access for shared
environments. The sensitive `sql_database_password` and
`sql_server_vm_password` outputs are deprecated and will be removed in the next
release.

When the workspace is also enabled, the vault is exposed to Databricks as a
Key Vault-backed secret scope (`key_vault.secret_scope_name`, default
`sts-infra`). The AzureDatabricks first-party application receives **Key Vault
Secrets User** on the vault. Reference the password from a notebook or a Unity
Catalog connection with `secret("sts-infra", "sql-database-admin-password")`.
Creating a Key Vault-backed scope requires a Microsoft Entra user identity
(the default Azure CLI login); set `key_vault.databricks_secret_scope_enabled =
false` when deploying as a service principal.

#### Microsoft Entra administrator

By default (`sql_database.entra_admin_enabled = true`) the deploying principal
becomes the logical server's Microsoft Entra administrator, shown as
`sts-infra-deployer`. SQL authentication stays enabled, so both methods work.
Connect with Entra authentication, for example from the test VM:

```bash
sqlcmd -S <sql_database.host> -d demo --authentication-method ActiveDirectoryDefault
```

#### Reach the database from the workspace VNet

The SQL VNet is isolated by default. Set
`sql_database.workspace_peering_enabled = true` to peer it with the workspace
VNet and link its private DNS zone to the workspace VNet. The two address
spaces must not overlap (plans reject overlapping ranges). Classic compute and
the test VM (`features.test_vm`) can then resolve `<server>.database.windows.net`
to the private endpoint and connect on port 1433.

Initialize the sample data from the test VM with
`modules/azure/sql-database/assets/seed.sql`, for example:

```bash
sqlcmd -S <sql_database.host> -d demo -U sqladminuser -P "$(az keyvault secret show \
  --vault-name <key_vault.name> --name sql-database-admin-password --query value -o tsv)" \
  -i seed.sql
```

Peering serves classic compute only. For Databricks serverless compute, use the
[NCC and Private Link path](../azure/serverless/sql-database/private-link.md), which Terraform can create with
`connectivity.sql_database.serverless = "private_link"`.


#### Serverless Private Link to Azure SQL Database

For Azure SQL Database, Terraform creates the serverless networking objects:

```hcl
databricks_account_id = "<azure-databricks-account-id>"

features = {
  workspace    = true
  sql_database = true
}

connectivity = {
  sql_database = {
    serverless = "private_link"
  }
}
```

The plan creates a Network Connectivity Configuration (NCC) in the workspace
region, binds it to the workspace, and adds a private endpoint rule for the
SQL logical server (`group_id = "sqlServer"`). Set
`existing_network_connectivity_config_id` to add the rule to an NCC that
already serves the workspace. Start from
`environments/examples/azure/workspace-sql-serverless-private-link.tfvars`.

Databricks then creates a managed private endpoint that stays **Pending** until
the SQL server owner approves it. With the default `endpoint_approval = "auto"`,
`./infra apply` approves exactly the connections this deployment requested.
To practice the approval step yourself, set `endpoint_approval = "manual"`:

```bash
./infra apply azure environments/local/my-sql.tfvars
./infra endpoints azure status environments/local/my-sql.tfvars
# Review component, resource_id, endpoint_name, and connection_id, then:
./infra endpoints azure approve environments/local/my-sql.tfvars \
  --connection-id <connection_id>
```

`status` lists `pending_endpoint_approvals` with the live `azure_status` and
the `connection_id` to approve. After approval, the rule reports `ESTABLISHED`
a few minutes later, and serverless compute can reach
`<server>.database.windows.net:1433`. Then run:

```bash
./infra verify azure environments/local/my-sql.tfvars
```

`verify` waits for the rule to become `ESTABLISHED`, loads the sample tables
`customers` and `orders`, and reports whether serverless (and, with
`sql_database.workspace_peering_enabled = true`, classic) compute reaches the
database. Create the Unity Catalog connection as described in
[Configure the SQL connection](../azure/serverless/sql-database/private-link.md#8-configure-the-sql-connection); the SQL
credentials are in the Key Vault and the Key Vault-backed secret scope
described [above](#azure-sql-database).


### SQL Server on a VM

Start from `environments/examples/azure/workspace-sql-server-vm-private-link.tfvars`
to create a VNet-injected workspace and SQL Server in a separate Azure VNet.
This simulates an on-premises source; it creates no connection to a real
external network.

`sql_server_vm.workspace_peering_enabled = true` creates peering, allows SQL
traffic from the classic compute subnets, and links the database's private
DNS zone to the workspace. `connectivity.sql_server_vm.serverless = "private_link"`
creates an internal Standard Load Balancer, a Private Link Service, and an
NCC rule using `sql_server_vm.private_dns_name` as its application hostname.
The custom service rule uses `domain_names`, with no `group_id`.
Use a hostname such as `sqlserver.lab.exampledomain.com`: serverless Private Link
does not support private-use TLDs such as `.internal`, `.localhost`, or `.test`.

The service has no public frontend and no automatically approved subscriptions.
By default, `./infra apply` approves only the Databricks endpoint returned by
this deployment's NCC. `endpoint_approval = "manual"` leaves it pending so
that you can approve it yourself.

During apply, Azure VM Run Command starts SQL Server Agent, loads `demo` with
three customers and five orders, installs the Lakeflow utility objects,
creates the `lakeflow` ingestion login, and enables and tests CDC capture.
Passwords are stored in Key Vault. `./infra verify` checks DNS, TCP,
authenticated queries, sample row counts, and the ingestion login over each
configured path. This prepares the source; it creates no ingestion pipeline.

The manual equivalents are the
[Private Link](../azure/manual/serverless-sql-server-vm-private-link.md) and
[private network gateway](../azure/manual/serverless-sql-server-vm-private-network-gateway.md)
guides. The disconnected `workspace-sql-server-vm-lakeflow-cdc` template
deploys the VM with no path, so that you can build one yourself.


### Private network gateway

A private network gateway connects Azure Databricks serverless compute to your
VNet through one managed gateway. Databricks injects the gateway into a subnet
you delegate to it, and serverless compute then reaches whatever that VNet
routes to: peered VNets, and networks behind ExpressRoute or a VPN.

The feature is in Public Preview, and Databricks bills the gateway by
provisioned bandwidth tier. See the
[overview](https://learn.microsoft.com/azure/databricks/security/network/serverless-network-security/private-network-gateway)
and the
[configuration steps](https://learn.microsoft.com/azure/databricks/security/network/serverless-network-security/private-network-gateway/configure-private-network-gateway)
in the Azure Databricks documentation.

#### Which compute uses it

| Compute | Path to the source |
| --- | --- |
| Classic | Runs in the workspace VNet, so it uses the VNet peering directly. The gateway is not involved. |
| Serverless | Enters the workspace VNet through the gateway, then follows the same VNet peering. |

A private network gateway serves serverless compute only. To connect both
compute types to one source, enable the source's `workspace_peering_enabled`
and set its serverless mode to `private_network_gateway`.

#### What the repository builds

```text
serverless compute
      |
private network gateway  (NCC, SPECIFIC_DESTINATIONS)
      |
gateway subnet 10.70.5.0/28  --+
                               |  workspace VNet 10.70.0.0/16
classic compute subnets  ------+
                               |
                          VNet peering + linked private DNS zone
                               |
                          source VNet (database)
```

- A dedicated subnet in the workspace VNet
  (`workspace_network.gateway_subnet_cidr`, `/28` or larger), delegated to
  `Microsoft.Databricks/workspaces`.
- A Network Connectivity Configuration attached to the workspace, shared with
  any private endpoint rules of the deployment.
- The gateway in `SPECIFIC_DESTINATIONS` mode, listing one DNS name for each
  source that uses it. Databricks allows those names in serverless egress
  control automatically.
- For the SQL Server VM, a network security rule that admits the gateway
  subnet on port 1433.

There is no endpoint to approve: `./infra endpoints` and `endpoint_approval`
apply only to Private Link.

#### Configure it

Start from the template:

```bash
./infra new azure my-png-lab --template workspace-sql-server-vm-private-network-gateway --target <target>
./infra explain azure environments/local/my-png-lab.tfvars
```

Or set the mode on a source in an existing environment:

```hcl
sql_server_vm = {
  workspace_peering_enabled = true
  private_dns_name          = "sqlserver.lab.exampledomain.com"
}

connectivity = {
  sql_server_vm = {
    serverless = "private_network_gateway" # none | private_link | private_network_gateway
  }
}

private_network_gateway = {
  bandwidth_tier_gbps   = 10 # 10, 30, 50, or 100
  private_dns_resolvers = [] # empty uses Azure-provided DNS
}
```

| Source | Requirements for `private_network_gateway` |
| --- | --- |
| `sql_server_vm` | `workspace_peering_enabled = true` and `private_dns_name` |
| `sql_database` | `sql_database.workspace_peering_enabled = true` |
| `mysql_flexible_server` | `mysql_flexible_server.workspace_peering_enabled = true` |

Sources can mix modes. One source can use Private Link while another uses the
gateway; a private endpoint rule always takes precedence over the gateway for
the same resource.

#### Build the gateway yourself

To practice the manual steps, set `private_network_gateway.manual = true`.
Terraform then creates only the delegated subnet and the source firewall rule.
You create the NCC, attach it to the workspace, and create the gateway by
following the
[manual guide](../azure/manual/serverless-sql-server-vm-private-network-gateway.md),
using the subnet and destinations that
`./infra output azure <tfvars> --json` lists under `serverless_connectivity`.
`./infra verify` checks the serverless path once your gateway is established.

Before you destroy the lab or switch `manual` back to `false`, delete the
gateway and detach and delete the NCC you created: Terraform does not manage
them, and the subnet cannot be deleted while a gateway uses it.

#### Requirements and limits

- The Premium plan, a Databricks account admin, and the preview enabled on the
  account console **Previews** page.
- A supported region. `./infra explain` and `./infra plan` warn when the
  location is not in the preview list.
- The gateway subnet must be unused by anything else, in the same region as
  the NCC and the workspace, and in the same Microsoft Entra tenant.
- An NCC holds at most two gateways. This matters when you reuse an NCC with
  `existing_network_connectivity_config_id`.
- The gateway cannot carry Azure Storage traffic (`blob.core.windows.net`,
  `dfs.core.windows.net`); use private endpoint rules for storage.
- Changing the gateway subnet replaces the gateway.

#### DNS

The gateway resolves names with Azure-provided DNS in the workspace VNet. Each
source's private DNS zone is linked to that VNet by the peering module, so the
hostname resolves to the private address. Set
`private_network_gateway.private_dns_resolvers` only when the names live on
your own DNS server, which must be reachable from the gateway subnet.

For Azure SQL Database and MySQL Flexible Server the destination is the
server's full hostname. Azure routes names that match a service endpoint
suffix around the gateway, so the destination must be that specific private
server name and not the service suffix.

#### Verify

```bash
./infra verify azure environments/local/my-png-lab.tfvars
```

The serverless check resolves the hostname, opens a TCP connection, signs in,
and counts the sample rows. A new gateway or destination can take several
minutes to take effect, and the check waits for it.

| Symptom | Cause and fix |
| --- | --- |
| Apply waits on the gateway, or it reports `FAILED` | The subnet is not delegated, is too small, or the region or Availability Zone is unsupported. `FAILED` is terminal: fix the cause, then plan and apply to replace the gateway. |
| `verify` fails at `dns` | The source's private DNS zone is not linked to the workspace VNet, or a custom resolver is unreachable from the gateway subnet. |
| `verify` fails at `tcp` | A network security group blocks the gateway subnet, or the NCC is not attached to the workspace. |
| `verify` fails at `login` on Azure SQL | The connection left through the public service endpoint path; check that the destination is the server's full hostname. |
| Destroy cannot delete the gateway subnet | Databricks was still removing the gateway. Wait a few minutes, then run the destroy plan and destroy again. |
