# Azure SQL Database deployment notes

`features.sql_database` creates an Azure SQL logical server and database with
public access disabled, plus a private endpoint and a
`privatelink.database.windows.net` private DNS zone in a dedicated VNet.

## Credentials

Terraform generates the SQL administrator password and, by default
(`key_vault.enabled = true`), stores it in an RBAC-mode Azure Key Vault created
in its own `<name_prefix>-secrets-rg` resource group:

| Secret | Contents |
| --- | --- |
| `sql-database-admin-username` / `sql-database-admin-password` | SQL authentication administrator |
| `sql-server-vm-sql-username` / `sql-server-vm-sql-password` | SQL Server VM login (when `features.sql_server_vm` is enabled) |
| `sql-server-vm-admin-username` / `sql-server-vm-admin-password` | SQL Server VM Windows administrator |

The deploying principal receives **Key Vault Secrets Officer** on the vault.
The `key_vault` output lists the vault name, URI, and secret names, never the
values. Read a value in an authorized terminal with:

```bash
az keyvault secret show --vault-name <key_vault.name> --name sql-database-admin-password --query value -o tsv
```

The vault keeps public network access enabled so Terraform on the operator
machine can write the secrets; access is controlled by Microsoft Entra RBAC.
It uses the minimum 7-day soft-delete retention without purge protection, and
Terraform purges it on destroy. The password still exists in Terraform state,
so use an encrypted remote backend with restricted access for shared
environments. The sensitive `sql_database_password` and
`sql_server_vm_password` outputs are deprecated and will be removed in the next
release.

When the workspace is also enabled, the vault is exposed to Databricks as a
Key Vault-backed secret scope (`key_vault.secret_scope_name`, default
`sts-infra`). The AzureDatabricks first-party application receives **Key Vault
Secrets User** on the vault. Reference the password from a notebook or a Unity
Catalog connection with `secret("sts-infra", "sql-database-admin-password")`.
Creating a Key Vault-backed scope requires a Microsoft Entra user identity
(the default Azure CLI login); set `key_vault.databricks_secret_scope_enabled =
false` when deploying as a service principal.

## Microsoft Entra administrator

By default (`sql_database.entra_admin_enabled = true`) the deploying principal
becomes the logical server's Microsoft Entra administrator, shown as
`sts-infra-deployer`. SQL authentication stays enabled, so both methods work.
Connect with Entra authentication, for example from the test VM:

```bash
sqlcmd -S <sql_database.host> -d demo --authentication-method ActiveDirectoryDefault
```

## Reach the database from the workspace VNet

The SQL VNet is isolated by default. Set
`sql_database.workspace_peering_enabled = true` to peer it with the workspace
VNet and link its private DNS zone to the workspace VNet. The two address
spaces must not overlap (plans reject overlapping ranges). Classic compute and
the test VM (`features.test_vm`) can then resolve `<server>.database.windows.net`
to the private endpoint and connect on port 1433.

Initialize the sample data from the test VM with
`modules/azure/sql-database/assets/seed.sql`, for example:

```bash
sqlcmd -S <sql_database.host> -d demo -U sqladminuser -P "$(az keyvault secret show \
  --vault-name <key_vault.name> --name sql-database-admin-password --query value -o tsv)" \
  -i seed.sql
```

Peering serves classic compute only. For Databricks serverless compute, use the
[NCC and Private Link path](private-link.md), which Terraform can create with
`connectivity.sql_database.serverless = "private_link"`.
