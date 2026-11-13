"""Seed access, seeding, state-forget, state-migrate, and output."""
from __future__ import annotations

import json
import os
import re
import time
import urllib.request

from . import auth, plans
from .common import ADDRESS_PATTERN, ROOT, die, err, file_sha256, out, utc_now
from .context import Context

SEED_ACCESS_SCOPE = {
    "module.external_volume_storage[0].azurerm_storage_account.this",
    "module.external_volume_storage[0].azurerm_role_assignment.seed_operator_storage[0]",
    "module.external_volume_storage[0].time_sleep.rbac_propagation",
}


def normalize_operator_cidr(value: str) -> str:
    if "/" in value:
        if not value.endswith("/32"):
            die("operator IP must be an IPv4 address or a /32 CIDR")
        value = value[: -len("/32")]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+", value) or any(int(octet) > 255 for octet in value.split(".")):
        die("operator IP must be a valid IPv4 address")
    return f"{value}/32"


def discover_public_ip() -> str:
    try:
        with urllib.request.urlopen("https://api.ipify.org", timeout=30) as response:
            return response.read().decode().strip()
    except OSError:
        die("could not discover the operator public IPv4 address; pass --operator-ip explicitly")


def validate_seed_access_plan_scope(ctx: Context, plan: str) -> None:
    unexpected = [
        f"{change.get('address')}: {','.join((change.get('change') or {}).get('actions') or [])}"
        for change in plans.plan_json(ctx, plan).get("resource_changes") or []
        if (change.get("change") or {}).get("actions") != ["no-op"] and change.get("address") not in SEED_ACCESS_SCOPE
    ]
    if unexpected:
        err("Seed-access plans may change only the storage firewall and temporary operator role.")
        err("Unexpected planned changes:")
        for line in unexpected:
            err(line)
        plans.remove_files(plan)
        die("create and apply a normal reconciliation plan before requesting temporary seed access")


def create_seed_access_plan(ctx: Context, vars_path: str, operator_ip: str = "") -> None:
    plans.start_operation(ctx, "azure", vars_path, "seed-access")
    operator_cidr = normalize_operator_cidr(operator_ip or discover_public_ip())
    plan, metadata = plans.plan_paths(ctx, "seed-access")
    plans.terraform_init(ctx)
    plans.remove_files(plan, metadata, f"{plan}.applied", f"{plan}.failed", f"{metadata}.failed", f"{plan}.summary.json")
    code = ctx.terraform_logged("seed-access-plan", "plan", f"-var-file={ctx.vars}", *ctx.tf_args, "-var=external_volume_bootstrap_access_enabled=true",
                                f"-var=external_volume_bootstrap_operator_cidr={operator_cidr}", f"-out={plan}")
    if code != 0:
        plans.remove_files(plan)
        die("terraform plan failed; no saved seed-access plan was kept")
    validate_seed_access_plan_scope(ctx, plan)
    plans.write_metadata(ctx, metadata, "seed-access")
    plans.show_plan_summary(ctx, plan)
    out(f"Temporary seed access is restricted to {operator_cidr}.")
    out(f"Saved seed-access plan: {plan}")


def apply_seed_access_plan(ctx: Context, vars_path: str) -> int:
    plans.start_operation(ctx, "azure", vars_path, "seed-access")
    plan, metadata = plans.plan_paths(ctx, "seed-access")
    if not os.path.isfile(plan):
        die(f"no saved seed-access plan for deployment '{ctx.id}'; create one first")
    if os.path.isfile(f"{plan}.applied"):
        die("this saved seed-access plan was already applied; create a new one")
    plans.terraform_init(ctx)
    plans.verify_metadata(ctx, metadata, "seed-access")
    plans.show_plan_summary(ctx, plan)
    ctx.active_plan, ctx.active_metadata, ctx.active_action = plan, metadata, "seed-access"
    if ctx.terraform_logged("seed-access", "apply", plan) != 0:
        plans.record_failed_plan(ctx, plan, metadata, "seed-access")
        return 1
    ctx.active_plan = ""
    with open(f"{plan}.applied", "w") as handle:
        handle.write(utc_now() + "\n")
    out(f"Temporary seed access is active. Upload data with: ./infra seed azure {ctx.vars}")
    return 0


