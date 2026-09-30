#!/usr/bin/env bash
# Exercises ./infra authentication (setup, doctor, preflight) against stub
# aws/az/databricks/terraform CLIs in a disposable copy of the repository.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

ROOT="$TEST_DIR/root"
mkdir -p "$ROOT/deployments/aws" "$ROOT/deployments/azure" "$ROOT/modules/aws" "$ROOT/modules/azure" \
  "$ROOT/environments/local" "$TEST_DIR/bin" "$TEST_DIR/state"
cp "$REPO/infra" "$REPO/components.json" "$ROOT/"
cp "$REPO/deployments/aws/providers.tf" "$ROOT/deployments/aws/"
cp "$REPO/deployments/azure/providers.tf" "$ROOT/deployments/azure/"
INFRA="$ROOT/infra"
AUTH_CONFIG="$TEST_DIR/config/auth.json"
CALL_LOG="$TEST_DIR/calls.log"
ERR_FILE="$TEST_DIR/stderr.log"

cat > "$TEST_DIR/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws %s\n' "$*" >> "$TEST_CALL_LOG"
[[ -z "${AWS_ACCESS_KEY_ID:-}" ]] || printf 'aws-env AWS_ACCESS_KEY_ID set for: %s\n' "$*" >> "$TEST_CALL_LOG"
profile=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[i]}" != "--profile" ]] || profile="${args[i + 1]}"
done
config="$AWS_CONFIG_FILE"
case "${1:-} ${2:-}" in
  "--version ")
    echo "aws-cli/2.27.14 Python/3.13.3 Darwin/25.6.0 exe/x86_64"
    ;;
  "configure list-profiles")
    [[ ! -f "$config" ]] || sed -n 's/^\[profile \(.*\)\]$/\1/p' "$config"
    ;;
  "configure set")
    touch "$config"
    grep -qxF "[profile $profile]" "$config" || printf '[profile %s]\n' "$profile" >> "$config"
    printf '%s' "$4" > "$TEST_STATE_DIR/aws-config-$profile-$3"
    ;;
  "configure get")
    cat "$TEST_STATE_DIR/aws-config-$profile-$3" 2>/dev/null || exit 1
    ;;
  "configure sso")
    printf '[profile %s]\n' "$profile" >> "$config"
    ;;
  "sso login")
    touch "$TEST_STATE_DIR/aws-login-$profile"
    ;;
  "sts get-caller-identity")
    if [[ -n "$profile" ]]; then
      [[ -f "$TEST_STATE_DIR/aws-login-$profile" ]] || exit 255
      account="$(cat "$TEST_STATE_DIR/aws-account-$profile" 2>/dev/null || echo 123456789012)"
    else
      [[ -n "${AWS_ACCESS_KEY_ID:-}" ]] || exit 255
      account=210987654321
    fi
    printf '{"Account":"%s","Arn":"arn:aws:sts::%s:assumed-role/Admin/tester"}\n' "$account" "$account"
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
[[ -z "${DATABRICKS_CONFIG_PROFILE:-}" ]] || printf 'databricks-env DATABRICKS_CONFIG_PROFILE set for: %s\n' "$*" >> "$TEST_CALL_LOG"
dir="$TEST_STATE_DIR/db"
mkdir -p "$dir"
profile="" host="" account=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --profile) profile="${args[i + 1]}" ;;
    --host) host="${args[i + 1]}" ;;
    --account-id) account="${args[i + 1]}" ;;
  esac
