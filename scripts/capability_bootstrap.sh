#!/usr/bin/env bash
set -euo pipefail
set +x

readonly CAPABILITIES_ROOT="/data/capabilities"
readonly SHIMS_ROOT="/data/capability-shims"
readonly PI_AGENT_DIR="${PI_AGENT_DIR:-/data/pi/agent}"
readonly CAPABILITY_MANIFEST_PATH="${CAPABILITY_MANIFEST_PATH:-/data/capabilities/manifest.json}"

die() {
  printf 'capability_bootstrap: %s\n' "$1" >&2
  exit 1
}

log() {
  printf 'capability_bootstrap: %s\n' "$1" >&2
}

require_command() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || die "required command is not available: ${name}"
}

json_type_or_null() {
  local path="$1"
  local actual
  actual="$(jq -r "${path} | type" "$CAPABILITY_MANIFEST_PATH")"
  printf '%s\n' "${actual%$'\r'}"
}

require_object_or_absent() {
  local path="$1"
  local actual
  actual="$(json_type_or_null "$path")"
  [[ "$actual" == "object" || "$actual" == "null" ]] || die "manifest ${path} must be an object when present"
}

require_array_or_absent() {
  local path="$1"
  local actual
  actual="$(json_type_or_null "$path")"
  [[ "$actual" == "array" || "$actual" == "null" ]] || die "manifest ${path} must be an array when present"
}

validate_secret_ref() {
  local ref="$1"
  [[ "$ref" =~ ^secret:[A-Za-z_][A-Za-z0-9_]*$ ]] || die "invalid secret reference: ${ref}"
}

resolve_secret_ref() {
  local ref="$1"
  local name
  validate_secret_ref "$ref"
  name="${ref#secret:}"
  if [[ -z "${!name:-}" ]]; then
    die "required secret environment variable is empty: ${name}"
  fi
  printf '%s' "${!name}"
}

shell_quote() {
  local value="$1"
  printf "'%s'" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
}

validate_command_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid wrapper command name: ${name}"
  [[ "$name" != *"/"* ]] || die "wrapper command name must not contain slash: ${name}"
}

validate_manifest() {
  local wrapper_names secret_refs

  jq -e '.version == 1' "$CAPABILITY_MANIFEST_PATH" >/dev/null || die "capability manifest version must be 1"

  require_object_or_absent '.pi'
  require_array_or_absent '.pi.packages'
  require_array_or_absent '.pi.skills'
  require_array_or_absent '.pi.extensions'
  require_object_or_absent '.cli'
  require_array_or_absent '.cli.required'
  require_array_or_absent '.cli.wrappers'
  require_object_or_absent '.auth'
  require_object_or_absent '.mcp'
  require_object_or_absent '.mcp.servers'
  require_array_or_absent '.validate'

  jq -e '(.cli.wrappers // []) | all(.[]; type == "object" and (.name | type == "string" and length > 0) and (.target | type == "string" and startswith("/")) and ((.env // {}) | type == "object") and ((.env // {}) | to_entries | all(.[]; (.key | type == "string") and (.value | type == "string" and startswith("secret:")))))' "$CAPABILITY_MANIFEST_PATH" >/dev/null \
    || die "manifest .cli.wrappers entries must be objects with a non-empty name, absolute target, and env object containing secret refs"

  wrapper_names="$(jq -r '.cli.wrappers[]?.name' "$CAPABILITY_MANIFEST_PATH")" \
    || die "failed to read manifest .cli.wrappers names"
  if [[ -n "$wrapper_names" ]]; then
    while IFS= read -r name; do
      name="${name%$'\r'}"
      validate_command_name "$name"
    done <<<"$wrapper_names"
  fi

  secret_refs="$(jq -r '.. | strings | select(startswith("secret:"))' "$CAPABILITY_MANIFEST_PATH")" \
    || die "failed to read manifest secret references"
  if [[ -n "$secret_refs" ]]; then
    while IFS= read -r ref; do
      ref="${ref%$'\r'}"
      validate_secret_ref "$ref"
    done <<<"$secret_refs"
  fi
}

