# Deployment workflow

Use a separate tfvars file and deployment ID for each environment. The normal
local workflow is:

```bash
./infra doctor aws environments/local/my-aws.tfvars
./infra validate aws
./infra plan aws environments/local/my-aws.tfvars
# Review the complete plan and its saved summary, then explicitly authorize it.
./infra apply aws environments/local/my-aws.tfvars
```

`plan` performs the same authentication checks as `doctor` and exits with the
same codes. It prints the counts of created, updated, replaced, and deleted
resources and lists every replacement and deletion; the full lists are saved
next to the plan as `apply.tfplan.summary.json`. Terraform output for plans and
applies is also written to `.artifacts/<cloud>/<deployment-id>/logs/`, and the
path is printed so long operations can be followed with `tail -f`.

`apply` accepts only the environment-specific saved plan and rejects it when
any of these changed:

- operation type, cloud, deployment ID, state path, or tfvars path;
- tfvars contents or Terraform/module source;
- provider lock file; or
- authenticated cloud account, principal, or selected local profiles.

An environment operation lock prevents concurrent plans or applies from
overwriting one another. The lock records its process ID, so a lock left by a
killed process on the same machine is removed automatically. `apply` also
rejects a saved plan that was already applied.

If Terraform apply fails, `./infra` invalidates the saved plan, reports the
number of resource instances and any tainted addresses found in state, and
prints the exact command needed to plan reconciliation. Never retry the stale
plan: cloud resources may have changed before the failure.

## Seed a locked-down Azure external volume

An operator cannot upload through an ADLS public endpoint after public network
access is disabled. Do not leave a permanent operator role or enable shared
keys to work around that boundary. Use the bounded bootstrap workflow instead:

```bash
# 1. Create a saved plan that permits only the current public IPv4 address.
./infra seed-access-plan azure environments/local/my-azure.tfvars

# 2. Review and apply that exact temporary-access plan.
./infra seed-access-apply azure environments/local/my-azure.tfvars

# 3. Upload with Azure CLI OAuth and create the normal lockdown plan.
./infra seed azure environments/local/my-azure.tfvars \
  --source modules/azure/external-volume-storage/assets/sample-json

# 4. Review and apply the lockdown plan.
./infra apply azure environments/local/my-azure.tfvars
```

Pass `--operator-ip <ipv4>` to the planning command if automatic public-IP
detection is unavailable. The temporary plan turns on the public endpoint with
a `/32` storage firewall rule and creates an operator Blob Data Contributor
assignment. The seed command retries authorization for at most three minutes
while Azure RBAC propagates. Every blob receives local SHA-256 metadata, which
is read back and verified. It then creates the normal saved plan from the
tfvars, disabling the public endpoint and deleting the temporary role. If an
upload or checksum check fails, it still attempts to create that lockdown plan.

The access connector's Blob Data Contributor assignment is permanent because
Databricks uses it as the storage credential. Only the human operator's
assignment is temporary.

### Metadata-only external volumes

When public access is disabled and no storage Private Link/NCC path is present,
set `external_volume_storage.allow_unreachable_storage = true` to acknowledge
that the deployment is intentionally metadata-only. Plans print a prominent
warning. Catalog Explorer can display the catalog, volume, and sometimes blob
listings through control-plane services, but Databricks compute cannot reliably
read the files until a supported network path is configured.

