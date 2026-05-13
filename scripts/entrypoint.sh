#!/usr/bin/env bash
set -euo pipefail
set +x

readonly DATA_ROOT="/data"
readonly DEFAULT_CODEX_HOME="/data/codex"
readonly DEFAULT_OPENCODE_HOME="/data/opencode"
readonly DEFAULT_PI_CODING_AGENT_DIR="/data/pi/agent"
readonly INFISICAL_RETRY_COUNT=3
readonly INFISICAL_RETRY_DELAY_SECONDS=2

die() {
  printf 'entrypoint: %s\n' "$1" >&2
  exit 1
}

log() {
  printf 'entrypoint: %s\n' "$1" >&2
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    die "required environment variable is empty: ${name}"
  fi
}

require_env "AGENT"
require_env "MULTICA_IMAGE_AGENT"
require_env "INFISICAL_TOKEN"
require_env "INFISICAL_PROJECT_ID"
require_env "INFISICAL_ENV"
require_env "INFISICAL_SECRET_PATH"
require_env "MULTICA_SERVER_URL"
require_env "MULTICA_APP_URL"
require_env "MULTICA_DAEMON_ID"
require_env "MULTICA_DAEMON_DEVICE_NAME"
require_env "MULTICA_AGENT_RUNTIME_NAME"
require_env "MULTICA_WORKSPACES_ROOT"
require_env "PORT"

case "$AGENT" in
  codex | opencode | pi)
    ;;
  *)
    die "unsupported AGENT: ${AGENT}"
    ;;
esac

if [[ "$AGENT" != "$MULTICA_IMAGE_AGENT" ]]; then
  die "runtime AGENT (${AGENT}) does not match image agent (${MULTICA_IMAGE_AGENT})"
fi

if [[ "$AGENT" == "codex" ]]; then
  unset OPENAI_API_KEY
  unset CODEX_API_KEY
fi

export HOME="/data/home"
export CODEX_HOME="$DEFAULT_CODEX_HOME"
export OPENCODE_HOME="$DEFAULT_OPENCODE_HOME"
export PI_CODING_AGENT_DIR="${PI_CODING_AGENT_DIR:-$DEFAULT_PI_CODING_AGENT_DIR}"
export MULTICA_WORKSPACES_ROOT="${MULTICA_WORKSPACES_ROOT}"

