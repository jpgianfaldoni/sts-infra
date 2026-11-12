"""Authentication: resolving profiles, checking sessions, doctor, and preflight.

Resolution makes no network calls; checks call the cloud and Databricks CLIs
to prove each session works for the account the environment pins. Every
check records an id, a status, a detail, and the exact command that fixes it.
"""
from __future__ import annotations

import glob
import json
import os
import re
import time

from . import authconfig
from . import clis
from .common import (
    AWS_DATABRICKS_ACCOUNTS_HOST, AZURE_DATABRICKS_ACCOUNTS_HOST, AZURE_DATABRICKS_AUTOMATION_VARS,
    EXIT_IDENTITY_MISMATCH, EXIT_LOGIN_REQUIRED, EXIT_MISSING_TOOL, ROOT, Exit, die, env_int, err, out,
    is_seconds, parse_json, text_sha256, version_at_least, Usage,
)
from .context import Context, cloud_root, scenario, tool_available

# --- resolution (no network calls) ------------------------------------------


def aws_region_for(ctx: Context) -> str:
    return (ctx.tfvar("region") or ctx.target_value("region") or os.environ.get("AWS_REGION")
            or os.environ.get("AWS_DEFAULT_REGION") or "us-west-2")


def resolve_aws(ctx: Context) -> None:
    ctx.aws_region = aws_region_for(ctx)
    ctx.aws_expected_account = ctx.tfvar("aws_account_id")
    if ctx.aws_expected_account:
        ctx.aws_expected_source = f"aws_account_id in {ctx.display_vars}"
    elif ctx.target_value("aws_account_id"):
        ctx.aws_expected_account = ctx.target_value("aws_account_id")
        ctx.aws_expected_source = f"target '{ctx.target}'"
    else:
        ctx.aws_expected_account = ctx.deployment_value("aws_account_id")
        if ctx.aws_expected_account:
            ctx.aws_expected_source = "the local authentication mapping"

    candidates = (
        (os.environ.get("AWS_PROFILE", ""), "AWS_PROFILE"),
        (lambda: ctx.deployment_value("aws_profile"), "deployment mapping"),
        (lambda: ctx.tfvar("aws_profile"), "tfvars"),
        (lambda: ctx.target_value("aws_profile"), "target"),
        (lambda: authconfig.account_value(f"aws/{ctx.aws_expected_account}", "aws_profile") if ctx.aws_expected_account else "", "account mapping"),
    )
    ctx.aws_profile, ctx.aws_profile_source = first_value(candidates)

    if ctx.aws_profile:
        clis.scrub_aws(ctx)
        if os.environ.get("AWS_ACCESS_KEY_ID") or os.environ.get("AWS_SESSION_TOKEN"):
            ctx.warnings.append(f"AWS access-key environment variables are set in this shell; ./infra ignores them because profile '{ctx.aws_profile}' is selected.")
    elif not ctx.aws_expected_account and os.environ.get("STS_INFRA_ALLOW_UNPINNED_ACCOUNT") == "1":
        ctx.warnings.append("No AWS profile or expected account is configured, so whichever account the ambient credentials belong to "
                            f"will be used (STS_INFRA_ALLOW_UNPINNED_ACCOUNT=1). Set target or aws_account_id in {ctx.display_vars}.")


def first_value(candidates):
    for value, source in candidates:
        value = value() if callable(value) else value
        if value:
            return value, source
    return "", ""


def azure_databricks_automation_env() -> bool:
    return any(os.environ.get(name) for name in AZURE_DATABRICKS_AUTOMATION_VARS)


def resolve_databricks_account(ctx: Context) -> None:
    if ctx.cloud == "aws":
        ctx.db_host = AWS_DATABRICKS_ACCOUNTS_HOST
        tfvars_key = "databricks_profile"
    else:
        ctx.db_host = AZURE_DATABRICKS_ACCOUNTS_HOST
        tfvars_key = "databricks_account_profile"
        if not azure_databricks_automation_env():
            ctx.db_auth_type = "azure-cli"
    ctx.db_account_id = ctx.setting_value("databricks_account_id")
    if not ctx.db_account_id:
        if not (ctx.cloud == "azure" or ctx.target):
            die(f"databricks_account_id is required in {ctx.display_vars} (or in its target)")
        ctx.db_mode = "none"

    account_key = f"databricks/{ctx.cloud}/{ctx.db_account_id}"
    candidates = (
        (os.environ.get("DATABRICKS_ACCOUNT_PROFILE", ""), "DATABRICKS_ACCOUNT_PROFILE"),
        (lambda: ctx.deployment_value("databricks_account_profile"), "deployment mapping"),
        (lambda: ctx.tfvar(tfvars_key), "tfvars"),
        (lambda: ctx.target_value("databricks_account_profile"), "target"),
        (lambda: authconfig.account_value(account_key, "databricks_account_profile") if ctx.db_account_id else "", "account mapping"),
    )
    ctx.db_account_profile, ctx.db_account_profile_source = first_value(candidates)

    if ctx.db_account_id:
        if ctx.db_account_profile:
            ctx.db_mode = "profile"
        elif ctx.db_auth_type == "azure-cli":
            ctx.db_mode = "azure-cli"
        else:
            ctx.db_mode = "environment"


