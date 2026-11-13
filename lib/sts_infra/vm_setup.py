"""./infra vm-setup-status: report the Azure VM Run Command results of this deployment's VMs.

Database VMs are prepared from inside the VM by Azure VM Run Command. When a
setup fails, its LAKEFLOW_CDC_SETUP_FAILED line explains why. This command
finds the deployment's VMs in state and reads each run command's instance
view, so nobody has to look up resource groups and VM names by hand. It only
reads; nothing is changed.
"""
from __future__ import annotations

import json

from . import auth
from .common import Usage, die, out, parse_json
from .context import Context

VM_TYPES = ("azurerm_linux_virtual_machine", "azurerm_windows_virtual_machine")
MARKERS = ("LAKEFLOW_CDC_SETUP_FAILED", "LAKEFLOW_CDC_SETUP_RESULT")
TAIL_LINES = 15


def state_vms(ctx: Context) -> list:
    vms = []
    for resource in ctx.state_json().get("resources") or []:
        if resource.get("type") not in VM_TYPES:
            continue
        for instance in resource.get("instances") or []:
            attributes = instance.get("attributes") or {}
            if attributes.get("name") and attributes.get("resource_group_name"):
                vms.append({"module": resource.get("module") or "", "name": attributes["name"], "resource_group": attributes["resource_group_name"]})
    return vms


def az_json(ctx: Context, *args):
    code, text = ctx.call(["az", *args, "--output", "json"], stderr="null")
    return parse_json(text) if code == 0 else None


def run_command_status(ctx: Context, vm: dict, name: str) -> dict:
    shown = az_json(ctx, "vm", "run-command", "show", "--resource-group", vm["resource_group"], "--vm-name", vm["name"],
                    "--run-command-name", name, "--instance-view")
    if not isinstance(shown, dict):
        return {"name": name, "state": "unreadable", "exit_code": None, "markers": [], "output_tail": [], "error_tail": []}
    view = shown.get("instanceView") or {}
    output_lines = (view.get("output") or "").splitlines()
    error_lines = (view.get("error") or "").splitlines()
    return {
        "name": name,
        "state": view.get("executionState") or shown.get("provisioningState") or "unknown",
        "exit_code": view.get("exitCode"),
        "start_time": view.get("startTime"),
        "end_time": view.get("endTime"),
        "markers": [line for line in output_lines + error_lines if line.startswith(MARKERS)],
        "output_tail": output_lines[-TAIL_LINES:],
        "error_tail": error_lines[-TAIL_LINES:],
    }


def vm_setup_status(ctx: Context, vars_path: str, json_mode: bool) -> int:
    ctx.prepare("azure", vars_path)
    ctx.check_legacy_state()
    ctx.bind()
    if not ctx.state_exists():
        die(f"state not found for deployment '{ctx.id}'")
    auth.preflight(ctx, "inspect", write=lambda line: None if json_mode else out(line))
    report = []
    for vm in state_vms(ctx):
        listed = az_json(ctx, "vm", "run-command", "list", "--resource-group", vm["resource_group"], "--vm-name", vm["name"])
        if not isinstance(listed, list):
            report.append({**vm, "error": "could not list the VM's run commands", "run_commands": []})
            continue
        names = [item.get("name") for item in listed if isinstance(item, dict) and item.get("name")]
        report.append({**vm, "run_commands": [run_command_status(ctx, vm, name) for name in names]})
    if json_mode:
        out(json.dumps({"vms": report}, indent=2, ensure_ascii=False))
    else:
        render(report)
    failed = any(cmd["state"] not in ("Succeeded", "Running", "Pending") or (cmd["exit_code"] not in (None, 0))
                 for vm in report for cmd in vm["run_commands"]) or any(vm.get("error") for vm in report)
    return 1 if failed else 0


def render(report: list) -> None:
    if not report:
        out("This deployment has no VMs in state.")
        return
    for vm in report:
        out(f"{vm['name']} (resource group {vm['resource_group']}):")
        if vm.get("error"):
            out(f"  {vm['error']}")
            continue
        if not vm["run_commands"]:
            out("  no run commands")
        for cmd in vm["run_commands"]:
            exit_text = "" if cmd["exit_code"] is None else f", exit {cmd['exit_code']}"
            out(f"  {cmd['name']}: {cmd['state']}{exit_text}")
            for line in cmd["markers"]:
                out(f"    {line}")
            if cmd["state"] != "Succeeded" or cmd["exit_code"] not in (None, 0):
                for label, lines in (("output", cmd["output_tail"]), ("error", cmd["error_tail"])):
                    if lines:
                        out(f"    last {label} lines:")
                        for line in lines:
                            out(f"      {line}")


def vm_setup_command(ctx: Context, args: list) -> int:
    if len(args) < 2 or args[0] != "azure" or any(arg != "--json" for arg in args[2:]):
        if args and args[0] == "aws":
            die("vm-setup-status supports azure only: AWS sources are prepared by the lab check job (see ./infra verify)")
        raise Usage()
    return vm_setup_status(ctx, args[1], "--json" in args[2:])
