"""./infra setup: reuse, discover, or create profiles and run the browser logins.

Only profile names and account identifiers are saved; credentials stay in the
AWS, Azure, and Databricks CLI caches.
"""
from __future__ import annotations

import re
import sys

from . import authconfig, clis
from .auth import resolve_auth
from .common import EXIT_IDENTITY_MISMATCH, EXIT_LOGIN_REQUIRED, EXIT_MISSING_TOOL, EXIT_USAGE, die, err, out, parse_json
from .context import Context, tool_available

FLAGS = {"--yes": "assume_yes", "-y": "assume_yes", "--no-databricks-profile": "no_databricks_profile", "--skip-workspace": "skip_workspace",
         "--workspace-login": "workspace_login", "--no-workspace-profile": "no_workspace_profile", "--device-code": "device_code", "--force-login": "force_login"}
VALUES = {"--aws-profile": "aws_profile", "--aws-account-id": "aws_account_id", "--sso-start-url": "sso_start_url", "--sso-region": "sso_region",
          "--sso-role-name": "sso_role_name", "--sso-session": "sso_session", "--databricks-profile": "databricks_profile",
          "--workspace-profile": "workspace_profile", "--tenant": "tenant"}


class Options:
    def __init__(self, args):
        for name in FLAGS.values():
            setattr(self, name, False)
        for name in VALUES.values():
            setattr(self, name, "")
        args = list(args)
        while args:
            arg = args.pop(0)
            if arg in FLAGS:
                setattr(self, FLAGS[arg], True)
            elif arg in VALUES:
                if not args or not args[0]:
                    die(f"{arg} requires a value")
                setattr(self, VALUES[arg], args.pop(0))
            else:
                die(f"unknown setup option: {arg}")

    def interactive(self) -> bool:
        return not self.assume_yes and sys.stdin.isatty()


def choose_value(options: Options, label: str, default: str, flag: str) -> str:
    if not options.interactive():
        if not default:
            die(f"{label} is required; pass {flag} <value>", EXIT_USAGE)
        err(f"{label}: {default}")
        return default
    sys.stderr.write(f"{label} [{default}]: " if default else f"{label}: ")
    sys.stderr.flush()
    line = sys.stdin.readline()
    if not line:
        die(f"setup input ended before {label} was provided")
    value = line.rstrip("\n") or default
    if not value:
        die(f"{label} is required")
    return value


def require_tools(*tools) -> None:
    missing = [tool for tool in tools if not tool_available(tool)]
    if missing:
        die(f"missing required tools: {' '.join(missing)}", EXIT_MISSING_TOOL)


def create_aws_profile(ctx: Context, options: Options, profile: str) -> None:
    account = options.aws_account_id or ctx.aws_expected_account
    start_url = options.sso_start_url or ctx.target_value("aws_sso.start_url") or authconfig.aws_sso_value("start_url")
    sso_region = options.sso_region or ctx.target_value("aws_sso.region") or authconfig.aws_sso_value("region")
    role = options.sso_role_name or ctx.target_value("aws_sso.role_name") or authconfig.aws_sso_value("role_name")
    session = options.sso_session or authconfig.aws_sso_value("session") or "sts-infra"
    if account and start_url and sso_region and role:
        if not re.fullmatch(r"[0-9]{12}", account):
            die(f"AWS account ID must be 12 digits: {account}")
        clis.write_aws_sso_profile(ctx, profile, account, role, session, start_url, sso_region)
        authconfig.save_aws_sso_defaults(session, start_url, sso_region, role)
        return
    if options.interactive():
        err(f"AWS profile '{profile}' is not configured; starting the AWS IAM Identity Center wizard.")
        code, _ = clis.aws_cmd(ctx, "configure", "sso", "--profile", profile, stdout="inherit")
        if code != 0:
            die("AWS SSO profile configuration failed")
        return
    die(f"AWS profile '{profile}' is not configured. Pass --sso-start-url, --sso-region, and --sso-role-name "
        f"(plus aws_account_id in {ctx.display_vars} or --aws-account-id), or rerun setup in a terminal to use the AWS SSO wizard.", EXIT_LOGIN_REQUIRED)


