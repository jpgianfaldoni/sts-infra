"""Per-command state: the environment, its local state, locks, and process calls.

One Context describes the deployment a command works on (cloud, tfvars,
deployment ID, state and artifact paths) plus the authentication selection
the checks resolve. Commands share it the way the original shell script
shared globals.
"""
from __future__ import annotations

import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

from . import authconfig
from .common import DEPLOYMENT_ID_PATTERN, ROOT, Exit, die, err

import infra_scenario as scenario  # lib/ is on sys.path; owns tfvars parsing and targets


class Interrupted(Exception):
    def __init__(self, code: int):
        super().__init__(code)
        self.code = code


class Context:
    def __init__(self, command_line: str = "./infra"):
        self.command_line = command_line
        self.cloud = ""
        self.vars = ""
        self.display_vars = ""
        self.id = ""
        self.dir = ""
        self.settings: dict = {}
        self.target = ""
        self.target_fields: dict | None = None
        self.state_dir = self.state = self.binding = self.artifacts = self.tf_data = ""
        self.lock = ""
        self.active_plan = self.active_metadata = self.active_action = ""
        self.plan_stage = "complete"
        self.plan_replace: list[str] = []
        self.reset_auth()

    # --- settings ---------------------------------------------------------

    def reset_auth(self, action: str = "check") -> None:
        self.auth_action = action
        self.tf_args: list[str] = []
        self.warnings: list[str] = []
        self.checks: list[dict] = []
        self.context_sha = ""
        self.aws_region = self.aws_profile = self.aws_profile_source = ""
        self.aws_expected_account = self.aws_expected_source = self.aws_account = self.aws_arn = ""
        self.db_host = self.db_account_id = ""
        self.db_mode = "none"
        self.db_auth_type = self.db_account_profile = self.db_account_profile_source = ""
        self.db_account_ok = False
        self.db_workspace_profile = self.db_workspace_profile_source = ""
        self.workspace_url = ""
        self.ws_via_account = False
        self.az_subscription = self.az_expected_tenant = self.az_tenant = ""
        self.az_principal = self.az_principal_type = ""
        self.az_ok = False
        self.aws_env_unset: tuple = ()
        self.db_env_unset: tuple = ()

    def tfvar(self, key: str, parent: str | None = None) -> str:
        return self.settings.get((parent, key), "")

    def target_value(self, field: str) -> str:
        if not self.target or self.target_fields is None:
            return ""
        return scenario.target_value(self.target_fields, field)

    def setting_value(self, key: str, field: str | None = None) -> str:
        """A tfvars value, falling back to the target field of the same meaning."""
        return self.tfvar(key) or self.target_value(field or key)

    def deployment_value(self, field: str) -> str:
        return authconfig.deployment_value(f"{self.cloud}/{self.id}", field)

    def setup_fix(self) -> str:
        return f"./infra setup {self.cloud} {self.display_vars} --yes"

    def endpoint_approval_mode(self) -> str:
        return self.tfvar("endpoint_approval") or "auto"

    # --- environment and state --------------------------------------------

    def prepare(self, cloud: str, vars_path: str) -> None:
        self.cloud = cloud
        self.vars = absolute_file(vars_path)
        self.dir = cloud_root(cloud)
        self.id = deployment_id_for(self.vars)
        self.settings = scenario.tfvars_settings(self.vars)
        self.target = self.tfvar("target")
        self.target_fields = scenario.load_targets().get(self.target) if self.target else None
        self.state_dir = f"{ROOT}/.state/{cloud}/{self.id}"
        self.state = f"{self.state_dir}/terraform.tfstate"
        self.binding = f"{self.state_dir}/environment.path"
        self.artifacts = f"{ROOT}/.artifacts/{cloud}/{self.id}"
        self.tf_data = f"{self.artifacts}/.terraform"
        self.display_vars = self.vars[len(ROOT) + 1:] if self.vars.startswith(ROOT + "/") else self.vars

    def bind(self) -> None:
        for path in (self.state_dir, self.artifacts, self.tf_data):
            os.makedirs(path, exist_ok=True)
        link = f"{self.dir}/terraform.tfstate.d"
        target = f"{ROOT}/.state/{self.cloud}"
        if os.path.islink(link):
            if os.readlink(link) != target:
                die(f"{link} points to an unexpected state directory")
        elif os.path.exists(link):
            die(f"{link} already exists and is not managed by ./infra")
        else:
            os.symlink(target, link)
        if os.path.isfile(self.binding):
            existing = Path(self.binding).read_text().rstrip("\n")
            if existing != self.vars:
                die(f"deployment ID '{self.id}' is already bound to another environment file: {existing}")
        else:
            Path(self.binding).write_text(self.vars + "\n")

    def check_legacy_state(self) -> None:
        legacy_state = f"{self.dir}/terraform.tfstate"
        legacy_plan_path = f"{ROOT}/.artifacts/{self.cloud}/terraform.tfplan.tfvars.path"
        if not (os.path.isfile(legacy_state) and not os.path.isfile(self.state)):
            return
        if not os.path.isfile(legacy_plan_path) or Path(legacy_plan_path).read_text().rstrip("\n") == self.vars:
            die(f"legacy state exists at {legacy_state}. Migrate it explicitly with: "
                f"./infra state-migrate {self.cloud} {self.vars} --confirm migrate-{self.cloud}-{self.id}")

    def state_json(self) -> dict:
        try:
            data = json.loads(Path(self.state).read_text())
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def state_exists(self) -> bool:
        return bool(self.state) and os.path.isfile(self.state)

    def state_workspace_id(self) -> str:
        if not self.state_exists():
            return ""
        state = self.state_json()
        candidates = [((state.get("outputs") or {}).get("workspace_id") or {}).get("value")]
        ids = [
            (instance.get("attributes") or {}).get("workspace_id")
            for resource in state.get("resources") or [] if resource.get("type") == "databricks_mws_workspaces"
            for instance in resource.get("instances") or []
        ]
        candidates.append(ids[0] if ids else None)
        for value in candidates:
            text = jq_tostring(value)
            if text.strip():
                return text.split("\n", 1)[0]
        return ""

    def state_workspace_url(self) -> str:
        if not self.state_exists():
            return ""
        state = self.state_json()
        candidates = [((state.get("outputs") or {}).get("workspace_url") or {}).get("value")]
        urls = [
            (instance.get("attributes") or {}).get("workspace_url")
            for resource in state.get("resources") or []
            if resource.get("type") in ("databricks_mws_workspaces", "azurerm_databricks_workspace")
            for instance in resource.get("instances") or []
        ]
        candidates.append(urls[0] if urls else None)
        from .common import normalize_host

        for value in candidates:
            if isinstance(value, str) and value.strip():
                return normalize_host(value)
        return ""

    def state_requires_workspace_auth(self) -> bool:
        """True when state holds resources managed through the workspace-level provider."""
        if not self.state_exists():
            return False
        for resource in self.state_json().get("resources") or []:
            workspace_level = (resource.get("provider") or "").endswith('databricks/databricks"].workspace') or resource.get("type") in (
                "databricks_catalog", "databricks_external_location", "databricks_storage_credential")
            if workspace_level and resource.get("instances"):
                return True
        return False

    # --- operation lock ---------------------------------------------------

    def acquire_lock(self) -> None:
        self.lock = f"{self.artifacts}/.operation.lock"
        os.makedirs(self.artifacts, exist_ok=True)
        try:
            os.mkdir(self.lock)
        except FileExistsError:
            pid, host, command = (read_text(f"{self.lock}/{name}") for name in ("pid", "host", "command"))
            if pid and host == socket.gethostname() and not process_alive(pid):
                err(f"Removing a stale operation lock left by process {pid} ({command or 'unknown command'}).")
                for name in ("pid", "host", "command"):
                    remove(f"{self.lock}/{name}")
                os.rmdir(self.lock)
                try:
                    os.mkdir(self.lock)
                except FileExistsError:
                    self.lock = ""
                    die(f"another operation is already running for deployment '{self.id}'")
            else:
                lock = self.lock
                self.lock = ""
                if pid:
                    die(f"another operation is already running for deployment '{self.id}' "
                        f"(process {pid} on {host or 'unknown host'}: {command or 'unknown command'})")
                die(f"another operation is already running for deployment '{self.id}'. If no ./infra process is running, remove {lock}")
        Path(f"{self.lock}/pid").write_text(f"{os.getpid()}\n")
        Path(f"{self.lock}/host").write_text(socket.gethostname() + "\n")
        Path(f"{self.lock}/command").write_text(self.command_line + "\n")
        signal.signal(signal.SIGTERM, _raise_interrupted)

    def release_lock(self) -> None:
        if self.lock and os.path.isdir(self.lock):
            for name in ("pid", "host", "command"):
                remove(f"{self.lock}/{name}")
            os.rmdir(self.lock)
        self.lock = ""

    # --- processes --------------------------------------------------------

    def process_env(self, unset=(), assign=None) -> dict:
        env = dict(os.environ)
        for name in unset:
            env.pop(name, None)
        env.update(assign or {})
        return env

    def call(self, argv, *, unset=(), assign=None, input=None, stdout="capture", stderr="inherit"):
        """Run a command; returns (exit code, captured stdout or '')."""
        streams = {"capture": subprocess.PIPE, "inherit": None, "null": subprocess.DEVNULL, "stderr": sys.stderr, "stdout": subprocess.STDOUT}
        sys.stdout.flush()
        sys.stderr.flush()
        try:
            completed = subprocess.run(
                list(argv), env=self.process_env(unset, assign), input=input, text=True,
                stdout=streams[stdout], stderr=streams[stderr],
            )
        except FileNotFoundError:
            return 127, ""
        return completed.returncode, completed.stdout or ""

    def terraform_env_parts(self):
        assign = {"TF_DATA_DIR": self.tf_data, "TF_WORKSPACE": self.id, "TF_IN_AUTOMATION": "1"}
        if not sys.stdout.isatty():
            for name in ("TF_CLI_ARGS_init", "TF_CLI_ARGS_plan", "TF_CLI_ARGS_apply"):
                assign[name] = os.environ.get(name) or "-no-color"
        return tuple(self.aws_env_unset) + tuple(self.db_env_unset), assign

    def terraform(self, *args, stdout="capture", stderr="inherit", input=None):
        unset, assign = self.terraform_env_parts()
        return self.call(["terraform", f"-chdir={self.dir}", *args], unset=unset, assign=assign, stdout=stdout, stderr=stderr, input=input)

    def terraform_output_json(self, stderr="inherit"):
        code, text = self.terraform("output", "-json", stderr=stderr)
        if code != 0:
            return None
        value = parse_json_object(text)
        return value

    def terraform_logged(self, name: str, *args) -> int:
        """Run Terraform, echoing its output and keeping a private copy agents can tail."""
        log_dir = f"{self.artifacts}/logs"
        log = f"{log_dir}/{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{name}.log"
        old_umask = os.umask(0o077)
        try:
            os.makedirs(log_dir, exist_ok=True)
            open(log, "w").close()
        finally:
            os.umask(old_umask)
        print(f"Terraform log: {log}", flush=True)
        unset, assign = self.terraform_env_parts()
        sys.stderr.flush()
        try:
            process = subprocess.Popen(
                ["terraform", f"-chdir={self.dir}", *args], env=self.process_env(unset, assign),
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            )
        except FileNotFoundError:
            err("terraform: command not found")
            return 127
        with open(log, "ab") as handle:
            while True:
                chunk = process.stdout.read1(65536) if hasattr(process.stdout, "read1") else process.stdout.read(4096)
                if not chunk:
                    break
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
                handle.write(chunk)
                handle.flush()
        return process.wait()