def resolve_databricks_workspace(ctx: Context) -> None:
    candidates = (
        (os.environ.get("DATABRICKS_WORKSPACE_PROFILE", ""), "DATABRICKS_WORKSPACE_PROFILE"),
        (lambda: ctx.deployment_value("databricks_workspace_profile"), "deployment mapping"),
        (lambda: ctx.tfvar("databricks_workspace_profile"), "tfvars"),
    )
    ctx.db_workspace_profile, ctx.db_workspace_profile_source = first_value(candidates)
    ctx.workspace_url = ctx.state_workspace_url()


def resolve_databricks_environment_hygiene(ctx: Context) -> None:
    """A profile-based or Azure CLI session must not be overridden by ambient Databricks variables."""
    if ctx.db_mode == "environment" and not ctx.db_workspace_profile:
        return
    if ctx.db_mode == "none" and not ctx.db_workspace_profile and ctx.db_auth_type != "azure-cli":
        return
    clis.scrub_databricks(ctx)
    if os.environ.get("DATABRICKS_CONFIG_PROFILE"):
        ctx.warnings.append(f"DATABRICKS_CONFIG_PROFILE={os.environ['DATABRICKS_CONFIG_PROFILE']} is ignored by ./infra; "
                            "use DATABRICKS_ACCOUNT_PROFILE or DATABRICKS_WORKSPACE_PROFILE, or run ./infra setup.")
    if os.environ.get("DATABRICKS_HOST") or os.environ.get("DATABRICKS_TOKEN") or os.environ.get("DATABRICKS_CLIENT_ID"):
        ctx.warnings.append("DATABRICKS_HOST, DATABRICKS_TOKEN, or DATABRICKS_CLIENT_ID is set in this shell; "
                            "./infra ignores them because local profiles are selected.")


def resolve_auth(ctx: Context, action: str = "check") -> None:
    ctx.reset_auth(action)
    if ctx.cloud == "aws":
        resolve_aws(ctx)
    else:
        ctx.az_subscription = ctx.setting_value("subscription_id")
        if not ctx.az_subscription and not ctx.target:
            die(f"subscription_id is required in {ctx.display_vars} (or in its target)")
        ctx.az_expected_tenant = ctx.setting_value("tenant_id") or ctx.deployment_value("azure_tenant_id")
    resolve_databricks_account(ctx)
    resolve_databricks_workspace(ctx)
    resolve_databricks_environment_hygiene(ctx)


# --- checks -------------------------------------------------------------------


def record(ctx: Context, check_id: str, status: str, detail: str, fix: str = "", **extra) -> None:
    result = {"id": check_id, "status": status, "detail": detail}
    if fix:
        result["fix"] = fix
    result.update({key: value for key, value in extra.items() if value})
    ctx.checks.append(result)


def checks_exit_code(ctx: Context) -> int:
    code = 0
    for check in ctx.checks:
        status = check["status"]
        if status == "missing_tool":
            code = EXIT_MISSING_TOOL
        elif status in ("mismatch", "denied", "unpinned", "choice_required", "not_found"):
            code = max(code, EXIT_IDENTITY_MISMATCH)
        elif status == "login_required":
            code = max(code, EXIT_LOGIN_REQUIRED)
    return code


def check_tools(ctx: Context, cloud: str) -> None:
    required = ["terraform", "databricks"] + (["aws"] if cloud == "aws" else ["az"])
    missing = [tool for tool in required if not tool_available(tool)]
    if missing:
        names = " ".join(missing)
        record(ctx, "tools", "missing_tool", f"missing required tools: {names}", f"install {names}, then rerun ./infra doctor {cloud}")
        return
    _, text = ctx.call(["terraform", "version", "-json"], stderr="null")
    reported = parse_json(text, {})
    version = (reported.get("terraform_version") or "") if isinstance(reported, dict) else ""
    if not version or not version_at_least(version, "1.11.0"):
        record(ctx, "tools", "missing_tool", f"Terraform {version or '(unknown version)'} is older than the required 1.11.0", "install Terraform 1.11 or newer")
        return
    details = f"terraform {version}"
    if cloud == "aws":
        _, text = ctx.call(["aws", "--version"], stderr="stdout")
        aws_version = (text.split() or [""])[0]
        if not aws_version.startswith("aws-cli/2."):
            record(ctx, "tools", "missing_tool", f"AWS CLI v2 is required for IAM Identity Center (found {aws_version or 'unknown'})", "install AWS CLI v2")
            return
        details += ", " + aws_version.replace("/", " ", 1)
    record(ctx, "tools", "ok", details)


