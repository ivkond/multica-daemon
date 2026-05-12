#!/usr/bin/env bash
set -euo pipefail
set +x

die() {
  printf 'setup_multica: %s\n' "$1" >&2
  exit 1
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    die "required environment variable is empty: ${name}"
  fi
}

require_env "MULTICA_SERVER_URL"
require_env "MULTICA_APP_URL"
require_env "MULTICA_TOKEN_FROM_SECRET_STORE"

multica_token="$MULTICA_TOKEN_FROM_SECRET_STORE"
unset MULTICA_TOKEN_FROM_SECRET_STORE

printf 'setup_multica: configuring Multica CLI\n' >&2
multica --version
multica config set server_url "$MULTICA_SERVER_URL"
multica config set app_url "$MULTICA_APP_URL"
multica login --token "$multica_token"
unset multica_token
printf 'setup_multica: Multica login completed\n' >&2
