# Authentication

No credentials are stored in this repository.

For AWS, configure an AWS CLI profile and a Databricks account profile:

```bash
aws configure sso --profile <aws-profile>
aws sso login --profile <aws-profile>
databricks auth login --host https://accounts.cloud.databricks.com --profile <databricks-profile>
```

Unity Catalog resources also use workspace APIs. When using interactive OAuth, authenticate to the deployed workspace with a separate profile and set `databricks_workspace_profile` in the environment tfvars:

```bash
databricks auth login --host https://<workspace-host> --profile <workspace-profile>
```

Put only the profile names in the environment tfvars. `./infra auth aws <tfvars>` checks AWS, account-level Databricks authentication, and the optional workspace-level session. If `databricks_workspace_profile` is omitted, Terraform reuses `databricks_profile`.

For Azure:

```bash
az login
az account set --subscription <subscription-id>
```

Service-principal and workload-identity environment variables supported by the Terraform providers also work in CI. Never add them to tfvars.
