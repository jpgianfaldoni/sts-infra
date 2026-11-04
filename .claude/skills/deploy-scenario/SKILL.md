---
name: deploy-scenario
description: Turn a plain-language request for a Databricks lab on AWS or Azure (workspace, databases, private network paths, sample data) into a deployed and verified sts-infra environment with ./infra, including account targets, the browser-login handoff, staged AWS deploys, verification, and teardown. Use when the user asks to create, change, authenticate, verify, resume, or tear down an environment in this repository.
---

# Deploy an sts-infra scenario

Follow `AGENTS.md`. This skill is the step-by-step loop; `./infra` enforces the
safety checks. The user should never need to read HCL: explain choices in
plain language and run the commands for them.

## 1. Map the request

```bash
./infra templates            # one-line scenario per template
./infra targets              # named accounts: AWS/Azure plus Databricks IDs
./infra ls                   # existing local deployments
```

Pick the closest template. Ask at most one short message of questions, each
with a default (see the decision table in `AGENTS.md`): account target,
classic vs serverless compute, what "privately" means for that compute,
region. Say plainly when the request needs something this repository does not
build (for example a serverless-only workspace or PostgreSQL on Azure) and
offer the closest scenario.

| Request | Template |
| --- | --- |
| AWS classic compute to private Postgres | `aws/workspace-postgres` |
| AWS serverless compute to private Postgres | `aws/serverless-postgres` |
| AWS serverless compute to private SQL Server | `aws/serverless-sql-server` |
| Azure serverless compute to private SQL Server | `azure/serverless-sql` |
| Azure SQL from classic and serverless, with a test VM | `azure/workspace-sql-serverless-private-link` |

If no target exists for the account, ask for the non-secret identifiers
(account IDs, region, and for AWS SSO the start URL, SSO region, and role
name) and run `./infra targets add`. When the user names the metastore their
labs share, add `--metastore <name>` so new environments skip the metastore
question.

## 2. Create and explain

```bash
./infra new <cloud> <name> --template <template> --target <target>
./infra explain <cloud> environments/local/<name>.tfvars
```

Edit `environments/local/<name>.tfvars` only where the request differs. Show
the user the `explain` output (what is built, each network path, the checks,
build time, and cost tier) and fix every `[error]` finding.

## 3. Authenticate

```bash
./infra doctor <cloud> environments/local/<name>.tfvars --json
```

Branch on the exit code, not on prose:

| Exit | Meaning | Action |
| --- | --- | --- |
| 0 | ready | continue |
| 10 | a browser login is needed | run `next_action.command` (it is `./infra setup ... --yes`) in the background, tell the user a browser window needs them, then `./infra doctor <cloud> <tfvars> --wait 600` |
| 11 | wrong account, tenant, profile, or target, no pinned AWS account, or (check `metastore`) a Unity Catalog metastore to choose | show `next_action.detail` to the user and ask which identity, target, or metastore to use (offer the check's `suggested` metastore as the default); do not guess |
| 12 | missing tool | tell the user which tool to install |

If you cannot start a background process, ask the user to run
`! ./infra setup <cloud> <tfvars> --yes` and then poll with `doctor --wait`.
Never ask for tokens, keys, or passwords, and never read the AWS, Azure, or
Databricks credential caches.

## 4. Plan, apply, verify

```bash
./infra plan <cloud> <tfvars>
./infra apply <cloud> <tfvars>
./infra verify <cloud> <tfvars>
```

Run plan and apply in the background and tail the `Terraform log:` path.
Before each apply, show the user the `Saved plan summary` line, every
`replace:`/`delete:` line, and the `Deployment stage` and `Endpoints` lines.

- AWS, new workspace: the first plan is `foundation (1 of 2)`. After its
  apply, run the printed `./infra setup aws ... --yes` (browser login to the
  new workspace), then plan and apply again.
- Serverless endpoint connections are approved automatically after apply
  unless the tfvars sets `endpoint_approval = "manual"`.
- `verify` loads the sample data and checks each path. On exit 13, read each
  failed check's `stage` and `hint`, fix or wait (serverless endpoints can
  take about 10 minutes to become `ESTABLISHED`), and rerun.

Report the result to the user in plain language: the workspace URL
(`./infra output <cloud> <tfvars> --json`), which compute reaches which source
over which path, and the sample-data row counts.

## 5. Resume or inspect

```bash
./infra status <cloud> <tfvars> --json         # next_action for this deployment
./infra output <cloud> <tfvars> --json         # sensitive values are redacted
./infra endpoints aws status <tfvars>
./infra endpoints azure status <tfvars>
```

## 6. Destroy

Follow the checklist in `guides/operations/deployment.md#destroy`, then:

```bash
./infra destroy-plan <cloud> <tfvars>
./infra destroy <cloud> <tfvars> --confirm destroy-<cloud>
```
