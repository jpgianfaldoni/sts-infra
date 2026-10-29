#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cloud="${1:-}"
[[ "$cloud" == "aws" || "$cloud" == "azure" ]] || { echo "cloud must be aws or azure" >&2; exit 2; }

# Keep validation provider data out of deployments/<cloud>/.terraform and never
# rewrite the committed provider lock file.
export TF_DATA_DIR="$ROOT/.artifacts/validate/$cloud/.terraform"
mkdir -p "$TF_DATA_DIR"

terraform -chdir="$ROOT/deployments/$cloud" init -backend=false -lockfile=readonly
terraform -chdir="$ROOT/deployments/$cloud" validate
terraform -chdir="$ROOT/deployments/$cloud" test
terraform fmt -check -recursive "$ROOT/deployments/$cloud" "$ROOT/modules/$cloud" "$ROOT/modules/shared"
bash -n "$ROOT/infra"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$ROOT/infra" "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh
else
  echo "NOTICE: shellcheck is not installed; skipping shell lint." >&2
fi
bash "$ROOT/tests/test_infra_auth_setup.sh"
python3 "$ROOT/tests/check_manifest.py"
python3 "$ROOT/tests/test_infra_scenario.py"
python3 "$ROOT/tests/test_lab_check_drivers.py" --static
python3 "$ROOT/tests/check_python_syntax.py"
python3 "$ROOT/tests/check_links.py"
python3 "$ROOT/tests/check_docs_commands.py"
bash "$ROOT/tests/check_no_secrets.sh"
