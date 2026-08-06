# UI guide: connect Azure Databricks serverless to private SQL Server resources

This guide explains the networking components and the UI steps required to
connect Azure Databricks serverless compute to SQL Server in Azure without
enabling public database access. Configuration is performed through the Azure
portal, the Azure Databricks account console, and the Databricks workspace UI.

## Guide scope

This document assumes that the Azure SQL logical server or SQL Server VM
already exists. It focuses on configuring and validating private connectivity;
database deployment and schema management are outside its scope.

Use these interfaces throughout the procedure:

| Interface | What is configured there |
|---|---|
| **Azure portal** | Azure SQL networking, private endpoint approval, load balancer, Private Link Service, and Microsoft Entra administrator. |
| **Databricks account console** | Network Connectivity Configuration, workspace attachment, and private endpoint rules. |
| **Databricks workspace UI** | Unity Catalog connection, credentials, and connection test. |

The text blocks in this guide show values to enter, resource-ID shapes, DNS
names, or validation queries. They are not infrastructure deployment scripts.

There are two distinct scenarios:

1. **Azure SQL Database:** Databricks creates a private endpoint directly to
   the Azure SQL logical server. This is the preferred and simpler design.
2. **SQL Server on an Azure VM:** The VM must be exposed through an internal
   Standard Load Balancer and an Azure Private Link Service.

Official references:

