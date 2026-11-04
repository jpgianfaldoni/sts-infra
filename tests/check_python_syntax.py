#!/usr/bin/env python3
"""Parse the Databricks notebooks under modules/; nothing else in the suite imports them.

lib/ and tests/ are executed by the other checks, so a syntax error there fails anyway.
"""
import ast
from pathlib import Path

root = Path(__file__).resolve().parents[1]
for path in root.glob("modules/**/*.py"):
    ast.parse(path.read_text(), filename=str(path))
print("Notebook Python syntax is valid")
