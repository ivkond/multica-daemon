#!/usr/bin/env bash
set -euo pipefail
set +x

die() {
  printf 'setup_agent: %s\n' "$1" >&2
  exit 1
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    die "required environment variable is empty: ${name}"
  fi
}

setup_codex() {
  local auth_path
  local codex_auth_json_b64
  local tmp_auth

  require_env "CODEX_HOME"

  auth_path="${CODEX_HOME}/auth.json"
  codex_auth_json_b64=""
  if [[ ! -f "$auth_path" ]]; then
    require_env "CODEX_AUTH_JSON_B64_FROM_SECRET_STORE"
    codex_auth_json_b64="$CODEX_AUTH_JSON_B64_FROM_SECRET_STORE"
  fi

  unset CODEX_AUTH_JSON_B64_FROM_SECRET_STORE
  unset OPENAI_API_KEY
  unset CODEX_API_KEY

  mkdir -p "$CODEX_HOME"
  chmod 700 "$CODEX_HOME"

  if [[ ! -f "$auth_path" ]]; then
    tmp_auth="$(mktemp "${CODEX_HOME}/auth.json.tmp.XXXXXX")"
    chmod 600 "$tmp_auth"
    if ! printf '%s' "$codex_auth_json_b64" | base64 -d > "$tmp_auth"; then
      rm -f "$tmp_auth"
      unset codex_auth_json_b64
      die "failed to decode Codex auth JSON"
    fi

    unset codex_auth_json_b64
    if ! jq empty "$tmp_auth"; then
      rm -f "$tmp_auth"
      die "decoded Codex auth JSON is invalid"
    fi

    mv "$tmp_auth" "$auth_path"
  fi

  chmod 600 "$auth_path"

  cat > "${CODEX_HOME}/config.toml" <<'EOF'
forced_login_method = "chatgpt"
cli_auth_credentials_store = "file"
EOF

  codex --version
}

setup_opencode() {
  require_env "OPENCODE_HOME"

  mkdir -p "$OPENCODE_HOME"
  chmod 700 "$OPENCODE_HOME"

  opencode --version
}

if [[ "$#" -ne 1 ]]; then
  die "usage: setup_agent.sh codex|opencode"
fi

agent="$1"

case "$agent" in
  codex)
    setup_codex
    ;;
  opencode)
    setup_opencode
    ;;
  *)
    die "unsupported AGENT: ${agent}"
    ;;
esac