done
case "${1:-} ${2:-}" in
  "auth profiles")
    shopt -s nullglob
    files=("$dir"/*.json)
    if ((${#files[@]} > 0)); then jq -s '{profiles: .}' "${files[@]}"; else echo '{"profiles":[]}'; fi
    ;;
  "auth login")
    if [[ " $* " == *" --help "* ]]; then
      echo "      --skip-workspace   Skip workspace selection for account-level access"
      exit 0
    fi
    jq -n --arg name "$profile" --arg host "$host" --arg account "$account" \
      '{name: $name, host: $host} + (if $account == "" then {} else {account_id: $account} end)' > "$dir/$profile.json"
    touch "$dir/$profile.login"
    ;;
  "auth describe")
    [[ -f "$dir/$profile.json" ]] || exit 1
    echo '{"status":"success","username":"tester@example.com"}'
    ;;
  "account workspaces"|"account metastores")
    if [[ -n "$profile" ]]; then
      [[ -f "$dir/$profile.login" ]] || exit 1
    elif [[ "${DATABRICKS_AUTH_TYPE:-}" == "azure-cli" ]]; then
      [[ -f "$TEST_STATE_DIR/azure-login" && -z "${TEST_AZ_NOT_ACCOUNT_ADMIN:-}" ]] || exit 1
    else
      [[ -n "${TEST_DB_ENV_CREDENTIALS:-}" ]] || exit 1
    fi
    if [[ "$2" == "workspaces" ]]; then echo "${TEST_DB_WORKSPACES:-[]}"; else echo '[]'; fi
    ;;
  "current-user me")
    if [[ -n "$profile" ]]; then
      [[ -f "$dir/$profile.login" ]] || exit 1
      profile_host="$(jq -r .host "$dir/$profile.json")"
      if [[ -n "${DATABRICKS_HOST:-}" && "${DATABRICKS_HOST%/}" != "${profile_host%/}" ]]; then
        [[ -n "${TEST_ACCOUNT_PROFILE_WORKS_ON_WORKSPACE:-}" ]] || exit 1
      fi
    elif [[ "${DATABRICKS_AUTH_TYPE:-}" == "azure-cli" ]]; then
      [[ -f "$TEST_STATE_DIR/azure-login" ]] || exit 1
    else
      [[ -n "${TEST_DB_ENV_CREDENTIALS:-}" ]] || exit 1
    fi
    echo '{"userName":"tester@example.com"}'
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
    [[ -f "$TEST_STATE_DIR/azure-login" ]] || exit 1
    printf '{"id":"00000000-0000-0000-0000-000000000000","tenantId":"%s","user":{"name":"tester@example.com","type":"user"}}\n' \
      "${TEST_AZ_TENANT:-11111111-1111-1111-1111-111111111111}"
    ;;
  "account get-access-token")
    [[ -f "$TEST_STATE_DIR/azure-login" && ! -f "$TEST_STATE_DIR/azure-expired" ]] || exit 1
    echo "2026-09-28 12:00:00.000000"
    ;;
  "network private-endpoint-connection")
    id=""
    for ((i = 1; i <= $#; i++)); do
      [[ "${!i}" != "--id" ]] || { j=$((i + 1)); id="${!j}"; }
    done
    case "$3" in
      list)
        printf '[{"id":"%s/privateEndpointConnections/conn-1","properties":{"privateEndpoint":{"id":"/subscriptions/databricks/resourceGroups/ncc/providers/Microsoft.Network/privateEndpoints/databricks-pe-1"},"privateLinkServiceConnectionState":{"status":"Pending"}}}]\n' "$id"
        ;;
      approve|reject)
        printf '{"id":"%s","properties":{"privateLinkServiceConnectionState":{"status":"%s"}}}\n' "$id" "$([[ "$3" == approve ]] && echo Approved || echo Rejected)"
        ;;
    esac
    ;;
  login*)
    printf 'az-login-env AZURE_CORE_LOGIN_EXPERIENCE_V2=%s\n' "${AZURE_CORE_LOGIN_EXPERIENCE_V2:-}" >> "$TEST_CALL_LOG"
    touch "$TEST_STATE_DIR/azure-login"
    rm -f "$TEST_STATE_DIR/azure-expired"
    ;;
  *)
    echo "unexpected az invocation: $*" >&2
    exit 1
    ;;
esac
EOF

cat > "$TEST_DIR/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'terraform %s\n' "$*" >> "$TEST_CALL_LOG"
[[ -z "${AWS_ACCESS_KEY_ID:-}" ]] || printf 'terraform-env AWS_ACCESS_KEY_ID set for: %s\n' "$*" >> "$TEST_CALL_LOG"
[[ -z "${DATABRICKS_CONFIG_PROFILE:-}" ]] || printf 'terraform-env DATABRICKS_CONFIG_PROFILE set for: %s\n' "$*" >> "$TEST_CALL_LOG"
[[ "${1:-}" != -chdir=* ]] || shift
case "${1:-}" in
  version) echo '{"terraform_version":"1.14.6"}' ;;
  init|apply|state) : ;;
  plan)
    for arg in "$@"; do
      [[ "$arg" != -out=* ]] || echo plan > "${arg#-out=}"
    done
    ;;
  show)
    if [[ -n "${TEST_PLAN_JSON:-}" ]]; then cat "$TEST_PLAN_JSON"; else echo '{"resource_changes":[]}'; fi
    ;;
  output)
    if [[ -n "${TEST_OUTPUT_JSON:-}" ]]; then echo "$TEST_OUTPUT_JSON"; else echo '{}'; fi
    ;;
  *)
    echo "unexpected terraform invocation: $*" >&2
    exit 1
    ;;
esac
EOF

chmod +x "$TEST_DIR/bin/"*

export PATH="$TEST_DIR/bin:$PATH"
export STS_INFRA_AUTH_CONFIG="$AUTH_CONFIG"
export TEST_CALL_LOG="$CALL_LOG"
export TEST_STATE_DIR="$TEST_DIR/state"
export AWS_CONFIG_FILE="$TEST_DIR/aws-config"
export HOME="$TEST_DIR/home"
mkdir -p "$HOME"
export STS_INFRA_RETRY_DELAY=0
export STS_INFRA_WAIT_INTERVAL=1
unset AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_REGION AWS_DEFAULT_REGION \
  DATABRICKS_ACCOUNT_PROFILE DATABRICKS_CONFIG_PROFILE DATABRICKS_WORKSPACE_PROFILE DATABRICKS_HOST DATABRICKS_TOKEN \
  DATABRICKS_CLIENT_ID DATABRICKS_CLIENT_SECRET DATABRICKS_AUTH_TYPE ARM_CLIENT_ID ARM_USE_MSI ARM_USE_OIDC INFRA_DEPLOYMENT_ID

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
pass() { echo "ok - $*"; }
reset_log() { : > "$CALL_LOG"; }
expect_log() {
  grep -Eq -- "$1" "$CALL_LOG" || { cat "$CALL_LOG" >&2; fail "expected a call matching: $1"; }
}
expect_no_log() {
  if grep -Eq -- "$1" "$CALL_LOG"; then
    cat "$CALL_LOG" >&2
    fail "unexpected call matching: $1"
  fi
}
# Usage: run [NAME=value ...] <command...>; sets OUT (stdout), ERR (stderr), CODE.
run() {
  set +e
  OUT="$(env "$@" </dev/null 2>"$ERR_FILE")"
  CODE=$?
  set -e
  ERR="$(cat "$ERR_FILE")"
}
expect_code() {
  [[ "$CODE" == "$1" ]] || { printf 'stdout:\n%s\nstderr:\n%s\n' "$OUT" "$ERR" >&2; fail "$2: expected exit $1, got $CODE"; }
}
# Usage: expect_json [jq options] <filter> <failure message>
expect_json() {
  local message="${*: -1}"
  jq -e "${@:1:$#-1}" <<< "$OUT" >/dev/null || { printf '%s\n' "$OUT" >&2; fail "$message"; }
}
expect_text() {
  [[ "$OUT$ERR" == *"$1"* ]] || { printf 'stdout:\n%s\nstderr:\n%s\n' "$OUT" "$ERR" >&2; fail "$2"; }
}

ACCOUNT_ID="00000000-0000-0000-0000-000000000000"
FAKE_AWS_SECRET="not-a-real-secret"
AWS_VARS="$ROOT/environments/local/aws-lab.tfvars"
cat > "$AWS_VARS" <<EOF
databricks_account_id = "$ACCOUNT_ID" # lab account
aws_account_id        = "123456789012"
region                = "us-east-1" // comment
aws_profile           = null

features = {
  workspace     = true
  unity_catalog = true
}
EOF
SECOND_VARS="$ROOT/environments/local/aws-second.tfvars"
cat > "$SECOND_VARS" <<EOF
databricks_account_id = "$ACCOUNT_ID"
aws_account_id        = "123456789012"
EOF
AUTO_VARS="$ROOT/environments/local/aws-auto.tfvars"
cat > "$AUTO_VARS" <<'EOF'
databricks_account_id = "11111111-2222-3333-4444-555555555555"
EOF
AZURE_VARS="$ROOT/environments/local/azure-lab.tfvars"
cat > "$AZURE_VARS" <<EOF
subscription_id       = "00000000-0000-0000-0000-000000000000"
tenant_id             = "11111111-1111-1111-1111-111111111111"
databricks_account_id = "$ACCOUNT_ID"

external_volume_storage = {
  volume_storage_path = "seed/path" # nested value
}
EOF
AZURE_PROFILE_VARS="$ROOT/environments/local/azure-profile.tfvars"
cat > "$AZURE_PROFILE_VARS" <<EOF
subscription_id       = "00000000-0000-0000-0000-000000000000"
databricks_account_id = "$ACCOUNT_ID"
EOF

# --- tfvars parsing --------------------------------------------------------
(
  # shellcheck source=/dev/null
  source "$INFRA"
  [[ "$(tfvar_value "$AWS_VARS" region)" == "us-east-1" ]] || fail "trailing // comment leaked into region"
  [[ "$(tfvar_value "$AWS_VARS" databricks_account_id)" == "$ACCOUNT_ID" ]] || fail "trailing # comment leaked into the account ID"
  [[ -z "$(tfvar_value "$AWS_VARS" aws_profile)" ]] || fail "null was not treated as unset"
  [[ "$(tfvar_value "$AWS_VARS" unity_catalog features)" == "true" ]] || fail "nested feature flag not read"
  [[ -z "$(tfvar_value "$AWS_VARS" workspace)" ]] || fail "nested key matched at the top level"
  [[ "$(tfvar_value "$AZURE_VARS" volume_storage_path external_volume_storage)" == "seed/path" ]] || fail "nested string not read"
)
pass "tfvars parsing ignores comments, null, and nested keys"

# --- AWS: setup without prompts ---------------------------------------------
reset_log
run "$INFRA" setup aws "$AWS_VARS" --yes \
  --sso-start-url https://example.awsapps.com/start --sso-region us-east-1 --sso-role-name Admin
expect_code 0 "non-interactive AWS setup"
expect_log '^aws configure set sso_session sts-infra --profile sts-aws-123456789012$'
expect_log '^aws configure set sso_account_id 123456789012 --profile sts-aws-123456789012$'
expect_log '^aws configure set sso_role_name Admin --profile sts-aws-123456789012$'
expect_log '^aws sso login --profile sts-aws-123456789012$'
expect_log "^databricks auth login --host https://accounts.cloud.databricks.com --account-id $ACCOUNT_ID --profile sts-aws-account-00000000 --skip-workspace$"
grep -qxF '[sso-session sts-infra]' "$AWS_CONFIG_FILE" || fail "SSO session was not written to the AWS config"
grep -qxF 'sso_start_url = https://example.awsapps.com/start' "$AWS_CONFIG_FILE" || fail "SSO start URL missing"
jq -e --arg account "$ACCOUNT_ID" '
  .version == 1 and
  .deployments["aws/aws-lab"] == {
    aws_profile: "sts-aws-123456789012",
    aws_account_id: "123456789012",
    databricks_account_id: $account,
    databricks_account_profile: "sts-aws-account-00000000"
  } and
  .accounts["aws/123456789012"].aws_profile == "sts-aws-123456789012" and
  .accounts["databricks/aws/" + $account].databricks_account_profile == "sts-aws-account-00000000" and
  .aws_sso == {session: "sts-infra", start_url: "https://example.awsapps.com/start", region: "us-east-1", role_name: "Admin"}
' "$AUTH_CONFIG" >/dev/null || { cat "$AUTH_CONFIG" >&2; fail "unexpected AWS auth mapping"; }
CONFIG_MODE="$(stat -f '%Lp' "$AUTH_CONFIG" 2>/dev/null || stat -c '%a' "$AUTH_CONFIG")"
[[ "$CONFIG_MODE" == "600" ]] || fail "authentication config mode is $CONFIG_MODE, expected 600"
pass "AWS setup creates the SSO profile and logs in without prompts"

reset_log
run "$INFRA" setup aws "$AWS_VARS" --yes
expect_code 0 "idempotent AWS setup"
expect_no_log '^aws sso login'
expect_no_log '^databricks auth login --host'
pass "AWS setup is a no-op when sessions are valid"

# --- AWS: doctor ------------------------------------------------------------
run "$INFRA" doctor aws "$AWS_VARS" --json
expect_code 0 "doctor with valid sessions"
expect_json '.ready and ([.checks[].id] == ["tools", "aws", "databricks_account", "databricks_workspace"]) and
  .checks[1].account_id == "123456789012" and .checks[1].source == "deployment mapping" and
  .checks[3].status == "not_required" and .next_action == null' "doctor JSON is not ready"
pass "doctor --json reports ready"

rm "$TEST_STATE_DIR/aws-login-sts-aws-123456789012"
run "$INFRA" doctor aws "$AWS_VARS" --json
expect_code 10 "doctor with an expired AWS session"
expect_json '.next_action.command == "./infra setup aws environments/local/aws-lab.tfvars --yes" and .next_action.browser_login' \
  "doctor did not point at ./infra setup"
reset_log
run "$INFRA" plan aws "$AWS_VARS"
expect_code 10 "plan with an expired AWS session"
expect_text "./infra setup aws environments/local/aws-lab.tfvars --yes" "plan did not print the setup command"
[[ "$OUT$ERR" != *"aws sso login"* ]] || fail "plan suggested a raw aws sso login"
expect_no_log '^terraform .* plan '
pass "expired sessions exit 10 with the canonical setup command"

(sleep 2 && touch "$TEST_STATE_DIR/aws-login-sts-aws-123456789012") &
run "$INFRA" doctor aws "$AWS_VARS" --wait 20
wait
expect_code 0 "doctor --wait after a browser login completes"
pass "doctor --wait returns once authentication completes"

echo 999999999999 > "$TEST_STATE_DIR/aws-account-sts-aws-123456789012"
run "$INFRA" doctor aws "$AWS_VARS" --json
expect_code 11 "doctor with the wrong AWS account"
expect_json '.checks[1].status == "mismatch"' "account mismatch not reported"
rm "$TEST_STATE_DIR/aws-account-sts-aws-123456789012"
pass "wrong AWS account exits 11"

printf '[profile other]\n' >> "$AWS_CONFIG_FILE"
touch "$TEST_STATE_DIR/aws-login-other"
reset_log
run AWS_PROFILE=other "$INFRA" doctor aws "$AWS_VARS" --json
expect_code 0 "AWS_PROFILE override"
expect_log '^aws sts get-caller-identity --output json --region us-east-1 --profile other$'
expect_json '.checks[1].source == "AWS_PROFILE"' "AWS_PROFILE source not reported"
pass "AWS_PROFILE overrides the saved mapping"

run "$INFRA" doctor aws "$SECOND_VARS" --json
expect_code 0 "doctor for a new environment in known accounts"
expect_json '.checks[1].source == "account mapping" and .checks[2].source == "account mapping"' "account mapping not reused"
pass "a new environment in the same accounts needs no setup"

# --- AWS: IAM Identity Center session expiry --------------------------------
SSO_CACHE="$HOME/.aws/sso/cache/$(printf '%s' sts-infra | shasum -a 1 | awk '{print $1}').json"
mkdir -p "$(dirname "$SSO_CACHE")"
jq -n '{accessToken: "not-a-real-token", expiresAt: (now + 600 | strftime("%Y-%m-%dT%H:%M:%SZ"))}' > "$SSO_CACHE"
run "$INFRA" doctor aws "$AWS_VARS" --json
expect_code 0 "doctor with a short SSO session"
expect_json '(.checks[1].session_minutes_left | tonumber) <= 10 and (.warnings | length) == 1' "short SSO session not reported"
[[ "$OUT" != *"not-a-real-token"* ]] || fail "SSO token leaked into doctor output"
jq '. + {refreshToken: "not-a-real-refresh-token"}' "$SSO_CACHE" > "$SSO_CACHE.tmp" && mv "$SSO_CACHE.tmp" "$SSO_CACHE"
run "$INFRA" doctor aws "$AWS_VARS" --json
expect_json '.checks[1].session_minutes_left == null and (.warnings | length) == 0' "refreshable SSO session reported as expiring"
rm -f "$SSO_CACHE"
reset_log
run "$INFRA" setup aws "$AWS_VARS" --yes --force-login
expect_code 0 "setup --force-login"
expect_log '^aws sso login --profile sts-aws-123456789012$'
pass "short IAM Identity Center sessions are reported without reading tokens"

# --- AWS: plan hygiene and bash 3.2 ----------------------------------------
reset_log
run DATABRICKS_CONFIG_PROFILE=some-workspace AWS_ACCESS_KEY_ID=AKIAEXAMPLE AWS_SECRET_ACCESS_KEY="$FAKE_AWS_SECRET" \
  "$INFRA" plan aws "$AWS_VARS"
expect_code 0 "plan with ambient credentials"
expect_log '^terraform -chdir=.* plan -var-file=.*aws-lab.tfvars -var=deployment_id=aws-lab -var=aws_profile=sts-aws-123456789012 -var=databricks_profile=sts-aws-account-00000000 -out='
# Version probes may see the shell environment; real operations must not.
expect_no_log '^terraform-env .* for: -chdir='
expect_no_log '^databricks-env '
expect_no_log '^aws-env .* for: (sts|configure|sso|ec2)'
expect_text "DATABRICKS_CONFIG_PROFILE=some-workspace is ignored" "ignored DATABRICKS_CONFIG_PROFILE was not reported"
[[ -f "$ROOT/.artifacts/aws/aws-lab/apply.tfplan.summary.json" ]] || fail "plan summary JSON missing"
ls "$ROOT/.artifacts/aws/aws-lab/logs/"*-plan.log >/dev/null 2>&1 || fail "plan log missing"
pass "profiles win over ambient credentials in Terraform and CLI calls"

reset_log
run AWS_ACCESS_KEY_ID=AKIAEXAMPLE AWS_SECRET_ACCESS_KEY="$FAKE_AWS_SECRET" TEST_DB_ENV_CREDENTIALS=1 /bin/bash "$INFRA" plan aws "$AUTO_VARS"
expect_code 0 "automation plan without profiles under /bin/bash"
expect_log '^terraform -chdir=.* plan -var-file=.*aws-auto.tfvars -var=deployment_id=aws-auto -out='
expect_log '^terraform-env AWS_ACCESS_KEY_ID set for: -chdir=.* plan '
expect_text "No AWS profile or expected account is configured" "unpinned automation account was not reported"
pass "automation path works with an empty profile argument list"

# --- AWS: plan summary ------------------------------------------------------
cat > "$TEST_DIR/plan.json" <<'EOF'
{"resource_changes": [
  {"address": "module.workspace[0].databricks_mws_workspaces.this", "type": "databricks_mws_workspaces", "change": {"actions": ["create"]}},
  {"address": "module.unity_catalog[0].databricks_catalog.this[0]", "type": "databricks_catalog", "change": {"actions": ["create"]}},
  {"address": "aws_s3_bucket.old", "type": "aws_s3_bucket", "change": {"actions": ["delete"]}},
  {"address": "aws_instance.broker", "type": "aws_instance", "change": {"actions": ["delete", "create"]}},
  {"address": "aws_vpc.this", "type": "aws_vpc", "change": {"actions": ["no-op"]}}
]}
EOF
run TEST_PLAN_JSON="$TEST_DIR/plan.json" "$INFRA" plan aws "$SECOND_VARS"
expect_code 0 "plan with a mixed change set"
expect_text "Saved plan summary: create=2 update=0 replace=1 delete=1" "plan counts"
expect_text "  replace: aws_instance.broker" "replacement not listed"
expect_text "  delete: aws_s3_bucket.old" "deletion not listed"
expect_text "creates the Databricks workspace and workspace-level resources in the same apply" "same-apply warning missing"
jq -e '.counts.replace == 1 and .delete == ["aws_s3_bucket.old"] and
  .warnings == ["workspace_and_workspace_resources_in_one_apply"]' \
  "$ROOT/.artifacts/aws/aws-second/apply.tfplan.summary.json" >/dev/null || fail "plan summary JSON is wrong"
pass "plan summary lists destructive changes and warns about a single-stage workspace"

# --- AWS: workspace authentication -----------------------------------------
mkdir -p "$ROOT/.state/aws/aws-lab"
cat > "$ROOT/.state/aws/aws-lab/terraform.tfstate" <<'EOF'
{"version": 4, "outputs": {"workspace_url": {"value": "https://dbc-lab.cloud.databricks.com"}},
 "resources": [{"mode": "managed", "type": "databricks_mws_workspaces", "name": "this",
   "provider": "provider[\"registry.terraform.io/databricks/databricks\"].mws",
   "instances": [{"attributes": {"workspace_id": 42, "workspace_url": "dbc-lab.cloud.databricks.com"}}]}]}
EOF

run "$INFRA" doctor aws "$AWS_VARS" --json
expect_code 10 "doctor without workspace authentication"
expect_json '.checks[3].status == "login_required" and .checks[3].workspace_url == "https://dbc-lab.cloud.databricks.com" and
  .next_action.command == "./infra setup aws environments/local/aws-lab.tfvars --yes"' "workspace login not requested"
reset_log
run "$INFRA" plan aws "$AWS_VARS"
expect_code 10 "plan without workspace authentication"
expect_no_log '^terraform .* plan '
pass "plans stop before Terraform when the workspace login is missing"

reset_log
run TEST_DB_WORKSPACES='[{"workspace_id": 42}]' "$INFRA" destroy-plan aws "$AWS_VARS"
expect_code 10 "destroy-plan without workspace authentication"
expect_text "./infra setup aws environments/local/aws-lab.tfvars --yes" "destroy did not ask for a workspace login"
expect_no_log '^terraform .* plan -destroy'
pass "destroy-plan fails before planning when workspace auth is missing"

reset_log
run "$INFRA" destroy-plan aws "$AWS_VARS"
expect_code 0 "destroy-plan for an externally deleted workspace"
expect_log '^terraform .* plan -destroy'
pass "externally deleted workspaces skip workspace authentication"

mkdir -p "$TEST_STATE_DIR/db"
echo '{"name": "old-ws", "host": "https://dbc-old.cloud.databricks.com"}' > "$TEST_STATE_DIR/db/old-ws.json"
touch "$TEST_STATE_DIR/db/old-ws.login"
run DATABRICKS_WORKSPACE_PROFILE=old-ws "$INFRA" doctor aws "$AWS_VARS" --json
expect_code 11 "workspace profile for another workspace"
expect_json '.checks[3].status == "mismatch"' "workspace host mismatch not reported"
pass "a workspace profile for another workspace exits 11"

reset_log
run "$INFRA" setup aws "$AWS_VARS" --yes
expect_code 0 "setup completing workspace login"
expect_log '^databricks auth login --host https://dbc-lab.cloud.databricks.com --profile sts-aws-lab-workspace$'
jq -e '.deployments["aws/aws-lab"].databricks_workspace_profile == "sts-aws-lab-workspace"' "$AUTH_CONFIG" >/dev/null ||
  fail "workspace profile not saved"
run "$INFRA" doctor aws "$AWS_VARS" --json
expect_code 0 "doctor after workspace setup"
reset_log
run TEST_DB_WORKSPACES='[{"workspace_id": 42}]' "$INFRA" destroy-plan aws "$AWS_VARS"
expect_code 0 "destroy-plan after the workspace login"
expect_log '^terraform .* plan -destroy .*-var=databricks_workspace_profile=sts-aws-lab-workspace'
pass "setup completes and saves the workspace login that plans and destroy need"

sleep 0 &
DEAD_PID=$!
wait "$DEAD_PID"
LOCK="$ROOT/.artifacts/aws/aws-lab/.operation.lock"
mkdir -p "$LOCK"
echo "$DEAD_PID" > "$LOCK/pid"
hostname > "$LOCK/host"
run "$INFRA" plan aws "$AWS_VARS"
expect_code 0 "plan with a stale lock"
expect_text "Removing a stale operation lock" "stale lock not reported"
[[ ! -d "$LOCK" ]] || fail "operation lock was not released"
pass "stale operation locks are recovered"

run TEST_OUTPUT_JSON='{"password": {"sensitive": true, "value": "hunter2"}, "url": {"sensitive": false, "value": "https://x"}}' \
  "$INFRA" output aws "$AWS_VARS" --json
expect_code 0 "output --json"
expect_json '.password.value == "<sensitive>" and .url.value == "https://x"' "sensitive output not redacted"
pass "output --json redacts sensitive values"

echo '{"name": "ACCOUNT", "host": "https://accounts.cloud.databricks.com", "account_id": "99999999-9999-9999-9999-999999999999"}' \
  > "$TEST_STATE_DIR/db/ACCOUNT.json"
reset_log
run "$INFRA" setup aws "$SECOND_VARS" --yes --databricks-profile ACCOUNT
expect_code 11 "setup with a profile for another Databricks account"
expect_no_log '^databricks auth login --host https://accounts.cloud.databricks.com .*--profile ACCOUNT'
pass "setup refuses to overwrite a profile for another account"

run "$INFRA" setup aws "$AUTO_VARS" --yes
expect_code 2 "non-interactive setup without enough information"
expect_text "pass --aws-profile" "missing profile hint"
pass "non-interactive setup explains missing input"

# --- Azure ------------------------------------------------------------------
reset_log
run "$INFRA" setup azure "$AZURE_VARS" --yes
expect_code 0 "Azure setup with the Azure CLI identity"
expect_log '^az login --tenant 11111111-1111-1111-1111-111111111111 --output none$'
expect_log '^az-login-env AZURE_CORE_LOGIN_EXPERIENCE_V2=off$'
expect_log '^databricks account metastores list --output json$'
expect_no_log '^databricks auth login'
jq -e --arg account "$ACCOUNT_ID" '.deployments["azure/azure-lab"] == {
  azure_subscription_id: "00000000-0000-0000-0000-000000000000",
  azure_tenant_id: "11111111-1111-1111-1111-111111111111",
  databricks_account_id: $account
}' "$AUTH_CONFIG" >/dev/null || { cat "$AUTH_CONFIG" >&2; fail "unexpected Azure auth mapping"; }
pass "Azure setup needs only az login"

reset_log
run "$INFRA" plan azure "$AZURE_VARS"
expect_code 0 "Azure plan"
expect_log '^terraform -chdir=.* plan -var-file=.*azure-lab.tfvars -var=deployment_id=azure-lab -var=subscription_id=00000000-0000-0000-0000-000000000000 -var=tenant_id=11111111-1111-1111-1111-111111111111 -var=databricks_auth_type=azure-cli -out='
pass "Azure plans pin the tenant and Databricks auth type"

touch "$TEST_STATE_DIR/azure-expired"
run "$INFRA" doctor azure "$AZURE_VARS" --json
expect_code 10 "Azure doctor with an expired token"
expect_json '.checks[1].status == "login_required" and .checks[2].status == "skipped"' "expired Azure session not detected"
rm "$TEST_STATE_DIR/azure-expired"
pass "Azure liveness is checked with a token request"

run TEST_AZ_TENANT=22222222-2222-2222-2222-222222222222 "$INFRA" doctor azure "$AZURE_VARS" --json
expect_code 11 "Azure doctor in the wrong tenant"
pass "wrong Azure tenant exits 11"

run TEST_AZ_NOT_ACCOUNT_ADMIN=1 "$INFRA" doctor azure "$AZURE_VARS" --json
expect_code 11 "Azure identity without account access"
expect_json '.checks[2].status == "denied" and (.next_action.command | contains("--databricks-profile"))' "account access denial not explained"
pass "missing Azure Databricks account access exits 11"

run DATABRICKS_WORKSPACE_PROFILE=azure-ws "$INFRA" doctor azure "$AZURE_VARS" --json
expect_code 0 "Azure doctor with a workspace profile override"
expect_json '.checks[3].profile == "azure-ws"' "DATABRICKS_WORKSPACE_PROFILE ignored on Azure"
pass "DATABRICKS_WORKSPACE_PROFILE is honored on Azure"

reset_log
run "$INFRA" setup azure "$AZURE_PROFILE_VARS" --yes --databricks-profile azure-databricks
expect_code 0 "Azure setup with a Databricks OAuth profile"
expect_log "^databricks auth login --host https://accounts.azuredatabricks.net --account-id $ACCOUNT_ID --profile azure-databricks --skip-workspace$"
reset_log
run "$INFRA" plan azure "$AZURE_PROFILE_VARS"
expect_code 0 "Azure plan with a Databricks profile"
expect_log '^terraform -chdir=.* plan .*-var=databricks_account_profile=azure-databricks -var=databricks_auth_type=azure-cli -out='
pass "Azure Databricks OAuth profiles remain supported"

mkdir -p "$ROOT/.state/azure/azure-lab"
echo '{"version": 4, "outputs": {}, "resources": []}' > "$ROOT/.state/azure/azure-lab/terraform.tfstate"
SQL_ID="/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/lab/providers/Microsoft.Sql/servers/sql-lab"
PENDING_OUTPUT="$(jq -cn --arg id "$SQL_ID" '{pending_endpoint_approvals: {sensitive: false, value: [
  {component: "sql_database", resource_id: $id, rule_id: "rule-1", endpoint_name: "databricks-pe-1", connection_state: "PENDING"}]}}')"
run TEST_OUTPUT_JSON="$PENDING_OUTPUT" "$INFRA" endpoints azure status "$AZURE_VARS"
expect_code 0 "Azure endpoint status"
expect_json --arg id "$SQL_ID/privateEndpointConnections/conn-1" \
  '.pending_endpoint_approvals[0].connection_id == $id and .pending_endpoint_approvals[0].azure_status == "Pending"' \
  "Azure endpoint connection not matched"
reset_log
run TEST_OUTPUT_JSON="$PENDING_OUTPUT" "$INFRA" endpoints azure approve "$AZURE_VARS" --connection-id "$SQL_ID/privateEndpointConnections/conn-1"
expect_code 0 "Azure endpoint approval"
expect_log "^az network private-endpoint-connection approve --id $SQL_ID/privateEndpointConnections/conn-1 "
run TEST_OUTPUT_JSON="$PENDING_OUTPUT" "$INFRA" endpoints azure approve "$AZURE_VARS" --connection-id /subscriptions/other/privateEndpointConnections/x
expect_code 1 "approving a foreign connection"
expect_text "not a private endpoint connection managed by this deployment" "foreign connection not refused"
pass "Azure NCC endpoints are listed and approved only for this deployment"

echo '{"version": 1, "deployments": {"aws/x": {"password": "nope"}}}' > "$TEST_DIR/bad-auth.json"
run STS_INFRA_AUTH_CONFIG="$TEST_DIR/bad-auth.json" "$INFRA" doctor aws "$AWS_VARS"
expect_code 1 "invalid local mapping"
expect_text "invalid local authentication config" "invalid mapping not rejected"
pass "unexpected fields in the local mapping are rejected"

echo "infra authentication tests passed"
