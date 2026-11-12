"""The local authentication mapping: profile names and account identifiers only.

~/.config/sts-infra/auth.json (or STS_INFRA_AUTH_CONFIG) records which AWS and
Databricks CLI profiles each deployment and account uses. It never holds a
credential; validation rejects any field outside the known set.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

from .common import AUTH_DEPLOYMENT_FIELDS, die

ACCOUNT_FIELDS = {"aws_profile", "databricks_account_profile"}
SSO_FIELDS = {"region", "role_name", "session", "start_url"}
TOP_LEVEL_FIELDS = {"accounts", "aws_sso", "deployments", "version"}


def auth_config_path() -> str:
    if os.environ.get("STS_INFRA_AUTH_CONFIG"):
        return os.environ["STS_INFRA_AUTH_CONFIG"]
    if os.environ.get("XDG_CONFIG_HOME"):
        return f"{os.environ['XDG_CONFIG_HOME']}/sts-infra/auth.json"
    home = os.environ.get("HOME")
    if not home:
        die("HOME is required to locate the local authentication config")
    return f"{home}/.config/sts-infra/auth.json"


def targets_path() -> str:
    if os.environ.get("STS_INFRA_TARGETS"):
        return os.environ["STS_INFRA_TARGETS"]
    return str(Path(auth_config_path()).parent / "targets.json")


def _nonempty_strings(mapping) -> bool:
    return all(isinstance(value, str) and value for value in mapping.values())


def _valid(data) -> bool:
    if not isinstance(data, dict) or data.get("version") != 1 or not set(data) <= TOP_LEVEL_FIELDS:
        return False
    deployments = data.get("deployments")
    if not isinstance(deployments, dict):
        return False
    for entry in deployments.values():
        if not (isinstance(entry, dict) and set(entry) <= set(AUTH_DEPLOYMENT_FIELDS) and _nonempty_strings(entry)):
            return False
    accounts = data.get("accounts") or {}
    if not isinstance(accounts, dict):
        return False
    for entry in accounts.values():
        if not (isinstance(entry, dict) and set(entry) <= ACCOUNT_FIELDS and _nonempty_strings(entry)):
            return False
    sso = data.get("aws_sso") or {}
    return isinstance(sso, dict) and set(sso) <= SSO_FIELDS and _nonempty_strings(sso)


def load(config: str | None = None) -> dict | None:
    """The validated mapping, or None when the file does not exist."""
    config = config or auth_config_path()
    if not os.path.isfile(config):
        return None
    try:
        data = json.loads(Path(config).read_text())
    except ValueError:
        data = None
    if not _valid(data):
        die(f"invalid local authentication config: {config}")
    return data


def validate(config: str | None = None) -> None:
    load(config)


def deployment_value(deployment_key: str, field: str) -> str:
    data = load() or {}
    value = (data.get("deployments") or {}).get(deployment_key, {}).get(field)
    return value if isinstance(value, str) else ""


def account_value(account_key: str, field: str) -> str:
    data = load() or {}
    value = (data.get("accounts") or {}).get(account_key, {}).get(field)
    return value if isinstance(value, str) else ""


def aws_sso_value(field: str) -> str:
    data = load() or {}
    value = (data.get("aws_sso") or {}).get(field)
    return value if isinstance(value, str) else ""


def _write(update) -> None:
    """Apply update(data) and replace the file atomically, readable by the owner only."""
    config = auth_config_path()
    data = load(config) or {"version": 1, "deployments": {}}
    update(data)
    directory = os.path.dirname(config) or "."
    old_umask = os.umask(0o077)
    try:
        os.makedirs(directory, exist_ok=True)
        temp = os.path.join(directory, f".auth.json.tmp.{os.getpid()}")
        try:
            fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as handle:
                json.dump(data, handle, indent=2)
                handle.write("\n")
            os.chmod(temp, 0o600)
            os.replace(temp, config)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)
    finally:
        os.umask(old_umask)
    validate(config)


def save_deployment(deployment_key: str, pairs) -> None:
    """Replace a deployment's mapping; empty values are omitted."""
    entry = {key: value for key, value in pairs if value}
    _write(lambda data: data["deployments"].__setitem__(deployment_key, entry))


def save_account(account_key: str, field: str, value: str) -> None:
    """Remember a profile for an account so other environments resolve it without setup."""
    if not value:
        return

    def update(data):
        if not isinstance(data.get("accounts"), dict):
            data["accounts"] = {}
        accounts = data["accounts"]
        accounts[account_key] = {**accounts.get(account_key, {}), field: value}

    _write(update)


def save_aws_sso_defaults(session: str, start_url: str, region: str, role: str) -> None:
    defaults = {"session": session, "start_url": start_url, "region": region}
    if role:
        defaults["role_name"] = role
    _write(lambda data: data.__setitem__("aws_sso", defaults))
