# Private network gateway

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

## Which compute uses it

| Compute | Path to the source |
| --- | --- |
| Classic | Runs in the workspace VNet, so it uses the VNet peering directly. The gateway is not involved. |
| Serverless | Enters the workspace VNet through the gateway, then follows the same VNet peering. |

A private network gateway serves serverless compute only. To connect both
compute types to one source, enable the source's `workspace_peering_enabled`
and set its serverless mode to `private_network_gateway`.

## What the repository builds

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

## Configure it

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

## Requirements and limits

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

## DNS

The gateway resolves names with Azure-provided DNS in the workspace VNet. Each
source's private DNS zone is linked to that VNet by the peering module, so the
hostname resolves to the private address. Set
`private_network_gateway.private_dns_resolvers` only when the names live on
your own DNS server, which must be reachable from the gateway subnet.

For Azure SQL Database and MySQL Flexible Server the destination is the
server's full hostname. Azure routes names that match a service endpoint
suffix around the gateway, so the destination must be that specific private
server name and not the service suffix.

## Verify

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
