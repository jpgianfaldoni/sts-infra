#!/usr/bin/env python3
import ast
from pathlib import Path

root = Path(__file__).resolve().parents[1]
for path in [*root.glob("modules/**/*.py"), *root.glob("tests/*.py")]:
    ast.parse(path.read_text(), filename=str(path))
print("Python syntax is valid")
