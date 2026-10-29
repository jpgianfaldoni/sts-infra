# Agent operating contract

Users of this repository describe a Databricks lab in plain language ("a
workspace on AWS and a Postgres database with sample data that classic compute
reaches privately") and expect it to be built, verified, and later destroyed
for them. They should not need to read Terraform, HCL, or networking docs.
This repository manages expensive cloud infrastructure. Agents must:

1. Read `components.json` and the selected environment tfvars before changing or planning infrastructure.
2. Use `./infra`; do not bypass its authentication and saved-plan checks for apply or destroy.
3. Never create `terraform.tfvars`, backend credentials, tokens, passwords, state, or plan files in Git.
4. Run `./infra validate <cloud>` after code changes. Static validation never authorizes deployment.
5. Show the user the saved plan summary, including every `replace:` and `delete:` line, before `./infra apply` or `./infra destroy`.
6. For endpoint approval, deployment, apply, and destroy, rely on the active harness approval policy and `./infra`'s built-in confirmation checks. Do not add a separate conversational approval gate.
7. Keep features in separate modules. Shared networking belongs only in the shared network or connectivity modules; modules used by both clouds live in `modules/shared`.
8. Prefer AWS Secrets Manager or Azure-managed secret stores. Do not print sensitive Terraform outputs in logs; `./infra output <cloud> <tfvars> --json` redacts them.

The `deploy-scenario` skill in `.claude/skills/` walks through this contract step by step.

## 1. Understand the request

Map the request onto a template before asking anything. `./infra templates`
lists every template with a one-line scenario, and `components.json` describes
each component (`summary`), connectivity mode (`connectivity_modes`), typical
build time (`minutes`), and cost tier (`cost`).

Ask only for what you cannot infer, in one short message, and offer a default
for each question:

| Decision | Ask when | Default and how to explain it |
| --- | --- | --- |
| Account | No target fits, or several do | Run `./infra targets` and offer the matching ones by name and description. |
| Cloud | Not stated | No default: ask. |
| Compute | "Databricks can reach X" without classic or serverless | Ask; explain that classic compute runs in the customer network and serverless compute runs in Databricks' account and needs Private Link. |
| "Privately" | The path is not named | Classic: VPC/VNet peering (simplest). Serverless: Private Link (the only private option). Mention AWS classic PrivateLink when the user wants to practice endpoint services. |
| Sample data | Not mentioned | Load it: `./infra verify` seeds `customers` and `orders` into PostgreSQL, RDS SQL Server, and Azure SQL. |
| Region | Not stated | The target's region, else `us-west-2` (AWS) or `westus2` (Azure). |

Clarify these phrasings instead of guessing:

- "Serverless workspace": this repository always creates a classic-capable
  workspace (VPC on AWS, VNet injection on Azure) in which serverless compute
  is available. Say so, and configure the serverless path the user wants.
  Serverless-only workspaces without a customer network are not supported yet.
- "On-premises": AWS only, as the simulated on-premises network
  (`simulated_on_prem`).
- PostgreSQL on Azure, MySQL, or other engines: not available; offer the
  closest supported scenario.

## 2. Create and check the environment

```bash
./infra new <cloud> <name> --template <template> --target <target>
./infra explain <cloud> environments/local/<name>.tfvars
```

`new` copies the template into the Git-ignored `environments/local/` and sets
the target. Edit the file only where the request differs from the template.
Then show the user the output of `explain`: what gets built, each network
path, the checks `verify` will run, and the build time and cost tier. Fix
every `[error]` finding (exit 1) before you plan.

If no target exists for the user's account, ask for the non-secret
identifiers and create one:

```bash
./infra targets add <name> --cloud aws --aws-account-id <12 digits> \
  --databricks-account-id <uuid> --region <region> \
  --sso-start-url <url> --sso-region <region> --sso-role-name <role> \
  [--metastore <name>] [--classic-node-type <type>]
./infra targets add <name> --cloud azure --subscription-id <uuid> \
  [--tenant-id <uuid>] [--databricks-account-id <uuid>] [--location <location>]
```

Shared accounts usually hold many Unity Catalog metastores per region, where
`metastore_mode = "auto"` refuses to choose. When the user names the metastore
their labs share, store it with `--metastore` (and the user's preferred check
node type with `--classic-node-type`): `./infra new` then writes both into
every new environment for that target.

AWS environments must pin their account through a target or
`aws_account_id`; `doctor` and `plan` exit 11 with status `unpinned`
otherwise.

## 3. Authenticate

1. Run `./infra doctor <cloud> <environment.tfvars> --json` and branch on its
   exit code: `0` ready, `10` a browser login is required, `11` the identity,
   account, tenant, profile, or target does not match the environment (or the
   AWS account is not pinned, or the Unity Catalog metastore needs a choice),
   `12` a tool is missing. `next_action.command` is the exact fix.
2. For exit `10`, run `./infra setup <cloud> <environment.tfvars> --yes`. With
   `--yes` (or without a terminal) setup asks no questions: it reuses or
   discovers profiles, opens the browser login for the user, and saves only
   profile names and account identifiers. Tell the user a browser window needs
   them; if you cannot run it, ask them to run it with the `!` prefix. Then wait
   with `./infra doctor <cloud> <environment.tfvars> --wait 600` instead of
   asking the user to confirm.
3. For exit `11`, show the detail to the user and let them choose the identity,
   profile, target, or (check `metastore`) the metastore. Do not guess or
   switch accounts yourself. The `metastore` check offers `suggested`, a
   metastore other local environments already pin; offer it as the default.
4. Never ask the user to paste credentials, and never read or print AWS, Azure,
   or Databricks credential or token caches. Do not run `aws sso login`,
   `az login`, or `databricks auth login` directly; `./infra setup` runs them
   with the correct account, tenant, and profile.
5. Setup may need non-secret values it cannot discover, such as an IAM
   Identity Center start URL, region, and role name for a new AWS profile.
   Store them in the target (`--sso-*` options of `./infra targets add`) so no
   later environment asks again. Never request a Databricks PAT.
6. Environment variables such as `AWS_PROFILE`, `DATABRICKS_ACCOUNT_PROFILE`,
   and `DATABRICKS_WORKSPACE_PROFILE` are explicit operator overrides. Do not
   silently replace or persist them. They do not survive between agent shell
   calls, so rely on the saved mapping instead of exporting them.
7. On Azure, one `az login` covers the subscription, the Databricks account,
   and the workspace.

If `doctor` warns that an IAM Identity Center session is about to expire, renew
it before a long apply or destroy with `./infra setup aws <environment.tfvars>
--yes --force-login`.

## 4. Deploy and verify

```bash
./infra plan <cloud> <tfvars>      # show the summary and every replace:/delete: line
./infra apply <cloud> <tfvars>
./infra verify <cloud> <tfvars>    # loads the sample data and checks each path
```

- Plans and applies take 10–40 minutes. Run them in the background and tail
  the `Terraform log:` file that `./infra` prints.
- **AWS deploys a new workspace in two stages.** The first plan reports
  `Deployment stage: foundation (1 of 2)` and creates the workspace, networks,
  and sources. After that apply, run the printed `./infra setup aws ... --yes`
  (a browser login to the new workspace), then plan and apply again to add
  Unity Catalog, Glue catalogs, and the lab check job. Azure needs one stage.
- **Endpoint approval is automatic** (`endpoint_approval = "auto"`, the
  default): after apply, `./infra` approves exactly the serverless private
  endpoint connections the deployment requested. With
  `endpoint_approval = "manual"` they stay pending so the user can practice the
  step with `./infra endpoints aws accept` or `./infra endpoints azure approve`
  (using a `connection_id` from `./infra endpoints azure status`). Classic AWS
  PrivateLink connections are always accepted by Terraform.
- **`verify`** copies the database credentials into a Databricks secret scope
  (AWS) or uses the Key Vault-backed scope (Azure), waits for serverless
  endpoint rules to become `ESTABLISHED`, runs the lab check job, and reports
  each path. Exit `0` means every path works; exit `13` means a check failed,
  with the failing stage (`dns`, `tcp`, `driver`, `credentials`, `login`,
  `seed`, `query`) and a hint; unexpected errors also print the end of the
  traceback. Show the user the results, including the sample-data row counts.
- `./infra status <cloud> <tfvars> --json` returns `next_action` for a
  deployment from local state, which is the way to resume work in a new
  session. `./infra ls` lists every local deployment and how long it has
  existed; remind the user to destroy labs they no longer need.

## 5. Troubleshoot

| Symptom | Cause and fix |
| --- | --- |
| `doctor` exit 11, status `unpinned` | Set `target` (or `aws_account_id`) in the tfvars. |
| `doctor` exit 11 on `target` | The target is undefined, for the other cloud, or the tfvars overrides it with different IDs; see `detail`. |
| Apply stops with an expired session | Run `./infra setup <cloud> <tfvars> --yes --force-login`, then plan again; `./infra` invalidated the failed plan. |
| `doctor` exit 11 on `metastore`, status `choice_required` | `metastore_mode = "auto"` found several metastores in the region. Ask the user which to use (offer `suggested`); set `unity_catalog.metastore_mode = "existing"` and `existing_metastore_name`, and offer to save it in the target with `--metastore`. |
| `doctor` exit 11 on `metastore`, status `not_found` | `existing_metastore_name` does not exist or is in another region; see `detail`. |
| `verify` fails at `dns` or `tcp` on serverless | The endpoint rule may still be provisioning: check `./infra endpoints <cloud> status`, wait a few minutes, rerun `verify`. |
| `verify` fails at `dns` or `tcp` on classic | The path is broken or deliberately absent; compare with `./infra explain`. |
| `verify` fails at `driver` | "could not install": the compute has no outbound internet access to PyPI. "Unexpected error": the pinned driver set in `modules/shared/lab-check/notebooks/lab_check.py` is incompatible; the hint lists the installed versions, and `python3 tests/test_lab_check_drivers.py` reproduces it locally. |
| `verify` fails at `login` or `credentials` | Rerun `verify` (it refreshes the credentials); on Azure, check the Key Vault-backed scope. |
| The classic check cluster cannot start | The region lacks capacity or quota for the default node type; set `lab_check.classic_node_type` (or `--classic-node-type` on the target). |
| Destroy refuses to start on AWS | It needs the workspace login to terminate clusters: run `./infra setup aws <tfvars> --yes`. |

## 6. Destroy

Follow `guides/operations/deployment.md#destroy`, then:

```bash
./infra destroy-plan <cloud> <tfvars>
./infra destroy <cloud> <tfvars> --confirm destroy-<cloud>
```
