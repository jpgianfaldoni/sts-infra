"""Wrappers for the aws, az, and databricks CLIs with credential hygiene.

When a profile is selected, ambient static credentials are removed from the
child environment so they cannot silently win over the profile.
"""
from __future__ import annotations

import json
import os
import re
import time

from .common import AWS_STATIC_CREDENTIAL_VARS, DATABRICKS_CREDENTIAL_VARS, env_int, normalize_host
from .context import Context


def scrub_aws(ctx: Context) -> None:
    ctx.aws_env_unset = AWS_STATIC_CREDENTIAL_VARS


def scrub_databricks(ctx: Context) -> None:
    ctx.db_env_unset = DATABRICKS_CREDENTIAL_VARS


def aws_cmd(ctx: Context, *args, **kwargs):
    return ctx.call(["aws", *args], unset=ctx.aws_env_unset, **kwargs)


def aws_cli(ctx: Context, *args, **kwargs):
    args = list(args)
    if ctx.aws_region:
        args += ["--region", ctx.aws_region]
    if ctx.aws_profile:
        args += ["--profile", ctx.aws_profile]
    return aws_cmd(ctx, *args, **kwargs)


def databricks_cli(ctx: Context, *args, assign=None, **kwargs):
    return ctx.call(["databricks", *args], unset=ctx.db_env_unset, assign=assign, **kwargs)


def databricks_workspace_cli(ctx: Context, workspace_url: str, *args, **kwargs):
    if ctx.db_workspace_profile:
        return databricks_cli(ctx, *args, "--profile", ctx.db_workspace_profile, **kwargs)
    if ctx.db_mode == "profile" and ctx.cloud == "aws":
        return databricks_cli(ctx, *args, "--profile", ctx.db_account_profile, assign={"DATABRICKS_HOST": workspace_url}, **kwargs)
    if ctx.db_auth_type == "azure-cli":
        return databricks_cli(ctx, *args, assign={"DATABRICKS_HOST": workspace_url, "DATABRICKS_AUTH_TYPE": "azure-cli"}, **kwargs)
    return databricks_cli(ctx, *args, assign={"DATABRICKS_HOST": workspace_url}, **kwargs)


def databricks_account_cli(ctx: Context, *args, **kwargs):
    if ctx.db_mode == "profile":
        return databricks_cli(ctx, *args, "--profile", ctx.db_account_profile, **kwargs)
    assign = {"DATABRICKS_HOST": ctx.db_host, "DATABRICKS_ACCOUNT_ID": ctx.db_account_id}
    if ctx.db_mode == "azure-cli":
        assign["DATABRICKS_AUTH_TYPE"] = "azure-cli"
        if ctx.az_tenant:
            assign["ARM_TENANT_ID"] = ctx.az_tenant
    return databricks_cli(ctx, *args, assign=assign, **kwargs)


def retry_delay() -> int:
    return env_int("STS_INFRA_RETRY_DELAY", 2)


def databricks_account_probe(ctx: Context, probe: str) -> bool:
    for attempt in (1, 2):
        code, _ = databricks_account_cli(ctx, "account", probe, "list", "--output", "json", stdout="null", stderr="null")
        if code == 0:
            return True
        if attempt == 1:
            time.sleep(retry_delay())
    return False


def databricks_profiles(ctx: Context) -> list:
    code, text = databricks_cli(ctx, "auth", "profiles", "--skip-validate", "--output", "json", stderr="null")
    try:
        profiles = (json.loads(text) or {}).get("profiles") or [] if code == 0 else []
    except (ValueError, AttributeError):
        profiles = []
    return [p for p in profiles if isinstance(p, dict)]


def databricks_profile_entry(ctx: Context, name: str):
    return next((p for p in databricks_profiles(ctx) if p.get("name") == name), None)


class ProfileState:
    def __init__(self, state: str, host: str = "", account: str = ""):
        self.state, self.host, self.account = state, host, account


def databricks_account_profile_state(ctx: Context, profile: str, host: str, account: str, probe: str) -> ProfileState:
    entry = databricks_profile_entry(ctx, profile)
    if entry is None:
        return ProfileState("missing")
    profile_host, profile_account = entry.get("host") or "", entry.get("account_id") or ""
    if normalize_host(profile_host) != normalize_host(host) or profile_account != account:
        return ProfileState("mismatch", profile_host, profile_account)
    for attempt in (1, 2):
        code, _ = databricks_cli(ctx, "account", probe, "list", "--profile", profile, "--output", "json", stdout="null", stderr="null")
        if code == 0:
            return ProfileState("ok", profile_host, profile_account)
        if attempt == 1:
            time.sleep(retry_delay())
    return ProfileState("expired", profile_host, profile_account)


def databricks_workspace_profile_state(ctx: Context, profile: str, workspace_url: str) -> ProfileState:
    entry = databricks_profile_entry(ctx, profile)
    if entry is None:
        return ProfileState("missing")
    profile_host = entry.get("host") or ""
    if workspace_url and normalize_host(profile_host) != normalize_host(workspace_url):
        return ProfileState("mismatch", profile_host)
    code, _ = databricks_cli(ctx, "current-user", "me", "--profile", profile, "--output", "json", stdout="null", stderr="null")
    return ProfileState("ok" if code == 0 else "expired", profile_host)