def check_target(ctx: Context) -> None:
    if not ctx.target:
        return
    if ctx.target_fields is None:
        record(ctx, "target", "mismatch", f"target '{ctx.target}' is not defined in {authconfig.targets_path()}",
               f"./infra targets add {ctx.target} --cloud {ctx.cloud} ...", target=ctx.target)
        return
    if ctx.target_value("cloud") != ctx.cloud:
        record(ctx, "target", "mismatch",
               f"target '{ctx.target}' is a {ctx.target_value('cloud')} target, but {ctx.display_vars} is a {ctx.cloud} environment",
               f"set target to a {ctx.cloud} target in {ctx.display_vars} (see ./infra targets)", target=ctx.target)
        return
    conflicts = []
    for field in ("aws_account_id", "databricks_account_id", "subscription_id", "tenant_id", "region", "location"):
        explicit, from_target = ctx.tfvar(field), ctx.target_value(field)
        if explicit and from_target and explicit != from_target:
            conflicts.append(f"{field} ({explicit} in tfvars, {from_target} in the target)")
    if conflicts:
        record(ctx, "target", "mismatch", f"{ctx.display_vars} overrides target '{ctx.target}' with different values: {' '.join(conflicts)}",
               f"remove the overriding values from {ctx.display_vars} or choose another target", target=ctx.target)
        return
    description = ctx.target_value("description")
    record(ctx, "target", "ok", f"target '{ctx.target}'" + (f" ({description})" if description else ""), "",
           target=ctx.target, path=authconfig.targets_path())


def caller_identity(ctx: Context):
    code, text = clis.aws_cli(ctx, "sts", "get-caller-identity", "--output", "json", stderr="null")
    identity = parse_json(text) if code == 0 else None
    return code, identity if isinstance(identity, dict) else {}


def check_aws(ctx: Context) -> None:
    profile_fields = {"profile": ctx.aws_profile, "source": ctx.aws_profile_source}
    mapping_account = ctx.deployment_value("aws_account_id")
    tfvars_account = ctx.tfvar("aws_account_id")
    if mapping_account and tfvars_account and mapping_account != tfvars_account:
        record(ctx, "aws", "mismatch", f"{ctx.display_vars} pins AWS account {tfvars_account}, but the local mapping expects {mapping_account}",
               f"./infra setup aws {ctx.display_vars}", **profile_fields)
        return
    if not ctx.aws_expected_account and os.environ.get("STS_INFRA_ALLOW_UNPINNED_ACCOUNT") != "1":
        _, identity = caller_identity(ctx)
        ctx.aws_account = identity.get("Account") or ""
        record(ctx, "aws", "unpinned",
               f"no AWS account is pinned for {ctx.display_vars}" + (f"; the current credentials are for account {ctx.aws_account}" if ctx.aws_account else "")
               + ". Pin the account so nothing is deployed to the wrong one",
               f"set target = \"<name>\" (see ./infra targets) or aws_account_id = \"{ctx.aws_account or '<12-digit id>'}\" in {ctx.display_vars}",
               **profile_fields, account_id=ctx.aws_account)
        return
    if ctx.aws_profile and not clis.aws_profile_exists(ctx, ctx.aws_profile):
        record(ctx, "aws", "login_required", f"AWS profile '{ctx.aws_profile}' ({ctx.aws_profile_source}) is not configured on this machine",
               ctx.setup_fix(), **profile_fields)
        return
    code, identity = caller_identity(ctx)
    if code != 0:
        if ctx.aws_profile:
            record(ctx, "aws", "login_required", f"AWS session for profile '{ctx.aws_profile}' ({ctx.aws_profile_source}) is expired or not logged in",
                   ctx.setup_fix(), **profile_fields)
        else:
            record(ctx, "aws", "login_required", "no AWS profile is selected and the environment credential chain has no valid credentials", ctx.setup_fix())
        return
    ctx.aws_account = identity.get("Account") or ""
    ctx.aws_arn = identity.get("Arn") or ""
    if not ctx.aws_account:
        record(ctx, "aws", "login_required", "could not determine the authenticated AWS account", ctx.setup_fix())
        return
    if ctx.aws_expected_account and ctx.aws_expected_account != ctx.aws_account:
        record(ctx, "aws", "mismatch",
               f"authenticated to AWS account {ctx.aws_account} as {ctx.aws_arn}, but {ctx.aws_expected_source} expects {ctx.aws_expected_account}",
               f"./infra setup aws {ctx.display_vars} --aws-profile <profile-for-{ctx.aws_expected_account}>",
               **profile_fields, account_id=ctx.aws_account, principal=ctx.aws_arn)
        return
    session_minutes = ""
    if ctx.aws_profile:
        credential_source = f"profile {ctx.aws_profile} from {ctx.aws_profile_source}"
        session_minutes = clis.aws_sso_session_minutes_left(ctx, ctx.aws_profile)
    else:
        credential_source = "environment credentials"
    if session_minutes:
        credential_source += f"; SSO session expires in {session_minutes} min"
        threshold = 60 if ctx.auth_action in ("apply", "destroy", "seed", "seed-access") else 15
        if int(session_minutes) < threshold:
            ctx.warnings.append(f"The IAM Identity Center session for AWS profile '{ctx.aws_profile}' expires in {session_minutes} minute(s), "
                                f"so a long operation may fail midway. Refresh it first: ./infra setup aws {ctx.display_vars} --yes --force-login")
    record(ctx, "aws", "ok", f"account {ctx.aws_account} as {ctx.aws_arn} ({credential_source})", "",
           profile=ctx.aws_profile, source=ctx.aws_profile_source or "environment", account_id=ctx.aws_account,
           principal=ctx.aws_arn, region=ctx.aws_region, session_minutes_left=session_minutes)


