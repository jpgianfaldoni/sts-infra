# Manually connect serverless compute to Azure SQL Database with Private Link

This guide connects Azure Databricks serverless compute to an Azure SQL
Database that has public access disabled, using a Network Connectivity
Configuration (NCC) and a private endpoint rule. It uses the Azure portal, the
Azure Databricks account console, and the workspace UI.

For SQL Server on an Azure VM, which needs a load balancer and a Private Link
service, see the [manual networking guides](../../manual/README.md).


It assumes the Azure SQL logical server and database already exist. Database
deployment and schema management are out of scope.

| Interface | What you configure there |
| --- | --- |
| Azure portal | Azure SQL networking and private endpoint approval |
| Databricks account console | NCC, workspace attachment, and the private endpoint rule |
| Databricks workspace UI | The Unity Catalog connection and the connection test |

Official references:

- [Configure private connectivity to Azure resources](https://learn.microsoft.com/azure/databricks/security/network/serverless-network-security/serverless-private-link)
- [Manage private endpoint rules](https://learn.microsoft.com/azure/databricks/security/network/serverless-network-security/manage-private-endpoint-rules)

## How the path works

```text
Azure Databricks workspace
  -> NCC attached to the workspace
  -> private endpoint rule
       destination: Azure SQL logical server resource ID
       subresource: sqlServer
  -> Databricks-managed private endpoint
  -> Azure SQL logical server
  -> database on TCP 1433
```

Serverless compute runs in a Databricks-managed network, not in the VNet that
classic compute uses. VNet injection, peering, private DNS zones, and private
endpoints set up for classic compute therefore give serverless compute no path
to a private resource.

| Component | Purpose |
| --- | --- |
| Network Connectivity Configuration (NCC) | Regional account object that lists the private destinations serverless compute may reach. A workspace uses one NCC at a time. |
| Private endpoint rule | Names the Azure resource and subresource to reach privately. |
| Databricks-managed private endpoint | The endpoint Databricks creates in its own network after you add the rule. |
| Approval on the Azure resource | The resource owner's approval of that endpoint. Nothing flows until it is approved. |

Azure SQL Database supports Private Link directly, with the subresource
`sqlServer`. Do not add a load balancer or a Private Link service for it.

## Requirements and limits

- Premium plan, and a workspace with serverless compute.
- Azure Databricks account admin.
- Permission to approve private endpoint connections on the SQL logical
  server.
- The NCC and the workspace must be in the same Azure region.
- A workspace uses one NCC. Add every destination it needs to that NCC.

Limits: 20 NCCs for each account and region, 100 private endpoints for each
region, and 50 workspaces for each NCC.

## Values to collect

| Value | Where to find it |
| --- | --- |
| Workspace name and region | Account console, **Workspaces** |
| SQL logical server resource ID | Azure portal, **JSON View** on the server's **Overview** page |
| SQL hostname | Server **Overview** page, normally `<server>.database.windows.net` |
| Database name | Server **SQL databases** page |
| Subresource | `sqlServer` |

## Procedure

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

## Security and DNS principles

### Keep public access disabled

Private Link is intended to avoid public ingress. Do not add broad public
firewall or NSG rules to make a generic connection test pass. Inspect the
detailed error first.

### Use the correct hostname

Use `<server>.database.windows.net`, the server's normal hostname.

Changing the hostname can bypass the intended rule or fail certificate
validation.

### Separate networking from authentication

These error types indicate different layers:

- Timeout, name-resolution failure, or connection refusal: investigate DNS,
  NCC binding, rule state, and endpoint approval.
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

## Troubleshooting checklist

### The NCC is not available on the workspace

- Confirm the workspace and NCC regions match exactly.
- Confirm account-admin permissions.
- Check whether the workspace is already bound to another NCC.

### The rule remains PENDING

- Approve the Databricks-created endpoint on the Azure SQL logical server.
- Confirm that the approved request is the new Databricks endpoint rather than
  an unrelated customer-VNet endpoint.

### The rule is ESTABLISHED but the connection fails

- Restart the serverless resource.
- Confirm the connection hostname and port.
- Confirm the database name and credentials.
- Verify that the database accepts the selected authentication method.

### The error recommends allowing public Internet access

Treat that recommendation as generic guidance. Do not enable public access
without first inspecting the detailed error. A database authentication or
authorization response proves that the request already reached SQL Server.

### Classic compute works but serverless fails

The two compute types use separate network paths. Recheck the NCC binding,
private endpoint rule, Azure-side approval, `ESTABLISHED` state, and serverless
restart rather than assuming the classic VNet path is reused.
