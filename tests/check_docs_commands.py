#!/usr/bin/env python3
"""Check that every ./infra command and flag in the Markdown docs exists.

Agents copy commands from AGENTS.md, the skill, and the guides verbatim, so a
renamed subcommand or flag in the docs is a broken instruction. The source of
truth is the usage text that ./infra prints.
"""
import re
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
usage = subprocess.run(["bash", str(root / "infra")], capture_output=True, text=True, check=False).stdout
if "Usage:" not in usage:
    sys.exit("could not read ./infra usage")

subcommands = set(re.findall(r"^\s+\./infra ([a-z-]+)", usage, re.M)) | {"auth"}
flags = set(re.findall(r"(--[a-z][a-z-]*)", usage))
# Flags that belong to other tools on the same line (for example sqlcmd or az).
command_pattern = re.compile(r"\./infra\s+([a-z-]+)((?:[^`|\n;&#]|\\\n)*)")

errors = []
documents = [root / "README.md", root / "AGENTS.md", *root.glob("guides/**/*.md"), *root.glob(".claude/skills/**/*.md")]
for path in documents:
    text = path.read_text()
    joined = re.sub(r"\\\n\s*", " ", text)
    for match in command_pattern.finditer(joined):
        subcommand, rest = match.group(1), match.group(2)
        line = joined.count("\n", 0, match.start()) + 1
        where = f"{path.relative_to(root)}: './infra {subcommand}'"
        if subcommand not in subcommands:
            errors.append(f"{where} is not an ./infra subcommand")
            continue
        for flag in re.findall(r"(?<![\w-])(--[a-z][a-z-]*)", rest):
            if flag not in flags:
                errors.append(f"{where} uses unknown flag {flag}")

if errors:
    print("Documentation references commands that ./infra does not provide:")
    print("\n".join(f"  {error}" for error in sorted(set(errors))))
    sys.exit(1)
print("Documented ./infra commands and flags exist")