render_env_wrapper() {
  local name="$1"
  local target="$2"
  local env_file="${CAPABILITIES_ROOT}/${name}/env"
  local shim_file="${SHIMS_ROOT}/${name}"
  local env_entries key ref value

  validate_command_name "$name"
  [[ "$target" == /* ]] || die "wrapper target for ${name} must be an absolute path"
  [[ -x "$target" ]] || die "wrapper target for ${name} is not executable: ${target}"

  mkdir -p "${CAPABILITIES_ROOT}/${name}"
  chmod 700 "${CAPABILITIES_ROOT}/${name}"
  : >"$env_file"
  chmod 600 "$env_file"

  env_entries="$(jq -r --arg name "$name" '.cli.wrappers[] | select(.name == $name) | .env // {} | to_entries[] | [.key, .value] | @tsv' "$CAPABILITY_MANIFEST_PATH")" \
    || die "failed to read env entries for wrapper: ${name}"

  if [[ -n "$env_entries" ]]; then
    while IFS=$'\t' read -r key ref; do
      [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "invalid env name for wrapper ${name}: ${key}"
      value="$(resolve_secret_ref "$ref")"
      printf 'export %s=%s\n' "$key" "$(shell_quote "$value")" >>"$env_file"
    done <<<"$env_entries"
  fi

  cat >"$shim_file" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$env_file"
exec "$target" "\$@"
EOF
  chmod 755 "$shim_file"
}

apply_env_wrappers() {
  local wrapper_rows name target

  wrapper_rows="$(jq -r '.cli.wrappers[]? | [.name, .target] | @tsv' "$CAPABILITY_MANIFEST_PATH")" \
    || die "failed to read manifest .cli.wrappers entries"

  if [[ -n "$wrapper_rows" ]]; then
    while IFS=$'\t' read -r name target; do
      [[ -n "$name" ]] || die "manifest .cli.wrappers entries must include a non-empty name"
      render_env_wrapper "$name" "$target"
    done <<<"$wrapper_rows"
  fi
}

apply_required_cli_checks() {
  local command_json
  local command_name
  local required_commands

  jq -e '(.cli.required // []) | all(.[]; type == "string")' "$CAPABILITY_MANIFEST_PATH" >/dev/null \
    || die "manifest .cli.required entries must be strings"

  required_commands="$(jq -c '.cli.required[]?' "$CAPABILITY_MANIFEST_PATH")" \
    || die "failed to read manifest .cli.required entries"

  if [[ -n "$required_commands" ]]; then
    while IFS= read -r command_json; do
      command_name="$(jq -r . <<<"$command_json")"
      command_name="${command_name%$'\r'}"
      validate_command_name "$command_name"
      command -v "$command_name" >/dev/null 2>&1 || die "declared CLI is not available on PATH: ${command_name}"
    done <<<"$required_commands"
  fi
}

load_manifest() {
  local manifest_dir
  local tmp_manifest

  manifest_dir="$(dirname "$CAPABILITY_MANIFEST_PATH")"
  tmp_manifest="$(mktemp "${manifest_dir}/.manifest.XXXXXX")" || return 1

  if [[ -n "${AGENT_CAPABILITIES_JSON_B64:-}" ]]; then
    if ! printf '%s' "$AGENT_CAPABILITIES_JSON_B64" | base64 -d >"$tmp_manifest"; then
      rm -f "$tmp_manifest"
      return 1
    fi
  elif [[ -n "${AGENT_CAPABILITIES_JSON:-}" ]]; then
    if ! printf '%s' "$AGENT_CAPABILITIES_JSON" >"$tmp_manifest"; then
      rm -f "$tmp_manifest"
      return 1
    fi
  else
    rm -f "$tmp_manifest"
    return 1
  fi

  if ! jq empty "$tmp_manifest" >/dev/null; then
    rm -f "$tmp_manifest"
    return 2
  fi

  if ! mv "$tmp_manifest" "$CAPABILITY_MANIFEST_PATH"; then
    rm -f "$tmp_manifest"
    return 1
  fi
}

main() {
  if [[ -z "${AGENT_CAPABILITIES_JSON_B64:-}" && -z "${AGENT_CAPABILITIES_JSON:-}" ]]; then
    log "no capability manifest configured; skipping"
    exit 0
  fi

  require_command jq

  mkdir -p "$CAPABILITIES_ROOT" "$SHIMS_ROOT" "$PI_AGENT_DIR" "$(dirname "$CAPABILITY_MANIFEST_PATH")"
  chmod 700 "$CAPABILITIES_ROOT" "$SHIMS_ROOT" "$PI_AGENT_DIR"

  if ! load_manifest; then
    die "capability manifest is not valid JSON or could not be loaded"
  fi

  validate_manifest
  apply_required_cli_checks
  apply_env_wrappers
  export PATH="${SHIMS_ROOT}:${PATH}"

  log "capability manifest loaded"
}

main "$@"
