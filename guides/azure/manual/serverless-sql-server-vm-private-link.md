# Manually connect serverless compute to SQL Server on a VM with Private Link

This guide builds the network path from Azure Databricks serverless compute
to SQL Server on an Azure VM by hand, using a Network Connectivity
Configuration (NCC), a private endpoint rule, an Azure Private Link service,
and an internal load balancer. It uses the Azure portal and the Databricks
account console, and the REST API only where the consoles offer no equivalent.

It covers networking only. It assumes the VM exists, SQL Server listens on TCP
`1433`, and the VM has no public IP. Database setup and CDC are out of scope.

Official references:

- [Configure private connectivity to resources in your VNet](https://learn.microsoft.com/azure/databricks/security/network/serverless-network-security/pl-to-internal-network)
- [Create a Private Link service using the Azure portal](https://learn.microsoft.com/azure/private-link/create-private-link-service-portal)

To build the same path with a private network gateway instead, see
[Private network gateway](serverless-sql-server-vm-private-network-gateway.md).

## How the path works

```text
serverless compute (Databricks network)
      |
NCC attached to the workspace
      |
private endpoint rule  (Private Link service resource ID + hostname)
      |
Databricks-managed private endpoint
      |
Azure Private Link service        (your VNet, NAT subnet)
      |
internal Standard Load Balancer   (frontend in the VM's subnet)
      |
SQL Server VM network interface, TCP 1433
```

A VM cannot be the target of a private endpoint directly. The load balancer
gives the VM a private frontend, and the Private Link service publishes that
frontend so that Databricks can create a private endpoint to it. You approve
that endpoint, and serverless compute then reaches SQL Server through the
hostname listed in the rule.

This path serves serverless compute only. Classic compute runs in the
workspace VNet and needs its own route to the VM, such as VNet peering.

## Requirements

- Premium plan, and a workspace with serverless compute.
- Databricks account admin.
- Permission in Azure to create a load balancer, a subnet, and a Private Link
  service in the VM's VNet, and to approve private endpoint connections.
- The load balancer and the Private Link service must be in the VM's region.
  The NCC must be in the workspace's region.

Limits: 20 NCCs for each account and region, 100 private endpoints for each
region, 50 workspaces for each NCC, and 100 domain names for each rule.
Databricks charges for serverless private connectivity.

## Values to collect

| Value | Where to find it | Example |
| --- | --- | --- |
| VM resource group and region | VM **Overview** page | `<sql-rg>`, `westus2` |
| VM's VNet and subnet | VM **Networking** page | `<sql-vnet>`, `snet-sql-vm` |
| VM network interface and private IP | VM **Networking** page | `10.90.1.4` |
| Free address range for a NAT subnet | VNet **Subnets** page | `10.90.2.0/24` |
| Hostname for SQL Server | You choose it | `sqlserver.lab.exampledomain.com` |
| Workspace name and region | Account console, **Workspaces** | `westus2` |

The hostname is the name clients put in the connection. The next section
explains how to choose it.

## DNS

With Private Link, you do not run DNS for serverless compute. The hostnames on
the private endpoint rule are the DNS configuration. Read this section before
you choose the hostname.

### Concepts

| Term | Meaning |
| --- | --- |
| Hostname (FQDN) | The full name a client connects to, such as `sqlserver.lab.exampledomain.com`. |
| Domain names (on the rule) | The hostnames that Databricks sends to this private endpoint. Up to 100 for each rule. |
| DNS zone | The container for the records of one domain, such as `lab.exampledomain.com`. |
| A record | A record in a zone that maps a name to an IPv4 address. |
| Azure Private DNS zone | A zone that answers only inside the VNets it is linked to. Serverless compute cannot see it. |
| Virtual network link | The link that makes a private zone visible to one VNet. |
| Custom DNS server | A DNS server you run, such as Active Directory DNS. Serverless compute cannot query it on this path. |
| Split-horizon DNS | The same name resolving to different addresses depending on where the query comes from. |
| Private-use top-level domain | A name ending such as `.internal`, `.localhost`, or `.test`, reserved for private networks. |

### How a name is resolved

1. Serverless compute looks up a hostname.
2. If the name is one of the rule's domain names, Databricks answers with the
   address of the private endpoint it created for that rule.
3. The connection goes through the endpoint to the Private Link service, the
   load balancer, and the VM.

Serverless compute never queries your DNS on this path. Records in an Azure
Private DNS zone or on a custom DNS server have no effect on it, and you do
not need to create any for serverless compute. A name that is not on a rule
resolves on the public internet, or fails.

### Rules for the domain names

- **Exact names only.** Enter the name of the specific server. Wildcards and
  service-level domains are not supported.
- **No private-use top-level domains.** A server known only as
  `sql01.corp.internal` needs a second name under a domain that is allowed,
  such as `sql01.corp.example.com`.
- **Every name a client ends up using must be listed.** Databricks does not
  follow aliases or redirects. If clients connect through a CNAME, or the
  server sends them on to another hostname (a failover partner or an
  availability group replica, for example), list those names too, and make
  sure the load balancer reaches them.
- **Use a domain your organization controls.** The rule takes over that name
  for serverless compute in the attached workspaces, whatever it resolves to
  elsewhere. The example domain in this guide is for the lab only.

### Scenarios

| Situation | What to configure |
| --- | --- |
| Serverless compute only | Put the hostname in the rule's **Domain names**. Create no DNS record. |
| The server already has a name in internal DNS, under an allowed domain | Use that same name on the rule, so that connection strings and certificates stay the same. |
| The server's only name ends in a private-use domain such as `.internal` | Choose a second name under an allowed domain and put it on the rule. Serverless clients connect with the second name. |
| Classic compute must use the same hostname | Give classic compute its own route (such as VNet peering) and its own DNS answer: an A record for the hostname, pointing to the VM's private IP, in a private DNS zone linked to the workspace VNet. This is split-horizon DNS: serverless compute gets the endpoint, classic compute gets the VM. |
| The workspace VNet uses a custom DNS server | Add the A record on that server instead of in a private zone. This affects classic compute only. |
| Several servers behind one load balancer | List each server's hostname on the same rule and give each its own load balancer rule and port. All names lead to the same endpoint, so the port selects the server. |
| The hostname must change later | Update the rule's domain names with the REST API (see [Change or remove the path](#change-or-remove-the-path)). No change is needed in Azure. |

### Hostnames and TLS

SQL Server clients that encrypt the connection check the server certificate
against the hostname they connected to. If you introduce a new hostname for
the rule, either issue a certificate that includes it or configure the client
to trust the server certificate. A certificate error after a successful TCP
test means the network path works and the name does not match the certificate.

### Checking DNS

From serverless compute, the Python test in step 8 prints the address the
hostname resolves to. A name-resolution error there means the name is not on
an established rule of the NCC attached to the workspace, or the serverless
session started before the change. Looking the name up from your laptop or
from a VM tells you nothing about this path.

## 1. Allow the load balancer and Private Link traffic to reach SQL Server

Connections arrive at the VM from the Private Link service's NAT subnet, and
health probes arrive from Azure Load Balancer. Open the network security group
on the VM's network interface or subnet and make sure inbound rules allow:

| Source | Destination | Port | Purpose |
| --- | --- | --- | --- |
| The NAT subnet range (created in step 3) | VM private IP | TCP `1433` | Connections from serverless compute |
| Service tag `AzureLoadBalancer` | VM private IP | TCP `1433` | Health probes |

The default rules `AllowVnetInBound` and `AllowAzureLoadBalancerInBound`
already cover both unless a higher-priority rule denies them. Do not allow
`1433` from the internet. Also confirm that the Windows firewall on the VM
allows TCP `1433`.

## 2. Create the internal load balancer

In the Azure portal, search for **Load balancers** and select **+ Create**.

**Basics** tab:

| Setting | Value |
| --- | --- |
| Resource group | The VM's resource group |
| Name | For example `lb-sql-vm` |
| Region | The VM's region |
| SKU | **Standard** |
| Type | **Internal** |
| Tier | **Regional** |

**Frontend IP configuration** tab: select **+ Add a frontend IP
configuration**.

| Setting | Value |
| --- | --- |
| Name | `sql-frontend` |
| Virtual network | The VM's VNet |
| Subnet | The VM's subnet |
| Assignment | **Dynamic**, or **Static** with an unused address in the subnet |
| Availability zone | **Zone-redundant** where offered |

**Backend pools** tab: select **+ Add a backend pool**.

| Setting | Value |
| --- | --- |
| Name | `sql-backend` |
| Virtual network | The VM's VNet |
| Backend Pool Configuration | **NIC** |
| IP configurations | Select **+ Add**, then the VM and its primary IP configuration |

A Private Link service requires a backend pool configured by **NIC**. Pools
configured by IP address are not supported.

**Inbound rules** tab: select **+ Add a load balancing rule**.

| Setting | Value |
| --- | --- |
| Name | `sql-tcp-1433` |
| IP Version | **IPv4** |
| Frontend IP address | `sql-frontend` |
| Backend pool | `sql-backend` |
| Protocol | **TCP** |
| Port | `1433` |
| Backend port | `1433` |
| Health probe | **Create new**: name `sql-tcp-1433`, protocol **TCP**, port `1433` |
| Session persistence | **None** |
| Idle timeout (minutes) | `30` |
| Enable TCP Reset | Selected |
| Enable Floating IP | Cleared |

Do not add an inbound NAT rule or an outbound rule. Select **Review +
create**, then **Create**.

After deployment, open the load balancer and check two things:

1. **Frontend IP configuration** shows a private address and no public IP.
2. **Monitoring > Insights** (or **Backend health**) shows the VM as healthy.
   If it is unhealthy, SQL Server is not answering on `1433` or a firewall
   blocks the probe. Fix that before you continue.

## 3. Create the Private Link service

The service needs a subnet for its NAT addresses. Use a dedicated subnet
rather than the VM's subnet, so that a network security rule can name it.

1. Open the VM's VNet, select **Subnets**, then **+ Subnet**.
2. Enter a name such as `snet-private-link-service` and an unused range.
3. Select **Add**.

Then search for **Private Link services** and select **+ Create**.

**Basics** tab: select the VM's resource group, enter a name such as
`pls-sql-vm`, and select the VM's region.

**Outbound settings** tab:

| Setting | Value |
| --- | --- |
| Load balancer | `lb-sql-vm` |
| Load balancer frontend IP address | `sql-frontend` |
| Source NAT subnet | The NAT subnet you created |
| Enable TCP proxy V2 | **No**. SQL Server does not expect the proxy header. |
| Private IP address settings | Keep the defaults (dynamic) |

The portal turns off Private Link service network policies on the NAT subnet
for you. If you script this step instead, disable
`privateLinkServiceNetworkPolicies` on the subnet first.

**Access security** tab: keep **Role-based access control only**, and add no
auto-approved subscriptions. Databricks requests its endpoint by resource ID,
and you approve it by hand in step 6.

Select **Review + create**, then **Create**. Open the new service, select
**JSON View** on the **Overview** page, and copy the resource ID:

```text
/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Network/privateLinkServices/<private-link-service-name>
```

## 4. Create or choose an NCC, and attach it to the workspace

A workspace uses one NCC at a time. If the workspace already has one, add the
rule to that NCC and skip to step 5.

Create the NCC:

1. Open the [account console](https://accounts.azuredatabricks.net).
2. In the sidebar, select **Security**, then
   **Network connectivity configurations**.
3. Select **Add network configuration**.
4. Enter a name and choose the workspace's region.
5. Select **Add**.

Attach it:

1. In the sidebar, select **Workspaces**.
2. Select the workspace, then **Update workspace**.
3. In the **Network connectivity configurations** field, select the NCC. If it
   is missing, the NCC and the workspace are in different regions.
4. Select **Update**, and allow about 10 minutes for the change to take
   effect.

An NCC can be replaced with another one but not removed from a workspace, and
Databricks refuses to delete an NCC while a workspace still uses it.

## 5. Add the private endpoint rule

1. In the account console, select **Security**, then
   **Network connectivity configurations**, and open the NCC.
2. On the **Private endpoint rules** tab, select
   **Add private endpoint rule**.
3. In **Azure resource ID**, paste the Private Link service resource ID.
4. In **Domain names**, enter the SQL Server hostname.
5. Leave the subresource empty. A Private Link service has none; the rule is
   identified by its domain names.
6. Select **Add**, and wait until the rule's **Status** is `PENDING`.

Databricks now creates a private endpoint in its own network and requests a
connection to your service. Names listed in **Domain names** are allowed in
serverless egress control automatically.

The same step with the REST API, using the Databricks CLI and an account-level
profile:

```bash
databricks api post \
  /api/2.0/accounts/<account-id>/network-connectivity-configs/<ncc-id>/private-endpoint-rules \
  --profile <account-profile> \
  --json '{
    "resource_id": "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Network/privateLinkServices/<private-link-service-name>",
    "domain_names": ["<sql-server-hostname>"]
  }'
```

## 6. Approve the private endpoint in Azure

1. In the Azure portal, open **Private Link center**, select
   **Private Link services**, and open your service.
2. Under **Settings**, select **Private endpoint connections**.
3. Select the pending connection. Check that its name starts with
   `databricks-` followed by the beginning of your NCC ID, so that you approve
   the request this NCC made and no other.
4. Select **Approve**, then **Yes**.

The connection state changes to **Approved**.

## 7. Confirm the rule is established

In the account console, refresh the NCC's **Private endpoint rules** tab until
the rule's **Status** is `ESTABLISHED`. This can take 10 minutes after
approval.

| Status | Meaning |
| --- | --- |
| `PENDING` | Waiting for approval on the Private Link service. |
| `ESTABLISHED` | The endpoint is approved and usable. |
| `REJECTED` | The connection was rejected in Azure. Delete the rule and add it again. |
| `DISCONNECTED` | The connection was removed in Azure. Delete the rule and add it again. |

## 8. Test from serverless compute

Wait about five more minutes, then start a new serverless session: changes
apply to serverless compute that starts afterward. In a notebook attached to
**Serverless**, run:

```python
import socket

host, port = "<sql-server-hostname>", 1433

print(socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP))
with socket.create_connection((host, port), timeout=10):
    print(f"TCP connection to {host}:{port} succeeded")
```

Connect by the exact hostname in the rule. A different name, or the VM's IP
address, does not match the rule and does not use the private endpoint.

## Change or remove the path

- **Change the hostnames**: update the rule's domain names with the REST API.

  ```bash
  databricks api patch \
    "/api/2.0/accounts/<account-id>/network-connectivity-configs/<ncc-id>/private-endpoint-rules/<rule-id>?update_mask=domain_names" \
    --profile <account-profile> \
    --json '{ "domain_names": ["<sql-server-hostname>", "<another-hostname>"] }'
  ```

- **Remove the path**: delete the rule on the NCC's **Private endpoint rules**
  tab first. Then delete the Private Link service, the load balancer, and the
  NAT subnet in Azure, in that order.

## Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| The NCC is not offered for the workspace | The NCC and the workspace are in different regions. |
| The rule is rejected when you add it | The hostname uses a private-use top-level domain, or the resource ID is not a Private Link service. |
| The rule stays `PENDING` | The connection is not approved yet on the Private Link service. |
| No pending connection appears in Azure | Wait a few minutes. Then check that the resource ID in the rule is this service's ID. |
| The rule is `ESTABLISHED` but the connection times out | The load balancer backend is unhealthy, or a network security group blocks the NAT subnet. Check backend health first. |
| Name resolution fails | The hostname differs from the rule's domain name, the workspace uses a different NCC, or the serverless session started before the change. |
| The connection works but sign-in fails | The network path is fine. Check the SQL login, password, and database. |
| Classic compute cannot connect | Expected. This path serves serverless compute only. |