def azure_account_show(ctx: Context):
    code, text = ctx.call(["az", "account", "show", "--subscription", ctx.az_subscription, "--output", "json"], stderr="null")
    show = parse_json(text) if code == 0 else None
    return code == 0, show if isinstance(show, dict) else {}


def azure_token_valid(ctx: Context) -> bool:
    # `az account show` only reads the local profile; requesting a token proves
    # the session is still valid without printing it.
    code, _ = ctx.call(["az", "account", "get-access-token", "--subscription", ctx.az_subscription, "--query", "expiresOn", "--output", "tsv"],
                       stdout="null", stderr="null")
    return code == 0


def check_azure(ctx: Context) -> None:
    mapped = ctx.deployment_value("azure_subscription_id")
    if mapped and mapped != ctx.az_subscription:
        record(ctx, "azure", "mismatch", f"the local mapping targets Azure subscription {mapped}, but {ctx.display_vars} requires {ctx.az_subscription}",
               f"./infra setup azure {ctx.display_vars}")
        return
    ok, show = azure_account_show(ctx)
    if not ok:
        record(ctx, "azure", "login_required", f"no Azure CLI session has access to subscription {ctx.az_subscription}", ctx.setup_fix(),
               subscription_id=ctx.az_subscription)
        return
    ctx.az_tenant = show.get("tenantId") or ""
    user = show.get("user") if isinstance(show.get("user"), dict) else {}
    ctx.az_principal = user.get("name") or ""
    ctx.az_principal_type = user.get("type") or ""
    if ctx.az_expected_tenant and ctx.az_expected_tenant != ctx.az_tenant:
        record(ctx, "azure", "mismatch", f"subscription {ctx.az_subscription} resolved to tenant {ctx.az_tenant}, but tenant {ctx.az_expected_tenant} is expected",
               f"./infra setup azure {ctx.display_vars} --tenant {ctx.az_expected_tenant}", subscription_id=ctx.az_subscription, tenant_id=ctx.az_tenant)
        return
    if not azure_token_valid(ctx):
        record(ctx, "azure", "login_required", f"the Azure CLI session for subscription {ctx.az_subscription} has expired", ctx.setup_fix(),
               subscription_id=ctx.az_subscription, tenant_id=ctx.az_tenant, principal=ctx.az_principal)
        return
    ctx.az_ok = True
    record(ctx, "azure", "ok",
           f"subscription {ctx.az_subscription} in tenant {ctx.az_tenant} as {ctx.az_principal or 'unknown principal'} ({ctx.az_principal_type or 'unknown type'})", "",
           subscription_id=ctx.az_subscription, tenant_id=ctx.az_tenant, principal=ctx.az_principal)


