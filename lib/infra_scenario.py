#!/usr/bin/env python3
"""Scenario helpers behind ./infra templates, new, explain, ls, and status.

Standard library only. ./infra runs this file with `python3 -I` and sets
STS_INFRA_ROOT and STS_INFRA_TARGETS_FILE. Nothing here calls a cloud API:
explain evaluates the environment file with `terraform console`, and ls and
status read local state and saved artifacts.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(os.environ.get("STS_INFRA_ROOT") or Path(__file__).resolve().parents[1])
TARGETS_FILE = Path(
    os.environ.get("STS_INFRA_TARGETS_FILE")
    or Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "sts-infra" / "targets.json"
)
CLOUDS = ("aws", "azure")
DEPLOYMENT_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
PLACEHOLDER_ID = "00000000-0000-0000-0000-000000000000"
ACCOUNT_KEYS = ("databricks_account_id", "aws_account_id", "subscription_id", "tenant_id")
# Settings a target supplies when the tfvars file leaves them out; ./infra
# passes the same values as -var arguments.
TARGET_TERRAFORM_FIELDS = {
    "aws": ("aws_account_id", "databricks_account_id", "region"),
    "azure": ("subscription_id", "tenant_id", "databricks_account_id", "location"),
}
# Sources whose lab check loads sample data; the others only connect.
SEEDED_SOURCES = {"aws": {"rds_postgres", "rds_sql_server"}, "azure": {"sql_database"}}
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def die(message, code=1):
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(code)


def display(path):
    path = Path(path)
    try:
        return str(path.resolve().relative_to(ROOT))
    except ValueError:
        return str(path)


def load_manifest():
    return json.loads((ROOT / "components.json").read_text())


def load_targets():
    if not TARGETS_FILE.is_file():
        return {}
    return json.loads(TARGETS_FILE.read_text()).get("targets", {})


# --- tfvars helpers -----------------------------------------------------------


def strip_comment(line):
    quoted = False
    for i, char in enumerate(line):
        if char == '"' and (i == 0 or line[i - 1] != "\\"):
            quoted = not quoted
        elif not quoted and (char == "#" or line.startswith("//", i)):
            return line[:i]
    return line


def top_level_assignments(path):
    """Return {key: raw value} for top-level `key = value` lines of a tfvars file."""
    values, depth = {}, 0
    for line in Path(path).read_text().splitlines():
        code = strip_comment(line)
        if depth == 0:
            match = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$", code)
            if match:
                values[match.group(1)] = match.group(2)
        depth += sum(code.count(c) for c in "{[") - sum(code.count(c) for c in "}]")
        depth = max(depth, 0)
    return values


def string_value(raw):
    if raw is None:
        return None
    match = re.fullmatch(r'"([^"]*)"', raw.strip())
    return match.group(1) if match else None


def deployment_id_for(tfvars):
    deployment_id = os.environ.get("INFRA_DEPLOYMENT_ID") or Path(tfvars).name.removesuffix(".tfvars")
    if not DEPLOYMENT_ID.match(deployment_id) or deployment_id == "default":
        die(f"invalid deployment ID '{deployment_id}'", 2)
    return deployment_id


# --- templates and new --------------------------------------------------------


def list_templates(cloud=None):
    rows = []
    for name in [cloud] if cloud else CLOUDS:
        for path in sorted((ROOT / "environments" / "examples" / name).glob("*.tfvars")):
            first = path.read_text().splitlines()[:1]
            description = first[0][len("# Scenario:"):].strip() if first and first[0].startswith("# Scenario:") else ""
            rows.append({"cloud": name, "template": path.stem, "description": description, "path": display(path)})
    return rows


def command_templates(args):
    rows = list_templates(args.cloud)
    if args.json:
        print(json.dumps({"version": 1, "templates": rows}, indent=2))
        return 0
    for cloud in CLOUDS:
        cloud_rows = [row for row in rows if row["cloud"] == cloud]
        if not cloud_rows:
            continue
        print(f"{cloud} templates:")
        width = max(len(row["template"]) for row in cloud_rows)
        for row in cloud_rows:
            print(f"  {row['template']:<{width}}  {row['description']}")
    print("Create an environment from one with: ./infra new <cloud> <name> --template <template> [--target <target>]")
    return 0


def block_bounds(lines, key):
    """Return (start, end) line indexes of a top-level `key = {` block, or None."""
    for start, line in enumerate(lines):
        if re.match(rf"^{key}\s*=\s*\{{\s*$", strip_comment(line)):
            for end in range(start + 1, len(lines)):
                if re.match(r"^\}\s*$", strip_comment(lines[end])):
                    return start, end
    return None


def apply_target_defaults(lines, name, target):
    """Write the target's metastore and check node type into a new environment.

    A target metastore replaces metastore_mode = "auto", which refuses to guess
    in accounts with several metastores per region; templates that choose
    another mode keep it.
    """
    metastore = target.get("metastore")
    bounds = block_bounds(lines, "unity_catalog")
    if metastore and bounds:
        start, end = bounds
        for i in range(start + 1, end):
            if re.match(r'^\s*metastore_mode\s*=\s*"auto"', strip_comment(lines[i])):
                lines[i : i + 1] = [
                    f"  # Metastore from target '{name}'.",
                    '  metastore_mode          = "existing"',
                    f'  existing_metastore_name = "{metastore}"',
                ]
                break
    node_type = target.get("classic_node_type")
    if node_type:
        bounds = block_bounds(lines, "lab_check")
        if bounds is None:
            lines += ["", "lab_check = {", f'  classic_node_type = "{node_type}" # from target \'{name}\'', "}"]
        elif not any(re.match(r"^\s*classic_node_type\s*=", lines[i]) for i in range(*bounds)):
            lines.insert(bounds[0] + 1, f'  classic_node_type = "{node_type}" # from target \'{name}\'')
    return lines


def command_new(args):
    if not DEPLOYMENT_ID.match(args.name) or args.name == "default":
        die("the environment name must match [A-Za-z0-9][A-Za-z0-9._-]{0,127}", 2)
    template = ROOT / "environments" / "examples" / args.cloud / f"{args.template.removesuffix('.tfvars')}.tfvars"
    if not template.is_file():
        names = ", ".join(row["template"] for row in list_templates(args.cloud))
        die(f"no {args.cloud} template named '{args.template}'. Available: {names}", 2)
    destination = ROOT / "environments" / "local" / f"{args.name}.tfvars"
    if destination.exists():
        die(f"{display(destination)} already exists; edit it or choose another name", 2)
    lines = template.read_text().splitlines()
    if args.target:
        target = load_targets().get(args.target)
        if target is None:
            die(f"target '{args.target}' is not defined in {TARGETS_FILE}; see ./infra targets", 2)
        if target.get("cloud") != args.cloud:
            die(f"target '{args.target}' is a {target.get('cloud')} target", 2)
        # The target supplies the account identifiers the template only has placeholders for.
        lines = [
            line for line in lines
            if not any(re.match(rf'^\s*{key}\s*=\s*"{PLACEHOLDER_ID}"', line) for key in ACCOUNT_KEYS)
        ]
        insert_at = 1 if lines and lines[0].startswith("# Scenario:") else 0
        lines[insert_at:insert_at] = [f'target = "{args.target}"']
        lines = apply_target_defaults(lines, args.target, target)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text("\n".join(lines).rstrip("\n") + "\n")
    print(f"Created {display(destination)} from {args.cloud}/{template.stem}.")
    if not args.target and PLACEHOLDER_ID in destination.read_text():
        print("Replace the placeholder account IDs, or add target = \"<name>\" (see ./infra targets).")
    print("Next:")
    print(f"  ./infra explain {args.cloud} {display(destination)}")
    print(f"  ./infra doctor {args.cloud} {display(destination)} --json")
    return 0


# --- explain ------------------------------------------------------------------


def terraform_env(cloud):
    data_dir = ROOT / ".artifacts" / "validate" / cloud / ".terraform"
    data_dir.mkdir(parents=True, exist_ok=True)
    return dict(os.environ, TF_DATA_DIR=str(data_dir), TF_IN_AUTOMATION="1")


def effective_config(cloud, tfvars, target):
    """Evaluate every root variable with Terraform so defaults and validations apply."""
    root = ROOT / "deployments" / cloud
    names = re.findall(r'^variable\s+"([^"]+)"', (root / "variables.tf").read_text(), re.M)
    expression = "jsonencode({" + ", ".join(f"{name} = var.{name}" for name in names) + "})\n"
    explicit = top_level_assignments(tfvars)
    args = [f"-var-file={Path(tfvars).resolve()}", f"-var=deployment_id={deployment_id_for(tfvars)}"]
    for field in TARGET_TERRAFORM_FIELDS[cloud]:
        if field not in explicit and target and target.get(field):
            args.append(f"-var={field}={target[field]}")
    env = terraform_env(cloud)

    def console():
        return subprocess.run(
            ["terraform", f"-chdir={root}", "console", *args],
            input=expression, capture_output=True, text=True, env=env, check=False,
        )

    result = console()
    if result.returncode != 0 and "terraform init" in ANSI.sub("", result.stderr):
        init = subprocess.run(
            ["terraform", f"-chdir={root}", "init", "-backend=false", "-lockfile=readonly", "-input=false"],
            capture_output=True, text=True, env=env, check=False,
        )
        if init.returncode != 0:
            return None, ANSI.sub("", init.stderr or init.stdout).strip()
        result = console()
    if result.returncode != 0:
        return None, ANSI.sub("", result.stderr or result.stdout).strip()
    return json.loads(json.loads(result.stdout.strip())), None


def enabled(config, name):
    return bool(config.get("features", {}).get(name))


def source_paths(cloud, config, components):
    """Return [{source, compute, mode}] for every enabled source with connectivity."""
    paths = []
    for name, component in components.items():
        if not component.get("feature", "").startswith("features.") or not enabled(config, name):
            continue
        modes = config.get("connectivity", {}).get(name, {})
        if "connectivity" not in component and "classic_path_option" not in component:
            continue
        classic = modes.get("classic", "none")
        if cloud == "azure" and name == "sql_database":
            classic = "peering" if config.get("sql_database", {}).get("workspace_peering_enabled") else "none"
        paths.append({"source": name, "compute": "classic", "mode": classic})
        paths.append({"source": name, "compute": "serverless", "mode": modes.get("serverless", "none")})
    return paths


def derived_components(cloud, config, paths):
    active = {(path["source"], path["compute"]): path["mode"] for path in paths}
    derived = set()
    if cloud == "aws":
        if any(mode == "private_link" for (_, compute), mode in active.items() if compute == "classic"):
            derived.add("classic_private_link")
        if enabled(config, "simulated_on_prem") and active.get(("simulated_on_prem", "classic")) == "transit_gateway":
            derived.add("transit_gateway")
    else:
        key_vault = config.get("key_vault", {})
        if key_vault.get("enabled", True) and (enabled(config, "sql_database") or enabled(config, "sql_server_vm")):
            derived.add("key_vault")
        if enabled(config, "workspace") and active.get(("sql_database", "classic")) == "peering":
            derived.add("vnet_peering")
    if enabled(config, "workspace") and any(mode == "private_link" for (_, compute), mode in active.items() if compute == "serverless"):
        derived.add("ncc")
    if enabled(config, "workspace") and config.get("lab_check", {}).get("enabled", True) and any(
        mode != "none" for mode in active.values()
    ):
        derived.add("lab_check")
    return derived


def analyze(cloud, config, manifest, explicit=None, target_name=None, target=None):
    """Turn the effective configuration into a plain-language scenario description."""
    explicit = explicit or {}
    cloud_manifest = manifest["clouds"][cloud]
    components = cloud_manifest["components"]
    modes = cloud_manifest.get("connectivity_modes", {})
    findings = []

    def finding(level, message):
        findings.append({"level": level, "message": message})

    paths = source_paths(cloud, config, components)
    derived = derived_components(cloud, config, paths)
    built = [
        name for name, component in components.items()
        if (component.get("feature", "").startswith("features.") and enabled(config, name)) or name in derived
    ]
    workspace = enabled(config, "workspace")

    # Accounts and target.
    accounts = {key: config.get(key) for key in ("aws_account_id", "databricks_account_id", "subscription_id", "tenant_id") if key in config}
    for key, value in accounts.items():
        if value == PLACEHOLDER_ID:
            finding("error", f"{key} is still the template placeholder; set target = \"<name>\" or the real ID.")
    if cloud == "aws" and not config.get("aws_account_id"):
        finding("warning", "No AWS account is pinned. doctor and plan refuse to run until target or aws_account_id is set (unless ./infra setup already recorded the account for this environment).")
    if target_name and target is None:
        finding("error", f"target '{target_name}' is not defined in {TARGETS_FILE}; add it with ./infra targets add.")

    # Connectivity that cannot work or that is silently ignored.
    for name, component in components.items():
        if "connectivity" not in component or enabled(config, name):
            continue
        modes_set = config.get("connectivity", {}).get(name, {})
        if any(mode != "none" for mode in modes_set.values()):
            finding("warning", f"connectivity.{name} is set but features.{name} is false, so no path is created.")
    if not workspace and any(path["mode"] != "none" for path in paths):
        finding("error", "Network paths need the workspace: set features.workspace = true or set the paths to none.")
    disconnected = sorted({path["source"] for path in paths} - {path["source"] for path in paths if path["mode"] != "none"})
    for source in disconnected:
        finding("info", f"{source} has no classic or serverless path, so no compute can reach it (intended for networking exercises).")

    if cloud == "azure":
        test_vm = config.get("test_vm", {})
        if enabled(config, "test_vm") and test_vm.get("allowed_ssh_source_cidr") in (None, "203.0.113.10/32"):
            finding("error", "test_vm.allowed_ssh_source_cidr must be your public IPv4 address as a /32 (the template value is a documentation address).")
        if enabled(config, "sql_database") and "lab_check" in derived and "key_vault" not in derived:
            finding("info", "Without the Key Vault-backed secret scope, the Azure SQL check only tests TCP reachability and loads no sample data.")
    if cloud == "aws" and config.get("glue_federation", {}).get("databricks_connectivity_enabled") and not enabled(config, "unity_catalog"):
        finding("error", "glue_federation.databricks_connectivity_enabled needs features.unity_catalog.")
    for name in built:
        component = components[name]
        if component.get("cost") == "high":
            finding("warning", f"{name} is expensive ({component.get('cost_note', 'bills hourly')}); destroy the lab when you finish.")

    checks = [
        {
            "source": path["source"],
            "compute": path["compute"],
            "mode": path["mode"],
            "sample_data": path["source"] in SEEDED_SOURCES[cloud] and (cloud != "azure" or "key_vault" in derived),
        }
        for path in paths
        if path["mode"] != "none" and "lab_check" in derived
    ]
    stages = 2 if cloud == "aws" and workspace else 1
    minutes = max([components[name].get("minutes", 5) for name in built] or [0]) + 5
    if "lab_check" in derived:
        minutes += 10 if any(check["compute"] == "classic" for check in checks) else 3
    costs = [components[name].get("cost", "low") for name in built]
    cost = "high" if "high" in costs else "medium" if "medium" in costs else "low"

    return {
        "version": 1,
        "cloud": cloud,
        "target": target_name,
        "accounts": accounts,
        "region": config.get("region") or config.get("location"),
        "components": [
            {"name": name, "summary": components[name].get("summary", ""), "derived": name in derived,
             "cost": components[name].get("cost"), "cost_note": components[name].get("cost_note")}
            for name in built
        ],
        "paths": [dict(path, description=modes.get(path["mode"], "")) for path in paths],
        "checks": checks,
        "stages": stages,
        "endpoint_approval": config.get("endpoint_approval", "auto") if "ncc" in derived else None,
        "estimate": {"minutes": minutes, "cost": cost},
        "findings": findings,
    }


def render_explanation(report, tfvars):
    cloud = report["cloud"]
    lines = [f"Scenario {cloud}/{deployment_id_for(tfvars)} ({display(tfvars)})"]
    account_text = ", ".join(f"{key} {value}" for key, value in report["accounts"].items() if value)
    if report["target"]:
        lines.append(f"Target: {report['target']} ({account_text or 'no account identifiers'})")
    elif account_text:
        lines.append(f"Accounts: {account_text}")
    if report["region"]:
        lines.append(f"Region: {report['region']}")
    lines.append("")
    lines.append("What gets built:")
    for component in report["components"]:
        lines.append(f"  - {component['name']}: {component['summary']}")
    if report["paths"]:
        lines.append("")
        lines.append("Network paths from Databricks compute:")
        for path in report["paths"]:
            if path["mode"] == "none":
                lines.append(f"  - {path['compute']} -> {path['source']}: none (this compute cannot reach it)")
            else:
                lines.append(f"  - {path['compute']} -> {path['source']}: {path['mode']}. {path['description']}")
    lines.append("")
    lines.append("After deploy:")
    if report["stages"] == 2:
        lines.append("  - A new AWS workspace deploys in two stages, with one browser login to the new workspace in between.")
    if report["endpoint_approval"] == "auto":
        lines.append("  - ./infra approves the serverless private endpoint connections right after apply.")
    elif report["endpoint_approval"] == "manual":
        lines.append("  - Serverless private endpoint connections stay pending until you approve them with ./infra endpoints.")
    if report["checks"]:
        lines.append(f"  - ./infra verify {cloud} {display(tfvars)} runs these checks:")
        for check in report["checks"]:
            extra = ", loading the sample tables customers and orders" if check["sample_data"] else ""
            lines.append(f"      {check['compute']} -> {check['source']} over {check['mode']}{extra}")
    else:
        lines.append("  - No lab checks: no source has a compute path.")
    estimate = report["estimate"]
    lines.append(f"  - Typical build time: about {estimate['minutes']} minutes; running cost: {estimate['cost']}.")
    if report["findings"]:
        lines.append("")
        lines.append("Findings:")
        for item in report["findings"]:
            lines.append(f"  [{item['level']}] {item['message']}")
    return "\n".join(lines)


def command_explain(args):
    tfvars = Path(args.tfvars)
    if not tfvars.is_file():
        die(f"tfvars file not found: {tfvars}")
    explicit = top_level_assignments(tfvars)
    target_name = string_value(explicit.get("target"))
    target = load_targets().get(target_name) if target_name else None
    config, error = effective_config(args.cloud, tfvars, target)
    if config is None:
        if args.json:
            print(json.dumps({"version": 1, "cloud": args.cloud, "valid": False, "error": error}, indent=2))
        else:
            print(f"Terraform rejected {display(tfvars)}:\n{error}", file=sys.stderr)
        return 1
    report = analyze(args.cloud, config, load_manifest(), explicit, target_name, target)
    report["valid"] = not any(item["level"] == "error" for item in report["findings"])
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(render_explanation(report, tfvars))
    return 0 if report["valid"] else 1


# --- ls and status ------------------------------------------------------------


def read_json(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None


def age(seconds):
    if seconds < 3600:
        return f"{max(int(seconds // 60), 0)}m"
    if seconds < 86400:
        return f"{int(seconds // 3600)}h"
    return f"{int(seconds // 86400)}d"


def saved_plan(artifacts, name):
    plan = artifacts / f"{name}.tfplan"
    if not plan.exists() or Path(f"{plan}.applied").exists() or Path(f"{plan}.failed").exists():
        return None
    return {"path": display(plan), "created": plan.stat().st_mtime}


def deployment_info(cloud, deployment_id):
    state_dir = ROOT / ".state" / cloud / deployment_id
    artifacts = ROOT / ".artifacts" / cloud / deployment_id
    state_file = state_dir / "terraform.tfstate"
    state = read_json(state_file) if state_file.exists() else None
    binding = state_dir / "environment.path"
    tfvars = binding.read_text().strip() if binding.exists() else None
    outputs = {key: value.get("value") for key, value in (state or {}).get("outputs", {}).items()}
    resources = sum(
        len(resource.get("instances", []))
        for resource in (state or {}).get("resources", [])
        if resource.get("mode") == "managed"
    )
    target = None
    if tfvars and Path(tfvars).is_file():
        target = string_value(top_level_assignments(tfvars).get("target"))
    verify = read_json(artifacts / "verify.json")
    return {
        "cloud": cloud,
        "deployment_id": deployment_id,
        "tfvars": display(tfvars) if tfvars else None,
        "target": target,
        "resources": resources,
        "stage": outputs.get("deployment_stage") or ("complete" if resources else None),
        "workspace_url": outputs.get("workspace_url"),
        "lab_check": outputs.get("lab_check") is not None,
        "pending_endpoints": len(outputs.get("pending_endpoint_acceptances") or outputs.get("pending_endpoint_approvals") or []),
        "state_changed": state_file.stat().st_mtime if state_file.exists() else None,
        "verify": {"status": verify.get("status"), "checked_at": verify.get("checked_at"),
                   "checked": (artifacts / "verify.json").stat().st_mtime} if verify else None,
        "apply_plan": saved_plan(artifacts, "apply"),
        "destroy_plan": saved_plan(artifacts, "destroy"),
    }


def all_deployments():
    found = []
    for cloud in CLOUDS:
        base = ROOT / ".state" / cloud
        if not base.is_dir():
            continue
        for state_dir in sorted(base.iterdir()):
            if state_dir.is_dir() and (state_dir / "terraform.tfstate").exists():
                found.append(deployment_info(cloud, state_dir.name))
    return found


def command_ls(args):
    deployments = all_deployments()
    if args.json:
        print(json.dumps({"version": 1, "deployments": deployments}, indent=2))
        return 0
    if not deployments:
        print("No local deployments.")
        return 0
    now = time.time()
    width = max(len("DEPLOYMENT"), *(len(f"{item['cloud']}/{item['deployment_id']}") for item in deployments))
    print(f"{'DEPLOYMENT':<{width}}  {'RESOURCES':>9}  {'STAGE':<10} {'CHANGED':>7}  {'VERIFY':<14} TARGET")
    for item in deployments:
        verify = item["verify"]
        verify_text = f"{verify['status']} {age(now - verify['checked'])} ago" if verify else ("not run" if item["lab_check"] else "-")
        changed = age(now - item["state_changed"]) if item["state_changed"] else "-"
        print(f"{item['cloud'] + '/' + item['deployment_id']:<{width}}  {item['resources']:>9}  {item['stage'] or 'empty':<10} "
              f"{changed:>7}  {verify_text:<14} {item['target'] or '-'}")
    live = [item for item in deployments if item["resources"]]
    if live:
        stale = [item for item in live if item["state_changed"] and now - item["state_changed"] > 7 * 86400]
        print(f"\n{len(live)} deployment(s) hold cloud resources that bill until destroyed.", end="")
        print(f" {len(stale)} unchanged for over 7 days." if stale else "")
        print("Destroy a finished lab with: ./infra destroy-plan <cloud> <tfvars>, then ./infra destroy ... --confirm destroy-<cloud>")
    return 0


FRESH_PLAN_SECONDS = 3600


def next_action(cloud, tfvars, info):
    shown = display(tfvars)
    now = time.time()
    # Saved plans older than an hour are re-planned rather than applied: the
    # cloud may have drifted and the summary the user reviewed is stale.
    destroy_plan, apply_plan = info["destroy_plan"], info["apply_plan"]
    if destroy_plan and now - destroy_plan["created"] < FRESH_PLAN_SECONDS:
        return f"./infra destroy {cloud} {shown} --confirm destroy-{cloud}", "a destroy plan was just reviewed and waits for confirmation"
    if destroy_plan:
        return f"./infra destroy-plan {cloud} {shown}", f"a destroy plan from {age(now - destroy_plan['created'])} ago exists; plan again and review it before destroying"
    if apply_plan and now - apply_plan["created"] < FRESH_PLAN_SECONDS:
        return f"./infra apply {cloud} {shown}", "a reviewed plan is waiting to be applied"
    if apply_plan:
        return f"./infra plan {cloud} {shown}", f"the saved plan is {age(now - apply_plan['created'])} old; plan again and review it"
    if not info["resources"]:
        return f"./infra plan {cloud} {shown}", "nothing is deployed yet (run ./infra doctor first if authentication is not set up)"
    if info["stage"] == "foundation":
        return f"./infra setup {cloud} {shown} --yes", "stage 1 is applied; log in to the new workspace, then plan stage 2"
    if info["lab_check"] and (
        not info["verify"] or info["verify"]["status"] != "passed" or info["verify"]["checked"] < info["state_changed"]
    ):
        return f"./infra verify {cloud} {shown}", "the network paths have not been verified since the last apply"
    return None, "deployed" + (" and verified" if info["verify"] else "")


def command_status(args):
    tfvars = Path(args.tfvars)
    if not tfvars.is_file():
        die(f"tfvars file not found: {tfvars}")
    info = deployment_info(args.cloud, deployment_id_for(tfvars))
    command, reason = next_action(args.cloud, tfvars, info)
    info["next_action"] = {"command": command, "reason": reason}
    if args.json:
        print(json.dumps(info, indent=2))
        return 0
    print(f"Deployment {args.cloud}/{info['deployment_id']} ({display(tfvars)})")
    print(f"  resources:  {info['resources']}" + (f" (stage {info['stage']})" if info["stage"] else ""))
    if info["workspace_url"]:
        print(f"  workspace:  {info['workspace_url']}")
    if info["verify"]:
        print(f"  verify:     {info['verify']['status']} at {info['verify']['checked_at']}")
    if info["pending_endpoints"]:
        print(f"  endpoints:  {info['pending_endpoints']} recorded as pending at the last apply (./infra endpoints {args.cloud} status shows live state)")
    print(f"Next: {command}  ({reason})" if command else f"Next: nothing to do ({reason})")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(prog="./infra", add_help=False)
    commands = parser.add_subparsers(dest="command", required=True)

    templates = commands.add_parser("templates")
    templates.add_argument("cloud", nargs="?", choices=CLOUDS)
    templates.add_argument("--json", action="store_true")

    new = commands.add_parser("new")
    new.add_argument("cloud", choices=CLOUDS)
    new.add_argument("name")
    new.add_argument("--template", required=True)
    new.add_argument("--target")

    explain = commands.add_parser("explain")
    explain.add_argument("cloud", choices=CLOUDS)
    explain.add_argument("tfvars")
    explain.add_argument("--json", action="store_true")

    ls = commands.add_parser("ls")
    ls.add_argument("--json", action="store_true")

    status = commands.add_parser("status")
    status.add_argument("cloud", choices=CLOUDS)
    status.add_argument("tfvars")
    status.add_argument("--json", action="store_true")

    try:
        args = parser.parse_args(argv)
    except SystemExit:
        print("Run ./infra without arguments for usage.", file=sys.stderr)
        return 2
    handlers = {
        "templates": command_templates,
        "new": command_new,
        "explain": command_explain,
        "ls": command_ls,
        "status": command_status,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
