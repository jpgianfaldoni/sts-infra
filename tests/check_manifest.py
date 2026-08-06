#!/usr/bin/env python3
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "components.json").read_text())
assert manifest["schema_version"] == 2
for cloud, config in manifest["clouds"].items():
    assert (root / config["root"]).is_dir(), f"missing {cloud} root"
    for name, component in config["components"].items():
        module = root / "modules" / cloud / component["module"]
        assert module.is_dir(), f"missing module for {cloud}.{name}: {module}"
        assert "feature" in component
print("component manifest is consistent")
