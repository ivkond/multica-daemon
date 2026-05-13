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
  if [[ -n "${AGENT_CAPABILITIES_JSON_B64:-}" ]]; then
    printf '%s' "$AGENT_CAPABILITIES_JSON_B64" | base64 -d >"$CAPABILITY_MANIFEST_PATH"
    return 0
  fi

  if [[ -n "${AGENT_CAPABILITIES_JSON:-}" ]]; then
    printf '%s' "$AGENT_CAPABILITIES_JSON" >"$CAPABILITY_MANIFEST_PATH"
    return 0
  fi

  return 1
}

main() {
  if [[ -z "${AGENT_CAPABILITIES_JSON_B64:-}" && -z "${AGENT_CAPABILITIES_JSON:-}" ]]; then
    log "no capability manifest configured; skipping"
    exit 0
  fi

  require_command jq

  mkdir -p "$CAPABILITIES_ROOT" "$SHIMS_ROOT" "$PI_AGENT_DIR" "$(dirname "$CAPABILITY_MANIFEST_PATH")"
  chmod 700 "$CAPABILITIES_ROOT" "$SHIMS_ROOT" "$PI_AGENT_DIR"

  load_manifest || die "failed to load capability manifest"

  jq empty "$CAPABILITY_MANIFEST_PATH" >/dev/null || die "capability manifest is not valid JSON"
  log "capability manifest loaded"
}

main "$@"
