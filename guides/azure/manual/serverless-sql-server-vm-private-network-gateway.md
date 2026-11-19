# Manually connect serverless compute to SQL Server on a VM with a private network gateway

This guide builds the network path from Azure Databricks serverless compute
to SQL Server on an Azure VM by hand, using a Network Connectivity
Configuration (NCC) and a private network gateway (PNG). It uses the Azure
portal and the Databricks account console, and the REST API only where the
consoles offer no equivalent.

It covers networking only. It assumes the VM exists, SQL Server listens on TCP
`1433`, and the VM has no public IP. Database setup and CDC are out of scope.

The private network gateway is in Public Preview. Official references:

- [Private network gateway](https://learn.microsoft.com/azure/databricks/security/network/serverless-network-security/private-network-gateway)
- [Configure a private network gateway](https://learn.microsoft.com/azure/databricks/security/network/serverless-network-security/private-network-gateway/configure-private-network-gateway)

To build the same path with a load balancer and Private Link instead, see
[Private Link](serverless-sql-server-vm-private-link.md).

## How the path works

```text
serverless compute (Databricks network)
      |
NCC attached to the workspace
      |
private network gateway  (routes only the DNS names you list)
      |
gateway subnet, delegated to Microsoft.Databricks/workspaces
      |
your VNet  --- routing and DNS you control --->  SQL Server VM, TCP 1433
```

Databricks injects the gateway into a subnet you delegate to it. Serverless
compute then reaches whatever that subnet can reach: the same VNet, peered
VNets, and networks behind ExpressRoute or a VPN. The gateway routes by DNS
name, so the VM needs a hostname that resolves from the gateway subnet's VNet.

The gateway serves serverless compute only. Classic compute runs in the
workspace VNet and needs its own route to the VM, such as VNet peering.

## Choose where the gateway subnet goes

| Option | Gateway subnet is in | Extra work |
| --- | --- | --- |
| A. Same VNet as the VM | The SQL Server VM's VNet | None. This is the shortest path. |
| B. Another VNet | A hub or workspace VNet | Peer that VNet with the VM's VNet and link the private DNS zone to it. |

Use option A unless you want one gateway to serve several VNets. Both options
were tested in this repository's lab.

## Requirements

- Premium plan, and a workspace with serverless compute.
- Databricks account admin.
- The preview enabled: account console, **Previews** page.
- Permission in Azure to create and delegate a subnet and to manage private
  DNS zones.
- A supported region. The gateway subnet, the NCC, and the workspace must all
  be in the same region.
- The VNet's subscription must be in the same Microsoft Entra tenant as the
  workspace's subscription.

Limits during the preview: at most two gateways for each NCC, 100 destinations
and two DNS resolvers for each gateway. Databricks bills the gateway by
bandwidth tier while it exists.

## Values to collect

| Value | Where to find it | Example |
| --- | --- | --- |
| Databricks account ID | Account console, user menu | `<account-id>` |
| Workspace name and region | Account console, **Workspaces** | `westus2` |
| VM's VNet and resource group | VM **Overview** page | `<sql-vnet>`, `<sql-rg>` |
| VM private IP | VM **Networking** page | `10.90.1.4` |
| Free address range for the gateway subnet | VNet **Subnets** page | `10.90.0.0/26` |
| Hostname for SQL Server | You choose it | `sqlserver.lab.exampledomain.com` |

## DNS

The gateway routes by DNS name, not by IP address, so DNS decides whether the
path works. Read this section before you choose the hostname.

### Concepts

| Term | Meaning |
| --- | --- |
| Hostname (FQDN) | The full name a client connects to, such as `sqlserver.lab.exampledomain.com`. |
| DNS zone | The container for the records of one domain, such as `lab.exampledomain.com`. |
| A record | A record in a zone that maps a name to an IPv4 address, such as `sqlserver` to `10.90.1.4`. |
| Public DNS zone | A zone anyone on the internet can query. |
| Azure Private DNS zone | A zone that answers only inside the VNets it is linked to. It needs no DNS server. |
| Virtual network link | The link that makes a private zone visible to one VNet. A zone can be linked to many VNets. Peering does not share a zone; each VNet needs its own link. |
| Azure-provided DNS | The default resolver of every VNet (`168.63.129.16`). It answers public names and the private zones linked to that VNet. |
| Custom DNS server | A DNS server you run, such as Active Directory DNS or BIND, on a VM or on-premises. A VNet can be set to use it instead of Azure-provided DNS (**DNS servers** on the VNet). |
| Forwarder | A DNS server that passes queries it cannot answer to another server. A custom server usually forwards to `168.63.129.16` so that it still resolves Azure private zones. |
| Azure DNS Private Resolver | A managed Azure service that works as a DNS server inside a VNet. Its inbound endpoint has a private IP that other networks can query. |
| Split-horizon DNS | The same name resolving to different addresses depending on where the query comes from, for example a private address inside the VNet and a public one outside. |

### How a name is resolved through the gateway

1. Serverless compute looks up a hostname.
2. If the name matches a gateway destination, Databricks sends the lookup to
   the gateway. A destination also matches its subdomains, so listing
   `lab.exampledomain.com` covers `sqlserver.lab.exampledomain.com`.
3. The gateway resolves the name from inside the gateway subnet, using one of
   two sources:
   - **Azure-provided DNS**, when the gateway has no DNS resolvers set. This
     is the default and the recommended setting.
   - **The DNS resolvers you set on the gateway**, up to two IP addresses.
4. The answer must be a private IP address the gateway subnet can route to.
5. Serverless compute receives a translated IPv6 address that stands for that
   private address, and connects through the gateway.

A name that matches no destination never reaches the gateway. It resolves on
the public internet, or fails.

The gateway's DNS source is a setting on the gateway. The documentation
describes only the two sources above, so do not assume the gateway follows the
**DNS servers** setting of the VNet: if the VNet uses custom DNS servers, set
them on the gateway as resolvers too.

### Scenarios

| Where the hostname lives | What to configure |
| --- | --- |
| Nowhere yet: the VM is reached by IP address | Create an Azure Private DNS zone with an A record, and link it to the gateway's VNet (step 1). Leave the gateway's resolvers empty. |
| An Azure Private DNS zone linked to another VNet | Add a virtual network link from that zone to the gateway's VNet. Leave the resolvers empty. |
| A custom DNS server in Azure, such as a domain controller | Set the server's IP addresses as the gateway's DNS resolvers. Allow DNS (TCP and UDP `53`) from the gateway subnet to the server. |
| A DNS server on-premises, reached over ExpressRoute or a VPN | Set its IP addresses as resolvers, or the inbound endpoint of an Azure DNS Private Resolver that forwards to it. The gateway subnet needs a route to that address. |
| Both Azure private zones and names on a custom server | Use the custom server as the resolver and have it forward to `168.63.129.16` for the Azure zones. The gateway uses one source, not both. |
| Two private zones with the same name but different records | Azure-provided DNS cannot tell them apart from one VNet. Use your own resolver. |
| A public DNS record that points to the private IP | Should resolve through Azure-provided DNS with no extra setup, but this was not tested in the lab, and it publishes an internal address. Prefer a private zone. |

To set or change the resolvers on an existing gateway, use the REST API. An
empty list switches back to Azure-provided DNS.

```bash
databricks api patch \
  "/api/networking/v1/accounts/<account-id>/network-connectivity-configs/<ncc-id>/private-network-gateways/<gateway-id>?update_mask=private_dns_resolvers" \
  --profile <account-profile> \
  --json '{ "private_dns_resolvers": [ { "resolver_type": "IP_ADDRESS", "value": "<dns-server-ip>" } ] }'
```

### Choosing the hostname

- Use a domain your organization controls. A private zone for a domain owned
  by someone else works inside the VNet, but the same name means something
  different everywhere else. The example domain in this guide is for the lab
  only.
- Prefer the name the database already has in your DNS over inventing a new
  one, so that clients, certificates, and documentation agree.
- The name in the gateway destination, the name in DNS, and the name in the
  client connection must be the same.
- If SQL Server uses a TLS certificate, the hostname should be on it.
  Otherwise clients must be told to trust the server certificate.
- Azure Storage hostnames (`blob.core.windows.net`, `dfs.core.windows.net`)
  are reserved and cannot be destinations.

### Checking DNS

From a VM in the gateway's VNet, `nslookup <sql-server-hostname>` must return
the VM's private IP. If it does not, the gateway cannot resolve the name
either. From serverless compute, use the Python test in step 8; the name
resolves to an IPv6 address there, as that step explains.

## 1. Give the VM a private hostname

This step implements the first scenario in [DNS](#dns). Skip it if a hostname
already resolves to the VM's private IP from the VNet that will hold the
gateway subnet.

1. In the Azure portal, search for **Private DNS zones** and select
   **+ Create**.
2. Select the VM's resource group. For **Name**, enter the zone, which is the
   hostname without its first label, for example `lab.exampledomain.com`.
   Select **Review + create**, then **Create**.
3. Open the zone and select **+ Record set**. Enter the first label of the
   hostname as **Name** (for example `sqlserver`), keep **Type** as **A**,
   enter the VM's private IP, and select **Add**.
4. In the zone, open **DNS Management > Virtual network links** and select
   **+ Add**. Enter a link name, select the VNet that will hold the gateway
   subnet, leave auto registration disabled, and select **Create**.

For option B, the link must be on the VNet that holds the gateway subnet, not
only on the VM's VNet.

Use a hostname you could also use with Private Link: that feature rejects
private-use top-level domains such as `.internal`, `.localhost`, and `.test`.

## 2. Create and delegate the gateway subnet

1. In the Azure portal, open the target VNet and select **Subnets**.
2. Select **+ Subnet**.
3. Enter a name such as `databricks-gateway` and an unused range of `/28` or
   larger.
4. Under **Subnet delegation**, select `Microsoft.Databricks/workspaces`.
5. Select **Add** (or **Save**).

The subnet must hold nothing else. Do not reuse a workspace's host or
container subnet.

For option B only, peer the two VNets: open one VNet, select **Peerings**,
select **+ Add**, choose the other VNet, and keep **Allow access to the remote
virtual network** enabled in both directions.

## 3. Allow the gateway subnet to reach SQL Server

Open the network security group on the VM's network interface or subnet and
check its inbound rules.

- If nothing overrides the default `AllowVnetInBound` rule, traffic from the
  gateway subnet is already allowed, both from the same VNet and from a peered
  VNet.
- If a higher-priority rule denies VNet traffic, add an inbound rule: source
  **IP Addresses** set to the gateway subnet range, destination the VM's
  private IP, service **MS SQL** (TCP `1433`), action **Allow**.

Also confirm that the Windows firewall on the VM allows TCP `1433`.

## 4. Create or choose an NCC

A workspace uses one NCC at a time. If the workspace already has one, add the
gateway to that NCC and skip to step 6.

1. Open the [account console](https://accounts.azuredatabricks.net).
2. In the sidebar, select **Security**, then
   **Network connectivity configurations**.
3. Select **Add network configuration**.
4. Enter a name and choose the workspace's region.
5. Select **Add**.

## 5. Attach the NCC to the workspace

1. In the account console sidebar, select **Workspaces**.
2. Select the workspace, then **Update workspace**.
3. In the **Network connectivity configurations** field, select the NCC. If it
   is missing, the NCC and the workspace are in different regions.
4. Select **Update**.

An NCC can be replaced with another one but not removed from a workspace, and
Databricks refuses to delete an NCC while a workspace still uses it.

## 6. Create the private network gateway

### In the account console

1. Select **Security**, then **Network connectivity configurations**, and open
   the NCC.
2. Open the **Private network gateway** tab and select
   **Add private network gateway**.
3. Follow the prompts with these values:

| Setting | Value |
| --- | --- |
| Name | A display name, such as `sql-vm-gateway` |
| Gateway subnet | Full resource ID of the delegated subnet (see below) |
| DNS resolvers | Leave empty to use Azure-provided DNS |
| Bandwidth | `10` Gbps is the lowest tier; the console preselects `30` |
| Traffic mode | `SPECIFIC_DESTINATIONS` |
| Destinations | The SQL Server hostname, type `DNS_NAME` |

The subnet resource ID has this form. To copy it, open the subnet in the
portal, or open the VNet's **JSON View** and find the subnet's `id`.

```text
/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Network/virtualNetworks/<vnet-name>/subnets/<subnet-name>
```

Use the subscription ID in that path, not the tenant ID, and keep it on one
line.

`SPECIFIC_DESTINATIONS` sends only the listed names through the gateway, and
Databricks allows those names in serverless egress control automatically. A
listed name also matches its subdomains. Set custom DNS resolvers only when
the hostname lives on your own DNS server; the server must be reachable from
the gateway subnet.

### With the REST API

Use the API when the tab is not available in your account console, or to
script the step. These commands use the Databricks CLI with an account-level
profile, created with `databricks auth login --host https://accounts.azuredatabricks.net --account-id <account-id>`.
The equivalent `curl` calls go to `https://accounts.azuredatabricks.net` with
a bearer token. The official steps use a service principal that is an account
admin; an account admin user login also worked in this repository's lab.

```bash
databricks api post \
  /api/networking/v1/accounts/<account-id>/network-connectivity-configs/<ncc-id>/private-network-gateways \
  --profile <account-profile> \
  --json '{
    "display_name": "sql-vm-gateway",
    "bandwidth_tier_gigabits_per_second": 10,
    "traffic_mode": "SPECIFIC_DESTINATIONS",
    "azure_cloud_connection": {
      "gateway_subnet": {
        "resource_id": "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Network/virtualNetworks/<vnet-name>/subnets/<subnet-name>"
      }
    },
    "private_dns_resolvers": [],
    "destinations": [
      { "destination_type": "DNS_NAME", "value": "<sql-server-hostname>" }
    ]
  }'
```

The response is a long-running operation with `"done": false`. Its `name`
contains the gateway ID, between `private-network-gateways/` and
`/operations/`.

## 7. Wait for the gateway

In the account console, refresh the **Private network gateway** tab until the
gateway shows `ESTABLISHED`. With the API:

```bash
databricks api get \
  /api/networking/v1/accounts/<account-id>/network-connectivity-configs/<ncc-id>/private-network-gateways/<gateway-id> \
  --profile <account-profile>
```

| State | Meaning |
| --- | --- |
| `CREATING` | Databricks is placing the gateway in the subnet. In the lab this took about two minutes. |
| `ESTABLISHED` | The gateway routes traffic. |
| `FAILED` | Terminal. Delete the gateway, fix the cause, and create a new one. |

## 8. Test from serverless compute

Wait a few minutes after the gateway is established and the NCC is attached,
then start a new serverless session: changes apply to serverless compute that
starts afterward. In a notebook attached to **Serverless**, run:

```python
import socket

host, port = "<sql-server-hostname>", 1433

print(socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP))
with socket.create_connection((host, port), timeout=10):
    print(f"TCP connection to {host}:{port} succeeded")
```

The hostname resolves to an IPv6 address in `64:ff9b:1::/48`, not to the VM's
IPv4 address. This is expected: serverless compute reaches the gateway over
IPv6, and the address embeds the private IPv4 address in its last 32 bits
(`0a5a:0104` is `10.90.1.4`).

Two consequences follow:

- Always connect by hostname. The gateway does not route a bare IPv4 address.
- Tools that only look up IPv4 addresses fail with a name-resolution error
  even when the path works. `nc` on serverless compute behaved this way in the
  lab; the Python test above and a SQL Server driver both worked.

## Change or remove the gateway

Updates and deletion use the REST API.

Change the destinations (`update_mask` names the fields to replace):

```bash
databricks api patch \
  "/api/networking/v1/accounts/<account-id>/network-connectivity-configs/<ncc-id>/private-network-gateways/<gateway-id>?update_mask=destinations" \
  --profile <account-profile> \
  --json '{ "destinations": [ { "destination_type": "DNS_NAME", "value": "<another-hostname>" } ] }'
```

Delete the gateway:

```bash
databricks api delete \
  /api/networking/v1/accounts/<account-id>/network-connectivity-configs/<ncc-id>/private-network-gateways/<gateway-id> \
  --profile <account-profile>
```

Deleting a gateway cuts every path that depends on it. The call returns
before Databricks finishes removing the gateway from the subnet, so wait a few
minutes before you delete the subnet. To change the subnet, delete the gateway
and create a new one.

## Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| Creation fails with an invalid subnet or parameter error | The subnet ID contains the tenant ID or a line break, or the subnet is not delegated. |
| The gateway stays `CREATING` for more than 10 minutes | The subnet is not delegated to `Microsoft.Databricks/workspaces`, is smaller than `/28`, or already holds other resources. |
| Name resolution fails in the Python test | The private DNS zone is not linked to the VNet that holds the gateway subnet, the workspace uses a different NCC, or the serverless session started before the change. |
| Name resolution fails only in a command-line tool | The tool looks up IPv4 addresses only. Test with Python. |
| The name resolves but the connection times out | A network security group or the Windows firewall blocks TCP `1433` from the gateway subnet. For option B, check the peering. |
| The connection works but sign-in fails | The network path is fine. Check the SQL login, password, and database. |
| Traffic to Azure Storage does not use the gateway | Storage domains are reserved. Use private endpoint rules for `blob` and `dfs`. |
