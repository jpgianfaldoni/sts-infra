"""Saved plans: plan, apply, destroy-plan, and destroy.

A saved plan records digests of the tfvars, the plan file, the Terraform
configuration, and the authenticated identity. Apply refuses a plan when any
of them changed, and a plan is applied at most once.
"""
from __future__ import annotations

import json
import os
import time

from . import auth, clis
from .common import EXIT_LOGIN_REQUIRED, ROOT, die, err, file_sha256, items_of, out, parse_json, text_sha256, utc_now
from .context import Context

EXCLUDED_DIRS = ("/.terraform/", "/tests/")


def configuration_sha256(cloud: str) -> str:
    """Digest of the CLI and the Terraform configuration a plan was made with."""
    files = ["infra", "components.json"]
    sources = [f"deployments/{cloud}", f"modules/{cloud}"] + (["modules/shared"] if os.path.isdir(f"{ROOT}/modules/shared") else [])
    found = []
    for source in sources + ["lib"]:
        for directory, dirnames, filenames in os.walk(f"{ROOT}/{source}"):
            dirnames[:] = [d for d in dirnames if d != "__pycache__"]
            for name in filenames:
                path = os.path.join(directory, name)
                relative = os.path.relpath(path, ROOT)
                if os.path.islink(path) or any(part in f"/{relative}" for part in EXCLUDED_DIRS):
                    continue
                if ".tfstate" in name or name == ".DS_Store" or name.endswith(".pyc"):
                    continue
                if source == "lib" and not name.endswith(".py"):
                    continue
                found.append(relative)
    lines = [f"{file_sha256(f'{ROOT}/{name}')}  {name}\n" for name in files + sorted(found)]
    return text_sha256("".join(lines))


def plan_paths(ctx: Context, action: str):
    plan = f"{ctx.artifacts}/{'apply' if action == 'apply' else 'destroy' if action == 'destroy' else action}.tfplan"
    return plan, f"{plan}.metadata"


def remove_files(*paths) -> None:
    for path in paths:
        if os.path.exists(path):
            os.unlink(path)


def write_metadata(ctx: Context, metadata: str, action: str) -> None:
    plan = metadata[: -len(".metadata")]
    lines = [
        "version=1", f"action={action}", f"cloud={ctx.cloud}", f"deployment_id={ctx.id}", f"tfvars_path={ctx.vars}",
        f"tfvars_sha256={file_sha256(ctx.vars)}", f"plan_sha256={file_sha256(plan)}",
        f"configuration_sha256={configuration_sha256(ctx.cloud)}", f"auth_context_sha256={ctx.context_sha}", f"state_path={ctx.state}",
    ]
    with open(metadata, "w") as handle:
        handle.write("\n".join(lines) + "\n")


def metadata_value(metadata: str, key: str) -> str:
    with open(metadata) as handle:
        for line in handle:
            name, _, value = line.rstrip("\n").partition("=")
            if name == key:
                return value
    return ""


def verify_metadata(ctx: Context, metadata: str, action: str) -> None:
    if not os.path.isfile(metadata):
        die("saved plan metadata is missing; create a new plan")
    checks = (
        ("version", "1", "unsupported saved plan metadata; create a new plan"),
        ("action", action, f"saved plan action does not match '{action}'"),
        ("cloud", ctx.cloud, "saved plan cloud does not match"),
        ("deployment_id", ctx.id, "saved plan deployment ID does not match"),
        ("tfvars_path", ctx.vars, "saved plan belongs to another environment file"),
        ("tfvars_sha256", lambda: file_sha256(ctx.vars), "tfvars changed after the saved plan; create a new plan"),
        ("plan_sha256", lambda: file_sha256(metadata[: -len(".metadata")]), "saved plan changed after it was created; create a new plan"),
        ("configuration_sha256", lambda: configuration_sha256(ctx.cloud), "Terraform configuration changed after the saved plan; create a new plan"),
        ("auth_context_sha256", ctx.context_sha, "authenticated identity, account, or profile selection changed after the saved plan; create a new plan"),
        ("state_path", ctx.state, "saved plan belongs to another state file"),
    )
    for key, expected, message in checks:
        if metadata_value(metadata, key) != (expected() if callable(expected) else expected):
            die(message)


