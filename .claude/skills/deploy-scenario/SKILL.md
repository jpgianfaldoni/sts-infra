---
name: deploy-scenario
description: Plan, deploy, inspect, or destroy an sts-infra Databricks lab scenario on AWS or Azure with ./infra, including the browser-login handoff. Use when the user asks to create, change, authenticate, deploy, or tear down an environment in this repository.
---

# Deploy an sts-infra scenario

Follow `AGENTS.md`. This skill is the step-by-step loop; `./infra` enforces the
safety checks.

## 1. Choose the environment

- Read `components.json` for components, connectivity modes, and options.
- Copy the closest template from `environments/examples/<cloud>/` into
  `environments/local/<name>.tfvars` (Git-ignored). Never edit the examples.
- On AWS, set `aws_account_id` when you know it: the provider then refuses
  every other account, and setup can find or create the right SSO profile.

## 2. Authenticate

```bash
./infra doctor <cloud> environments/local/<name>.tfvars --json
```

Branch on the exit code, not on prose:

| Exit | Meaning | Action |
| --- | --- | --- |
| 0 | ready | continue |
| 10 | a browser login is needed | run `next_action.command` (it is `./infra setup ... --yes`) in the background, tell the user a browser window needs them, then `./infra doctor <cloud> <tfvars> --wait 600` |
| 11 | wrong account, tenant, or profile | show `next_action.detail` to the user and ask which identity to use; do not guess |
| 12 | missing tool | tell the user which tool to install |

If you cannot start a background process, ask the user to run
`! ./infra setup <cloud> <tfvars> --yes` and then poll with `doctor --wait`.

When setup needs information it cannot discover (for a new AWS SSO profile:
`--sso-start-url`, `--sso-region`, `--sso-role-name`), ask the user for those
values. They are not secrets. Never ask for tokens, keys, or passwords, and
never read the AWS, Azure, or Databricks credential caches.

Environment variables do not persist between agent shell calls. Rely on the
saved mapping from setup instead of exporting `AWS_PROFILE` or
`DATABRICKS_*_PROFILE`.

## 3. Plan and apply

```bash
./infra validate <cloud>                # after any code change
./infra plan <cloud> <tfvars>
```

Plans and applies can take 10–40 minutes; run them in the background and tail
the `Terraform log:` path that `./infra` prints. Show the user the
`Saved plan summary` line plus every `replace:`/`delete:` line (the full list
is in the `Plan summary JSON` file), then:

```bash
./infra apply <cloud> <tfvars>
```

On AWS, if apply prints `Next: the workspace ... exists`, run the printed
`./infra setup ... --yes` (a browser login for the new workspace), then plan
again. If `doctor` warns that the IAM Identity Center session expires soon, run
`./infra setup aws <tfvars> --yes --force-login` before a long apply or destroy.

## 4. Inspect

```bash
./infra output <cloud> <tfvars> --json         # sensitive values are redacted
./infra endpoints aws status <tfvars>           # pending_endpoint_acceptances (serverless only)
./infra endpoints azure status <tfvars>         # pending_endpoint_approvals with connection_id
```

Classic AWS PrivateLink connections are accepted by Terraform. Accept a
serverless connection only with the IDs from `pending_endpoint_acceptances`,
and approve an Azure NCC connection only with a `connection_id` from
`endpoints azure status`:

```bash
./infra endpoints azure approve <tfvars> --connection-id <id>
```

## 5. Destroy

Follow the checklist in `guides/operations/deployment.md#destroy`, then:

```bash
./infra destroy-plan <cloud> <tfvars>
./infra destroy <cloud> <tfvars> --confirm destroy-<cloud>
```