def check_databricks_account(ctx: Context) -> None:
    probe = "workspaces" if ctx.cloud == "aws" else "metastores"
    if ctx.db_mode == "none":
        record(ctx, "databricks_account", "not_required", f"no databricks_account_id in {ctx.display_vars}")
        return
    mapped = ctx.deployment_value("databricks_account_id")
    if mapped and mapped != ctx.db_account_id:
        record(ctx, "databricks_account", "mismatch", f"the local mapping targets Databricks account {mapped}, but {ctx.display_vars} requires {ctx.db_account_id}",
               f"./infra setup {ctx.cloud} {ctx.display_vars}", account_id=ctx.db_account_id)
        return
    fields = {"profile": ctx.db_account_profile, "source": ctx.db_account_profile_source, "account_id": ctx.db_account_id}
    if ctx.db_mode == "profile":
        state = clis.databricks_account_profile_state(ctx, ctx.db_account_profile, ctx.db_host, ctx.db_account_id, probe)
        if state.state == "missing":
            record(ctx, "databricks_account", "login_required",
                   f"Databricks profile '{ctx.db_account_profile}' ({ctx.db_account_profile_source}) does not exist", ctx.setup_fix(), **fields)
        elif state.state == "mismatch":
            record(ctx, "databricks_account", "mismatch",
                   f"Databricks profile '{ctx.db_account_profile}' targets {state.host or 'no host'} account {state.account or '(none)'}, "
                   f"but {ctx.display_vars} requires {ctx.db_host} account {ctx.db_account_id}",
                   f"./infra setup {ctx.cloud} {ctx.display_vars} --databricks-profile <profile-for-{ctx.db_account_id}>", **fields)
        elif state.state == "expired":
            record(ctx, "databricks_account", "login_required",
                   f"the Databricks session for profile '{ctx.db_account_profile}' is expired or lacks account access", ctx.setup_fix(), **fields)
        else:
            ctx.db_account_ok = True
            _, text = clis.databricks_cli(ctx, "auth", "describe", "--profile", ctx.db_account_profile, "--output", "json", stderr="null")
            described = parse_json(text, {})
            principal = (described.get("username") or "") if isinstance(described, dict) else ""
            record(ctx, "databricks_account", "ok",
                   f"account {ctx.db_account_id}" + (f" as {principal}" if principal else "")
                   + f" (profile {ctx.db_account_profile} from {ctx.db_account_profile_source})", "", **fields, principal=principal)
    elif ctx.db_mode == "azure-cli":
        if not ctx.az_ok:
            record(ctx, "databricks_account", "skipped", "requires a valid Azure CLI session", "", account_id=ctx.db_account_id, source="azure-cli")
        elif clis.databricks_account_probe(ctx, probe):
            ctx.db_account_ok = True
            record(ctx, "databricks_account", "ok", f"account {ctx.db_account_id} as {ctx.az_principal or 'the Azure CLI identity'} (Azure CLI)", "",
                   account_id=ctx.db_account_id, source="azure-cli", principal=ctx.az_principal)
        else:
            record(ctx, "databricks_account", "denied",
                   f"the Azure CLI identity cannot call the Azure Databricks account API for account {ctx.db_account_id}; it must be an account admin",
                   f"./infra setup azure {ctx.display_vars} --databricks-profile <profile-name>", account_id=ctx.db_account_id, source="azure-cli")
    else:
        if clis.databricks_account_probe(ctx, probe):
            ctx.db_account_ok = True
            record(ctx, "databricks_account", "ok", f"account {ctx.db_account_id} (environment credentials)", "", account_id=ctx.db_account_id, source="environment")
        else:
            record(ctx, "databricks_account", "login_required", "no Databricks account credentials were found in the environment", ctx.setup_fix(),
                   account_id=ctx.db_account_id, source="environment")


def aws_name_prefix(ctx: Context) -> str:
    """The resource name prefix Terraform derives (deployments/aws/main.tf)."""
    prefix = ctx.tfvar("name_prefix")
    if not prefix:
        prefix = re.sub(r"[^a-z0-9]+", "-", ctx.id.lower()).strip("-")[:24].rstrip("-")
        if not prefix:
            prefix = "demo"
        elif not re.match(r"^[a-z]", prefix):
            prefix = f"d-{prefix}"
    return prefix


def local_pinned_metastores(ctx: Context) -> list:
    """Metastore names other local AWS environments pin, most used first."""
    counts: dict = {}
    for path in sorted(glob.glob(f"{ROOT}/environments/local/*.tfvars")):
        if not os.path.isfile(path) or path == ctx.vars:
            continue
        name = scenario.tfvar_value(path, "existing_metastore_name", "unity_catalog")
        if name:
            counts[name] = counts.get(name, 0) + 1
    return [name for name, _ in sorted(counts.items(), key=lambda item: (item[1], item[0]), reverse=True)]


