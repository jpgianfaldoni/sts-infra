"""Shared constants, errors, and small helpers for the ./infra CLI."""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from pathlib import Path

# lib/sts_infra/common.py -> repository root. Paths stay logical (symlinks in
# parent directories are kept) so displayed paths match what the user typed.
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

EXIT_USAGE = 2
EXIT_LOGIN_REQUIRED = 10
EXIT_IDENTITY_MISMATCH = 11
EXIT_MISSING_TOOL = 12
EXIT_VERIFY_FAILED = 13

AWS_DATABRICKS_ACCOUNTS_HOST = "https://accounts.cloud.databricks.com"
AZURE_DATABRICKS_ACCOUNTS_HOST = "https://accounts.azuredatabricks.net"
# Ambient credentials that would compete with an explicitly selected profile.
AWS_STATIC_CREDENTIAL_VARS = ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_SECURITY_TOKEN")
DATABRICKS_CREDENTIAL_VARS = (
    "DATABRICKS_CONFIG_PROFILE", "DATABRICKS_HOST", "DATABRICKS_ACCOUNT_ID", "DATABRICKS_WORKSPACE_ID",
    "DATABRICKS_TOKEN", "DATABRICKS_CLIENT_ID", "DATABRICKS_CLIENT_SECRET", "DATABRICKS_AUTH_TYPE",
    "DATABRICKS_USERNAME", "DATABRICKS_PASSWORD", "DATABRICKS_AZURE_RESOURCE_ID",
)
# Any of these means Azure automation supplies its own Databricks credentials.
AZURE_DATABRICKS_AUTOMATION_VARS = ("DATABRICKS_TOKEN", "DATABRICKS_CLIENT_ID", "DATABRICKS_AUTH_TYPE", "ARM_CLIENT_ID", "ARM_USE_MSI", "ARM_USE_OIDC")
AUTH_DEPLOYMENT_FIELDS = (
    "aws_account_id", "aws_profile", "azure_subscription_id", "azure_tenant_id",
    "databricks_account_id", "databricks_account_profile", "databricks_workspace_profile",
)
CLOUDS = ("aws", "azure")
# Terraform resource addresses, including indexes such as ["name"] and [0].
ADDRESS_PATTERN = re.compile(r'^[][A-Za-z0-9_."-]+$')
DEPLOYMENT_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


class Exit(Exception):
    """Stop the command with an exit code, optionally after printing ERROR: <message>."""

    def __init__(self, code: int, message: str | None = None):
        super().__init__(message or "")
        self.code = code
        self.message = message


class Usage(Exception):
    """Print the usage text and exit 2."""


def die(message: str, code: int = 1):
    raise Exit(code, message)


def out(text: str = "") -> None:
    sys.stdout.write(text + "\n")
    sys.stdout.flush()


def err(text: str = "") -> None:
    sys.stdout.flush()
    sys.stderr.write(text + "\n")
    sys.stderr.flush()


def is_seconds(value: str) -> bool:
    """A non-negative whole number of seconds, like the shell's ^[0-9]+$."""
    return re.fullmatch(r"[0-9]+", value) is not None


def env_int(name: str, default: int) -> int:
    value = os.environ.get(name, "")
    return int(value) if is_seconds(value) else default


def file_sha256(path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def text_sha256(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def normalize_host(host: str) -> str:
    host = host or ""
    if host.endswith("/"):  # one trailing slash, like ${host%/}
        host = host[:-1]
    if host and not host.startswith(("http://", "https://")):
        host = "https://" + host
    return host.lower()


def version_at_least(have: str, need: str) -> bool:
    have = re.split(r"[-+]", have, maxsplit=1)[0]

    def parts(text):
        values = []
        for piece in (text.split(".") + ["0", "0", "0"])[:3]:
            values.append(int(piece) if piece.isdigit() else 0)
        return values

    return parts(have) >= parts(need)


def parse_json(text: str, default=None):
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        return default


def write_private(path, text: str) -> None:
    """Write a file readable by the owner only (umask 077)."""
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(text)


def utc_now() -> str:
    import time

    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def items_of(value, *keys):
    """A list response, or the first list under one of keys in an object response."""
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for key in keys:
            if isinstance(value.get(key), list):
                return value[key]
    return []
