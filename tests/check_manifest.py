#!/usr/bin/env python3
"""Cross-check components.json against the deployment variables.

components.json is the machine-readable catalog agents read first, so every
feature, connectivity mode, option, and auth variable it lists must exist in
deployments/<cloud>/variables.tf with the same allowed values and defaults.
"""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "components.json").read_text())
errors = []

OPENERS = {"(": ")", "{": "}", "[": "]"}
CLOSERS = set(OPENERS.values())


def strip_comments(text):
    out, i, in_string = [], 0, False
    while i < len(text):
        char = text[i]
        if in_string:
            out.append(char)
            if char == "\\" and i + 1 < len(text):
                out.append(text[i + 1])
                i += 1
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
            out.append(char)
        elif char == "#" or text.startswith("//", i):
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = len(text) if end < 0 else end + 2
            continue
        else:
            out.append(char)
        i += 1
    return "".join(out)


def matching(text, start):
    """Return the index of the bracket that closes text[start]."""
    stack, i, in_string = [], start, False
    while i < len(text):
        char = text[i]
        if in_string:
            if char == "\\":
                i += 1
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char in OPENERS:
            stack.append(OPENERS[char])
        elif char in CLOSERS:
            if not stack or stack.pop() != char:
                raise ValueError(f"unbalanced bracket at offset {i}")
            if not stack:
                return i
        i += 1
    raise ValueError(f"unclosed bracket at offset {start}")


def split_top_level(body):
    """Split an HCL object body into entries at top-level newlines or commas."""
    entries, depth, current, in_string = [], 0, [], False
    for char in body:
        if in_string:
            current.append(char)
            if char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char in OPENERS:
            depth += 1
        elif char in CLOSERS:
            depth -= 1
        if depth == 0 and char in "\n,":
            entries.append("".join(current).strip())
            current = []
        else:
            current.append(char)
    entries.append("".join(current).strip())
    return [entry for entry in entries if entry]


def parse_literal(text):
    text = text.strip()
    if text == "null":
        return None
    if text in ("true", "false"):
        return text == "true"
    if re.fullmatch(r"-?\d+(\.\d+)?", text):
        return float(text) if "." in text else int(text)
    if re.fullmatch(r'"[^"]*"', text):
        return text[1:-1]
    if text in ("[]", "{}"):
        return [] if text == "[]" else {}
    return NotImplemented


def parse_type(expr):
    """Return (type_name, default, attributes) for an HCL type expression."""
    expr = expr.strip()
    default = None
    has_optional = expr.startswith("optional(")
    if has_optional:
        inner = expr[len("optional("):matching(expr, len("optional") )]
        parts = split_top_level(inner)
        expr = parts[0]
        default = parse_literal(parts[1]) if len(parts) > 1 else None
    if expr.startswith("object("):
        open_paren = len("object")
        inner = expr[open_paren + 1:matching(expr, open_paren)].strip()
        assert inner.startswith("{"), f"unexpected object type: {expr[:40]}"
        body = inner[1:matching(inner, 0)]
        attributes = {}
        for entry in split_top_level(body):
            name, _, value = entry.partition("=")
            attributes[name.strip()] = parse_type(value)
        return "object", default, attributes
    return re.sub(r"\s+", "", expr), default, {}


def parse_variables(path):
    text = strip_comments(path.read_text())
    variables = {}
    for match in re.finditer(r'^variable\s+"([^"]+)"\s*\{', text, re.M):
        start = match.end() - 1
        block = text[start + 1:matching(text, start)]
        type_match = re.search(r"^\s*type\s*=\s*", block, re.M)
        if type_match:
            expr_start = type_match.end()
            line_end = block.find("\n", expr_start)
            head = block[expr_start:line_end if line_end >= 0 else len(block)]
            bracket = re.search(r"[({\[]", head)
            if bracket:
                end = matching(block, expr_start + bracket.start())
                type_expr = block[expr_start:end + 1]
            else:
                type_expr = head
            type_name, _, attributes = parse_type(type_expr)
        else:
            type_name, attributes = "any", {}
        default = NotImplemented
        default_match = re.search(r"^\s*default\s*=\s*(.*)$", block, re.M)
        if default_match:
            default = parse_literal(default_match.group(1))
        validations = []
        for validation in re.finditer(r"^\s*validation\s*\{", block, re.M):
            v_start = validation.end() - 1
            validations.append(block[v_start + 1:matching(block, v_start)])
        variables[match.group(1)] = {
            "type": type_name,
            "default": default,
            "attributes": attributes,
            "validations": validations,
        }
    return variables


def resolve(variables, path):
    """Return (type_name, default) for a dotted variable path, or None."""
    name, *rest = path.split(".")
    variable = variables.get(name)
    if variable is None:
        return None
    type_name, default, attributes = variable["type"], variable["default"], variable["attributes"]
    for part in rest:
        if part not in attributes:
            return None
        type_name, default, attributes = attributes[part]
    return type_name, default