- [Configure private connectivity to Azure resources](https://learn.microsoft.com/azure/databricks/security/network/serverless-network-security/serverless-private-link)
- [Configure private connectivity to resources in your VNet](https://learn.microsoft.com/azure/databricks/security/network/serverless-network-security/pl-to-internal-network)
- [Manage private endpoint rules](https://learn.microsoft.com/azure/databricks/security/network/serverless-network-security/manage-private-endpoint-rules)

## Understand the networking model

Azure Databricks serverless compute runs in a Databricks-managed network. It
does not run in the customer-managed VNet used by classic compute. VNet
injection, VNet peering, private DNS zones, and private endpoints configured
for classic compute therefore do not automatically give serverless compute a
path to private Azure resources.

Serverless private networking uses these components:

| Component | Purpose |
|---|---|
| **Serverless compute plane** | Runs serverless notebooks, jobs, SQL warehouses, Lakeflow pipelines, and model-serving workloads in a Databricks-managed network. |
| **Network Connectivity Configuration (NCC)** | Regional account object that defines private destinations available to serverless workloads. |
| **Workspace-to-NCC binding** | Activates the NCC for serverless workloads in a workspace. A workspace can use only one NCC at a time. |
| **Private endpoint rule** | Identifies the Azure resource and subresource that Databricks must reach privately. |
| **Databricks-managed private endpoint** | Consumer-side Azure Private Link endpoint created by Databricks after the rule is added. |
| **Azure resource approval** | Resource-owner approval that authorizes the Databricks private endpoint. |
| **Azure SQL logical server** | Private Link provider for Azure SQL Database. It supports a direct endpoint with subresource `sqlServer`. |
| **Azure Private Link Service** | Provider used for custom services, including SQL Server on a VM behind an internal Standard Load Balancer. |

The NCC affects serverless compute only. Classic compute still uses its own
VNet, routes, DNS, and private endpoints.

## Choose the correct architecture

### Azure SQL Database

```text
Azure Databricks workspace
  -> workspace-to-NCC binding
  -> NCC private endpoint rule
       destination: Azure SQL logical server resource ID
       subresource: sqlServer
  -> Databricks-managed private endpoint
  -> Azure SQL logical server
  -> Azure SQL database on TCP 1433
```

Azure SQL Database supports Private Link directly. Do not add an Azure Load
Balancer or customer-managed Private Link Service for this scenario.

### SQL Server on an Azure VM

```text
Azure Databricks workspace
  -> workspace-to-NCC binding
  -> NCC private endpoint rule
       destination: Azure Private Link Service resource ID
       domain: stable SQL Server application hostname
  -> Databricks-managed private endpoint
  -> Azure Private Link Service
  -> internal Standard Load Balancer on TCP 1433
  -> SQL Server VM private IP on TCP 1433
```

A VM does not expose the Azure SQL `sqlServer` subresource. The load balancer
and Private Link Service provide the private service frontend that Databricks
can consume.

## Requirements and limits

- Azure Databricks serverless compute must be available in the workspace.
- You must be an Azure Databricks account administrator.
- You need permission to inspect and approve private endpoint connections on
  the Azure destination.
- The NCC and workspace must be in the same Azure region.
- A workspace can be attached to only one NCC. Add all required destination
  rules to that NCC.
- The database must listen on the configured TCP port and accept the selected
  authentication method.

Current documented regional limits include:

- Up to 10 NCCs per Databricks account and region.
- Up to 100 private endpoints per region across those NCCs.
- Up to 50 workspaces attached to one NCC.

## Values to collect

Before starting, record:

| Setting | Where to find it |
|---|---|
| Databricks account | Azure Databricks account console |
| Workspace and workspace region | **Workspaces** in the account console |
| Azure SQL logical server resource ID | Azure portal **JSON View** on the SQL server overview page |
| Azure SQL hostname | SQL server **Overview** page; normally `<server>.database.windows.net` |
| Database name | Azure SQL server **SQL databases** page |
| Azure SQL subresource | `sqlServer` |
| SQL Server VM application hostname | The stable hostname applications will use |
| Private Link Service resource ID | Private Link Service **Overview > JSON View** |

## Azure SQL Database procedure

### 1. Prepare Azure SQL for private access

1. Open the Azure portal.
2. Navigate to the Azure SQL **logical server**, not only the individual
   database.
3. Open **Networking**.
4. Set **Public network access** to **Disabled**.
5. Save the change.
6. Under **Private endpoint connections**, review existing endpoints so that
   the new Databricks request can be identified later.

Disabling public access prevents Internet-sourced connections, including
public client applications and the portal query editor. It does not prevent an
approved private endpoint from reaching the server.

An existing private endpoint in an application VNet is useful for clients in
that VNet, but it cannot be reused by the Databricks-managed serverless
network. Databricks creates a separate private endpoint for the NCC.

### 2. Create or reuse an NCC

1. Open the [Azure Databricks account console](https://accounts.azuredatabricks.net).
2. Select the correct Databricks account.
3. Go to **Security > Network connectivity configurations**.
4. Check whether the workspace already uses an NCC in its region.
5. If an appropriate NCC exists, reuse it. Otherwise click
   **Add network configuration**.
6. Enter a descriptive name.
7. Select the same Azure region as the workspace.
8. Create the NCC.

Sharing an NCC among related workspaces is useful when they require the same
private destinations. Use separate NCCs when business units or security
boundaries require different destination policies.

### 3. Attach the NCC to the workspace

1. In the account console, open **Workspaces**.
2. Select the target Azure Databricks workspace.
3. Locate **Networking**.
4. In **Network connectivity configuration**, select the NCC.
5. Save the workspace configuration.
6. Confirm that the workspace continues to report a healthy running state.

If the NCC is not available in the dropdown, verify that its region exactly
matches the workspace region.

### 4. Add the Azure SQL private endpoint rule

1. In the Azure portal, open the Azure SQL logical server.
2. Open **Overview > JSON View**.
3. Copy the full server resource ID. It has this shape:

   ```text
   /subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Sql/servers/<server-name>
   ```

4. Return to the Azure Databricks account console.
5. Go to **Security > Network connectivity configurations**.
6. Open the NCC and select **Private endpoint rules**.
7. Click **Add private endpoint rule**.
8. Paste the logical-server ID into **Destination Azure resource ID**.
9. Enter the following value in **Azure subresource ID**:

   ```text
   sqlServer
   ```

10. Create the rule.
11. Wait for the rule to show `PENDING`.

Use the logical-server resource ID—not the database ID and not the ID of an
existing private endpoint.

### 5. Approve the Databricks private endpoint

1. Return to the Azure SQL logical server in the Azure portal.
2. Open **Networking > Private endpoint connections**.
3. Find the new pending request created by Azure Databricks.
4. Select the request and review its target resource.
5. Click **Approve**.
6. Add a clear description, such as
   `Azure Databricks serverless NCC`.
7. Confirm that the Azure connection state becomes **Approved**.

The rule cannot route traffic while approval is pending.

### 6. Confirm the rule is established

1. Return to the NCC in the Azure Databricks account console.
2. Open **Private endpoint rules**.
3. Refresh until the Azure SQL rule reports `ESTABLISHED`.
4. Confirm that the workspace still displays the intended NCC assignment.

Relevant states are:

- `PENDING`: waiting for Azure-side approval.
- `ESTABLISHED`: approved and ready for serverless traffic.
- `REJECTED`: the resource owner rejected the request.
- `DISCONNECTED`: the Azure-side connection was removed.
- `EXPIRED`: the request was not approved within the allowed period.
- `CREATE_FAILED`: validate the resource ID, subresource, region, permissions,
  support, and endpoint quota.

### 7. Restart serverless resources

Restart serverless resources that were already running when the NCC or rule
changed. This includes running notebooks, jobs, pipelines, model-serving
endpoints, and SQL warehouses.

Starting a new serverless session also ensures it receives the latest network
configuration.

### 8. Configure the SQL connection

In the Azure Databricks workspace:

1. Open **Catalog**.
2. Go to **External Data > Connections**.
3. Click **Create connection**.
4. Select the SQL Server connection type.
5. Enter the normal Azure SQL hostname:

   ```text
   <server>.database.windows.net
   ```

6. Use port `1433`.
7. Enter the database name when requested by the connection or foreign-catalog
   workflow.
8. Select the intended authentication method.
9. Store credentials using the workspace's approved secret-management method.
10. Keep encryption enabled.
11. Test the connection.

Use `<server>.database.windows.net` as the application hostname. Do not use
the `privatelink.database.windows.net` alias directly; the normal hostname is
required for standard Azure SQL DNS and certificate validation.

For SQL authentication, verify the exact username, password, and database.
For Microsoft Entra authentication, grant the selected identity access inside
the database. Azure resource permissions alone do not grant database access.

Do not enable **Trust server certificate** for a production Azure SQL
connection. Azure SQL provides a publicly trusted certificate for its normal
hostname.

### 9. Validate from serverless compute

Use a serverless notebook, job, pipeline, or SQL warehouse and run a small
authenticated query against an existing table.

Successful authentication and query execution confirm:

- The workspace is bound to the correct NCC.
- The private endpoint rule is established.
- Serverless DNS and routing selected the private endpoint.
- Azure SQL accepted TLS and database credentials.

Test with a read-only query first. Add write permissions only when the workload
requires them.

## SQL Server on an Azure VM procedure

### Values to collect before starting

Record the values for the target environment before creating the load
balancer. Values shown in angle brackets are placeholders and must not be
entered literally.

| Setting | Value |
|---|---|
| Resource group | `<sql-server-resource-group>` |
| Region | `<sql-server-vm-region>` |
| Virtual network | `<sql-server-vnet>` |
| SQL VM subnet | `<sql-server-vm-subnet>` |
| SQL Server VM | `<sql-server-vm-name>` |
| SQL Server NIC | `<sql-server-vm-nic>` |
| SQL Server private IP | `<sql-server-private-ip>` |
| SQL Server port | `1433` |
| Unused IP in the SQL VM subnet | `<load-balancer-private-frontend-ip>` |
| Private Link Service NAT subnet | `<private-link-service-nat-subnet>` |
| Unused IP in the NAT subnet | `<private-link-service-nat-ip>` |
| Stable SQL application hostname | `<sql-server-application-hostname>` |
| Databricks endpoint subscription | `<databricks-private-endpoint-subscription-id>` |

Find the VM, NIC, VNet, subnet, private IP, resource group, and region on the
VM's **Overview** and **Networking** pages. Check the subnet address ranges
before selecting unused frontend and NAT IP addresses; do not guess them or
reuse the VM's IP.

The VM should have no public IP. Its network security group and Windows
firewall must permit TCP `1433` from the Private Link Service NAT subnet and
permit Azure Load Balancer health probes. Deny other inbound traffic unless a
separate approved management path requires it.

### 1. Prepare SQL Server and the VM network

1. Confirm SQL Server listens on a fixed TCP port, normally `1433`.
2. Confirm the service listens on the VM's private interface.
3. Disable public IP access when it is not explicitly required for another
   controlled use case.
4. In the VM network security group, do not allow Internet-sourced access to
   TCP `1433`.
5. Create or choose a dedicated subnet for the Private Link Service NAT IPs.

### 2. Create an internal Standard Load Balancer

In the Azure portal, go to **Load balancers > Create** and complete each tab as
follows.

#### Basics tab

1. Select the subscription containing the SQL Server VM.
2. Select `<sql-server-resource-group>`.
3. Enter a descriptive name such as `internal-sql-lb`.
4. Select `<sql-server-vm-region>`. The load balancer and VM must be in the
   same region.
5. Select **Standard** as the SKU.
6. Select **Internal** as the type.
7. Select **Regional** as the tier if the portal displays that option.
8. Do not select **Gateway Load Balancer**. It is intended for inserting
   network virtual appliances, not for balancing SQL traffic.

#### Frontend IP configuration tab

1. Click **Add a frontend IP configuration**.
2. Enter `sql-frontend` as the name.
3. Select **IPv4**.
4. Select `<sql-server-vnet>`.
5. After selecting the virtual network, select `<sql-server-vm-subnet>`.
6. Select **Static** IP assignment.
7. Enter `<load-balancer-private-frontend-ip>`, an unused address inside the
   selected subnet.
8. Select **Zone-redundant** where supported unless the workload has a
   deliberate zonal design that requires a specific zone.
9. Save the frontend configuration.

The subnet and private-IP fields appear only after the virtual network has
been selected. The frontend must be private; do not create or select a public
IP address.

#### Backend pools tab

1. Click **Add a backend pool**.
2. Enter `sql-backend` as the name.
3. Select `<sql-server-vnet>`.
4. For backend-pool configuration, select **NIC** if the portal asks whether
   to use NICs or IP addresses.
5. Click **Add**, select `<sql-server-vm-name>`, and select its primary IP
   configuration on `<sql-server-vm-nic>`.
6. Confirm that `<sql-server-private-ip>` is shown and save the backend pool.

Do not enter the load-balancer frontend IP as a backend. The backend is the
SQL Server VM NIC at `<sql-server-private-ip>`.

#### Inbound rules tab

Add one load-balancing rule. When the rule asks for a health probe, select
**Create new** and configure the probe first:

| Health-probe setting | Value |
|---|---|
| Name | `sql-tcp-1433` |
| Protocol | `TCP` |
| Port | `1433` |
| Interval | `5` seconds |
| Unhealthy threshold | `2` consecutive failures |

Configure the load-balancing rule with these values:

| Load-balancing rule setting | Value |
|---|---|
| Name | `sql-tcp-1433` |
| IP version | `IPv4` |
| Frontend IP address | `sql-frontend` |
| Backend pool | `sql-backend` |
| Protocol | `TCP` |
| Frontend port | `1433` |
| Backend port | `1433` |
| Health probe | `sql-tcp-1433` |
| Session persistence | `None` |
| Floating IP | `Disabled` |
| TCP reset | `Disabled` |
| Outbound SNAT | Disable when the backend subnet already has an approved explicit outbound path |

If the backend subnet uses a NAT gateway, Azure Firewall, or another explicit
egress design, disable implicit outbound SNAT on the load-balancing rule. If
the VM still requires outbound access and no path exists, design an approved
outbound rule or NAT gateway rather than accepting an accidental default.

Do not add an inbound NAT rule. RDP is intentionally not exposed through the
load balancer.

#### Outbound rules, tags, and creation

1. If the VM subnet already has approved explicit outbound connectivity, do
   not add an outbound rule. Otherwise configure the organization's required
   outbound design.
2. Add organizational tags if required.
3. Open **Review + create** and confirm:
   - SKU is **Standard**.
   - Type is **Internal**.
   - Frontend IP is `<load-balancer-private-frontend-ip>` on
     `<sql-server-vm-subnet>`.
   - No public IP is present.
4. Select **Create**.

#### Validate the load balancer

1. Open the new internal load balancer after deployment finishes.
2. Confirm the frontend private IP is
   `<load-balancer-private-frontend-ip>`.
3. Open **Backend pools** and confirm `sql-backend` contains the VM NIC.
4. Open **Load balancing rules** and confirm TCP `1433` maps to TCP `1433`.
5. Open **Backend health** and confirm the VM reports **Healthy**.

If the backend is unhealthy, confirm SQL Server is running and listening on
TCP `1433`, the Windows firewall permits `1433`, and the VM network security
group permits the `AzureLoadBalancer` service tag to reach that port.

The load balancer supplies a stable frontend and health-aware routing. It does
not make the database public because its frontend is internal.

### 3. Create the Azure Private Link Service

Create the Private Link Service only after the load-balancer backend reports
healthy.

#### Basics tab

1. Go to **Private Link services > Create**.
2. Select `<sql-server-resource-group>`.
3. Enter a descriptive name such as `sql-private-link-service`.
4. Select `<sql-server-vm-region>`.

#### Outbound settings tab

1. Select the internal Standard Load Balancer created in the previous step.
2. Select frontend IP configuration `sql-frontend`.
3. Select `<sql-server-vnet>`.
4. Select source NAT subnet `<private-link-service-nat-subnet>`.
5. Select **IPv4**.
6. Select **Static** assignment and enter
   `<private-link-service-nat-ip>` if a fixed NAT address is required. Dynamic
   assignment is also supported when a stable NAT IP is not required by the
   security policy.
7. Keep **TCP proxy V2** disabled. SQL Server does not expect the proxy
   protocol header.

The source NAT subnet is different from the load-balancer frontend subnet.
Use `<private-link-service-nat-subnet>`, not `<sql-server-vm-subnet>`, for the
Private Link Service NAT IP.

#### Access security tab

1. Restrict visibility to approved subscriptions.
2. Add the Databricks-managed private-endpoint subscription ID:

   ```text
   <databricks-private-endpoint-subscription-id>
   ```

   Obtain this account- and region-specific value from the approved
   Databricks deployment information or your Databricks representative. Do
   not reuse an ID copied from another account or region.

3. Leave auto-approval disabled so the Databricks endpoint request must be
   reviewed and approved manually.
4. Review and create the service.

After creation:

1. Open the new Private Link Service.
2. Confirm its provisioning state is **Succeeded**.
3. Open **Overview > JSON View** and copy the full resource ID.
4. Keep the **Private endpoint connections** page open; the Databricks request
   will appear there after the NCC rule is created.

### 4. Add the VM service to the NCC

1. Open the Azure Databricks account console.
2. Go to **Security > Network connectivity configurations**.
3. Open the NCC already attached to the workspace.
4. Select **Private endpoint rules** and click
   **Add private endpoint rule**.
5. Use the Azure Private Link Service resource ID as the destination.
6. Add `<sql-server-application-hostname>`, the stable hostname that
   applications will use. For example:

   ```text
   sqlvm.internal.example.com
   ```

7. Create the rule and wait for `PENDING`.

For a customer-managed Private Link Service, the hostname identifies which
serverless traffic must use the private route. It must exactly match the
hostname in the SQL Server connection settings.

### 5. Approve and validate the VM endpoint

1. In the Azure portal, open the Private Link Service.
2. Select **Private endpoint connections**.
3. Approve the Databricks-created pending request.
4. Return to the NCC and wait for `ESTABLISHED`.
5. Restart running serverless resources.
6. Create a SQL Server connection using
   `<sql-server-application-hostname>` and port `1433`.
7. Run an authenticated query from serverless compute.

If the load balancer target is unhealthy, troubleshoot that path before the
NCC. Private Link cannot deliver usable connections to an unhealthy backend.

## Security and DNS principles

### Keep public access disabled

Private Link is intended to avoid public ingress. Do not add broad public
firewall or NSG rules to make a generic connection test pass. Inspect the
detailed error first.

### Use the correct hostname

- Azure SQL Database: use `<server>.database.windows.net`.
- SQL Server VM: use the exact stable hostname listed in the NCC rule.

Changing the hostname can bypass the intended rule or fail certificate
validation.

### Separate networking from authentication

These error types indicate different layers:

- Timeout, name-resolution failure, or connection refusal: investigate DNS,
  NCC binding, rule state, endpoint approval, load balancer health, and NSGs.
- `Login failed for user`: the network path reached SQL Server; investigate
  username whitespace, password, database, authentication method, and grants.
- Certificate or hostname error: verify the normal application hostname,
  encryption settings, and certificate trust configuration.

### Protect credentials

Use Databricks secrets or an approved external secret manager. Do not place
passwords in notebooks, screenshots, documentation, or connection strings that
will be committed to source control.

## Classic compute considerations

NCC rules do not apply to classic compute.

For classic compute to reach Azure SQL Database privately, create a private
endpoint reachable from the classic-compute VNet and configure the
`privatelink.database.windows.net` private DNS zone for that VNet.

For classic compute to reach a SQL Server VM, provide routed connectivity such
as VNet peering, Virtual WAN, VPN, or ExpressRoute, together with appropriate
routes, DNS, and NSG rules.

## Troubleshooting checklist

### The NCC is not available on the workspace

- Confirm the workspace and NCC regions match exactly.
- Confirm account-admin permissions.
- Check whether the workspace is already bound to another NCC.

### The rule remains PENDING

- Approve the Databricks-created endpoint on the Azure SQL logical server or
  Private Link Service.
- Confirm that the approved request is the new Databricks endpoint rather than
  an unrelated customer-VNet endpoint.

### The rule is ESTABLISHED but the connection fails

- Restart the serverless resource.
- Confirm the connection hostname and port.
- Confirm the database name and credentials.
- For a VM, confirm load balancer health and VM NSG rules.
- Verify that the database accepts the selected authentication method.

### The error recommends allowing public Internet access

Treat that recommendation as generic guidance. Do not enable public access
without first inspecting the detailed error. A database authentication or
authorization response proves that the request already reached SQL Server.

### Classic compute works but serverless fails

The two compute types use separate network paths. Recheck the NCC binding,
private endpoint rule, Azure-side approval, `ESTABLISHED` state, and serverless
restart rather than assuming the classic VNet path is reused.