normalized_workspaces_root="$(realpath -m -- "$MULTICA_WORKSPACES_ROOT")"
case "$normalized_workspaces_root" in
  /data/*)
    export MULTICA_WORKSPACES_ROOT="$normalized_workspaces_root"
    ;;
  *)
    die "MULTICA_WORKSPACES_ROOT must be under /data"
    ;;
esac

case "$normalized_workspaces_root" in
  /data/home | /data/home/* | /data/codex | /data/codex/* | /data/opencode | /data/opencode/* | /data/pi | /data/pi/*)
    die "MULTICA_WORKSPACES_ROOT must not overlap runtime state paths: /data/home, /data/codex, /data/opencode, /data/pi"
    ;;
esac

mkdir -p "$HOME" "$MULTICA_WORKSPACES_ROOT" "$CODEX_HOME" "$OPENCODE_HOME" "/data/pi" "$PI_CODING_AGENT_DIR"
chmod 700 "$HOME" "$MULTICA_WORKSPACES_ROOT" "$CODEX_HOME" "$OPENCODE_HOME" "/data/pi" "$PI_CODING_AGENT_DIR"
[[ -w "$HOME" ]] || die "HOME is not writable"
[[ -w "$MULTICA_WORKSPACES_ROOT" ]] || die "MULTICA_WORKSPACES_ROOT is not writable"
[[ -w "$CODEX_HOME" ]] || die "CODEX_HOME is not writable"
[[ -w "$OPENCODE_HOME" ]] || die "OPENCODE_HOME is not writable"
[[ -w "$PI_CODING_AGENT_DIR" ]] || die "PI_CODING_AGENT_DIR is not writable"

command -v infisical >/dev/null 2>&1 || die "infisical CLI is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

infisical_token="$INFISICAL_TOKEN"
unset INFISICAL_TOKEN
export INFISICAL_API_URL="${INFISICAL_API_URL:-https://app.infisical.com/api}"

infisical_response=""
for attempt in 1 2 3; do
  if infisical_response_candidate="$(INFISICAL_TOKEN="$infisical_token" infisical export \
    --silent \
    --format=json \
    --projectId "$INFISICAL_PROJECT_ID" \
    --env "$INFISICAL_ENV" \
    --path "$INFISICAL_SECRET_PATH")"; then
    infisical_response="$infisical_response_candidate"
    break
  fi

  if [[ "$attempt" -lt "$INFISICAL_RETRY_COUNT" ]]; then
    sleep "$INFISICAL_RETRY_DELAY_SECONDS"
  fi
done
unset infisical_token
[[ -n "$infisical_response" ]] || die "Infisical secret fetch failed after 3 attempts"

extract_secret() {
  local primary_name="$1"
  local legacy_name="$2"
  jq -r --arg primary "$primary_name" --arg legacy "$legacy_name" '
    def object_value($name): .[$name] // empty;
    def array_value($name):
      ([.[] | select((.key? // .secretKey? // .name?) == $name) | (.value? // .secretValue? // empty)] | first) // empty;
    if type == "object" then
      object_value($primary) // object_value($legacy) // empty
    elif type == "array" then
      array_value($primary) // array_value($legacy) // empty
    else
      empty
    end
  '
}

declare -a INFISICAL_EXPORTED_SECRET_NAMES=()

export_infisical_secrets_for_bootstrap() {
  local rows key value_b64 value

  if ! rows="$(printf '%s' "$infisical_response" | jq -r '
    def env_secret_rows:
      if type == "object" then
        to_entries[] | select(.value != null) | [.key, (.value | tostring | @base64)] | @tsv
      elif type == "array" then
        .[] | [(.key? // .secretKey? // .name? // empty), (.value? // .secretValue? // empty)] | select(.[0] != "" and .[1] != null) | [.[0], (.[1] | tostring | @base64)] | @tsv
      else
        empty
      end;
    env_secret_rows
  ')"; then
    die "Infisical export response is not valid JSON"
  fi

  if [[ -n "$rows" ]]; then
    while IFS=$'\t' read -r key value_b64; do
      key="${key%$'\r'}"
      value_b64="${value_b64%$'\r'}"
      [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
      [[ -z "${!key:-}" ]] || continue
      if ! value="$(printf '%s' "$value_b64" | base64 -d)"; then
        die "failed to decode Infisical secret value for ${key}"
      fi
      printf -v "$key" '%s' "$value"
      export "$key"
      INFISICAL_EXPORTED_SECRET_NAMES+=("$key")
    done <<<"$rows"
  fi
}

unset_infisical_bootstrap_secrets() {
  local name
  for name in "${INFISICAL_EXPORTED_SECRET_NAMES[@]}"; do
    unset "$name"
  done
  INFISICAL_EXPORTED_SECRET_NAMES=()
}

if ! MULTICA_TOKEN_FROM_SECRET_STORE="$(printf '%s' "$infisical_response" | extract_secret "MULTICA_TOKEN" "multica_token")"; then
  die "Infisical export response is not valid JSON"
fi
if ! CODEX_AUTH_JSON_B64_FROM_SECRET_STORE="$(printf '%s' "$infisical_response" | extract_secret "CODEX_AUTH_JSON_B64" "codex_auth_json_b64")"; then
  die "Infisical export response is not valid JSON"
fi
if ! PI_AUTH_JSON_B64_FROM_SECRET_STORE="$(printf '%s' "$infisical_response" | extract_secret "PI_AUTH_JSON_B64" "pi_auth_json_b64")"; then
  die "Infisical export response is not valid JSON"
fi
if ! GITHUB_TOKEN_FROM_SECRET_STORE="$(printf '%s' "$infisical_response" | extract_secret "GITHUB_TOKEN" "github_token")"; then
  die "Infisical export response is not valid JSON"
fi

export_infisical_secrets_for_bootstrap

[[ -n "$MULTICA_TOKEN_FROM_SECRET_STORE" ]] || die "Infisical secret is missing MULTICA_TOKEN"
if [[ "$AGENT" == "codex" && -z "$CODEX_AUTH_JSON_B64_FROM_SECRET_STORE" ]]; then
  die "Infisical secret is missing CODEX_AUTH_JSON_B64 for codex"
fi
if [[ "$AGENT" == "pi" && -z "$PI_AUTH_JSON_B64_FROM_SECRET_STORE" ]]; then
  die "Infisical secret is missing PI_AUTH_JSON_B64 for pi"
fi

configure_github_credentials() {
  local github_token="$1"
  local netrc_path="${HOME}/.netrc"
  local git_credentials_path="${HOME}/.git-credentials"
  local managed_marker="# managed by multica-daemon entrypoint"

  if [[ -z "$github_token" ]]; then
    if [[ -f "$netrc_path" ]] && grep -qxF "$managed_marker" "$netrc_path"; then
      rm -f "$netrc_path"
    fi
    rm -f "$git_credentials_path"
    git config --global --unset-all credential.helper >/dev/null 2>&1 || true
    git config --global --unset-all credential.useHttpPath >/dev/null 2>&1 || true
    return
  fi

  umask 077
  {
    printf '%s\n' "$managed_marker"
    printf 'machine github.com\n'
    printf '  login x-access-token\n'
    printf '  password %s\n' "$github_token"
  } >"$netrc_path"
  chmod 600 "$netrc_path"

  printf 'https://x-access-token:%s@github.com\n' "$github_token" >"$git_credentials_path"
  chmod 600 "$git_credentials_path"
  git config --global credential.helper "store --file ${git_credentials_path}"
  git config --global credential.useHttpPath false
}

configure_github_credentials "$GITHUB_TOKEN_FROM_SECRET_STORE"
unset GITHUB_TOKEN_FROM_SECRET_STORE

log "running capability bootstrap"
/usr/local/bin/capability_bootstrap.sh
export PATH="/data/capability-shims:${PATH}"
unset GITHUB_TOKEN
unset_infisical_bootstrap_secrets

log "running multica setup"
MULTICA_TOKEN_FROM_SECRET_STORE="$MULTICA_TOKEN_FROM_SECRET_STORE" /usr/local/bin/setup_multica.sh
unset MULTICA_TOKEN_FROM_SECRET_STORE

log "running agent setup"
case "$AGENT" in
  codex)
    CODEX_AUTH_JSON_B64_FROM_SECRET_STORE="$CODEX_AUTH_JSON_B64_FROM_SECRET_STORE" /usr/local/bin/setup_agent.sh "$AGENT"
    ;;
  pi)
    PI_AUTH_JSON_B64_FROM_SECRET_STORE="$PI_AUTH_JSON_B64_FROM_SECRET_STORE" /usr/local/bin/setup_agent.sh "$AGENT"
    ;;
  opencode)
    /usr/local/bin/setup_agent.sh "$AGENT"
    ;;
esac
unset CODEX_AUTH_JSON_B64_FROM_SECRET_STORE
unset PI_AUTH_JSON_B64_FROM_SECRET_STORE

unset INFISICAL_PROJECT_ID
unset INFISICAL_ENV
unset INFISICAL_SECRET_PATH
unset infisical_response
unset infisical_response_candidate
unset normalized_workspaces_root

python3 /usr/local/bin/health_proxy.py --port "$PORT" &
health_proxy_pid="$!"
sleep 1
if ! kill -0 "$health_proxy_pid" >/dev/null 2>&1; then
  die "health proxy failed to start"
fi
unset health_proxy_pid

exec multica daemon start --foreground