Use `external_volume_storage.metastore_mode = "existing"` with `metastore_id`
to reuse a regional metastore, `"create"` to manage a dedicated one, or
`"auto"` (see [metastore selection](#metastore-selection)). Unity
Catalog force deletion remains disabled unless
`external_volume_storage.allow_force_destroy = true` is deliberately set for a
disposable environment.

## First AWS workspace deployment

A practical first deployment has two explicit stages:

1. Enable the workspace, but leave `unity_catalog = false` and every service's
   classic and serverless connectivity mode set to `none`. Plan, review, and
   apply the account-level workspace infrastructure.
2. Run `./infra setup aws <tfvars> --yes`. Setup detects the new workspace,
   completes its OAuth login in the browser, and saves the profile. Then enable
   Unity Catalog, the selected services, and connectivity, and create, review,
   and apply a new plan.

With a local OAuth profile, the workspace login can only be created once the
workspace exists, so a single-stage plan that also creates workspace-level
resources prints a warning. `apply` prints the setup command as soon as the
workspace exists.

## Metastore selection

`unity_catalog.metastore_mode` (AWS) and `external_volume_storage.metastore_mode`
(Azure) accept:

- `create` (default): manage a dedicated metastore for this deployment;
- `existing`: assign the named (AWS `existing_metastore_name`) or identified
  (Azure `metastore_id`) metastore;
- `auto`: keep the metastore this deployment created earlier, reuse the only
  metastore in the region, or create one if the region has none.

Shared accounts often hold many metastores per region. In that case `auto` stops
the plan and lists some of them instead of attaching the workspace to another
team's metastore; choose `existing` or `create`.

## Outputs and PrivateLink acceptance

Always identify the environment whose state should be read:

```bash
./infra output aws environments/local/my-aws.tfvars
./infra output aws environments/local/my-aws.tfvars --json   # sensitive values redacted
./infra endpoints aws status environments/local/my-aws.tfvars
```

PrivateLink endpoint services use `acceptance_required = true`. `endpoints aws
status` lists every connection that still needs a decision under
`pending_endpoint_acceptances`, with its `service_id` and `endpoint_id`. After
reviewing them, explicitly authorize and run:

```bash
./infra endpoints aws accept environments/local/my-aws.tfvars \
  --service-id vpce-svc-... \
  --endpoint-id vpce-...
```

Endpoint acceptance changes external state and is separate from Terraform
planning and applying. See the [AWS connectivity matrix](../aws/connectivity.md)
for supported combinations.

## Destroy

Before creating an AWS destroy plan:

1. Ensure workspace-level authentication is available. `destroy-plan` checks it
   before planning and exits `10` with the setup command if it is missing
   (unless the workspace was already deleted outside Terraform). After the
   saved plan is verified and the typed destroy confirmation is
   supplied, `./infra destroy` sends termination requests for every
   non-terminated cluster, then waits for all of them under one shared 20-minute
   deadline before Terraform deletes the workspace. Any authentication,
   request, or timeout failure aborts destroy. Cluster instances are runtime
   resources outside Terraform state, so this prevents their ENIs from retaining
   the workspace subnets and VPC.
2. Run `./infra endpoints aws status ...`. For every active serverless
   PrivateLink connection, review its IDs and run the explicit `endpoints aws
   reject` command documented in the [AWS connectivity guide](../aws/connectivity.md).
   Wait until AWS no longer reports an active connection.
3. For disposable environments, set
   `allow_destructive_demo_cleanup = true`. This empties versioned workspace and
   Unity Catalog buckets, disables database deletion protection, and skips final
   snapshots. If protected resources already exist, first plan and apply that
   configuration change.

These steps prevent unmanaged cluster ENIs, endpoint connections, and versioned
bucket objects from blocking Terraform teardown. Then save, review, explicitly
authorize, and apply the destroy plan. The confirmation authorizes both cluster
termination and the reviewed Terraform destroy plan:

```bash
./infra destroy-plan aws environments/local/my-aws.tfvars
./infra destroy aws environments/local/my-aws.tfvars --confirm destroy-aws
```

On Azure, `allow_destructive_demo_cleanup = true` lets destroy delete a lab
resource group that still contains resources Terraform does not manage. Azure
Policy can inject such resources (for example a DNS security policy linked to
every VNet), and without the flag the resource group deletion stops with "the
Resource Group still contains Resources".

Terraform creates each deployment's NCC before its workspace and deletes it
after the workspace, because Databricks refuses to delete an NCC that is still
attached to a workspace. An NCC passed in with
`existing_network_connectivity_config_id` is never deleted.

Do not enable destructive cleanup for production.

## Shared-account limits

Shared field and sandbox accounts can reach Databricks limits that a customer
account rarely does:

- **NCCs per region** (for example 50): reuse one with
  `existing_network_connectivity_config_id`.
- **Private endpoints per region** across the account's NCCs (for example
  30): serverless `private_link` rules fail with "Cannot have more than 30
  private endpoints"; use `none` or clean up unused rules.
- **Metastores per region**: `metastore_mode = "auto"` stops when it finds
  several; choose `existing` or `create`.
