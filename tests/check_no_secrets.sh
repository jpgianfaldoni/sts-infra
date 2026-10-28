#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v rg >/dev/null 2>&1; then
  echo "check_no_secrets: ripgrep (rg) is required" >&2
  exit 1
fi

# rg honors .gitignore, so this scans tracked and untracked-but-not-ignored
# files. Each pattern requires a literal value, so variable names, references
# such as var.x or ${VAR}, and <placeholder> text in docs do not match.
found=0
scan() {
  local label="$1"
  shift
  if rg -n --hidden --glob '!.git/**' --glob '!tests/check_no_secrets.sh' "$@" "$ROOT"; then
    echo "possible committed secret detected: $label" >&2
    found=1
  fi
}

scan "AWS access key ID" '(AKIA|ASIA)[0-9A-Z]{16}'
scan "private key" -e '-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----'
scan "Databricks personal access token" 'dapi[0-9a-f]{32}'
scan "JSON Web Token" 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.'
scan "AWS secret access key" -i 'aws_secret_access_key\s*=\s*[A-Za-z0-9/+]'
scan "SQL administrator password" 'administrator_login_password\s*=\s*"[^$]'
scan "client secret or token literal" -i '(client_secret|ARM_CLIENT_SECRET|DATABRICKS_CLIENT_SECRET|DATABRICKS_TOKEN)"?\s*[=:]\s*"[^"$<{[:space:]]{8,}"'
scan "client secret or token environment assignment" '(ARM_CLIENT_SECRET|DATABRICKS_CLIENT_SECRET|DATABRICKS_TOKEN)=[A-Za-z0-9._~+/-]{16,}'
scan "tfvars password, secret, or token literal" -i --glob '*.tfvars' '^\s*\w*(password|secret|token)\w*\s*=\s*"[^"]+"'

if [[ "$found" -ne 0 ]]; then
  exit 1
fi
echo "secret scan passed"