def ensure_databricks_account_profile(ctx: Context, profile: str, probe: str) -> None:
    state = clis.databricks_account_profile_state(ctx, profile, ctx.db_host, ctx.db_account_id, probe)
    if state.state == "ok":
        return
    if state.state == "mismatch":
        die(f"Databricks profile '{profile}' already targets {state.host or 'another host'} account {state.account or '(none)'}; "
            "choose another --databricks-profile so it is not overwritten", EXIT_IDENTITY_MISMATCH)
    skip_flag = clis.databricks_login_skip_workspace_flag(ctx)
    err(f"Starting Databricks OAuth login for account {ctx.db_account_id}, profile '{profile}'. Complete it in your browser.")
    args = ["auth", "login", "--host", ctx.db_host, "--account-id", ctx.db_account_id, "--profile", profile] + ([skip_flag] if skip_flag else [])
    code, _ = clis.databricks_cli(ctx, *args, stdout="stderr")
    if code != 0:
        die("Databricks OAuth login failed", EXIT_LOGIN_REQUIRED)
    if clis.databricks_account_profile_state(ctx, profile, ctx.db_host, ctx.db_account_id, probe).state != "ok":
        die(f"Databricks account session verification failed for profile '{profile}'", EXIT_LOGIN_REQUIRED)


def profile_fits(ctx: Context, name: str, workspace_url: str) -> bool:
    """True when the profile does not exist yet or already targets this workspace."""
    entry = clis.databricks_profile_entry(ctx, name)
    return entry is None or clis.normalize_host(entry.get("host") or "") == clis.normalize_host(workspace_url)


def unused_workspace_profile_name(ctx: Context, workspace_url: str) -> str:
    deployment = ctx.id[len("sts-"):] if ctx.id.startswith("sts-") else ctx.id
    base = f"sts-{deployment}-workspace"
    for suffix in [""] + [f"-{n}" for n in range(2, 100)]:
        if profile_fits(ctx, base + suffix, workspace_url):
            return base + suffix
    return base


def setup_workspace_profile(ctx: Context, options: Options, workspace_url: str) -> str:
    """The chosen workspace profile, or '' when the account-level credentials already work there."""
    default = options.workspace_profile or ctx.db_workspace_profile
    if not default and not options.workspace_login and clis.workspace_accepts_account_credentials(ctx, workspace_url):
        err(f"Databricks workspace: {workspace_url} accepts the account-level credentials; no separate login is needed.")
        return ""
    if default and not options.workspace_profile and not profile_fits(ctx, default, workspace_url):
        # A saved profile for an earlier, destroyed workspace of this
        # deployment: leave it alone and pick a name that fits this workspace.
        err(f"Saved workspace profile '{default}' targets another workspace; choosing a new profile for {workspace_url}.")
        default = ""
    default = default or clis.discover_workspace_profile(ctx, workspace_url) or unused_workspace_profile_name(ctx, workspace_url)
    name = choose_value(options, "Databricks workspace profile", default, "--workspace-profile")
    state = clis.databricks_workspace_profile_state(ctx, name, workspace_url)
    if state.state == "mismatch":
        die(f"Databricks profile '{name}' targets {state.host}, not {workspace_url}; choose another --workspace-profile", EXIT_IDENTITY_MISMATCH)
    if state.state != "ok":
        err(f"Starting Databricks OAuth login for workspace {workspace_url}, profile '{name}'. Complete it in your browser.")
        code, _ = clis.databricks_cli(ctx, "auth", "login", "--host", workspace_url, "--profile", name, stdout="stderr")
        if code != 0:
            die("Databricks workspace OAuth login failed", EXIT_LOGIN_REQUIRED)
        if clis.databricks_workspace_profile_state(ctx, name, workspace_url).state != "ok":
            die(f"Databricks workspace session verification failed for profile '{name}'", EXIT_LOGIN_REQUIRED)
    err(f"Databricks workspace: {workspace_url} (profile: {name})")
    return name