def select_plan_stage(ctx: Context, action: str) -> None:
    """A new AWS workspace deploys in two stages; the foundation stage defers workspace-level resources.

    A workspace login cannot exist before the workspace does, and an
    account-level OAuth profile cannot create every workspace-level resource.
    """
    ctx.plan_stage = "complete"
    if ctx.cloud != "aws" or action != "apply" or ctx.tfvar("workspace", "features") == "false":
        return
    if ctx.db_mode != "profile" or ctx.workspace_url:
        return
    ctx.plan_stage = "foundation"
    ctx.tf_args.append("-var=workspace_resources_enabled=false")


def plan_json(ctx: Context, plan: str) -> dict:
    code, text = ctx.terraform("show", "-json", plan)
    if code != 0:
        die(f"terraform show failed for {plan}")
    value = parse_json(text, {})
    return value if isinstance(value, dict) else {}


def plan_defers_workspace_resources(ctx: Context, plan: str) -> bool:
    code, text = ctx.terraform("show", "-json", plan)
    value = parse_json(text, {}) if code == 0 else None
    if not isinstance(value, dict):
        return True
    requested = (((value.get("planned_values") or {}).get("outputs") or {}).get("workspace_resources_requested") or {}).get("value")
    return requested is not False


def show_plan_summary(ctx: Context, plan: str, stage: str = "complete") -> None:
    data = plan_json(ctx, plan)
    changes = [c for c in data.get("resource_changes") or [] if (c.get("change") or {}).get("actions") not in (["no-op"], ["read"])]

    def addresses(test):
        return [c.get("address") for c in changes if test((c.get("change") or {}).get("actions") or [])]

    is_replace = lambda actions: "create" in actions and "delete" in actions  # noqa: E731
    outputs = ((data.get("planned_values") or {}).get("outputs") or {})
    storage = (outputs.get("external_volume_storage") or {}).get("value") or {}
    summary = {
        "version": 1,
        "stage": stage,
        "endpoint_approval": ctx.endpoint_approval_mode(),
        "new_endpoint_rules": len([a for a in addresses(lambda actions: "create" in actions) if "databricks_mws_ncc_private_endpoint_rule" in a]),
        "counts": {
            "create": len(addresses(lambda a: a == ["create"])),
            "update": len(addresses(lambda a: a == ["update"])),
            "replace": len(addresses(is_replace)),
            "delete": len(addresses(lambda a: a == ["delete"])),
        },
        "create": addresses(lambda a: a == ["create"]),
        "update": addresses(lambda a: a == ["update"]),
        "replace": addresses(is_replace),
        "delete": addresses(lambda a: a == ["delete"]),
        "warnings": ["metadata_only_external_storage"] if isinstance(storage, dict) and storage.get("connectivity_status") == "metadata_only" else [],
    }
    summary_file = f"{plan}.summary.json"
    with open(summary_file, "w") as handle:
        json.dump(summary, handle, indent=2)
        handle.write("\n")
    counts = summary["counts"]
    out(f"Saved plan summary: create={counts['create']} update={counts['update']} replace={counts['replace']} delete={counts['delete']}")
    for address in summary["replace"]:
        out(f"  replace: {address}")
    for address in summary["delete"]:
        out(f"  delete: {address}")
    if "metadata_only_external_storage" in summary["warnings"]:
        err("WARNING: this plan leaves external storage in metadata-only mode.")
        err("Unity Catalog objects can be browsed, but Databricks compute cannot read the files until public or private storage connectivity is configured.")
    if stage == "foundation":
        out("Deployment stage: foundation (1 of 2). This plan creates the workspace, networks, and data sources.")
        out("  Unity Catalog, Glue catalogs, and the lab check job need a login to the new workspace, so the next plan adds them.")
    rules = summary["new_endpoint_rules"]
    if rules:
        if ctx.endpoint_approval_mode() == "auto":
            out(f"Endpoints: after apply, ./infra approves the {rules} serverless private endpoint connection(s) this plan requests (endpoint_approval = \"auto\").")
        else:
            out(f"Endpoints: the {rules} serverless private endpoint connection(s) this plan requests stay pending until you approve them "
                f"(endpoint_approval = \"manual\"); see ./infra endpoints {ctx.cloud} status.")
    out(f"Plan summary JSON: {summary_file}")


def tainted_addresses(ctx: Context) -> list:
    tainted = []
    for resource in ctx.state_json().get("resources") or []:
        module = resource.get("module") or ""
        for instance in resource.get("instances") or []:
            if instance.get("status") != "tainted":
                continue
            address = (f"{module}." if module else "") + f"{resource.get('type')}.{resource.get('name')}"
            if "index_key" in instance:
                key = instance["index_key"]
                address += f'["{key}"]' if isinstance(key, str) else f"[{key}]"
            tainted.append(address)
    return tainted