def _raise_interrupted(signum, frame):
    raise Interrupted(143)


def jq_tostring(value) -> str:
    """jq's `// empty | tostring`: null and false are empty, strings stay as they are."""
    if value is None or value is False:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, bool):
        return "true"
    if isinstance(value, (int, float)):
        return str(value) if not isinstance(value, float) or not value.is_integer() else str(int(value))
    return json.dumps(value, separators=(",", ":"))


def parse_json_object(text: str):
    try:
        value = json.loads(text)
    except (TypeError, ValueError):
        return None
    return value


def read_text(path: str) -> str:
    try:
        return Path(path).read_text().strip()
    except OSError:
        return ""


def remove(path: str) -> None:
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


def process_alive(pid: str) -> bool:
    try:
        os.kill(int(pid), 0)
    except (ValueError, ProcessLookupError):
        return False
    except PermissionError:
        return True
    return True


def cloud_root(cloud: str) -> str:
    if cloud not in ("aws", "azure"):
        die("cloud must be aws or azure")
    return f"{ROOT}/deployments/{cloud}"


def absolute_file(path: str) -> str:
    if not os.path.isfile(path):
        die(f"tfvars file not found: {path}")
    return os.path.join(os.path.abspath(os.path.dirname(path) or "."), os.path.basename(path))


def deployment_id_for(vars_path: str) -> str:
    deployment_id = os.environ.get("INFRA_DEPLOYMENT_ID") or os.path.basename(vars_path)
    if not os.environ.get("INFRA_DEPLOYMENT_ID") and deployment_id.endswith(".tfvars"):
        deployment_id = deployment_id[: -len(".tfvars")]
    if not DEPLOYMENT_ID_PATTERN.fullmatch(deployment_id):
        die("deployment ID must match [A-Za-z0-9][A-Za-z0-9._-]{0,127}")
    if deployment_id == "default":
        die("deployment ID 'default' is reserved by Terraform")
    return deployment_id


def tool_available(name: str) -> bool:
    return shutil.which(name) is not None


__all__ = ["Context", "Interrupted", "Exit", "cloud_root", "absolute_file", "deployment_id_for", "tool_available", "scenario"]
