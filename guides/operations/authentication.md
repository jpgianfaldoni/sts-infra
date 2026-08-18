# Authentication

No credentials are stored in this repository. `./infra setup` interactively
selects local profiles and starts browser-based login. `./infra doctor`
verifies an existing session without logging in. Planning and applying run the
same preflight automatically, so `doctor` is optional.

## Local operators

For the first use of an AWS environment on a machine, run:

```bash
./infra setup aws environments/local/my-aws.tfvars
```

The wizard asks for an AWS CLI profile, confirms the Databricks account ID from
the selected tfvars, and suggests a Databricks account profile. It configures a
missing AWS SSO profile, starts AWS IAM Identity Center and Databricks OAuth U2M
browser login when required, verifies both sessions, and saves this non-secret
mapping under `~/.config/sts-infra/auth.json`:

```json
{
  "version": 1,
  "deployments": {
    "aws/my-aws": {
      "aws_profile": "my-aws-sso",
      "aws_account_id": "123456789012",
      "databricks_account_id": "00000000-0000-0000-0000-000000000000",
      "databricks_account_profile": "sts-my-aws-databricks"
    }
  }
}
```

The file contains no tokens, access keys, passwords, or client secrets. Those
remain in the standard CLI caches. Set `STS_INFRA_AUTH_CONFIG` to use another
local path. Explicit environment variables take precedence over the saved
mapping, and the legacy profile tfvars remain the final fallback:

1. `AWS_PROFILE` or `DATABRICKS_ACCOUNT_PROFILE`/
   `DATABRICKS_CONFIG_PROFILE`;
2. the setup mapping;
3. `aws_profile` or `databricks_profile` in the selected tfvars.

The preflight checks that a saved mapping still resolves to the AWS and
Databricks accounts recorded during setup. Rerun `./infra setup` to replace the
mapping or refresh an expired browser session.

Unity Catalog resources use workspace APIs. After the workspace exists, create
a workspace OAuth profile when the account profile cannot authenticate to that
workspace:

```bash
databricks auth login --host https://<workspace-host> \
  --profile <databricks-workspace-profile>
export DATABRICKS_WORKSPACE_PROFILE=<databricks-workspace-profile>
```

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
./infra setup azure environments/local/my-azure.tfvars
```

Setup starts `az login` only when the selected subscription has no valid
session. The subscription comes from the environment tfvars, and preflight
verifies it without changing the Azure CLI's global active subscription.
Service-principal and workload-identity environment variables supported by the
AzureRM provider can be used for automation.
