"""Azure cleanup recovery using reviewed state repairs and saved Terraform plans.

Inspection reads only resources already identified by this deployment's state.
It never retrieves secret values, recovers/purges a vault through Azure CLI, or
changes cloud resources. State repairs are separately saved, identity-bound,
rechecked at apply time, and followed by a fresh Terraform recovery plan.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path
from urllib.parse import urlsplit

from . import clis, endpoints, plans
from .common import ADDRESS_PATTERN, die, file_sha256, items_of, out, parse_json, utc_now, write_private
from .context import Context

REPAIR_FILE = "recovery.plan.json"
NOT_FOUND = re.compile(r"\((?:ResourceNotFound|ResourceGroupNotFound|ParentResourceNotFound|NotFound)\)")


def state_instances(state: dict):
    for resource in state.get("resources") or []:
        if resource.get("mode") != "managed":
            continue
        base = ((resource.get("module") or "") + ".").lstrip(".") + resource["type"] + "." + resource["name"]
        for instance in resource.get("instances") or []:
            address = base
            if "index_key" in instance:
                address += "[" + json.dumps(instance["index_key"]) + "]"
            yield address, resource, instance.get("attributes") or {}


def azure_resource_exists(ctx: Context, resource_id: str) -> bool:
    if not resource_id.lower().startswith(f"/subscriptions/{ctx.az_subscription}/".lower()):
        die("recovery refused a resource ID outside the authenticated subscription")
    code, text = ctx.call([
        "az", "resource", "show", "--ids", resource_id, "--subscription", ctx.az_subscription,
        "--query", "id", "--output", "json", "--only-show-errors",
    ], stderr="stdout")
    if code == 0:
        returned = parse_json(text)
        if not isinstance(returned, str) or returned.lower() != resource_id.lower():
            die(f"could not confirm the identity of Azure resource {resource_id}; no recovery plan was created")
        return True
    if NOT_FOUND.search(text):
        return False
    die(f"could not inspect Azure resource {resource_id}; authorization or API failures are not proof of deletion")


def inspect(ctx: Context) -> dict:
    state = ctx.state_json()
    instances = list(state_instances(state))
    report = {"version": 1, "deleted": [], "forget": [], "secret_imports": {}, "restore_targets": []}
    missing_workspace = False
    for address, resource, attributes in instances:
        # Terraform refresh handles ordinary deleted resources. Inspect the
        # two parents that need recovery orchestration before that refresh.
        if resource["type"] not in ("azurerm_databricks_workspace", "azurerm_key_vault"):
            continue
        resource_id = attributes.get("id")
        if not resource_id:
            die(f"{address} has no resource ID; recovery needs intact local state")
        if not azure_resource_exists(ctx, resource_id):
            report["deleted"].append({"address": address, "id": resource_id})
            report["restore_targets"].append(address)
            if resource["type"] == "azurerm_databricks_workspace":
                missing_workspace = True
    if missing_workspace:
        for address, resource, _attributes in instances:
            if (resource.get("provider") or "").endswith('databricks/databricks"].workspace'):
                report["forget"].append({"address": address, "reason": "parent workspace was deleted in Azure"})

    # Probe each NCC referenced by an actual rule in state, never account-wide.
    by_ncc = {}
    for address, resource, attributes in instances:
        if resource["type"] != "databricks_mws_ncc_private_endpoint_rule":
            continue
        ncc, rule_id = attributes.get("network_connectivity_config_id"), attributes.get("rule_id")
        if not ncc or not rule_id:
            die(f"{address} lacks its NCC or rule ID; cannot prove a state repair is safe")
        if ncc not in by_ncc:
            code, text = clis.databricks_account_cli(
                ctx, "account", "network-connectivity", "list-private-endpoint-rules", ncc, "--output", "json", stderr="null",
            )
            listed = parse_json(text) if code == 0 else None
            if not endpoints.valid_rule_list(listed):
                die(f"could not inspect NCC {ncc}; no recovery plan was created")
            by_ncc[ncc] = {r.get("rule_id"): r for r in items_of(listed, "items", "rules") if isinstance(r, dict)}
        rule = by_ncc[ncc].get(rule_id)
        # Absence from a valid, complete list and an explicit tombstone are
        # safe to forget. Rejected active rules still require normal replace.
        if rule is None or rule.get("deactivated"):
            report["forget"].append({
                "address": address, "reason": "NCC rule is missing" if rule is None else "NCC rule is deactivated",
                "ncc_id": ncc, "rule_id": rule_id,
            })

    vault = ((state.get("outputs") or {}).get("key_vault") or {}).get("value") or {}
    # Recover the parent vault in Terraform first. Its soft-deleted secrets
    # may reappear only after that apply, so import them in the next plan.
    vault_missing = any(item["address"].endswith(".azurerm_key_vault.this") for item in report["deleted"])
    if not vault_missing and vault.get("name"):
        vault_id = vault.get("id") or ""
        if not vault_id.lower().startswith(f"/subscriptions/{ctx.az_subscription}/".lower()):
            die("Key Vault output does not belong to the authenticated subscription")
        names = vault.get("secret_names") or []
        managed = {a.get("name") for _addr, resource, a in instances if resource["type"] == "azurerm_key_vault_secret"
                   and (a.get("key_vault_id") or "").lower() == vault_id.lower()}
        needed = set(names) - managed
        if needed:
            code, text = ctx.call([
                "az", "keyvault", "secret", "list", "--vault-name", vault["name"], "--subscription", ctx.az_subscription,
                "--query", "[].{name:name,id:id}", "--output", "json", "--only-show-errors",
            ], stderr="null")
            listed = parse_json(text) if code == 0 else None
            if not isinstance(listed, list):
                die("could not list recovered secret metadata; secret values were not requested")
            for secret in listed:
                if not isinstance(secret, dict):
                    die("malformed recovered secret metadata")
                name, secret_id = secret.get("name"), secret.get("id")
                if name not in needed:
                    continue
                expected_host = urlsplit(vault.get("uri") or "").hostname
                parsed = urlsplit(secret_id or "")
                if not expected_host or parsed.scheme != "https" or parsed.hostname != expected_host or parsed.path != f"/secrets/{name}":
                    die("recovered secret metadata does not match the deployment's vault")
                # list-versions returns metadata, never values. AzureRM's
                # import ID must include a version, unlike secret list IDs.
                code, text = ctx.call([
                    "az", "keyvault", "secret", "list-versions", "--vault-name", vault["name"], "--name", name,
                    "--subscription", ctx.az_subscription, "--query", "sort_by(@, &attributes.created)[-1].id",
                    "--output", "json", "--only-show-errors",
                ], stderr="null")
                versioned = parse_json(text) if code == 0 else None
                parsed = urlsplit(versioned or "")
                if (parsed.scheme != "https" or parsed.hostname != expected_host
                        or not re.fullmatch(r"/secrets/" + re.escape(name) + r"/[A-Za-z0-9-]+", parsed.path)
                        or parsed.query or parsed.fragment or parsed.username):
                    die("could not confirm the recovered secret version without retrieving its value")
                report["secret_imports"][name] = versioned
    report["forget"].sort(key=lambda item: item["address"])
    return report


def repair_path(ctx: Context) -> str:
    return f"{ctx.artifacts}/{REPAIR_FILE}"


def pending(ctx: Context) -> bool:
    path = repair_path(ctx)
    return os.path.isfile(path) and not os.path.exists(path + ".applied")


def show_repairs(report: dict) -> None:
    out(f"Saved recovery summary: forget={len(report['forget'])} (state only); create=0 update=0 replace=0 delete=0")
    for item in report["forget"]:
        out(f"  forget: {item['address']} ({item['reason']})")


def clear_repairs(ctx: Context) -> None:
    path = repair_path(ctx)
    plans.remove_files(path, path + ".metadata", path + ".applied", path + ".failed")


def recover_plan(ctx: Context, vars_path: str) -> None:
    plans.start_operation(ctx, "azure", vars_path, "recover")
    if not ctx.state_exists():
        die("cleanup recovery requires this deployment's local state; use ./infra plan for a new environment")
    # Invalidate an earlier pending plan even when inspection subsequently
    # fails: an old apply must not be mistaken for this recovery attempt.
    apply, metadata = plans.plan_paths(ctx, "apply")
    plans.remove_files(apply, metadata, apply + ".summary.json")
    clear_repairs(ctx)
    report = inspect(ctx)
    for item in report["deleted"]:
        out(f"Cleanup detected: {item['address']} is absent in Azure.")
    if report["forget"]:
        plans.terraform_init(ctx)
        report["state_sha256"] = file_sha256(ctx.state)
        path = repair_path(ctx)
        write_private(path, json.dumps(report, indent=2) + "\n")
        plans.write_metadata(ctx, path + ".metadata", "recover")
        show_repairs(report)
        out(f"Saved recovery plan: {path}")
        out(f"Next: ./infra apply azure {ctx.display_vars}; then rerun ./infra recover-plan azure {ctx.display_vars}.")
        return
    if report["secret_imports"]:
        ctx.tf_args.append("-var=recovery_secret_imports=" + json.dumps(report["secret_imports"], separators=(",", ":")))
    if report["restore_targets"]:
        out("Recovery stage: restore the missing workspace/vault and their dependencies first; inspect recovered secrets in the next recover-plan.")
    plans.save_prepared_plan(ctx, "apply", targets=report["restore_targets"], recovery=True)


def apply_repairs(ctx: Context, cloud: str, vars_path: str) -> int:
    plans.start_operation(ctx, cloud, vars_path, "recover")
    path = repair_path(ctx)
    if os.path.exists(path + ".applied"):
        die("this saved recovery plan was already applied; run recover-plan again")
    if os.path.exists(path + ".failed"):
        die("the previous recovery attempt was interrupted or failed; run recover-plan again")
    plans.verify_metadata(ctx, path + ".metadata", "recover")
    report = parse_json(Path(path).read_text())
    if not isinstance(report, dict) or report.get("state_sha256") != file_sha256(ctx.state):
        die("state changed after the recovery plan; run recover-plan again")
    current = inspect(ctx)
    if current["forget"] != report.get("forget"):
        die("live recovery evidence changed; run recover-plan again")
    show_repairs(report)
    plans.terraform_init(ctx)
    # Back up the original state before the first removal, without printing it.
    write_private(path + ".state.backup", Path(ctx.state).read_text())
    write_private(path + ".failed", utc_now() + "\n")
    for item in report["forget"]:
        address = item["address"]
        if not ADDRESS_PATTERN.fullmatch(address):
            die("invalid resource address in the recovery plan")
        code, _text = ctx.terraform("state", "rm", "--", address, stdout="null", stderr="null")
        if code != 0:
            die("state repair failed; the saved recovery plan was invalidated. Run recover-plan again")
        out(f"Removed {address} from state; no cloud resource was deleted.")
    write_private(path + ".applied", utc_now() + "\n")
    plans.remove_files(path + ".failed")
    out(f"Next: ./infra recover-plan azure {ctx.display_vars} (create and review the next saved Terraform plan).")
    return 0
