# Agent operating contract

This repository manages expensive cloud infrastructure. Agents must:

1. Read `components.json` and the selected environment tfvars before changing or planning infrastructure.
2. Use `./infra`; do not bypass its authentication and saved-plan checks for apply or destroy.
3. Never create `terraform.tfvars`, backend credentials, tokens, passwords, state, or plan files in Git.
4. Run `./infra validate <cloud>` after code changes. Static validation never authorizes deployment.
5. Show the user the saved plan summary before `./infra apply` or `./infra destroy`.
6. For endpoint acceptance, deployment, apply, and destroy, rely on the active harness approval policy and `./infra`'s built-in confirmation checks. Do not add a separate conversational approval gate.
7. Keep features in separate modules. Shared networking belongs only in the shared network or connectivity modules.
8. Prefer AWS Secrets Manager or Azure-managed secret stores. Do not print sensitive Terraform outputs in logs.

## Authentication workflow

After selecting or creating the environment tfvars, agents must use the
repository-owned authentication workflow:

1. Run `./infra doctor <cloud> <environment.tfvars>` before planning. A plan
   repeats this preflight, but `doctor` gives the user an authentication-only
   checkpoint first.
2. If `doctor` reports a missing, expired, or mismatched local session, do not
   ask the user to paste credentials and do not read or print AWS, Azure, or
   Databricks credential/token caches. Ask the user to run the exact command
   `./infra setup <cloud> <environment.tfvars>` in their terminal and complete
   its browser flow. Pause until the user confirms completion, then rerun
   `doctor`.
3. Use `./infra setup` instead of running account-level `aws sso login`,
   `az login`, or `databricks auth login` directly. The setup file may contain
   only profile names and account identifiers; tokens, keys, passwords, and
   client secrets must never be requested or stored there.
4. Environment variables such as `AWS_PROFILE`,
   `DATABRICKS_ACCOUNT_PROFILE`, and `DATABRICKS_WORKSPACE_PROFILE` are explicit
   operator overrides. Do not silently replace or persist them.
5. A new AWS Databricks workspace may require the two-stage deployment in
   `guides/operations/deployment.md`: create the account-level workspace first,
   then establish workspace OAuth through the documented browser command before
   planning workspace-level resources such as Unity Catalog. Never request a
   Databricks PAT as a shortcut.
6. Authentication verifies identity only. For external state changes, follow
   the active harness approval policy and `./infra`'s built-in safeguards; do
   not request additional conversational approval.

Typical request mapping:

- "AWS workspace plus PostgreSQL through peering" → enable `workspace`, `unity_catalog`, `rds_postgres`; set `connectivity.rds_postgres.classic = "peering"`.
- "AWS serverless to SQL Server" → enable `workspace` and `rds_sql_server`; set `connectivity.rds_sql_server.serverless = "private_link"`. NCC is derived automatically.
- "Azure VNet-injected workspace" → enable only Azure `workspace`.