def upload_blob_with_retry(ctx: Context, account: str, container: str, blob: str, path: str, checksum: str) -> bool:
    attempts = 18
    for attempt in range(1, attempts + 1):
        code, _ = ctx.call(["az", "storage", "blob", "upload", "--account-name", account, "--container-name", container, "--name", blob,
                            "--file", path, "--auth-mode", "login", "--overwrite", "true", "--metadata", f"sha256={checksum}",
                            "--only-show-errors", "--output", "none"], stdout="inherit")
        if code == 0:
            return True
        if attempt < attempts:
            err(f"Blob upload is not authorized yet; retrying RBAC propagation ({attempt}/{attempts})...")
            time.sleep(10)
    return False


def seed_command(ctx: Context, args: list) -> int:
    if not (args and args[0] == "azure" and len(args) >= 2):
        die("seed requires: azure <environment.tfvars> [--source <directory>] [--destination-path <path>]")
    from .context import absolute_file, scenario

    vars_path = args[1]
    source = f"{ROOT}/modules/azure/external-volume-storage/assets/sample-json"
    destination = scenario.tfvar_value(absolute_file(vars_path), "volume_storage_path", "external_volume_storage") or "volume"
    rest = args[2:]
    while rest:
        arg = rest.pop(0)
        if arg == "--source":
            if not rest:
                die("--source requires a directory")
            source = rest.pop(0)
        elif arg == "--destination-path":
            if not rest:
                die("--destination-path requires a path")
            destination = rest.pop(0)
        else:
            die(f"unknown seed option: {arg}")
    return seed_external_volume(ctx, vars_path, source, destination)


def seed_external_volume(ctx: Context, vars_path: str, source: str, destination: str) -> int:
    ctx.prepare("azure", vars_path)
    ctx.check_legacy_state()
    ctx.bind()
    if not os.path.isdir(source):
        die(f"seed source directory not found: {source}")
    source = os.path.abspath(source)
    destination = destination[1:] if destination.startswith("/") else destination
    destination = destination[:-1] if destination.endswith("/") else destination
    if not destination:
        die("seed destination path cannot be empty")
    ctx.acquire_lock()
    auth.preflight(ctx, "seed")
    if not ctx.state_exists():
        die(f"state not found for deployment '{ctx.id}'")
    plans.terraform_init(ctx)
    outputs = ctx.terraform_output_json()
    if not isinstance(outputs, dict):
        die("could not read Terraform outputs")
    storage = (outputs.get("external_volume_storage") or {}).get("value") or {}
    if not (storage.get("bootstrap_access_enabled") is True and storage.get("public_network_access_enabled") is True):
        die("temporary seed access is not active; run seed-access-plan, review it, and run seed-access-apply first")
    account, container = storage.get("storage_account_name") or "", storage.get("container_name") or ""
    if not account or not container:
        die("external-volume storage outputs are incomplete")
    uploaded, failed = 0, False
    for directory, _, filenames in os.walk(source):
        for name in filenames:
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, source)
            blob = f"{destination}/{relative}"
            checksum = file_sha256(path)
            out(f"Uploading {relative} to {container}/{blob}")
            if not upload_blob_with_retry(ctx, account, container, blob, path, checksum):
                err(f"ERROR: failed to upload {relative} after bounded RBAC retries.")
                failed = True
                break
            code, remote = ctx.call(["az", "storage", "blob", "metadata", "show", "--account-name", account, "--container-name", container,
                                     "--name", blob, "--auth-mode", "login", "--query", "sha256", "--output", "tsv", "--only-show-errors"])
            if (remote.strip() if code == 0 else "") != checksum:
                err(f"ERROR: checksum metadata verification failed for {relative}.")
                failed = True
                break
            uploaded += 1
        if failed:
            break
    if uploaded == 0 and not failed:
        failed = True
        err(f"ERROR: no files were found under {source}.")
    ctx.release_lock()
    out("Creating the normal lockdown plan to disable public access and remove the temporary operator role.")
    plans.create_plan(ctx, "azure", ctx.vars, "apply")
    if failed:
        err(f"Seeding failed, but a lockdown plan was created. Review it and run ./infra apply azure {ctx.vars}.")
        return 1
    out(f"Uploaded and verified {uploaded} file(s). Review the lockdown plan, then run: ./infra apply azure {ctx.vars}")
    return 0


