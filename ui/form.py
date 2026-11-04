#!/usr/bin/env python3
"""Form model for environment files behind the local web UI.

Turns the effective Terraform configuration of a tfvars file into a small
form (target, region, features, connectivity, endpoint approval) and writes
the form back into the file while keeping every other line in place, so the
templates' comments and advanced settings survive editing.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import infra_scenario as scenario  # noqa: E402

AZURE_ONLY_KEYS = ("subscription_id", "tenant_id", "location")
AWS_ONLY_KEYS = ("aws_account_id", "region")
REGION_KEY = {"aws": "region", "azure": "location"}


def environment_cloud(path, targets):
    """Infer the cloud of an environment file from its target or account keys."""
    values = scenario.top_level_assignments(path)
    target = scenario.string_value(values.get("target"))
    if target and target in targets and targets[target].get("cloud") in scenario.CLOUDS:
        return targets[target]["cloud"]
    if any(key in values for key in AZURE_ONLY_KEYS):
        return "azure"
    if any(key in values for key in AWS_ONLY_KEYS):
        return "aws"
    text = Path(path).read_text()
    azure_features = ("sql_database", "test_vm", "custom_dns", "external_volume_storage", "sql_server_vm")
    return "azure" if any(re.search(rf"^\s*{name}\s*=", text, re.M) for name in azure_features) else "aws"


def form_model(cloud, config, manifest):
    components = manifest["clouds"][cloud]["components"]
    features = {
        name: bool(config.get("features", {}).get(name))
        for name, component in components.items()
        if component.get("feature", "").startswith("features.")
    }
    connectivity = {}
    for name, component in components.items():
        declared = component.get("connectivity", {})
        option = component.get("classic_path_option")
        if not declared and not option:
            continue
        modes = config.get("connectivity", {}).get(name, {})
        entry = {}
        if "classic" in declared:
            entry["classic"] = {"mode": modes.get("classic", "none"), "allowed": declared["classic"]["modes"]}
        elif option:
            enabled = bool((config.get(name) or {}).get(option))
            entry["classic"] = {"mode": "peering" if enabled else "none", "allowed": ["none", "peering"], "option": option}
        if "serverless" in declared:
            entry["serverless"] = {"mode": modes.get("serverless", "none"), "allowed": declared["serverless"]["modes"]}
        connectivity[name] = entry
    return {
        "cloud": cloud,
        "target": None,
        "region": config.get(REGION_KEY[cloud]),
        "endpoint_approval": config.get("endpoint_approval") or "auto",
        "features": features,
        "connectivity": connectivity,
    }


# --- line editing -------------------------------------------------------------


def top_level_index(lines, key):
    depth = 0
    for i, line in enumerate(lines):
        code = scenario.strip_comment(line)
        if depth == 0 and re.match(rf"^\s*{key}\s*=", code):
            return i
        depth += sum(code.count(c) for c in "{[") - sum(code.count(c) for c in "}]")
        depth = max(depth, 0)
    return None


def last_top_level_assignment(lines):
    """Index after the header assignments: the scalar `key = value` lines before the first block."""
    index = 1 if lines and lines[0].startswith("# Scenario:") else 0
    for i, line in enumerate(lines):
        code = scenario.strip_comment(line)
        if re.search(r"[{\[]\s*$", code):
            break
        if re.match(r"^\s*[A-Za-z_][A-Za-z0-9_]*\s*=\s*[^{\[]", code):
            index = i + 1
    return index


def hcl_literal(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "null"
    if isinstance(value, (int, float)):
        return str(value)
    return '"' + str(value).replace('"', '\\"') + '"'


def set_top_level(lines, key, value):
    """Set, or with value None remove, a top-level scalar assignment."""
    index = top_level_index(lines, key)
    if value is None:
        if index is not None:
            del lines[index]
        return lines
    rendered = f"{key} = {hcl_literal(value)}"
    if index is not None:
        lines[index] = rendered
    else:
        lines.insert(last_top_level_assignment(lines), rendered)
    return lines


def aligned(pairs, indent="  "):
    if not pairs:
        return []
    width = max(len(key) for key, _ in pairs)
    return [f"{indent}{key:<{width}} = {value}" for key, value in pairs]


def replace_block(lines, key, body):
    """Replace the top-level `key = { ... }` block with body lines (none removes it)."""
    bounds = scenario.block_bounds(lines, key)
    block = [f"{key} = {{", *body, "}"] if body else []
    if bounds:
        start, end = bounds
        if not block and start > 0 and lines[start - 1].strip() == "":
            start -= 1
        lines[start:end + 1] = block
    elif block:
        lines += ["", *block]
    return lines


def set_block_key(lines, block, key, value):
    bounds = scenario.block_bounds(lines, block)
    if bounds is None:
        lines += ["", f"{block} = {{", f"  {key} = {hcl_literal(value)}", "}"]
        return lines
    start, end = bounds
    for i in range(start + 1, end):
        if re.match(rf"^\s*{key}\s*=", scenario.strip_comment(lines[i])):
            lines[i] = f"  {key} = {hcl_literal(value)}"
            return lines
    lines.insert(end, f"  {key} = {hcl_literal(value)}")
    return lines


def apply_form(lines, model, manifest):
    cloud = model["cloud"]
    components = manifest["clouds"][cloud]["components"]
    set_top_level(lines, "target", model.get("target") or None)
    if model.get("target"):
        # The target supplies the account identifiers; drop template placeholders.
        lines[:] = [
            line for line in lines
            if not any(re.match(rf'^\s*{key}\s*=\s*"{scenario.PLACEHOLDER_ID}"', line) for key in scenario.ACCOUNT_KEYS)
        ]
    if model.get("region"):
        set_top_level(lines, REGION_KEY[cloud], model["region"])
    if model.get("endpoint_approval"):
        set_top_level(lines, "endpoint_approval", model["endpoint_approval"])

    features = model.get("features", {})
    replace_block(lines, "features", aligned([(name, hcl_literal(bool(on))) for name, on in features.items() if name in components]))

    body = []
    for name, entry in model.get("connectivity", {}).items():
        component = components.get(name)
        if component is None or not features.get(name):
            continue
        declared = component.get("connectivity", {})
        option = component.get("classic_path_option")
        if option and "classic" in entry:
            set_block_key(lines, name, option, entry["classic"].get("mode", "none") != "none")
        pairs = [
            (compute, hcl_literal(entry.get(compute, {}).get("mode", "none")))
            for compute in ("classic", "serverless")
            if compute in declared
        ]
        if pairs:
            body += [f"  {name} = {{", *aligned(pairs, "    "), "  }"]
    replace_block(lines, "connectivity", body)
    return lines


def write_form(path, model, manifest):
    path = Path(path)
    lines = path.read_text().splitlines()
    apply_form(lines, model, manifest)
    path.write_text("\n".join(lines).rstrip("\n") + "\n")
