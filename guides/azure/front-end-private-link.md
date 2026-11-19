# Manually configure front-end Private Link for an Azure Databricks workspace

This guide makes an Azure Databricks workspace reachable over Azure Private
Link, so that users and API clients connect to it through private endpoints in
your network. Microsoft calls this inbound Private Link. It uses the Azure
portal.

It does not cover the private path from classic compute to the control plane
(back-end Private Link) or from serverless compute to your data sources.

Official reference:
[Configure inbound Private Link for workspaces](https://learn.microsoft.com/azure/databricks/security/network/front-end/front-end-private-connect).

## How the path works

```text
User's browser or API client
      |
your network (transit VNet, reached directly, by VPN, or by ExpressRoute)
      |
      +-- private endpoint: databricks_ui_api        -> workspace UI and REST API
      |
      +-- private endpoint: browser_authentication   -> Microsoft Entra sign-in callback
      |
private DNS zone privatelink.azuredatabricks.net resolves both to private IPs
```

Two private endpoints are involved, with different jobs:

| Endpoint (target sub-resource) | Purpose | How many |
| --- | --- | --- |
| `databricks_ui_api` | Carries the workspace UI and REST API traffic | One for each workspace |
| `browser_authentication` | Carries the single sign-on callback during browser login | One for each region and private DNS zone, shared by all workspaces there |

The transit VNet is the VNet your users' traffic arrives in. Both endpoints go
in it.

## Choose an access model

| Model | Public access | Use it when |
| --- | --- | --- |
| Hybrid | Stays enabled, restricted with IP access lists or ingress controls | You are testing, or some clients must still connect from trusted public addresses |
| No public access | Disabled | All users can reach the transit VNet, and you want every connection to be private |

Start with hybrid access, confirm that private access works, and disable
public access last. Disabling it first locks out anyone who has no private
path yet, including you.

## Requirements

- The workspace is on the Premium plan and uses VNet injection.
- Permission to create private endpoints and manage private DNS records.
- A transit VNet with a subnet for private endpoints.
- For an existing workspace: all clusters, pools, and classic SQL warehouses
  stopped while you change its network settings.

## Values to collect

| Value | Where to find it | Example |
| --- | --- | --- |
| Workspace URL | Workspace **Overview** page | `adb-1234567890123456.7.azuredatabricks.net` |
| Workspace region | Workspace **Overview** page | `westus2` |
| Transit VNet and endpoint subnet | **Virtual networks** | `10.70.2.0/26` |

## 1. Check the workspace

1. Open the workspace in the Azure portal.
2. Under **Settings**, select **Networking**.
3. Confirm that **Secure cluster connectivity (No Public IP)** is enabled and
   that **Allow Public Network Access** is **Enabled** for now.

## 2. Create the `databricks_ui_api` private endpoint

1. On the workspace's **Networking** page, select **Private endpoint
   connections**, then **+ Private endpoint**.
2. Select a resource group, enter a name such as `my-workspace-ui-pe`, and
   check that the region matches the workspace.
3. Select **Next: Resource** and set **Target sub-resource** to
   `databricks_ui_api`.
4. Select **Next: Virtual Network**, then the transit VNet and the subnet for
   private endpoints.
5. Select **Next** and keep **Integrate with private DNS zone** set to
   **Yes**. The portal selects the zone `privatelink.azuredatabricks.net`.
6. Create the endpoint.

## 3. Create the `browser_authentication` private endpoint

Browser sign-in redirects through a regional address
(`<region>.pl-auth.azuredatabricks.net`). Without this endpoint, sign-in fails
for users who have no public path, even though the workspace itself resolves
privately.

Only one such endpoint should exist for a region and private DNS zone. If one
already serves the region, skip this step.

Azure Databricks recommends hosting it on a dedicated workspace that runs no
workloads (a "private web auth" workspace), so that deleting an ordinary
workspace cannot break sign-in for the others:

1. Create a resource group and a VNet in the same region.
2. Create an Azure Databricks workspace in that VNet. On the **Networking**
   tab choose Secure Cluster Connectivity **Yes**, your own VNet **Yes**,
   **Public Network Access** **Disabled**, and **Required NSG Rules**
   **NoAzureDatabricksRules**.
3. Add a **Delete** lock to it under **Settings > Locks**.

Then create the endpoint, on that workspace:

1. On its **Networking** page, select **Private endpoint connections**, then
   **+ Private endpoint**.
2. Set **Target sub-resource** to `browser_authentication`.
3. Select the same transit VNet and endpoint subnet as in step 2.
4. Keep **Integrate with private DNS zone** set to **Yes**, and create the
   endpoint.

For a disposable test you can put the `browser_authentication` endpoint on
the workspace you are testing instead. Do not do this in production.

## 4. Check DNS

Open the private DNS zone `privatelink.azuredatabricks.net` and confirm two A
records:

| Record name | Points to |
| --- | --- |
| The workspace ID, such as `adb-1234567890123456.7` | The private IP of the `databricks_ui_api` endpoint |
| `<region>.pl-auth` | The private IP of the `browser_authentication` endpoint |

The zone must be linked to the transit VNet: open **Virtual network links** in
the zone and add the VNet if it is missing.

How the name resolves: the public name `adb-….azuredatabricks.net` is an alias
for `adb-….privatelink.azuredatabricks.net`. Inside a VNet linked to the
private zone, that second name resolves to the endpoint's private IP. Outside,
it resolves to a public address.

If clients use your own DNS servers and not Azure-provided DNS, choose one of
these:

- **Conditional forwarding (recommended):** forward `*.azuredatabricks.net`
  and `*.privatelink.azuredatabricks.net` to Azure DNS (`168.63.129.16`, from
  a server inside a VNet linked to the zone).
- **Manual A records:** create an A record for the workspace URL and one for
  the regional `pl-auth` URL, both pointing to the endpoint IPs. Some regions
  use more than one sign-in address.

## 5. Test private access

From a machine that reaches the transit VNet (a VM in it, or a client
connected by VPN or ExpressRoute):

```bash
nslookup adb-1234567890123456.7.azuredatabricks.net
curl -I https://adb-1234567890123456.7.azuredatabricks.net
```

`nslookup` must return the private IP of the `databricks_ui_api` endpoint, with
the `privatelink` name shown as the canonical name. Then open the workspace
URL in a browser on that machine and sign in. A completed sign-in proves the
`browser_authentication` endpoint works too.

To test the browser from your own computer through a Linux VM in the VNet,
open an SSH SOCKS proxy to it and let the browser resolve names through the
proxy:

```bash
ssh -N -D 1080 <admin-user>@<vm-address>

google-chrome --user-data-dir="$(mktemp -d)" \
  --proxy-server="socks5://127.0.0.1:1080" \
  --host-resolver-rules="MAP * ~NOTFOUND , EXCLUDE 127.0.0.1"
```

In Firefox, set a manual SOCKS v5 proxy of `127.0.0.1:1080` and enable
**Proxy DNS when using SOCKS v5**.

## 6. Disable public access (optional)

Do this only after step 5 succeeds for every group of users.

1. Stop all classic compute in the workspace.
2. On the workspace's **Networking** page, set **Allow Public Network Access**
   to **Disabled**.
3. Set **Required NSG Rules** as your design needs. With back-end Private Link
   in place, choose **NoAzureDatabricksRules**; without it, classic compute
   still needs the default rules to reach the control plane.
4. Save, and repeat the test in step 5.

From now on, tools that call the workspace API from outside the network, such
as Terraform or the Databricks CLI on a laptop, must also run from a machine
with a private path.

## Remove the configuration

Enable public network access again before you delete the endpoints, or the
workspace becomes unreachable. Then delete the `databricks_ui_api` endpoint.
Delete the `browser_authentication` endpoint only if no other workspace in the
region relies on it.

## Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| The workspace URL resolves to a public IP from inside the network | The private DNS zone is not linked to the VNet the client uses, or the client uses a DNS server that does not forward to Azure DNS. |
| The workspace page loads but sign-in fails or loops | The `browser_authentication` endpoint or its `pl-auth` record is missing. |
| "Public access is not allowed" style errors | Public access is disabled and the client has no private path. Check DNS from that client first. |
| Changing the network settings fails | Classic compute was still running in the workspace. Stop it and retry. |
| Two `pl-auth` records conflict | More than one `browser_authentication` endpoint exists for the region and zone. Keep one. |