def forget_state(ctx: Context, cloud: str, vars_path: str, address: str, confirmation: str) -> None:
    """Remove one resource from state without touching the cloud, for objects the cloud already deleted."""
    ctx.prepare(cloud, vars_path)
    ctx.check_legacy_state()
    ctx.bind()
    expected = f"forget-{cloud}-{ctx.id}"
    if confirmation != expected:
        die(f"state-forget requires: --confirm {expected}")
    if not ADDRESS_PATTERN.fullmatch(address):
        die(f"invalid resource address: {address}")
    if not ctx.state_exists():
        die(f"state not found for deployment '{ctx.id}'")
    ctx.acquire_lock()
    code, _ = ctx.terraform("init", "-backend=false", "-lockfile=readonly", stdout="null")
    if code != 0:
        die("terraform init failed")
    code, listed = ctx.terraform("state", "list", stderr="stdout")
    if code != 0:
        die(f"could not list the state: {listed}")
    entries = listed.splitlines()
    if address not in entries:
        name = re.sub(r"\[[^]]*\]", "", address).rsplit(".", 1)[-1]
        err("State entries like it:")
        for entry in entries:
            if name in entry:
                err(f"  {entry}")
        die(f"{address} is not in the state of deployment '{ctx.id}'")
    code, _ = ctx.terraform("state", "rm", "--", address, stdout="inherit")
    if code != 0:
        die(f"terraform state rm failed for {address}")
    ctx.release_lock()
    out(f"Removed {address} from the state; nothing in the cloud was deleted. Plan again to recreate it: ./infra plan {cloud} {ctx.display_vars}")


def migrate_state(ctx: Context, cloud: str, vars_path: str, confirmation: str) -> None:
    ctx.prepare(cloud, vars_path)
    legacy_state = f"{ctx.dir}/terraform.tfstate"
    legacy_backup = f"{ctx.dir}/terraform.tfstate.backup"
    legacy_plan_path = f"{ROOT}/.artifacts/{cloud}/terraform.tfplan.tfvars.path"
    expected = f"migrate-{cloud}-{ctx.id}"
    if confirmation != expected:
        die(f"state migration requires: --confirm {expected}")
    if not os.path.isfile(legacy_state):
        die(f"no legacy state found at {legacy_state}")
    if os.path.exists(ctx.state):
        die(f"destination state already exists: {ctx.state}")
    if os.path.isfile(legacy_plan_path) and open(legacy_plan_path).read().rstrip("\n") != ctx.vars:
        die("legacy plan metadata associates the state with another environment file")
    ctx.bind()
    os.replace(legacy_state, ctx.state)
    if os.path.isfile(legacy_backup):
        os.replace(legacy_backup, f"{ctx.state}.backup")
    out(f"Migrated local state to: {ctx.state}")
    out("Create and review a new saved plan before the next apply or destroy.")


def show_outputs(ctx: Context, cloud: str, vars_path: str, json_mode: bool) -> int:
    ctx.prepare(cloud, vars_path)
    ctx.check_legacy_state()
    ctx.bind()
    if not ctx.state_exists():
        die(f"state not found for deployment '{ctx.id}'")
    if not json_mode:
        code, _ = ctx.terraform("output", stdout="inherit")
        return code
    outputs = ctx.terraform_output_json()
    if not isinstance(outputs, dict):
        die("could not read Terraform outputs")
    # Sensitive values are redacted so outputs are safe to show in logs.
    redacted = {name: ({**value, "value": "<sensitive>"} if isinstance(value, dict) and value.get("sensitive") else value)
                for name, value in outputs.items()}
    out(json.dumps(redacted, indent=2, ensure_ascii=False))
    return 0
