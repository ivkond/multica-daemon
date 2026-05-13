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
  [[ "$ref" =~ ^secret:[A-Z_][A-Z0-9_]*$ ]] || die "invalid secret reference: ${ref}"
}

validate_command_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid wrapper command name: ${name}"
  [[ "$name" != *"/"* ]] || die "wrapper command name must not contain slash: ${name}"
}

validate_manifest() {
  local version
  version="$(jq -r '.version // empty' "$CAPABILITY_MANIFEST_PATH")"
  version="${version%$'\r'}"
  [[ "$version" == "1" ]] || die "capability manifest version must be 1"

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

  while IFS= read -r name; do
    name="${name%$'\r'}"
    validate_command_name "$name"
  done < <(jq -r '.cli.wrappers[]?.name // empty' "$CAPABILITY_MANIFEST_PATH")

  while IFS= read -r ref; do
    ref="${ref%$'\r'}"
    validate_secret_ref "$ref"
  done < <(jq -r '.. | strings | select(startswith("secret:"))' "$CAPABILITY_MANIFEST_PATH")
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

  log "capability manifest loaded"
}

main "$@"
