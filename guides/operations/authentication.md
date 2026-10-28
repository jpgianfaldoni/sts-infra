# Authentication

No credentials are stored in this repository. `./infra setup` selects or
creates local CLI profiles and starts browser logins when needed. `./infra
doctor` verifies the sessions without logging in. Planning, applying, and every
other state-changing command run the same checks automatically.

## Quick start

```bash
./infra doctor aws environments/local/my-aws.tfvars       # what is missing?
./infra setup aws environments/local/my-aws.tfvars --yes  # fix it (opens a browser)
```

With `--yes`, or when stdin is not a terminal, setup asks no questions: it uses
the detected defaults and exits with a clear message when something it cannot
discover is missing. Without `--yes` in a terminal, it asks you to confirm each
default. Running setup again is a no-op when every session is valid.

## Checking authentication

`./infra doctor <cloud> <tfvars>` checks, in order:

| Check | AWS | Azure |
| --- | --- | --- |
| `tools` | Terraform 1.11+, AWS CLI v2, Databricks CLI, jq | Terraform 1.11+, Azure CLI, Databricks CLI, jq, curl |
| cloud | `aws sts get-caller-identity` for the selected profile, compared with the expected account | `az account show` plus a token request for the subscription, compared with the expected tenant |
| `databricks_account` | an account-API call with the account profile | an account-API call with the Azure CLI identity or a mapped profile |
| `databricks_workspace` | once the workspace exists: the workspace OAuth profile (checked against this deployment's workspace URL) | only when a workspace profile is configured; otherwise the Azure CLI identity is used |

Add `--json` for a machine-readable report and `--wait <seconds>` to poll until
a browser login finishes:

```json
{
  "ready": false,
  "exit_code": 10,
  "checks": [
    {"id": "tools", "status": "ok", "detail": "terraform 1.14.6, aws-cli 2.27.14"},
    {"id": "aws", "status": "login_required", "profile": "sts-aws-123456789012", "source": "deployment mapping",
     "detail": "AWS session for profile 'sts-aws-123456789012' (deployment mapping) is expired or not logged in",
     "fix": "./infra setup aws environments/local/my-aws.tfvars --yes"}
  ],
  "warnings": [],
  "next_action": {"check": "aws", "status": "login_required", "browser_login": true,
                  "command": "./infra setup aws environments/local/my-aws.tfvars --yes"}
}
```

| Exit code | Meaning |
| --- | --- |
| 0 | ready |
| 10 | a browser login is required; run `next_action.command` |
| 11 | the identity, account, tenant, or profile does not match the environment |
| 12 | a required tool is missing or too old |

Every authentication failure in `plan`, `apply`, `destroy-plan`, and the other
commands uses the same exit codes and ends with the same single fix.

## AWS

Setup resolves three identities:

1. **AWS profile.** Uses `--aws-profile`, `AWS_PROFILE`, the saved mapping, or
   `aws_profile` in the tfvars. If none is set and the tfvars pins
   `aws_account_id`, setup finds a configured profile for that account (by
   `sso_account_id` or `role_arn`). Otherwise it suggests `sts-aws-<account>`.
   A missing profile is written non-interactively as an IAM Identity Center
   profile under a shared `sso-session`, so a single `aws sso login` covers
   every account in that session:

   ```bash
   ./infra setup aws environments/local/my-aws.tfvars --yes \
     --sso-start-url https://my-org.awsapps.com/start \
     --sso-region us-east-1 \
     --sso-role-name AdministratorAccess
   ```

   The start URL, region, and role are remembered for the next profile. In a
   terminal, setup can use the interactive `aws configure sso` wizard instead.
   Pass `--device-code` to print a verification URL and code instead of
   opening a browser.
2. **Databricks account profile.** Uses `--databricks-profile`,
   `DATABRICKS_ACCOUNT_PROFILE`, the saved mapping, or `databricks_profile` in
   the tfvars. Otherwise it reuses any valid `~/.databrickscfg` profile for the
   same account, or creates `sts-aws-account-<id>` with a browser OAuth login.
   Setup never overwrites a profile that targets a different account.
3. **Databricks workspace profile.** Once the workspace exists, setup reuses
   a valid profile for that workspace host or creates
   `sts-<deployment>-workspace` with an OAuth login, and saves it. The `apply`
   that creates the workspace prints this command. Plans with workspace-level
   resources (Unity Catalog, Glue connectivity) and destroy (which terminates
   clusters first) need it.

   The account-level OAuth profile cannot replace this login. The Databricks
   CLI refuses account profiles for workspace commands, and in a live test the
   Terraform unified provider (account host plus `workspace_id`) created a
   storage credential but failed on the external location with
   `Authentication failed`.

`doctor` reports how many minutes remain in an IAM Identity Center session that
the CLI cannot refresh on its own (it reads only the expiry fields of the SSO
cache entry, never tokens). Plans warn below 15 minutes and applies or destroys
below 60 minutes. Renew early with `./infra setup aws <tfvars> --yes --force-login`.

Set `aws_account_id` in the tfvars to pin the account: the Terraform provider
then refuses to operate anywhere else (`allowed_account_ids`), and setup can
find or create the right profile without asking.

## Azure

```bash
./infra setup azure environments/local/my-azure.tfvars --yes
```

Setup runs `az login` only when the subscription has no valid session (or with
`--force-login`). It uses
`tenant_id` from the tfvars (or `--tenant`) and suppresses the Azure CLI
subscription picker, because the subscription always comes from the tfvars. The
active Azure CLI subscription is never changed.

The same Azure identity then authenticates to the Azure Databricks account API
and to the workspace (Terraform passes `auth_type = "azure-cli"` and the tenant
to both Databricks providers), so no separate Databricks login is needed. The
identity must be an Azure Databricks account admin for account-level resources
such as metastores. If it is not, map a separate OAuth profile:

```bash
./infra setup azure environments/local/my-azure.tfvars --yes --databricks-profile my-azure-account
```

Use `--no-databricks-profile` to switch an existing mapping back to the Azure
CLI identity.

## The local mapping

Setup saves non-secret identifiers to `~/.config/sts-infra/auth.json`
(`STS_INFRA_AUTH_CONFIG` overrides the path; the file is mode 600):

```json
{
  "version": 1,
  "deployments": {
    "aws/my-aws": {
      "aws_profile": "sts-aws-123456789012",
      "aws_account_id": "123456789012",
      "databricks_account_id": "00000000-0000-0000-0000-000000000000",
      "databricks_account_profile": "sts-aws-account-00000000",
      "databricks_workspace_profile": "sts-my-aws-workspace"
    },
    "azure/my-azure": {
      "azure_subscription_id": "00000000-0000-0000-0000-000000000000",
      "azure_tenant_id": "11111111-1111-1111-1111-111111111111",
      "databricks_account_id": "00000000-0000-0000-0000-000000000000"
    }
  },
  "accounts": {
    "aws/123456789012": {"aws_profile": "sts-aws-123456789012"},
    "databricks/aws/00000000-0000-0000-0000-000000000000": {"databricks_account_profile": "sts-aws-account-00000000"}
  },
  "aws_sso": {"session": "sts-infra", "start_url": "https://my-org.awsapps.com/start", "region": "us-east-1", "role_name": "AdministratorAccess"}
}
```

The file contains no tokens, access keys, passwords, or client secrets; those
remain in the standard CLI caches. The `accounts` section lets a new
environment in a known account work without running setup again.

Profiles resolve in this order:

1. `AWS_PROFILE`, `DATABRICKS_ACCOUNT_PROFILE`, or `DATABRICKS_WORKSPACE_PROFILE`;
2. the deployment mapping;
3. `aws_profile`, `databricks_profile` (AWS), `databricks_account_profile`
   (Azure), or `databricks_workspace_profile` in the tfvars;
4. the account mapping.

The checks confirm that each profile still resolves to the accounts recorded
during setup and pinned in the tfvars. A workspace profile must point at this
deployment's workspace URL.

## Ambient credentials

When a profile is selected, `./infra` removes competing credentials from the
environment of Terraform and of its own CLI calls, so the identity that the
checks verified is the one Terraform uses:

- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_SESSION_TOKEN`;
- `DATABRICKS_CONFIG_PROFILE`, `DATABRICKS_HOST`, `DATABRICKS_TOKEN`,
  `DATABRICKS_CLIENT_ID`/`SECRET`, and the other `DATABRICKS_*` credential
  variables.

`doctor` prints a warning when any of these are set. `DATABRICKS_CONFIG_PROFILE`
is never treated as the account profile, because it usually points at a
workspace.

## Automation and applications

Omit every profile setting. The providers then use their standard credential
chains, and the checks verify those instead. The saved plan still records the
authenticated identity.

| Cloud | Variables |
| --- | --- |
| AWS | an assumed role or workload identity (`AWS_ROLE_ARN` + `AWS_WEB_IDENTITY_TOKEN_FILE`, or container/instance credentials); set `aws_account_id` in tfvars to pin the account |
| Databricks on AWS | `DATABRICKS_CLIENT_ID` + `DATABRICKS_CLIENT_SECRET` (OAuth M2M) or workload identity federation |
| Azure | `ARM_CLIENT_ID`, `ARM_TENANT_ID`, and `ARM_USE_OIDC=true`/`ARM_USE_MSI=true` (or a client secret); when any of these is set, `./infra` does not force Azure CLI authentication for Databricks |

Use short-lived credentials injected into one deployment worker. Never put
access keys, OAuth client secrets, tokens, or backend credentials in tfvars.
Static AWS access keys and Databricks personal access tokens are legacy
fallbacks, not recommended application authentication.

For a customer-facing service, have each customer provision an assumable AWS
role with an external ID, and grant the application's Databricks service
principal only the required account and workspace permissions.
