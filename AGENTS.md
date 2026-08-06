# Agent operating contract

This repository manages expensive cloud infrastructure. Agents must:

1. Read `components.json` and the selected environment tfvars before changing or planning infrastructure.
2. Use `./infra`; do not bypass its authentication and saved-plan checks for apply or destroy.
3. Never create `terraform.tfvars`, backend credentials, tokens, passwords, state, or plan files in Git.
4. Run `./infra validate <cloud>` after code changes. Static validation never authorizes deployment.
5. Show the user the saved plan summary and obtain explicit authorization before `./infra apply` or `./infra destroy`.
6. Treat endpoint acceptance, deployment, and destroy as external state changes requiring explicit user authorization.
7. Keep features in separate modules. Shared networking belongs only in the shared network or connectivity modules.
8. Prefer AWS Secrets Manager or Azure-managed secret stores. Do not print sensitive Terraform outputs in logs.

Typical request mapping:

- "AWS workspace plus PostgreSQL through peering" → enable `workspace`, `unity_catalog`, `rds_postgres`; set `connectivity.rds_postgres.classic = "peering"`.
- "AWS serverless to SQL Server" → enable `workspace` and `rds_sql_server`; set `connectivity.rds_sql_server.serverless = "private_link"`. NCC is derived automatically.
- "Azure VNet-injected workspace" → enable only Azure `workspace`.
