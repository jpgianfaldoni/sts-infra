# Authentication

No credentials are stored in this repository. `./infra doctor` verifies an
existing session; it does not perform an interactive login. Planning and
applying run the same preflight automatically, so `doctor` is optional.

## Local operators

Use short-lived AWS IAM Identity Center credentials and Databricks OAuth U2M:

```bash
aws configure sso --profile <aws-profile>
aws sso login --profile <aws-profile>
databricks auth login https://accounts.cloud.databricks.com \
  --account-id <databricks-account-id> \
  --profile <databricks-account-profile>
```

Set operator-specific profile names in the shell instead of the infrastructure
tfvars:

```bash
export AWS_PROFILE=<aws-profile>
export DATABRICKS_ACCOUNT_PROFILE=<databricks-account-profile>
```

Unity Catalog resources use workspace APIs. After the workspace exists, create
a workspace OAuth profile when the account profile cannot authenticate to that
workspace:

```bash
databricks auth login https://<workspace-host> \
  --profile <databricks-workspace-profile>
export DATABRICKS_WORKSPACE_PROFILE=<databricks-workspace-profile>
```

`DATABRICKS_CONFIG_PROFILE` is accepted as an account-profile fallback. The
legacy `aws_profile`, `databricks_profile`, and
`databricks_workspace_profile` tfvars remain supported so existing local
environment files continue to work.

Verify the sessions when troubleshooting:

```bash
./infra doctor aws environments/local/my-aws.tfvars
```

## Automation and applications

Omit all profile settings. The AWS and Databricks Terraform providers then use
their standard credential chains:

- AWS: OIDC or another workload identity assumes a narrowly scoped IAM role.
- Databricks: workload identity federation when available, otherwise OAuth M2M
  for a service principal.

Use short-lived credentials injected into one deployment worker. Never put
AWS access keys, OAuth client secrets, tokens, or backend credentials in
tfvars. Static AWS access keys and Databricks personal access tokens are legacy
fallbacks, not recommended application authentication.

For a customer-facing service, have each customer provision an assumable AWS
role with an external ID and grant the application's Databricks service
principal only the required account and workspace permissions.

## Azure

For local use:

```bash
az login
```

The subscription comes from the environment tfvars. Preflight verifies that
subscription without changing the Azure CLI's global active subscription.
Service-principal and workload-identity environment variables supported by the
AzureRM provider can be used for automation.
