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

  log "capability manifest loaded"
}

main "$@"
