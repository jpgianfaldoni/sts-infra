#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if rg -n --hidden --glob '!.git/**' --glob '!tests/check_no_secrets.sh' '(AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|administrator_login_password\s*=\s*"[^$])' "$ROOT"; then
  echo "possible committed secret detected" >&2
  exit 1
fi
echo "basic secret scan passed"