def record_failed_plan(ctx: Context, plan: str, metadata: str, action: str) -> None:
    ctx.active_plan = ""
    with open(f"{plan}.failed", "w") as handle:
        handle.write(utc_now() + "\n")
    if os.path.isfile(metadata):
        os.replace(metadata, f"{metadata}.failed")
    code, listed = ctx.terraform("state", "list", stderr="null")
    count = len([line for line in listed.splitlines() if line.strip()]) if code == 0 else 0
    err(f"Terraform state currently contains {count} resource instance(s).")
    tainted = tainted_addresses(ctx) if ctx.state_exists() else []
    if tainted:
        err("Tainted resource instances:")
        for address in tainted:
            err(address)
    else:
        err("No tainted resource instances were recorded in local state.")
    err(f"The failed saved plan was invalidated. Reconcile with: ./infra plan {ctx.cloud} {ctx.vars}")
    err(f"ERROR: Terraform {action} failed; resources may have changed before the failure.")


def start_operation(ctx: Context, cloud: str, vars_path: str, action: str) -> None:
    ctx.prepare(cloud, vars_path)
    ctx.check_legacy_state()
    ctx.bind()
    ctx.acquire_lock()
    auth.preflight(ctx, action)


def terraform_init(ctx: Context) -> None:
    code, _ = ctx.terraform("init", "-backend=false", "-lockfile=readonly", stdout="inherit")
    if code != 0:
        die("terraform init failed")


def create_plan(ctx: Context, cloud: str, vars_path: str, action: str) -> None:
    start_operation(ctx, cloud, vars_path, action)
    plan, metadata = plan_paths(ctx, action)
    terraform_init(ctx)
    remove_files(plan, metadata, f"{plan}.applied", f"{plan}.failed", f"{metadata}.failed", f"{plan}.summary.json")
    select_plan_stage(ctx, action)
    args = ["plan"] + (["-destroy"] if action != "apply" else []) + [f"-var-file={ctx.vars}", *ctx.tf_args, f"-out={plan}"]
    # --replace forces a resource the cloud left broken (for example a rejected
    # private endpoint rule) to be recreated; it shows up as replace: below.
    args += [f"-replace={address}" for address in ctx.plan_replace]
    if ctx.terraform_logged("plan" if action == "apply" else "destroy-plan", *args) != 0:
        remove_files(plan)
        die("terraform plan failed; no saved plan was kept")
    write_metadata(ctx, metadata, action)
    if ctx.plan_stage == "foundation" and not plan_defers_workspace_resources(ctx, plan):
        ctx.plan_stage = "complete"
    with open(metadata, "a") as handle:
        handle.write(f"stage={ctx.plan_stage}\n")
    show_plan_summary(ctx, plan, ctx.plan_stage)
    out(f"Saved plan: {plan}")


def apply_plan(ctx: Context, cloud: str, vars_path: str, action: str) -> int:
    from . import endpoints

    start_operation(ctx, cloud, vars_path, action)
    plan, metadata = plan_paths(ctx, action)
    if not os.path.isfile(plan):
        die(f"no saved {action} plan for deployment '{ctx.id}'; create one first")
    if os.path.isfile(f"{plan}.applied"):
        die("this saved plan was already applied; create a new plan")
    terraform_init(ctx)
    verify_metadata(ctx, metadata, action)
    ctx.plan_stage = metadata_value(metadata, "stage") or "complete"
    show_plan_summary(ctx, plan, ctx.plan_stage)
    if action == "destroy" and cloud == "aws":
        terminate_workspace_clusters(ctx)
        endpoints.reject_serverless_endpoints_before_destroy(ctx)
    ctx.active_plan, ctx.active_metadata, ctx.active_action = plan, metadata, action
    if ctx.terraform_logged(action, "apply", plan) != 0:
        record_failed_plan(ctx, plan, metadata, action)
        return 1
    ctx.active_plan = ""
    with open(f"{plan}.applied", "w") as handle:
        handle.write(utc_now() + "\n")
    if action == "destroy":
        forget_workspace_profile(ctx)
    if action == "apply":
        if not endpoints.approve_after_apply(ctx):
            err(f"WARNING: automatic endpoint approval did not finish; review with ./infra endpoints {ctx.cloud} status {ctx.display_vars}")
        print_next_steps_after_apply(ctx)
    return 0