def workspace_accepts_account_credentials(ctx: Context, workspace_url: str) -> bool:
    """True when the account-level credentials also authenticate to the workspace."""
    quiet = {"stdout": "null", "stderr": "null"}
    if ctx.db_mode == "profile":
        if ctx.cloud != "aws":
            return False
        code, _ = databricks_cli(ctx, "current-user", "me", "--profile", ctx.db_account_profile, "--output", "json",
                                 assign={"DATABRICKS_HOST": workspace_url}, **quiet)
    elif ctx.db_mode == "azure-cli":
        code, _ = databricks_cli(ctx, "current-user", "me", "--output", "json",
                                 assign={"DATABRICKS_HOST": workspace_url, "DATABRICKS_AUTH_TYPE": "azure-cli"}, **quiet)
    else:
        code, _ = databricks_cli(ctx, "current-user", "me", "--output", "json", assign={"DATABRICKS_HOST": workspace_url}, **quiet)
    return code == 0


def databricks_login_skip_workspace_flag(ctx: Context) -> str:
    code, text = ctx.call(["databricks", "auth", "login", "--help"], stderr="null")
    return "--skip-workspace" if "--skip-workspace" in text else ""


def _matching_profile_names(ctx: Context, host: str, account: str | None):
    wanted = normalize_host(host)
    names = []
    for profile in databricks_profiles(ctx):
        profile_host = (profile.get("host") or "").lower()
        if profile_host.endswith("/"):  # jq rtrimstr("/") removes one slash
            profile_host = profile_host[:-1]
        if profile_host == wanted and (account is None or (profile.get("account_id") or "") == account):
            names.append(profile.get("name") or "")
    return names[:3]


def discover_databricks_account_profile(ctx: Context, host: str, account: str, probe: str) -> str:
    for name in _matching_profile_names(ctx, host, account):
        if name and databricks_account_profile_state(ctx, name, host, account, probe).state == "ok":
            return name
    return ""


def discover_workspace_profile(ctx: Context, workspace_url: str) -> str:
    for name in _matching_profile_names(ctx, workspace_url, None):
        if name and databricks_workspace_profile_state(ctx, name, workspace_url).state == "ok":
            return name
    return ""


def aws_profile_exists(ctx: Context, profile: str) -> bool:
    code, text = aws_cmd(ctx, "configure", "list-profiles", stderr="null")
    return profile in text.splitlines()


def aws_configure_get(ctx: Context, key: str, profile: str) -> str:
    code, text = aws_cmd(ctx, "configure", "get", key, "--profile", profile, stderr="null")
    return text.strip() if code == 0 else ""


def aws_sso_session_minutes_left(ctx: Context, profile: str) -> str:
    """Minutes left in a profile's IAM Identity Center session, or '' when unknown or auto-refreshed.

    Only the expiry fields of the SSO cache entry are used; tokens never leave the file.
    """
    import hashlib
    import math
    from datetime import datetime, timezone

    key = aws_configure_get(ctx, "sso_session", profile) or aws_configure_get(ctx, "sso_start_url", profile)
    if not key:
        return ""
    cache = os.path.join(os.environ.get("HOME", ""), ".aws", "sso", "cache", hashlib.sha1(key.encode()).hexdigest() + ".json")
    try:
        with open(cache) as handle:
            entry = json.load(handle)
    except (OSError, ValueError):
        return ""
    if not isinstance(entry, dict) or entry.get("refreshToken"):
        return ""
    expires = entry.get("expiresAt")
    if not isinstance(expires, str):
        return ""
    expires = re.sub(r"\.[0-9]+Z$", "Z", re.sub(r"UTC$", "Z", expires))
    try:
        moment = datetime.strptime(expires, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return ""
    return str(math.floor((moment.timestamp() - time.time()) / 60))


def discover_aws_profile(account: str) -> str:
    """A configured AWS profile for an account, found from non-secret config keys."""
    config = os.environ.get("AWS_CONFIG_FILE") or os.path.join(os.environ.get("HOME", ""), ".aws", "config")
    try:
        lines = open(config).read().splitlines()
    except OSError:
        return ""
    name = ""
    for line in lines:
        if re.match(r"^\s*\[", line):
            name = ""
            match = re.match(r"^\s*\[profile\s+([^]]+)\]", line)
            if match:
                name = match.group(1)
            elif re.match(r"^\s*\[default\]", line):
                name = "default"
            continue
        if name and re.match(rf"^\s*sso_account_id\s*=\s*{re.escape(account)}\s*$", line):
            return name
        if name and re.match(rf"^\s*role_arn\s*=.*:iam::{re.escape(account)}:", line):
            return name
    return ""


def write_aws_sso_profile(ctx: Context, profile: str, account: str, role: str, session: str, start_url: str, sso_region: str) -> None:
    from .common import err

    config = os.environ.get("AWS_CONFIG_FILE") or os.path.join(os.environ.get("HOME", ""), ".aws", "config")
    old_umask = os.umask(0o077)
    try:
        os.makedirs(os.path.dirname(config) or ".", exist_ok=True)
        open(config, "a").close()
    finally:
        os.umask(old_umask)
    with open(config) as handle:
        existing = handle.read()
    if f"[sso-session {session}]" not in existing.splitlines():
        with open(config, "a") as handle:
            if existing:
                handle.write("\n")
            handle.write(f"[sso-session {session}]\nsso_start_url = {start_url}\nsso_region = {sso_region}\nsso_registration_scopes = sso:account:access\n")
    for key, value in (("sso_session", session), ("sso_account_id", account), ("sso_role_name", role), ("region", ctx.aws_region)):
        aws_cmd(ctx, "configure", "set", key, value, "--profile", profile, stdout="inherit")
    err(f"Configured AWS profile '{profile}' for account {account} (role {role}, SSO session {session}).")
