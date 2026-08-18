#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/state"
AUTH_CONFIG="$TEST_DIR/config/auth.json"
CALL_LOG="$TEST_DIR/calls.log"

cat > "$TEST_DIR/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws %s\n' "$*" >> "$TEST_CALL_LOG"
case "${1:-} ${2:-}" in
  "configure list-profiles")
    [[ ! -f "$TEST_STATE_DIR/aws-configured" ]] || echo "test-aws"
    ;;
  "configure sso")
    touch "$TEST_STATE_DIR/aws-configured"
    ;;
  "sso login")
    touch "$TEST_STATE_DIR/aws-logged-in"
    ;;
  "sts get-caller-identity")
    [[ -f "$TEST_STATE_DIR/aws-logged-in" ]] || exit 1
    printf '{"Account":"123456789012","Arn":"arn:aws:sts::123456789012:assumed-role/test/user"}\n'
    ;;
  *)
    echo "unexpected aws invocation: $*" >&2
    exit 1
    ;;
esac
EOF

cat > "$TEST_DIR/bin/databricks" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'databricks %s\n' "$*" >> "$TEST_CALL_LOG"
case "${1:-} ${2:-}" in
  "auth describe")
    printf '{"status":"success","account_id":"00000000-0000-0000-0000-000000000000","details":{"host":"https://accounts.cloud.databricks.com"}}\n'
    ;;
  "account workspaces")
    [[ -f "$TEST_STATE_DIR/databricks-logged-in" ]] || exit 1
    printf '[]\n'
    ;;
  "auth login")
    touch "$TEST_STATE_DIR/databricks-logged-in"
    ;;
  *)
    echo "unexpected databricks invocation: $*" >&2
    exit 1
    ;;
esac
EOF

cat > "$TEST_DIR/bin/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'az %s\n' "$*" >> "$TEST_CALL_LOG"
case "${1:-} ${2:-}" in
  "account show")
    [[ -f "$TEST_STATE_DIR/azure-logged-in" ]] || exit 1
    printf '{"id":"00000000-0000-0000-0000-000000000000"}\n'
    ;;
  "login ")
    touch "$TEST_STATE_DIR/azure-logged-in"
    printf '[]\n'
    ;;
  *)
    echo "unexpected az invocation: $*" >&2
    exit 1
    ;;
esac
EOF

chmod +x "$TEST_DIR/bin/aws" "$TEST_DIR/bin/databricks" "$TEST_DIR/bin/az"

export PATH="$TEST_DIR/bin:$PATH"
export STS_INFRA_AUTH_CONFIG="$AUTH_CONFIG"
export TEST_CALL_LOG="$CALL_LOG"
export TEST_STATE_DIR="$TEST_DIR/state"
unset AWS_PROFILE DATABRICKS_ACCOUNT_PROFILE DATABRICKS_CONFIG_PROFILE DATABRICKS_WORKSPACE_PROFILE

if ! printf 'test-aws\n\ntest-databricks\n' | \
  "$ROOT/infra" setup aws "$ROOT/environments/examples/aws/workspace-postgres.tfvars" \
    >"$TEST_DIR/setup.out" 2>"$TEST_DIR/setup.err"; then
  cat "$TEST_DIR/setup.err" >&2
  exit 1
fi

jq -e '
  .version == 1 and
  .deployments["aws/workspace-postgres"].aws_profile == "test-aws" and
  .deployments["aws/workspace-postgres"].aws_account_id == "123456789012" and
  .deployments["aws/workspace-postgres"].databricks_account_id == "00000000-0000-0000-0000-000000000000" and
  .deployments["aws/workspace-postgres"].databricks_account_profile == "test-databricks"
' "$AUTH_CONFIG" >/dev/null

CONFIG_MODE="$(stat -f '%Lp' "$AUTH_CONFIG" 2>/dev/null || stat -c '%a' "$AUTH_CONFIG")"
[[ "$CONFIG_MODE" == "600" ]] || { echo "authentication config mode is $CONFIG_MODE, expected 600" >&2; exit 1; }

rg -q '^aws configure sso --profile test-aws$' "$CALL_LOG"
rg -q '^aws sso login --profile test-aws$' "$CALL_LOG"
rg -q '^databricks auth login --host https://accounts.cloud.databricks.com --account-id 00000000-0000-0000-0000-000000000000 --profile test-databricks$' "$CALL_LOG"

: > "$CALL_LOG"
"$ROOT/infra" doctor aws "$ROOT/environments/examples/aws/workspace-postgres.tfvars" >/dev/null
rg -q '^aws sts get-caller-identity --output json --region us-west-2 --profile test-aws$' "$CALL_LOG"
rg -q '^databricks auth describe --profile test-databricks --output json$' "$CALL_LOG"
rg -q '^databricks account workspaces list --profile test-databricks --output json$' "$CALL_LOG"

: > "$CALL_LOG"
"$ROOT/infra" setup azure "$ROOT/environments/examples/azure/workspace-sql.tfvars" >/dev/null
rg -q '^az login$' "$CALL_LOG"
rg -q '^az account show --subscription 00000000-0000-0000-0000-000000000000 --output json$' "$CALL_LOG"

echo "interactive auth setup test passed"