def setup_aws(ctx: Context, vars_path: str, options: Options) -> None:
    ctx.prepare("aws", vars_path)
    require_tools("aws", "databricks")
    authconfig.validate()
    resolve_auth(ctx, "setup")
    clis.scrub_aws(ctx)
    clis.scrub_databricks(ctx)
    device = ["--use-device-code"] if options.device_code else []

    out(f"Authentication setup for aws/{ctx.id} ({ctx.display_vars}).")
    out("Only profile names and account identifiers are saved; credentials stay in the AWS and Databricks CLI caches.")

    aws_default = options.aws_profile or ctx.aws_profile
    if not aws_default and ctx.aws_expected_account:
        aws_default = clis.discover_aws_profile(ctx.aws_expected_account) or f"sts-aws-{ctx.aws_expected_account}"
    aws_profile = choose_value(options, "AWS CLI profile", aws_default, "--aws-profile")
    ctx.aws_profile = aws_profile
    if not clis.aws_profile_exists(ctx, aws_profile):
        create_aws_profile(ctx, options, aws_profile)
    code, text = (1, "") if options.force_login else clis.aws_cli(ctx, "sts", "get-caller-identity", "--output", "json", stderr="null")
    if code != 0:
        out(f"Starting AWS IAM Identity Center login for profile '{aws_profile}'. Complete it in your browser.")
        login_code, _ = clis.aws_cmd(ctx, "sso", "login", "--profile", aws_profile, *device, stdout="inherit")
        if login_code != 0:
            die("AWS SSO login failed", EXIT_LOGIN_REQUIRED)
        code, text = clis.aws_cli(ctx, "sts", "get-caller-identity", "--output", "json")
        if code != 0:
            die(f"AWS session verification failed for profile '{aws_profile}'", EXIT_LOGIN_REQUIRED)
    identity = parse_json(text, {}) or {}
    ctx.aws_account = identity.get("Account") or "" if isinstance(identity, dict) else ""
    ctx.aws_arn = identity.get("Arn") or "" if isinstance(identity, dict) else ""
    if not ctx.aws_account:
        die("could not determine the authenticated AWS account")
    if ctx.aws_expected_account and ctx.aws_expected_account != ctx.aws_account and ctx.setting_value("aws_account_id"):
        die(f"profile '{aws_profile}' authenticates to AWS account {ctx.aws_account}, but {ctx.aws_expected_source} expects {ctx.aws_expected_account}",
            EXIT_IDENTITY_MISMATCH)
    out(f"AWS: account {ctx.aws_account} as {ctx.aws_arn} (profile: {aws_profile})")

    out(f"Databricks account: {ctx.db_account_id} (from {ctx.display_vars})")
    db_default = (options.databricks_profile or ctx.db_account_profile
                  or clis.discover_databricks_account_profile(ctx, ctx.db_host, ctx.db_account_id, "workspaces")
                  or f"sts-aws-account-{ctx.db_account_id.split('-', 1)[0]}")
    db_profile = choose_value(options, "Databricks account profile", db_default, "--databricks-profile")
    ensure_databricks_account_profile(ctx, db_profile, "workspaces")
    ctx.db_account_profile = db_profile
    ctx.db_mode = "profile"
    out(f"Databricks account: verified (profile: {db_profile})")

    if options.skip_workspace:
        workspace_profile = ctx.db_workspace_profile
    elif ctx.workspace_url:
        workspace_profile = setup_workspace_profile(ctx, options, ctx.workspace_url)
    else:
        workspace_profile = options.workspace_profile
        out("Databricks workspace: not created yet. After the apply that creates it, rerun this command to add the workspace login.")

    authconfig.save_deployment(f"aws/{ctx.id}", [
        ("aws_profile", aws_profile), ("aws_account_id", ctx.aws_account), ("databricks_account_id", ctx.db_account_id),
        ("databricks_account_profile", db_profile), ("databricks_workspace_profile", workspace_profile),
    ])
    authconfig.save_account(f"aws/{ctx.aws_account}", "aws_profile", aws_profile)
    authconfig.save_account(f"databricks/aws/{ctx.db_account_id}", "databricks_account_profile", db_profile)
    out(f"Authentication setup complete. Local mapping: {authconfig.auth_config_path()}")
    out(f"Verify at any time with: ./infra doctor aws {ctx.display_vars}")


def azure_session_ready(ctx: Context) -> bool:
    code, _ = ctx.call(["az", "account", "show", "--subscription", ctx.az_subscription, "--output", "json"], stdout="null", stderr="null")
    if code != 0:
        return False
    code, _ = ctx.call(["az", "account", "get-access-token", "--subscription", ctx.az_subscription, "--query", "expiresOn", "--output", "tsv"],
                       stdout="null", stderr="null")
    return code == 0


