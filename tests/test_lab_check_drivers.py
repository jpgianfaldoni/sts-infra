#!/usr/bin/env python3
"""Check the database driver sets the lab check notebook installs.

The notebook installs each driver set with `pip install --no-deps`, so every
set must pin exact versions and include all of its own dependencies. With
--static only those rules are checked (no network). Without it, each set is
installed from the configured package index into a temporary directory and the
APIs the notebook calls are exercised in an isolated interpreter, which catches
an upstream release that breaks a pinned combination.
"""
import argparse
import ast
import subprocess
import sys
import tempfile
from pathlib import Path

NOTEBOOK = Path(__file__).resolve().parents[1] / "modules" / "shared" / "lab-check" / "notebooks" / "lab_check.py"

# Attributes the notebook uses from each driver; importing them proves the
# installed set is coherent (scramp 1.5 removed make_channel_binding).
SMOKE = {
    "postgresql": "import pg8000.native, scramp, dateutil; pg8000.native.Connection; pg8000.native.DatabaseError; "
    "pg8000.native.InterfaceError; scramp.make_channel_binding",
    "sqlserver": "import pymssql; pymssql.connect; pymssql.Error",
}

# Resolves each installed distribution's requirements against the others.
COMPLETENESS = r"""
import importlib.metadata, sys
from pip._vendor.packaging.requirements import Requirement
from pip._vendor.packaging.utils import canonicalize_name
dists = {canonicalize_name(d.metadata["Name"]): d for d in importlib.metadata.distributions(path=[sys.argv[1]])}
missing = []
for dist in dists.values():
    for raw in dist.requires or []:
        req = Requirement(raw)
        if req.marker is not None and not req.marker.evaluate({"extra": ""}):
            continue
        found = dists.get(canonicalize_name(req.name))
        if found is None or not req.specifier.contains(found.version, prereleases=True):
            missing.append(f"{dist.metadata['Name']} requires {raw}")
print("\n".join(missing))
sys.exit(1 if missing else 0)
"""


def load_drivers():
    tree = ast.parse(NOTEBOOK.read_text())
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "DRIVERS" for t in node.targets):
            return ast.literal_eval(node.value)
    sys.exit(f"FAIL: DRIVERS not found in {NOTEBOOK}")


def check_static(drivers):
    errors = []
    if set(drivers) != set(SMOKE):
        errors.append(f"DRIVERS engines {sorted(drivers)} do not match the smoke tests {sorted(SMOKE)}")
    for engine, (packages, _module) in drivers.items():
        for package in packages:
            name, sep, version = package.partition("==")
            if not sep or not name or not version or any(c in version for c in "<>=!~,*"):
                errors.append(f"{engine}: {package!r} must pin an exact version (name==version)")
    return errors


def check_installed(drivers):
    errors = []
    for engine, (packages, _module) in drivers.items():
        with tempfile.TemporaryDirectory(prefix=f"lab-check-{engine}-") as target:
            install = subprocess.run(
                [sys.executable, "-m", "pip", "install", "--quiet", "--disable-pip-version-check", "--no-deps",
                 "--target", target, *packages],
                capture_output=True, text=True,
            )
            if install.returncode != 0:
                errors.append(f"{engine}: pip could not install {' '.join(packages)}:\n{install.stderr.strip()[-1500:]}")
                continue
            complete = subprocess.run([sys.executable, "-c", COMPLETENESS, target], capture_output=True, text=True)
            if complete.returncode != 0:
                errors.append(f"{engine}: the pinned set is missing dependencies:\n{complete.stdout.strip()}{complete.stderr.strip()}")
            # -I ignores user site-packages and PYTHONPATH, so only the pinned
            # set (plus the standard library) is importable.
            smoke = subprocess.run(
                [sys.executable, "-I", "-c", f"import sys; sys.path.insert(0, {target!r}); {SMOKE[engine]}"],
                capture_output=True, text=True,
            )
            if smoke.returncode != 0:
                errors.append(f"{engine}: the driver API check failed:\n{smoke.stderr.strip()[-1500:]}")
            else:
                print(f"ok - {engine}: {' '.join(packages)}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--static", action="store_true", help="check the pins only; do not install anything")
    args = parser.parse_args()
    drivers = load_drivers()
    errors = check_static(drivers)
    if not errors and not args.static:
        errors = check_installed(drivers)
    if errors:
        print("\n".join(f"FAIL: {error}" for error in errors), file=sys.stderr)
        return 1
    print("lab check driver sets are " + ("pinned" if args.static else "pinned, complete, and working"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
