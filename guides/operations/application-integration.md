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

The wrapper supports the standard AWS, Azure, and Databricks provider
environment variables when no local profile overrides are set; see the
[automation table](authentication.md#automation-and-applications). Use
`./infra doctor <cloud> <tfvars> --json` as the "verify identity" step: it
reports each identity and exits `0`, `10` (credentials missing or expired),
`11` (wrong account, principal, or target, or no pinned AWS account), or `12`
(missing tool). Pin the AWS account with `aws_account_id` or a target; a worker
that deliberately relies on ambient credentials must set
`STS_INFRA_ALLOW_UNPINNED_ACCOUNT=1`.

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
Verify the network paths (./infra verify --json)
        ↓
Record status and non-sensitive outputs
```

Use the same saved-plan and explicit-approval process for destroy. Serverless
endpoint approval happens right after apply when `endpoint_approval = "auto"`;
set `"manual"` to make it a separately authorized step.

With local OAuth profiles, a new AWS workspace deploys in two stages (see
[first AWS workspace deployment](deployment.md#first-aws-workspace-deployment)).
Automation that authenticates with environment credentials deploys in one
stage, as long as its service principal can call the new workspace's APIs.
AWS destroy also needs workspace authentication to terminate clusters;
`destroy-plan` verifies it before planning. `./infra verify --json` and
`./infra status --json` give a worker machine-readable results and the next
step.

## Production boundary

The repository intentionally uses local state. Before running multiple workers
or storing customer deployments, replace local state with encrypted remote
state that provides locking, backup, access control, and audit history. Also
add a durable job queue, per-deployment concurrency control, cancellation,
timeouts, and redacted structured logs. Do not expose arbitrary Terraform CLI
arguments or user-supplied module source through the application.