def forget_workspace_profile(ctx: Context) -> None:
    """The workspace is gone, so its profile must not be reused for the next workspace of this deployment."""
    from . import authconfig

    key = f"{ctx.cloud}/{ctx.id}"
    profile = authconfig.deployment_value(key, "databricks_workspace_profile")
    if not profile or ctx.state_workspace_url():
        return
    authconfig.forget_deployment_field(key, "databricks_workspace_profile")
    out(f"Forgot workspace profile '{profile}' for {key}: its workspace was destroyed (the profile itself stays in the Databricks CLI config).")


def print_next_steps_after_apply(ctx: Context) -> None:
    url = ctx.state_workspace_url()
    if ctx.plan_stage == "foundation":
        out("Stage 1 of 2 applied" + (f"; the workspace is {url}" if url else "") + ". Next:")
        out(f"  1. {ctx.setup_fix()}   (opens a browser login to the new workspace)")
        out(f"  2. ./infra plan {ctx.cloud} {ctx.display_vars}   (adds the workspace-level resources)")
        out(f"  3. ./infra apply {ctx.cloud} {ctx.display_vars}")
        return
    if ctx.cloud == "aws" and url and not ctx.db_workspace_profile and not ctx.ws_via_account:
        out(f"Next: the workspace {url} exists. Add its login before verifying or destroying:")
        out(f"  {ctx.setup_fix()}")
        return
    outputs = ctx.terraform_output_json(stderr="null")
    if isinstance(outputs, dict) and (outputs.get("lab_check") or {}).get("value") is not None:
        out(f"Next: ./infra verify {ctx.cloud} {ctx.display_vars}   (loads the sample data and checks every network path)")


def terminate_workspace_clusters(ctx: Context) -> None:
    """Terminate the workspace's clusters before destroy so Terraform can delete its network."""
    outputs = ctx.terraform_output_json()
    if outputs is None:
        die("could not read the workspace URL from Terraform state before destroy")
    if not isinstance(outputs, dict):
        die("could not parse the workspace URL from Terraform state before destroy")
    url = (outputs.get("workspace_url") or {}).get("value") or ""
    if not url:
        out("No workspace in state; skipping cluster termination.")
        return
    if not ctx.state_workspace_id():
        out("No managed Databricks workspace resource remains in state; skipping cluster termination.")
        return
    if auth.state_workspace_absent_from_account(ctx):
        out(f"Workspace {ctx.state_workspace_id()} is absent from the Databricks account; skipping cluster termination for the externally deleted workspace.")
        return
    code, _ = clis.databricks_workspace_cli(ctx, url, "current-user", "me", "--output", "json", stdout="null")
    if code != 0:
        die(f"Databricks workspace authentication is required to terminate clusters before destroy. Run: {ctx.setup_fix()}", EXIT_LOGIN_REQUIRED)

    def active_clusters():
        code, text = clis.databricks_workspace_cli(ctx, url, "clusters", "list", "--output", "json")
        if code != 0:
            return None
        listed = parse_json(text)
        if listed is None:
            die("could not parse the Databricks cluster list before destroy")
        return [c for c in items_of(listed, "clusters") if isinstance(c, dict) and c.get("state") != "TERMINATED"]

    clusters = active_clusters()
    if clusters is None:
        die("could not list Databricks clusters before destroy")
    requested = []
    for cluster in clusters:
        cluster_id, name = cluster.get("cluster_id"), cluster.get("cluster_name") or "unnamed"
        if not cluster_id:
            continue
        out(f"Requesting Databricks cluster termination: {name} ({cluster_id})")
        code, _ = clis.databricks_workspace_cli(ctx, url, "clusters", "delete", cluster_id, "--no-wait", stdout="inherit")
        if code != 0:
            die(f"could not request termination for cluster {cluster_id}; Terraform destroy was not started")
        requested.append(cluster_id)
    if not requested:
        out("Databricks cluster cleanup complete: no active clusters.")
        return
    deadline = time.time() + 1200
    while True:
        clusters = active_clusters()
        if clusters is None:
            die("could not check Databricks cluster termination progress")
        remaining = [f"{c.get('cluster_id')}\t{c.get('cluster_name') or 'unnamed'}\t{c.get('state')}" for c in clusters if c.get("cluster_id") in requested]
        if not remaining:
            out(f"Databricks cluster cleanup complete: {len(requested)} cluster(s) terminated.")
            return
        if time.time() >= deadline:
            err("Clusters still active after the shared 20-minute cleanup deadline:")
            for row in remaining:
                err(row)
            die("Databricks clusters did not terminate; Terraform destroy was not started")
        out("Waiting for Databricks clusters to terminate:")
        for row in remaining:
            out(row)
        time.sleep(10)
