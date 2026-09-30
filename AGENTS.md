# Agent operating contract

This repository manages expensive cloud infrastructure. Agents must:

1. Read `components.json` and the selected environment tfvars before changing or planning infrastructure.
2. Use `./infra`; do not bypass its authentication and saved-plan checks for apply or destroy.
3. Never create `terraform.tfvars`, backend credentials, tokens, passwords, state, or plan files in Git.
4. Run `./infra validate <cloud>` after code changes. Static validation never authorizes deployment.
5. Show the user the saved plan summary, including every `replace:` and `delete:` line, before `./infra apply` or `./infra destroy`.
6. For endpoint acceptance, deployment, apply, and destroy, rely on the active harness approval policy and `./infra`'s built-in confirmation checks. Do not add a separate conversational approval gate.
7. Keep features in separate modules. Shared networking belongs only in the shared network or connectivity modules.
8. Prefer AWS Secrets Manager or Azure-managed secret stores. Do not print sensitive Terraform outputs in logs; `./infra output <cloud> <tfvars> --json` redacts them.

The `deploy-scenario` skill in `.claude/skills/` walks through this contract step by step.

## Authentication workflow

After selecting or creating the environment tfvars:

1. Run `./infra doctor <cloud> <environment.tfvars> --json` and branch on its
   exit code: `0` ready, `10` a browser login is required, `11` the identity,
   account, tenant, or profile does not match the environment, `12` a tool is
   missing. `next_action.command` is the exact fix.
2. For exit `10`, run `./infra setup <cloud> <environment.tfvars> --yes`. With
   `--yes` (or without a terminal) setup asks no questions: it reuses or
   discovers profiles, opens the browser login for the user, and saves only
   profile names and account identifiers. Tell the user a browser window needs
   them; if you cannot run it, ask them to run it with the `!` prefix. Then wait
   with `./infra doctor <cloud> <environment.tfvars> --wait 600` instead of
   asking the user to confirm.
3. For exit `11`, show the detail to the user and let them choose the identity
   or profile. Do not guess or switch accounts yourself.
4. Never ask the user to paste credentials, and never read or print AWS, Azure,
   or Databricks credential or token caches. Do not run `aws sso login`,
   `az login`, or `databricks auth login` directly; `./infra setup` runs them
   with the correct account, tenant, and profile.
5. Setup may ask for non-secret values it cannot discover, such as an IAM
   Identity Center start URL, region, and role name for a new AWS profile
   (`--sso-start-url`, `--sso-region`, `--sso-role-name`). Ask the user for
   those. Never request a Databricks PAT.
6. Environment variables such as `AWS_PROFILE`, `DATABRICKS_ACCOUNT_PROFILE`,
   and `DATABRICKS_WORKSPACE_PROFILE` are explicit operator overrides. Do not
   silently replace or persist them. They do not survive between agent shell
   calls, so rely on the saved mapping instead of exporting them.
7. On AWS, the Databricks workspace may need its own OAuth login after it is
   first created. `./infra apply` prints the next step, and `doctor` reports
   `databricks_workspace` as `login_required`; rerun
   `./infra setup aws <environment.tfvars> --yes`, which logs in to the
   workspace and saves the profile. On Azure, one `az login` covers the
   subscription, the Databricks account, and the workspace.
8. Authentication verifies identity only. For external state changes, follow
   the active harness approval policy and `./infra`'s built-in safeguards; do
   not request additional conversational approval.

If `doctor` warns that an IAM Identity Center session is about to expire, renew
it before a long apply or destroy with `./infra setup aws <environment.tfvars>
--yes --force-login`.

Serverless private endpoints need an explicit decision: AWS with
`./infra endpoints aws accept|reject`, Azure with
`./infra endpoints azure approve|reject` using a `connection_id` from
`./infra endpoints azure status`. Classic AWS PrivateLink connections are
accepted by Terraform.

Plans and applies can take 10–40 minutes. Run them in the background and tail
the `Terraform log:` file that `./infra` prints rather than holding the output
in context.

Typical request mapping:

- "AWS workspace plus PostgreSQL through peering" → enable `workspace`, `unity_catalog`, `rds_postgres`; set `connectivity.rds_postgres.classic = "peering"`.
- "AWS serverless to SQL Server" → enable `workspace` and `rds_sql_server`; set `connectivity.rds_sql_server.serverless = "private_link"`. NCC is derived automatically.
- "Azure VNet-injected workspace" → enable only Azure `workspace`.