def check_metastore(ctx: Context) -> None:
    """AWS: resolve unity_catalog.metastore_mode against the account before any plan."""
    if ctx.cloud != "aws" or ctx.auth_action not in ("check", "apply"):
        return
    if ctx.tfvar("unity_catalog", "features") == "false" or ctx.tfvar("workspace", "features") == "false":
        return
    if ctx.state_exists() and any(r.get("type") == "databricks_metastore_assignment" and r.get("instances")
                                  for r in ctx.state_json().get("resources") or []):
        record(ctx, "metastore", "ok", "assigned to the workspace (recorded in state)")
        return
    name = ctx.tfvar("existing_metastore_name", "unity_catalog")
    mode = "existing" if name else (ctx.tfvar("metastore_mode", "unity_catalog") or "create")
    region = ctx.setting_value("region") or "us-west-2"
    prefix = aws_name_prefix(ctx)
    if mode == "create":
        record(ctx, "metastore", "ok", f"creates metastore {prefix}-metastore in {region}", "", mode="create")
        return
    if not ctx.db_account_ok:
        record(ctx, "metastore", "skipped", "requires a valid Databricks account session", "", mode=mode)
        return
    code, text = clis.databricks_account_cli(ctx, "account", "metastores", "list", "--output", "json", stderr="null")
    listed = parse_json(text) if code == 0 else None
    if not isinstance(listed, list):
        record(ctx, "metastore", "skipped",
               f"could not list the account's metastores; Terraform resolves metastore_mode = \"{mode}\" during the second stage", "", mode=mode)
        return
    listed = [item for item in listed if isinstance(item, dict)]
    if mode == "existing":
        found = next(((item.get("region") or "") for item in listed if item.get("name") == name), None)
        fix = f"set unity_catalog.existing_metastore_name in {ctx.display_vars} to a metastore in {region}"
        if found is None:
            record(ctx, "metastore", "not_found",
                   f"metastore '{name}' (unity_catalog.existing_metastore_name) does not exist in Databricks account {ctx.db_account_id}", fix,
                   mode="existing", metastore=name)
        elif found and found != region:
            record(ctx, "metastore", "not_found",
                   f"metastore '{name}' is in {found}, but the workspace is in {region}; a workspace can only use a metastore in its own region", fix,
                   mode="existing", metastore=name)
        else:
            record(ctx, "metastore", "ok", f"uses existing metastore {name} in {region}", "", mode="existing", metastore=name)
        return
    managed = f"{prefix}-metastore"
    if any(item.get("name") == managed for item in listed):
        record(ctx, "metastore", "ok", f"auto: keeps managing metastore {managed}", "", mode="auto", metastore=managed)
        return
    regional = sorted(item.get("name") for item in listed if item.get("region") == region and item.get("name") != managed)
    count = len(regional)
    if count == 0:
        record(ctx, "metastore", "ok", f"auto: creates metastore {managed} (none exists in {region})", "", mode="auto")
    elif count == 1:
        record(ctx, "metastore", "ok", f"auto: reuses metastore {regional[0]}, the only one in {region}", "", mode="auto", metastore=regional[0])
    else:
        suggestion = next((candidate for candidate in local_pinned_metastores(ctx) if candidate in regional), "")
        candidates = ", ".join(regional[:8]) + (", ..." if count > 8 else "")
        record(ctx, "metastore", "choice_required",
               f"auto mode found {count} metastores in {region} ({candidates}) and will not guess"
               + (f"; other local environments use {suggestion}" if suggestion else ""),
               f"set unity_catalog = {{ metastore_mode = \"existing\", existing_metastore_name = \"{suggestion or '<name>'}\" }} in {ctx.display_vars}, "
               "or metastore_mode = \"create\" for a dedicated metastore",
               mode="auto", region=region, count=str(count), suggested=suggestion)


def state_workspace_absent_from_account(ctx: Context) -> bool:
    workspace_id = ctx.state_workspace_id()
    if not workspace_id:
        return False
    code, text = clis.databricks_account_cli(ctx, "account", "workspaces", "list", "--output", "json", stderr="null")
    if code != 0:
        return False
    listed = parse_json(text)
    if listed is None:
        return False  # an unreadable list never counts as proof the workspace is gone
    from .context import jq_tostring
    from .common import items_of

    return not any(isinstance(item, dict) and jq_tostring(item.get("workspace_id")) == workspace_id
                   for item in items_of(listed, "workspaces"))


def workspace_auth_requirement(ctx: Context):
    """(required|recommended|not_required, detail)."""
    if not ctx.workspace_url:
        return "not_required", "the workspace does not exist yet"
    if ctx.auth_action == "endpoint":
        return "not_required", "endpoint decisions use only cloud credentials"
    if ctx.auth_action == "inspect":
        return "not_required", "reading VM setup results uses only Azure credentials"
    if ctx.auth_action == "verify":
        return "required", "verify runs the lab check job in the workspace"
    if ctx.cloud == "aws" and ctx.auth_action == "destroy":
        if ctx.db_account_ok and state_workspace_absent_from_account(ctx):
            return "not_required", f"workspace {ctx.state_workspace_id()} was deleted externally; destroy does not need workspace authentication"
        return "required", "destroy terminates workspace clusters before Terraform runs"
    if ctx.state_requires_workspace_auth():
        return "required", "state contains workspace-level Databricks resources"
    if ctx.cloud == "aws":
        uc = ctx.tfvar("unity_catalog", "features")
        glue = ctx.tfvar("databricks_connectivity_enabled", "glue_federation")
        lab = ctx.tfvar("enabled", "lab_check")
        if uc != "false" or glue == "true" or lab != "false":
            return "required", "the configuration manages workspace-level Databricks resources"
        return "recommended", "needed later so destroy can terminate workspace clusters"
    return "not_required", "no workspace-level Databricks resources are managed"


