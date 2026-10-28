# Azure workspace front-end Private Link lab

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

## Deploy

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

## Connect to the test VM

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

## Cleanup

This lab contains billable resources. Destroy it when testing is complete:

```bash
./infra destroy-plan azure environments/local/my-front-end-private-link.tfvars
./infra destroy azure environments/local/my-front-end-private-link.tfvars --confirm destroy-azure
```
