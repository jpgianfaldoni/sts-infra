#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cloud="${1:-}"
[[ "$cloud" == "aws" || "$cloud" == "azure" ]] || { echo "cloud must be aws or azure" >&2; exit 2; }

terraform -chdir="$ROOT/deployments/$cloud" init -backend=false
terraform -chdir="$ROOT/deployments/$cloud" validate
terraform -chdir="$ROOT/deployments/$cloud" test
terraform fmt -check -recursive "$ROOT/deployments/$cloud" "$ROOT/modules/$cloud"
bash -n "$ROOT/infra"
python3 "$ROOT/tests/check_manifest.py"
python3 "$ROOT/tests/check_python_syntax.py"
python3 "$ROOT/tests/check_links.py"
bash "$ROOT/tests/check_no_secrets.sh"