def check_databricks_workspace(ctx: Context) -> None:
    requirement, detail = workspace_auth_requirement(ctx)
    failure_status = "login_required" if requirement == "required" else "recommended"
    url = ctx.workspace_url
    if ctx.db_workspace_profile:
        profile = {"profile": ctx.db_workspace_profile, "source": ctx.db_workspace_profile_source}
        if not url:
            record(ctx, "databricks_workspace", "not_required", f"{detail}; profile '{ctx.db_workspace_profile}' is verified once it exists", "", **profile)
            return
        if requirement == "not_required":
            record(ctx, "databricks_workspace", "not_required", detail, "", profile=ctx.db_workspace_profile, workspace_url=url)
            return
        state = clis.databricks_workspace_profile_state(ctx, ctx.db_workspace_profile, url)
        if state.state == "mismatch":
            record(ctx, "databricks_workspace", "mismatch",
                   f"Databricks profile '{ctx.db_workspace_profile}' ({ctx.db_workspace_profile_source}) targets {state.host}, but this deployment's workspace is {url}",
                   f"./infra setup {ctx.cloud} {ctx.display_vars} --workspace-profile <new-profile-name>", **profile, workspace_url=url)
        elif state.state in ("missing", "expired"):
            record(ctx, "databricks_workspace", failure_status,
                   f"Databricks workspace profile '{ctx.db_workspace_profile}' is {state.state} for {url} ({detail})", ctx.setup_fix(),
                   **profile, workspace_url=url)
        else:
            record(ctx, "databricks_workspace", "ok", f"{url} (profile {ctx.db_workspace_profile} from {ctx.db_workspace_profile_source})", "",
                   **profile, workspace_url=url)
        return
    if requirement == "not_required":
        record(ctx, "databricks_workspace", "not_required", detail, "", workspace_url=url)
        return
    if ctx.db_mode == "profile" and not ctx.db_account_ok:
        record(ctx, "databricks_workspace", "skipped", "requires a valid Databricks account session", "", workspace_url=url)
        return
    if clis.workspace_accepts_account_credentials(ctx, url):
        ctx.ws_via_account = True
        record(ctx, "databricks_workspace", "ok", f"{url} accepts the account-level credentials", "", workspace_url=url, source="account")
        return
    record(ctx, "databricks_workspace", failure_status, f"{url} needs a workspace OAuth login ({detail})", ctx.setup_fix(), workspace_url=url)


def run_auth_checks(ctx: Context, action: str = "check") -> None:
    resolve_auth(ctx, action)
    check_tools(ctx, ctx.cloud)
    if ctx.checks[0]["status"] == "missing_tool":
        return
    check_target(ctx)
    if ctx.checks[-1]["status"] == "mismatch" and ctx.target:
        return  # account checks are meaningless until the target resolves
    if ctx.cloud == "aws":
        check_aws(ctx)
    else:
        check_azure(ctx)
    check_databricks_account(ctx)
    check_databricks_workspace(ctx)
    check_metastore(ctx)


# --- Terraform context ----------------------------------------------------------


def build_terraform_context(ctx: Context) -> None:
    # Resource names default to the deployment ID when tfvars omit name_prefix.
    args = [f"-var=deployment_id={ctx.id}"]
    if ctx.target:
        fields = ("aws_account_id", "databricks_account_id", "region") if ctx.cloud == "aws" else ("databricks_account_id", "location")
        for field in fields:
            if not ctx.tfvar(field) and ctx.target_value(field):
                args.append(f"-var={field}={ctx.target_value(field)}")
    if ctx.cloud == "aws":
        if ctx.aws_profile:
            args.append(f"-var=aws_profile={ctx.aws_profile}")
        if ctx.db_mode == "profile":
            args.append(f"-var=databricks_profile={ctx.db_account_profile}")
        if ctx.db_workspace_profile:
            args.append(f"-var=databricks_workspace_profile={ctx.db_workspace_profile}")
        context = (f"cloud=aws\naws_account={ctx.aws_account}\naws_principal={ctx.aws_arn}\naws_profile={ctx.aws_profile}\n"
                   f"aws_region={ctx.aws_region}\ndatabricks_account={ctx.db_account_id}\ndatabricks_mode={ctx.db_mode}\n"
                   f"databricks_account_profile={ctx.db_account_profile}\ndatabricks_workspace_profile={ctx.db_workspace_profile}\n")
    else:
        args.append(f"-var=subscription_id={ctx.az_subscription}")
        if ctx.az_tenant:
            args.append(f"-var=tenant_id={ctx.az_tenant}")
        if ctx.db_mode == "profile":
            args.append(f"-var=databricks_account_profile={ctx.db_account_profile}")
        if ctx.db_workspace_profile:
            args.append(f"-var=databricks_workspace_profile={ctx.db_workspace_profile}")
        if ctx.db_auth_type:
            args.append(f"-var=databricks_auth_type={ctx.db_auth_type}")
        context = (f"cloud=azure\nsubscription={ctx.az_subscription}\ntenant={ctx.az_tenant}\nprincipal={ctx.az_principal}\n"
                   f"principal_type={ctx.az_principal_type}\ndatabricks_account={ctx.db_account_id}\ndatabricks_mode={ctx.db_mode}\n"
                   f"databricks_account_profile={ctx.db_account_profile}\ndatabricks_workspace_profile={ctx.db_workspace_profile}\n")
    ctx.tf_args = args
    ctx.context_sha = text_sha256(context)


