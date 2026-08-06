#!/usr/bin/env python3
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
bad = []
for path in root.rglob("*.md"):
    if ".terraform" in path.parts:
        continue
    for target in re.findall(r"\[[^]]+\]\(([^)]+)\)", path.read_text()):
        if target.startswith(("http://", "https://", "#", "mailto:")):
            continue
        if not (path.parent / target.split("#")[0]).resolve().exists():
            bad.append(f"{path.relative_to(root)}: {target}")
assert not bad, "broken relative links:\n" + "\n".join(bad)
print("Markdown relative links are valid")
