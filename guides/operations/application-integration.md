# Application integration baseline

The Terraform modules can be used behind a desktop, internal, or
customer-facing application. Treat `./infra` as the reference orchestration
contract, not as a network API or long-running application server.

## Deployment identity

Assign every deployment a stable identity:

```text
customer ID + deployment ID + cloud + region
```

Pass the customer/deployment portion through `INFRA_DEPLOYMENT_ID`. Use an
isolated worker and tfvars file for each operation. The wrapper isolates local
state, plans, provider data, and locks by that ID and verifies the identity
again before apply.

## Authentication

Do not install customer CLI profiles on a hosted application server.

- For AWS, obtain short-lived credentials by assuming a customer IAM role.
  Cross-account customer roles should require an external ID.
- For Databricks, use workload identity federation when available or OAuth M2M
  for a service principal. Grant it only the required account/workspace roles.
- Inject credentials only into the deployment worker and never copy them into
  tfvars, logs, plan metadata, or Terraform outputs.

The wrapper supports the standard AWS and Databricks provider environment
variables when no local profile overrides are set.

## Application workflow

```text
Connect cloud accounts
        ↓
Verify identity and permissions
        ↓
Create isolated deployment and plan
        ↓
Display plan summary and collect approval
        ↓
Apply the exact verified plan
        ↓
Record status and non-sensitive outputs
```

Use the same saved-plan and explicit-approval process for destroy. PrivateLink
endpoint acceptance is another separately authorized external change.

AWS workspace provisioning may require two jobs: account-level workspace
infrastructure first, then workspace-scoped Unity Catalog resources after the
workspace exists and its service principal assignment is ready.

## Production boundary

The repository intentionally uses local state. Before running multiple workers
or storing customer deployments, replace local state with encrypted remote
state that provides locking, backup, access control, and audit history. Also
add a durable job queue, per-deployment concurrency control, cancellation,
timeouts, and redacted structured logs. Do not expose arbitrary Terraform CLI
arguments or user-supplied module source through the application.