# --- reporting --------------------------------------------------------------------

TAGS = {"ok": "ok", "not_required": "n/a", "skipped": "skipped", "recommended": "warn", "login_required": "login", "mismatch": "mismatch",
        "unpinned": "unpinned", "choice_required": "choose", "not_found": "not found", "denied": "denied", "missing_tool": "missing"}


def print_checks(ctx: Context, write=out) -> None:
    for check in ctx.checks:
        tag = "[" + TAGS.get(check["status"], check["status"]) + "]"
        write(f"  {tag:<10} {check['id']:<21} {check['detail']}")
    for warning in ctx.warnings:
        err(f"WARNING: {warning}")


def next_action(ctx: Context):
    groups = (("missing_tool",), ("mismatch", "denied", "unpinned"), ("choice_required", "not_found"), ("login_required",))
    for group in groups:
        for check in ctx.checks:
            if check["status"] in group:
                return {"check": check["id"], "status": check["status"], "command": check.get("fix"),
                        "browser_login": check["status"] == "login_required", "detail": check["detail"]}
    return None


def print_next_action(ctx: Context, write=out) -> None:
    action = next_action(ctx)
    if action is None:
        return
    command = action["command"] or ""
    if action["browser_login"]:
        write(f"Next step ({action['check']}): {command}")
        write("  This opens a browser login for you to complete; credentials stay in the CLI caches.")
    elif command:
        write(f"Next step ({action['check']}): {command}")


def json_report(ctx: Context, code: int) -> str:
    report = {
        "version": 1, "cloud": ctx.cloud, "deployment_id": ctx.id or None, "tfvars": ctx.display_vars or None,
        "ready": code == 0, "exit_code": code, "checks": ctx.checks, "warnings": ctx.warnings, "next_action": next_action(ctx),
    }
    return json.dumps(report, indent=2, ensure_ascii=False)


def preflight(ctx: Context, action: str = "check", write=out) -> None:
    run_auth_checks(ctx, action)
    code = checks_exit_code(ctx)
    write("Authentication checks:")
    print_checks(ctx, write)
    if code != 0:
        print_next_action(ctx, err)
        raise Exit(code, "authentication preflight failed; nothing was changed.")
    build_terraform_context(ctx)
    write("Authentication preflight passed.")


def doctor_command(ctx: Context, cloud: str, args: list) -> int:
    vars_path, json_mode, wait_seconds = "", False, 0
    while args:
        arg = args.pop(0)
        if arg == "--json":
            json_mode = True
        elif arg == "--wait":
            if not args or not is_seconds(args[0]):
                die("--wait requires a number of seconds")
            wait_seconds = int(args.pop(0))
        elif arg.startswith("-"):
            die(f"unknown doctor option: {arg}")
        elif vars_path:
            raise Usage()
        else:
            vars_path = arg
    cloud_root(cloud)
    ctx.cloud = cloud
    if not vars_path:
        ctx.reset_auth()
        check_tools(ctx, cloud)
        code = checks_exit_code(ctx)
    else:
        ctx.prepare(cloud, vars_path)
        started = time.time()
        while True:
            run_auth_checks(ctx, "check")
            code = checks_exit_code(ctx)
            if code != EXIT_LOGIN_REQUIRED or wait_seconds <= 0 or time.time() - started >= wait_seconds:
                break
            if not json_mode:
                err(f"Waiting for authentication to complete ({int(wait_seconds - (time.time() - started))}s left)...")
            time.sleep(env_int("STS_INFRA_WAIT_INTERVAL", 5))
    if json_mode:
        out(json_report(ctx, code))
    else:
        if vars_path:
            out(f"Authentication for {cloud}/{ctx.id} ({ctx.display_vars}):")
        else:
            out(f"Tooling for {cloud} (pass an environment tfvars file to check authentication):")
        print_checks(ctx)
        if code == 0:
            out("Ready.")
        else:
            print_next_action(ctx)
    return code
