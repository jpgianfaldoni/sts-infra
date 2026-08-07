# Deployment workflow

Use a separate tfvars file and deployment ID for each environment. The normal
local workflow is:

```bash
./infra validate aws
./infra plan aws environments/local/my-aws.tfvars
# Review the complete plan and its saved summary, then explicitly authorize it.
./infra apply aws environments/local/my-aws.tfvars
```

`plan` performs authentication preflight automatically. `apply` accepts only
the environment-specific saved plan and rejects it when any of these changed:

- operation type, cloud, deployment ID, state path, or tfvars path;
- tfvars contents or Terraform/module source;
- provider lock file; or
- authenticated cloud account or selected local profiles.

An environment operation lock prevents concurrent plans or applies from
overwriting one another. `apply` also rejects a saved plan that was already
applied.

## First AWS workspace deployment

A practical first deployment has two explicit stages:

1. Enable the workspace, but leave `unity_catalog = false` and every service's
   classic and serverless connectivity mode set to `none`. Plan, review, and
   apply the account-level workspace infrastructure.
2. Authenticate to the new workspace if a separate local OAuth profile is
   required. Enable Unity Catalog, the selected services, and connectivity;
   then create, review, and apply a new plan.

Terraform can sometimes resolve the workspace host in one apply, but the two
stages make the authentication boundary and failures easier to understand.

## Outputs and PrivateLink acceptance

Always identify the environment whose state should be read:

```bash
./infra output aws environments/local/my-aws.tfvars
./infra endpoints aws status environments/local/my-aws.tfvars
```

PrivateLink endpoint services use `acceptance_required = true`. After reviewing
the expected endpoint-service and endpoint IDs, explicitly authorize and run:

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

1. Stop or delete every classic Databricks cluster attached to the workspace.
   Cluster instances are runtime resources outside Terraform state; their ENIs
   otherwise keep the workspace subnets and VPC alive after workspace deletion.
2. Run `./infra endpoints aws status ...`. For every active serverless
   PrivateLink connection, review its IDs and run the explicit `endpoints aws
   reject` command documented in the [AWS connectivity guide](../aws/connectivity.md).
   Wait until AWS no longer reports an active connection.
3. For disposable environments, set
   `allow_destructive_demo_cleanup = true`. This empties versioned workspace and
   Unity Catalog buckets, disables database deletion protection, and skips final
   snapshots. If protected resources already exist, first plan and apply that
   configuration change.

These prerequisites prevent unmanaged cluster ENIs, endpoint connections, and
versioned bucket objects from blocking Terraform teardown. Then save, review,
explicitly authorize, and apply the destroy plan:

```bash
./infra destroy-plan aws environments/local/my-aws.tfvars
./infra destroy aws environments/local/my-aws.tfvars --confirm destroy-aws
```

Do not enable destructive cleanup for production.