def allowed_modes(variables):
    """Map var paths to the modes permitted by contains([...], ...) validations."""
    allowed = {}

    def restrict(path, modes):
        allowed[path] = allowed[path] & modes if path in allowed else set(modes)

    for variable in variables.values():
        for validation in variable["validations"]:
            for match in re.finditer(r"contains\(\s*\[([^\]]*)\]\s*,\s*([\w.]+)\s*\)", validation):
                modes = set(re.findall(r'"([^"]+)"', match.group(1)))
                target = match.group(2)
                if target.startswith("var."):
                    restrict(target[len("var."):], modes)
                    continue
                loop = re.search(r"for\s+" + re.escape(target) + r"\s+in\s+\[([^\]]*)\]", validation)
                if loop:
                    for item in re.findall(r"var\.([\w.]+)", loop.group(1)):
                        restrict(item, modes)
    return allowed


def paths_of(variables, name, prefix):
    variable = variables.get(name)
    if variable is None:
        return set()
    found = set()

    def walk(attributes, current):
        for attr, (type_name, _, children) in attributes.items():
            if children:
                walk(children, f"{current}.{attr}")
            else:
                found.add(f"{current}.{attr}")

    walk(variable["attributes"], prefix)
    return found


assert manifest["schema_version"] == 4, "components.json schema_version must be 4"
for cloud, config in manifest["clouds"].items():
    deployment = root / config["root"]
    assert deployment.is_dir(), f"missing {cloud} root"
    variables = parse_variables(deployment / "variables.tf")
    modes_by_path = allowed_modes(variables)

    declared_features = {f"features.{name}" for name in variables["features"]["attributes"]}
    manifest_features = set()
    manifest_connectivity = {}
    for name, component in config["components"].items():
        label = f"{cloud}.{name}"
        # Modules shared by both clouds live under modules/shared.
        module_name = component["module"]
        module = root / "modules" / (module_name if module_name.startswith("shared/") else f"{cloud}/{module_name}")
        if not module.is_dir():
            errors.append(f"{label}: missing module {module.relative_to(root)}")
        for field in ("summary", "minutes", "cost"):
            if field not in component:
                errors.append(f"{label}: missing {field}")
        if component.get("cost") not in (None, "low", "medium", "high"):
            errors.append(f"{label}: cost must be low, medium, or high")
        feature = component.get("feature")
        if not feature:
            errors.append(f"{label}: missing feature")
        elif feature.startswith("features."):
            manifest_features.add(feature)
        elif not feature.startswith("derived."):
            errors.append(f"{label}: feature must start with features. or derived.: {feature}")
        for dependency in component.get("dependencies", []):
            if dependency not in config["components"]:
                errors.append(f"{label}: unknown dependency {dependency}")
        for kind, connectivity in component.get("connectivity", {}).items():
            manifest_connectivity[connectivity["path"]] = (label, kind, set(connectivity["modes"]))
        for option_name, option in component.get("options", {}).items():
            where = f"{label}.options.{option_name}"
            resolved = resolve(variables, option["path"])
            if resolved is None:
                errors.append(f"{where}: {option['path']} is not a variable or attribute")
                continue
            type_name, default = resolved
            if option.get("type") and option["type"] != type_name:
                errors.append(f"{where}: type {option['type']} does not match variables.tf ({type_name})")
            if "default" in option and default is not NotImplemented and option["default"] != default:
                errors.append(f"{where}: default {option['default']!r} does not match variables.tf ({default!r})")
            if "allowed" in option:
                parsed = modes_by_path.get(option["path"])
                if parsed is None:
                    errors.append(f"{where}: no contains() validation found for {option['path']}")
                elif set(option["allowed"]) != parsed:
                    errors.append(f"{where}: allowed {sorted(option['allowed'])} != validation {sorted(parsed)}")

    for missing in sorted(declared_features - manifest_features):
        errors.append(f"{cloud}: {missing} exists in variables.tf but not in components.json")
    for extra in sorted(manifest_features - declared_features):
        errors.append(f"{cloud}: {extra} is in components.json but not in variables.tf")

    declared_connectivity = paths_of(variables, "connectivity", "connectivity")
    for path in sorted(declared_connectivity - set(manifest_connectivity)):
        errors.append(f"{cloud}: {path} exists in variables.tf but not in components.json")
    for path, (label, kind, modes) in sorted(manifest_connectivity.items()):
        if path not in declared_connectivity:
            errors.append(f"{label}.connectivity.{kind}: {path} is not in variables.tf")
            continue
        parsed = modes_by_path.get(path)
        if parsed is None:
            errors.append(f"{label}.connectivity.{kind}: no contains() validation restricts {path}")
        elif parsed != modes:
            errors.append(f"{label}.connectivity.{kind}: modes {sorted(modes)} != validation {sorted(parsed)}")

    for auth_variable in config.get("auth_variables", []):
        if auth_variable["name"] not in variables:
            errors.append(f"{cloud}.auth_variables: {auth_variable['name']} is not declared in variables.tf")

assert not errors, "component manifest drift:\n" + "\n".join(errors)
print("component manifest is consistent with variables.tf")