def setup_azure(ctx: Context, vars_path: str, options: Options) -> None:
    ctx.prepare("azure", vars_path)
    require_tools("az", "databricks")
    authconfig.validate()
    resolve_auth(ctx, "setup")
    clis.scrub_databricks(ctx)

    out(f"Authentication setup for azure/{ctx.id} ({ctx.display_vars}).")
    out("Only subscription, tenant, and profile identifiers are saved; credentials stay in the Azure and Databricks CLI caches.")

    tenant = options.tenant or ctx.az_expected_tenant
    if options.force_login or not azure_session_ready(ctx):
        args = (["--tenant", tenant] if tenant else []) + (["--use-device-code"] if options.device_code else [])
        out(f"Starting Azure CLI login{' for tenant ' + tenant if tenant else ''}. Complete it in your browser.")
        # Disable the post-login subscription picker; the subscription comes from tfvars.
        code, _ = ctx.call(["az", "login", *args, "--output", "none"], assign={"AZURE_CORE_LOGIN_EXPERIENCE_V2": "off"}, stdout="inherit")
        if code != 0:
            die("Azure login failed", EXIT_LOGIN_REQUIRED)
    code, text = ctx.call(["az", "account", "show", "--subscription", ctx.az_subscription, "--output", "json"], stderr="null")
    if code != 0:
        die(f"the signed-in Azure identity cannot access subscription {ctx.az_subscription}" + (f" in tenant {tenant}" if tenant else ""),
            EXIT_IDENTITY_MISMATCH)
    code, _ = ctx.call(["az", "account", "get-access-token", "--subscription", ctx.az_subscription, "--query", "expiresOn", "--output", "tsv"],
                       stdout="null", stderr="null")
    if code != 0:
        die(f"Azure session verification failed for subscription {ctx.az_subscription}", EXIT_LOGIN_REQUIRED)
    show = parse_json(text, {})
    show = show if isinstance(show, dict) else {}
    ctx.az_tenant = show.get("tenantId") or ""
    ctx.az_principal = (show.get("user") or {}).get("name") or "" if isinstance(show.get("user"), dict) else ""
    if tenant and tenant != ctx.az_tenant:
        die(f"subscription {ctx.az_subscription} belongs to tenant {ctx.az_tenant}, not {tenant}", EXIT_IDENTITY_MISMATCH)
    ctx.az_ok = True
    out(f"Azure: subscription {ctx.az_subscription} in tenant {ctx.az_tenant} as {ctx.az_principal or 'unknown principal'}")

    db_profile = ""
    if ctx.db_account_id:
        out(f"Databricks account: {ctx.db_account_id} (from {ctx.display_vars})")
        db_default = "" if options.no_databricks_profile else (options.databricks_profile or ctx.db_account_profile)
        if db_default:
            db_profile = choose_value(options, "Azure Databricks account profile", db_default, "--databricks-profile")
            ensure_databricks_account_profile(ctx, db_profile, "metastores")
            ctx.db_account_profile = db_profile
            ctx.db_mode = "profile"
            out(f"Databricks account: verified (profile: {db_profile})")
        else:
            ctx.db_mode = "azure-cli"
            ctx.db_auth_type = "azure-cli"
            if not clis.databricks_account_probe(ctx, "metastores"):
                die(f"the Azure CLI identity cannot call the Azure Databricks account API for account {ctx.db_account_id}. Use an account admin identity, "
                    "or pass --databricks-profile <name> to use a separate Databricks OAuth login.", EXIT_IDENTITY_MISMATCH)
            out("Databricks account: verified with the Azure CLI identity (no separate Databricks login needed)")

    if options.no_workspace_profile:
        workspace_profile = ""
        out("Databricks workspace: uses the Azure CLI identity through the workspace resource ID (saved workspace profile removed).")
    elif options.skip_workspace:
        workspace_profile = ctx.db_workspace_profile
    elif options.workspace_profile or ctx.db_workspace_profile:
        if ctx.workspace_url:
            workspace_profile = setup_workspace_profile(ctx, options, ctx.workspace_url)
        else:
            workspace_profile = options.workspace_profile or ctx.db_workspace_profile
    else:
        workspace_profile = ""
        out("Databricks workspace: uses the Azure CLI identity through the workspace resource ID.")

    authconfig.save_deployment(f"azure/{ctx.id}", [
        ("azure_subscription_id", ctx.az_subscription), ("azure_tenant_id", ctx.az_tenant), ("databricks_account_id", ctx.db_account_id),
        ("databricks_account_profile", db_profile), ("databricks_workspace_profile", workspace_profile),
    ])
    if ctx.db_account_id:
        authconfig.save_account(f"databricks/azure/{ctx.db_account_id}", "databricks_account_profile", db_profile)
    out(f"Authentication setup complete. Local mapping: {authconfig.auth_config_path()}")
    out(f"Verify at any time with: ./infra doctor azure {ctx.display_vars}")


def setup_command(ctx: Context, cloud: str, vars_path: str, args) -> None:
    options = Options(args)
    if options.no_workspace_profile and cloud != "azure":
        die("--no-workspace-profile is Azure only: AWS workspaces need their own OAuth login")
    if cloud == "aws":
        setup_aws(ctx, vars_path, options)
    else:
        setup_azure(ctx, vars_path, options)
