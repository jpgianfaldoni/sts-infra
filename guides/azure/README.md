# Azure tutorials

- [Workspace front-end Private Link lab](front-end-private-link.md), with a test VM and the `databricks_ui_api` and `browser_authentication` endpoints.
- [Serverless tutorials](serverless/README.md), organized by data source. Serverless Private Link to Azure SQL Database is automated with `connectivity.sql_database.serverless = "private_link"` (NCC, workspace binding, and private endpoint rule); approve the endpoint with `./infra endpoints azure approve`.
- [Azure SQL Database notes](serverless/sql-database/overview.md): credentials in Key Vault, a Key Vault-backed Databricks secret scope, the Microsoft Entra administrator, and optional VNet peering for classic compute and the test VM.
- The `sql-server-vm` module prepares a private VM and a subnet with Private Link service network policies disabled; create the load balancer and Private Link service manually when following the UI exercise.
- The `databricks-workspace` module creates a VNet-injected workspace with a `databricks_ui_api` private endpoint.
- The `external-volume-storage` module can create, reuse (`metastore_mode = "existing"`), or automatically choose (`metastore_mode = "auto"`) a Unity Catalog metastore and expose locked-down ADLS as an external volume. Auto mode keeps the metastore it manages, reuses the only other metastore in the region, creates one when there is none, and fails the plan when several exist. Without a storage Private Link/NCC path, the volume is intentionally metadata-only; use the [temporary OAuth seed workflow](../operations/deployment.md#seed-a-locked-down-azure-external-volume) to place demo files and then restore lockdown.

Resource names derive from the environment file name (the deployment ID) when `name_prefix` and `workspace_name` are not set.
