# Capability Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a deploy-time capability bootstrap layer that prepares CLI tools, auth material, Pi settings, and MCP config before the Multica daemon starts.

**Architecture:** Keep the runtime image responsible for installed binaries and add a focused bootstrap script that consumes a validated JSON manifest and already-fetched secret values. The bootstrap writes tool-specific auth/config under `/data/capabilities`, generates wrappers under `/data/capability-shims`, generates Pi settings under `/data/pi/agent`, and fails fast before daemon launch when declared capabilities are missing or invalid.

**Tech Stack:** Bash, jq, Python stdlib for validation tests/helpers, Infisical/Vault-normalized secret environment variables, Pi `settings.json`, Docker/Railway runtime scripts.

---

## Scope

This plan implements the first useful version of deploy-time capability preconfiguration.

Included:

- capability manifest loading from `AGENT_CAPABILITIES_JSON` or `AGENT_CAPABILITIES_JSON_B64`;
- schema validation with `jq`/Bash checks;
- required CLI binary checks;
- tool-specific env-wrapper generation;
- GitHub HTTPS `.netrc` generation;
- Pi `settings.json` generation for packages, skills, and extensions;
- MCP config file generation for a future Pi MCP gateway extension;
- redacted diagnostics;
- startup integration before Multica and agent setup.

Excluded from this first implementation:

- runtime apt installs;
- arbitrary package installation from manifest;
- a full MCP gateway implementation;
- cloud-provider credential-process flows;
- non-root runtime migration.

## File Structure

- Create `scripts/capability_bootstrap.sh`: validates and applies the deploy-time capability manifest.
- Create `docs/capability-bootstrap-spec.md`: operator-facing contract for manifest shape, auth modes, generated files, and security rules.
- Modify `scripts/entrypoint.sh`: calls `capability_bootstrap.sh` after secret fetch and directory preparation, before `setup_multica.sh` and `setup_agent.sh`.
- Modify `Dockerfile`: copies `capability_bootstrap.sh` to `/usr/local/bin` and marks it executable.
- Modify `README.md`: documents capability manifest setup and examples.
- Modify `docs/runtime-spec.md`: documents bootstrap lifecycle position and generated directories.
- Modify `docs/security-and-secrets-spec.md`: documents secret materialization rules and forbidden logging.
- Optional test helpers under `scripts/tests/` only if the repo already has no test framework and shell validation needs fixture files.

## Manifest Contract

The bootstrap accepts an empty or missing manifest as a no-op. When present, the manifest must be valid JSON with this shape:

```json
{
  "version": 1,
  "pi": {
    "packages": ["npm:@org/pi-agent-toolbox@1.0.0"],
    "skills": ["/data/capabilities/skills"],
    "extensions": ["/data/capabilities/extensions/mcp-gateway.ts"]
  },
  "cli": {
    "required": ["git", "rg"],
    "wrappers": [
      {
        "name": "psql",
        "target": "/usr/bin/psql",
        "env": {
          "PGHOST": "secret:POSTGRES_HOST",
          "PGUSER": "secret:POSTGRES_USER",
          "PGPASSWORD": "secret:POSTGRES_PASSWORD",
          "PGDATABASE": "secret:POSTGRES_DB"
        }
      }
    ]
  },
  "auth": {
    "github": {
      "mode": "netrc",
      "token": "secret:GITHUB_TOKEN"
    }
  },
  "mcp": {
    "servers": {
      "github": {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-github@1.0.0"],
        "env": {
          "GITHUB_PERSONAL_ACCESS_TOKEN": "secret:GITHUB_TOKEN"
        }
      }
    }
  },
  "validate": [["command", "-v", "git"]]
}
```

Secret references use `secret:NAME`. The bootstrap resolves them from environment variables created by the entrypoint secret-store fetch. Secret values must never be logged.

---

## Task 1: Capability Bootstrap No-Op Skeleton

**Files:**

- Create: `scripts/capability_bootstrap.sh`

**SMART DoD:**

- `bash -n scripts/capability_bootstrap.sh` succeeds.
- Missing `AGENT_CAPABILITIES_JSON` and `AGENT_CAPABILITIES_JSON_B64` exits 0 without writing files.
- The script creates `/data/capabilities` and `/data/capability-shims` only when a manifest is present.

- [ ] **Step 1: Write script header and helpers**

Create `scripts/capability_bootstrap.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
set +x

readonly CAPABILITIES_ROOT="/data/capabilities"
readonly SHIMS_ROOT="/data/capability-shims"
readonly PI_AGENT_DIR="${PI_CODING_AGENT_DIR:-/data/pi/agent}"
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
```

- [ ] **Step 2: Add manifest loading no-op behavior**

Append:

```bash
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
  require_command jq

  if ! load_manifest; then
    log "no capability manifest configured; skipping"
    exit 0
  fi

  mkdir -p "$CAPABILITIES_ROOT" "$SHIMS_ROOT" "$PI_AGENT_DIR"
  chmod 700 "$CAPABILITIES_ROOT" "$SHIMS_ROOT" "$PI_AGENT_DIR"

  jq empty "$CAPABILITY_MANIFEST_PATH" >/dev/null || die "capability manifest is not valid JSON"
  log "capability manifest loaded"
}

main "$@"
```

- [ ] **Step 3: Run syntax validation**

Run:

```bash
bash -n scripts/capability_bootstrap.sh
```

Expected:

```text
exit code 0
```

- [ ] **Step 4: Run no-op smoke validation**

Run:

```bash
env -i PATH="$PATH" bash scripts/capability_bootstrap.sh
```

Expected:

```text
capability_bootstrap: no capability manifest configured; skipping
```

- [ ] **Step 5: Commit**

```bash
git add scripts/capability_bootstrap.sh
git commit -m "feat: add capability bootstrap skeleton"
```

---

## Task 2: Manifest Validation

**Files:**

- Modify: `scripts/capability_bootstrap.sh`

**SMART DoD:**

- Manifest `.version` must equal `1`.
- Top-level sections default safely when absent.
- Wrapper names must be safe command names.
- Secret references must use `secret:NAME` and `NAME` must match shell env naming rules.

- [ ] **Step 1: Add validation helpers**

Add before `main()`:

```bash
json_type_or_null() {
  local path="$1"
  jq -r "${path} | type" "$CAPABILITY_MANIFEST_PATH"
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
```

- [ ] **Step 2: Add schema validation function**

Add:

```bash
validate_manifest() {
  local version
  version="$(jq -r '.version // empty' "$CAPABILITY_MANIFEST_PATH")"
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
    validate_command_name "$name"
  done < <(jq -r '.cli.wrappers[]?.name // empty' "$CAPABILITY_MANIFEST_PATH")

  while IFS= read -r ref; do
    validate_secret_ref "$ref"
  done < <(jq -r '.. | strings | select(startswith("secret:"))' "$CAPABILITY_MANIFEST_PATH")
}
```

- [ ] **Step 3: Call validation from main**

After `jq empty` in `main()`, add:

```bash
  validate_manifest
```

- [ ] **Step 4: Validate expected failure**

Run:

```bash
AGENT_CAPABILITIES_JSON='{"version":2}' bash scripts/capability_bootstrap.sh
```

Expected:

```text
capability_bootstrap: capability manifest version must be 1
```

- [ ] **Step 5: Commit**

```bash
git add scripts/capability_bootstrap.sh
git commit -m "feat: validate capability manifest"
```

---

## Task 3: Required CLI Checks

**Files:**

- Modify: `scripts/capability_bootstrap.sh`

**SMART DoD:**

- Every string in `.cli.required[]` is checked with `command -v`.
- Missing commands fail before any auth files or wrappers are written.

- [ ] **Step 1: Add required CLI function**

Add before `main()`:

```bash
apply_required_cli_checks() {
  local command_name
  while IFS= read -r command_name; do
    [[ -n "$command_name" ]] || continue
    validate_command_name "$command_name"
    command -v "$command_name" >/dev/null 2>&1 || die "declared CLI is not available on PATH: ${command_name}"
  done < <(jq -r '.cli.required[]? // empty' "$CAPABILITY_MANIFEST_PATH")
}
```

- [ ] **Step 2: Call it in main after manifest validation**

Add:

```bash
  apply_required_cli_checks
```

- [ ] **Step 3: Validate missing command failure**

Run:

```bash
AGENT_CAPABILITIES_JSON='{"version":1,"cli":{"required":["definitely_missing_multica_tool"]}}' bash scripts/capability_bootstrap.sh
```

Expected:

```text
capability_bootstrap: declared CLI is not available on PATH: definitely_missing_multica_tool
```

- [ ] **Step 4: Commit**

```bash
git add scripts/capability_bootstrap.sh
git commit -m "feat: check declared capability binaries"
```

---

## Task 4: Secret Resolution Helper

**Files:**

- Modify: `scripts/capability_bootstrap.sh`

**SMART DoD:**

- `secret:NAME` resolves from environment variable `NAME`.
- Missing secret env fails with the secret name, not the value.
- Secret values are never printed.

- [ ] **Step 1: Add resolver**

Add before `main()`:

```bash
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
```

- [ ] **Step 2: Validate missing secret failure through a wrapper manifest**

This task only adds the helper, so use a Bash source smoke check:

```bash
bash -n scripts/capability_bootstrap.sh
```

Expected:

```text
exit code 0
```

- [ ] **Step 3: Commit**

```bash
git add scripts/capability_bootstrap.sh
git commit -m "feat: add capability secret resolver"
```

---

## Task 5: Env Wrapper Generation

**Files:**

- Modify: `scripts/capability_bootstrap.sh`

**SMART DoD:**

- `.cli.wrappers[]` creates `/data/capabilities/<name>/env` with `600` permissions.
- `.cli.wrappers[]` creates `/data/capability-shims/<name>` with `755` permissions.
- Wrapper env files contain shell-quoted values.
- Generated wrappers exec the target binary with original arguments.

- [ ] **Step 1: Add shell quote helper**

Add before `main()`:

```bash
shell_quote() {
  local value="$1"
  printf "'%s'" "$(printf '%s' "$value" | sed "s/'/'\\''/g")"
}
```

- [ ] **Step 2: Add wrapper renderer**

Add:

```bash
render_env_wrapper() {
  local name="$1"
  local target="$2"
  local env_file="${CAPABILITIES_ROOT}/${name}/env"
  local shim_file="${SHIMS_ROOT}/${name}"
  local key ref value

  validate_command_name "$name"
  [[ "$target" == /* ]] || die "wrapper target for ${name} must be an absolute path"
  [[ -x "$target" ]] || die "wrapper target for ${name} is not executable: ${target}"

  mkdir -p "${CAPABILITIES_ROOT}/${name}"
  chmod 700 "${CAPABILITIES_ROOT}/${name}"
  : >"$env_file"
  chmod 600 "$env_file"

  while IFS=$'\t' read -r key ref; do
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "invalid env name for wrapper ${name}: ${key}"
    value="$(resolve_secret_ref "$ref")"
    printf 'export %s=%s\n' "$key" "$(shell_quote "$value")" >>"$env_file"
  done < <(jq -r --arg name "$name" '.cli.wrappers[] | select(.name == $name) | .env // {} | to_entries[] | [.key, .value] | @tsv' "$CAPABILITY_MANIFEST_PATH")

  cat >"$shim_file" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$env_file"
exec "$target" "\$@"
EOF
  chmod 755 "$shim_file"
}

apply_env_wrappers() {
  local row name target
  while IFS=$'\t' read -r name target; do
    [[ -n "$name" ]] || continue
    render_env_wrapper "$name" "$target"
  done < <(jq -r '.cli.wrappers[]? | [.name, .target] | @tsv' "$CAPABILITY_MANIFEST_PATH")
}
```

- [ ] **Step 3: Call wrapper generation after required CLI checks**

Add in `main()`:

```bash
  apply_env_wrappers
  export PATH="${SHIMS_ROOT}:${PATH}"
```

- [ ] **Step 4: Validate wrapper generation locally**

Run:

```bash
CAPABILITY_TEST_VALUE="$(printf 'capability-test')" DEMO_TOKEN="$CAPABILITY_TEST_VALUE" AGENT_CAPABILITIES_JSON='{"version":1,"cli":{"wrappers":[{"name":"echo-demo","target":"/bin/echo","env":{"DEMO_TOKEN":"secret:DEMO_TOKEN"}}]}}' bash scripts/capability_bootstrap.sh
```

Expected:

```text
capability_bootstrap: capability manifest loaded
```

Then run:

```bash
test -x /data/capability-shims/echo-demo
test -f /data/capabilities/echo-demo/env
```

Expected:

```text
both commands exit code 0
```

- [ ] **Step 5: Commit**

```bash
git add scripts/capability_bootstrap.sh
git commit -m "feat: generate capability env wrappers"
```

---

## Task 6: GitHub Netrc Auth

**Files:**

- Modify: `scripts/capability_bootstrap.sh`

**SMART DoD:**

- `.auth.github.mode == "netrc"` writes `${HOME}/.netrc` with `600` permissions.
- Token is resolved from `secret:GITHUB_TOKEN` style reference.
- Git credential helper is not required for this task; `.netrc` is enough for HTTPS clone.

- [ ] **Step 1: Add GitHub netrc renderer**

Add before `main()`:

```bash
apply_github_netrc() {
  local mode token_ref token netrc_path
  mode="$(jq -r '.auth.github.mode // empty' "$CAPABILITY_MANIFEST_PATH")"
  [[ -n "$mode" ]] || return 0
  [[ "$mode" == "netrc" ]] || die "unsupported auth.github.mode: ${mode}"

  token_ref="$(jq -r '.auth.github.token // empty' "$CAPABILITY_MANIFEST_PATH")"
  [[ -n "$token_ref" ]] || die "auth.github.token is required for netrc mode"
  token="$(resolve_secret_ref "$token_ref")"

  mkdir -p "$HOME"
  chmod 700 "$HOME"
  netrc_path="${HOME}/.netrc"
  {
    printf 'machine github.com\n'
    printf '  login x-access-token\n'
    printf '  password %s\n' "$token"
  } >"$netrc_path"
  chmod 600 "$netrc_path"
}
```

- [ ] **Step 2: Call after wrapper generation**

Add in `main()`:

```bash
  apply_github_netrc
```

- [ ] **Step 3: Validate file creation**

Run:

```bash
HOME=/tmp/capability-home GITHUB_TOKEN='dummy-token' AGENT_CAPABILITIES_JSON='{"version":1,"auth":{"github":{"mode":"netrc","token":"secret:GITHUB_TOKEN"}}}' bash scripts/capability_bootstrap.sh
stat -c '%a' /tmp/capability-home/.netrc
```

Expected:

```text
600
```

- [ ] **Step 4: Commit**

```bash
git add scripts/capability_bootstrap.sh
git commit -m "feat: add github netrc capability auth"
```

---

## Task 7: Pi Settings Generation

**Files:**

- Modify: `scripts/capability_bootstrap.sh`

**SMART DoD:**

- `.pi.packages`, `.pi.skills`, and `.pi.extensions` generate `${PI_CODING_AGENT_DIR}/settings.json`.
- Existing settings are overwritten only by this bootstrap contract.
- Empty Pi sections generate no settings file.

- [ ] **Step 1: Add Pi settings renderer**

Add before `main()`:

```bash
apply_pi_settings() {
  local has_pi settings_path
  has_pi="$(jq -r '((.pi.packages // []) + (.pi.skills // []) + (.pi.extensions // [])) | length' "$CAPABILITY_MANIFEST_PATH")"
  [[ "$has_pi" != "0" ]] || return 0

  mkdir -p "$PI_AGENT_DIR"
  chmod 700 "$PI_AGENT_DIR"
  settings_path="${PI_AGENT_DIR}/settings.json"

  jq '{
    packages: (.pi.packages // []),
    skills: (.pi.skills // []),
    extensions: (.pi.extensions // [])
  }' "$CAPABILITY_MANIFEST_PATH" >"$settings_path"
  chmod 600 "$settings_path"
  jq empty "$settings_path" >/dev/null || die "generated Pi settings.json is invalid"
}
```

- [ ] **Step 2: Call after auth renderers**

Add in `main()`:

```bash
  apply_pi_settings
```

- [ ] **Step 3: Validate settings generation**

Run:

```bash
PI_CODING_AGENT_DIR=/tmp/pi-agent AGENT_CAPABILITIES_JSON='{"version":1,"pi":{"packages":["npm:@org/pkg@1.0.0"],"skills":["/data/capabilities/skills"],"extensions":[]}}' bash scripts/capability_bootstrap.sh
python3 -m json.tool /tmp/pi-agent/settings.json
```

Expected includes:

```json
{
  "packages": ["npm:@org/pkg@1.0.0"],
  "skills": ["/data/capabilities/skills"],
  "extensions": []
}
```

- [ ] **Step 4: Commit**

```bash
git add scripts/capability_bootstrap.sh
git commit -m "feat: generate pi capability settings"
```

---

## Task 8: MCP Config Generation

**Files:**

- Modify: `scripts/capability_bootstrap.sh`

**SMART DoD:**

- `.mcp.servers` generates `/data/pi/agent/mcp.json`.
- Server env secret refs are materialized into `/data/capabilities/mcp-<server>/env` with `600` permissions.
- Generated `mcp.json` references `envFile`, not raw secret values.

- [ ] **Step 1: Add MCP renderer**

Add before `main()`:

```bash
apply_mcp_config() {
  local server_count server env_dir env_file mcp_path key ref value
  server_count="$(jq -r '(.mcp.servers // {}) | length' "$CAPABILITY_MANIFEST_PATH")"
  [[ "$server_count" != "0" ]] || return 0

  mkdir -p "$PI_AGENT_DIR"
  chmod 700 "$PI_AGENT_DIR"
  mcp_path="${PI_AGENT_DIR}/mcp.json"

  jq '{servers: {}}' "$CAPABILITY_MANIFEST_PATH" >"$mcp_path"

  while IFS= read -r server; do
    validate_command_name "$server"
    env_dir="${CAPABILITIES_ROOT}/mcp-${server}"
    env_file="${env_dir}/env"
    mkdir -p "$env_dir"
    chmod 700 "$env_dir"
    : >"$env_file"
    chmod 600 "$env_file"

    while IFS=$'\t' read -r key ref; do
      [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "invalid MCP env name for ${server}: ${key}"
      value="$(resolve_secret_ref "$ref")"
      printf 'export %s=%s\n' "$key" "$(shell_quote "$value")" >>"$env_file"
    done < <(jq -r --arg server "$server" '.mcp.servers[$server].env // {} | to_entries[] | [.key, .value] | @tsv' "$CAPABILITY_MANIFEST_PATH")

    tmp_file="${mcp_path}.tmp"
    jq --arg server "$server" --arg envFile "$env_file" '
      .servers[$server] = {
        command: input.command,
        args: (input.args // []),
        envFile: $envFile
      }
    ' "$mcp_path" < <(jq --arg server "$server" '.mcp.servers[$server]' "$CAPABILITY_MANIFEST_PATH") >"$tmp_file"
    mv "$tmp_file" "$mcp_path"
  done < <(jq -r '.mcp.servers // {} | keys[]' "$CAPABILITY_MANIFEST_PATH")

  chmod 600 "$mcp_path"
  jq empty "$mcp_path" >/dev/null || die "generated mcp.json is invalid"
}
```

- [ ] **Step 2: Call after Pi settings generation**

Add in `main()`:

```bash
  apply_mcp_config
```

- [ ] **Step 3: Validate MCP config generation**

Run:

```bash
PI_CODING_AGENT_DIR=/tmp/pi-agent-mcp GITHUB_TOKEN=dummy AGENT_CAPABILITIES_JSON='{"version":1,"mcp":{"servers":{"github":{"command":"npx","args":["-y","@modelcontextprotocol/server-github@1.0.0"],"env":{"GITHUB_PERSONAL_ACCESS_TOKEN":"secret:GITHUB_TOKEN"}}}}}' bash scripts/capability_bootstrap.sh
python3 -m json.tool /tmp/pi-agent-mcp/mcp.json
```

Expected: generated JSON contains `envFile` and does not contain `dummy`.

- [ ] **Step 4: Commit**

```bash
git add scripts/capability_bootstrap.sh
git commit -m "feat: generate mcp capability config"
```

---

## Task 9: Validation Commands

**Files:**

- Modify: `scripts/capability_bootstrap.sh`

**SMART DoD:**

- `.validate[]` supports simple command arrays.
- Validation commands run after generated wrappers/auth/settings exist.
- Validation failure stops startup.
- Validation output is not captured into logs by the script.

- [ ] **Step 1: Add command validation runner**

Add before `main()`:

```bash
run_validation_commands() {
  local count index length command_json
  count="$(jq -r '(.validate // []) | length' "$CAPABILITY_MANIFEST_PATH")"
  [[ "$count" != "0" ]] || return 0

  for ((index = 0; index < count; index++)); do
    length="$(jq -r --argjson i "$index" '.validate[$i] | length' "$CAPABILITY_MANIFEST_PATH")"
    [[ "$length" -gt 0 ]] || die "validate[${index}] must not be empty"
    command_json="$(jq -c --argjson i "$index" '.validate[$i]' "$CAPABILITY_MANIFEST_PATH")"
    mapfile -t validation_args < <(printf '%s' "$command_json" | jq -r '.[]')
    "${validation_args[@]}" >/dev/null || die "capability validation command failed at index ${index}"
  done
}
```

- [ ] **Step 2: Call as final apply step**

Add near the end of `main()` before final log:

```bash
  run_validation_commands
  log "capability bootstrap completed"
```

- [ ] **Step 3: Validate success and failure**

Run:

```bash
AGENT_CAPABILITIES_JSON='{"version":1,"validate":[["command","-v","sh"]]}' bash scripts/capability_bootstrap.sh
```

Expected:

```text
capability_bootstrap: capability bootstrap completed
```

Run:

```bash
AGENT_CAPABILITIES_JSON='{"version":1,"validate":[["false"]]}' bash scripts/capability_bootstrap.sh
```

Expected:

```text
capability_bootstrap: capability validation command failed at index 0
```

- [ ] **Step 4: Commit**

```bash
git add scripts/capability_bootstrap.sh
git commit -m "feat: run capability validation commands"
```

---

## Task 10: Entrypoint Integration

**Files:**

- Modify: `scripts/entrypoint.sh`
- Modify: `Dockerfile`

**SMART DoD:**

- Dockerfile copies `scripts/capability_bootstrap.sh` to `/usr/local/bin/capability_bootstrap.sh`.
- Entrypoint calls bootstrap after secret fetch and path setup, before Multica setup and agent setup.
- For Pi runtime, `PI_CODING_AGENT_DIR` is available before bootstrap.
- Existing `codex` and `opencode` behavior remains unchanged when no manifest is configured.

- [ ] **Step 1: Modify Dockerfile script copy block**

Add:

```dockerfile
COPY scripts/capability_bootstrap.sh /usr/local/bin/capability_bootstrap.sh
```

And add it to chmod:

```dockerfile
RUN chmod 755 /usr/local/bin/entrypoint.sh \
  /usr/local/bin/setup_multica.sh \
  /usr/local/bin/setup_agent.sh \
  /usr/local/bin/capability_bootstrap.sh \
  /usr/local/bin/health_proxy.py
```

- [ ] **Step 2: Modify entrypoint runtime directories**

Ensure these exports exist before bootstrap:

```bash
export HOME="/data/home"
export PI_CODING_AGENT_DIR="${PI_CODING_AGENT_DIR:-/data/pi/agent}"
```

Ensure these directories are created:

```bash
mkdir -p "$HOME" "$MULTICA_WORKSPACES_ROOT" "$CODEX_HOME" "$OPENCODE_HOME" "$PI_CODING_AGENT_DIR" /data/capabilities /data/capability-shims
chmod 700 "$HOME" "$MULTICA_WORKSPACES_ROOT" "$CODEX_HOME" "$OPENCODE_HOME" "$PI_CODING_AGENT_DIR" /data/capabilities /data/capability-shims
```

- [ ] **Step 3: Call bootstrap before Multica setup**

Add after secret normalization and before `setup_multica.sh`:

```bash
log "running capability bootstrap"
/usr/local/bin/capability_bootstrap.sh
export PATH="/data/capability-shims:${PATH}"
```

- [ ] **Step 4: Validate syntax**

Run:

```bash
bash -n scripts/entrypoint.sh
bash -n scripts/capability_bootstrap.sh
```

Expected:

```text
both commands exit code 0
```

- [ ] **Step 5: Commit**

```bash
git add Dockerfile scripts/entrypoint.sh scripts/capability_bootstrap.sh
git commit -m "feat: run capability bootstrap at startup"
```

---

## Task 11: Documentation

**Files:**

- Create: `docs/capability-bootstrap-spec.md`
- Modify: `README.md`
- Modify: `docs/runtime-spec.md`
- Modify: `docs/security-and-secrets-spec.md`
- Modify: `ROADMAP.md`

**SMART DoD:**

- Operators can understand how to define a manifest and secrets.
- Docs state that system binaries still belong in image flavors unless explicitly preinstalled.
- Docs state that secrets are materialized only into tool-specific files with restrictive permissions.
- ROADMAP links to the capability bootstrap spec.

- [ ] **Step 1: Create spec document**

Create `docs/capability-bootstrap-spec.md` with:

```markdown
# Capability Bootstrap Specification

Date: 2026-05-13

## Purpose

Capability bootstrap prepares declared agent tooling before `multica daemon` starts. It does not install arbitrary operating-system packages at runtime.

## Inputs

- `AGENT_CAPABILITIES_JSON`: raw JSON manifest.
- `AGENT_CAPABILITIES_JSON_B64`: base64 JSON manifest. Takes precedence over raw JSON.
- Secret references in the manifest use `secret:NAME` and resolve from runtime environment variable `NAME` after the secret-store fetch step.

## Generated Paths

- `/data/capabilities`: capability-specific auth/config files, mode `700`.
- `/data/capability-shims`: wrapper commands, mode `700`.
- `/data/pi/agent/settings.json`: Pi package/skill/extension settings, mode `600`.
- `/data/pi/agent/mcp.json`: generated MCP server config, mode `600`.

## Supported Sections

### `cli.required`

List of binaries that must be available on `PATH`.

### `cli.wrappers`

Wrapper commands that inject tool-specific environment variables from secret references.

### `auth.github`

`netrc` mode writes `${HOME}/.netrc` for GitHub HTTPS access.

### `pi`

Generates Pi settings for `packages`, `skills`, and `extensions`.

### `mcp.servers`

Generates `mcp.json` with `envFile` references for a future Pi MCP gateway extension.

### `validate`

Command arrays run after bootstrap rendering.

## Security Rules

- The manifest must not contain raw secret values.
- Secrets are never printed.
- Generated secret-bearing files use `600` permissions.
- Runtime package installation is out of scope for the first implementation.
```

- [ ] **Step 2: Add README section**

Add a concise section named `Capability Bootstrap` that links to `docs/capability-bootstrap-spec.md` and includes a minimal manifest example with `cli.required`, `auth.github`, and `pi.packages`.

- [ ] **Step 3: Update runtime spec**

Add bootstrap to lifecycle between secret fetch and Multica setup:

```text
5. Run capability bootstrap when AGENT_CAPABILITIES_JSON or AGENT_CAPABILITIES_JSON_B64 is configured.
6. Configure Multica CLI.
7. Configure selected agent.
```

- [ ] **Step 4: Update security spec**

Add rules:

```text
Capability manifests contain secret references, not raw values.
Generated capability files with secret material must be chmod 600.
Secret-bearing generated files live under /data/capabilities or HOME-only auth files such as /data/home/.netrc.
```

- [ ] **Step 5: Update ROADMAP**

Add link:

```markdown
- [Capability bootstrap specification](docs/capability-bootstrap-spec.md) — deploy-time auth/config preparation for declared tools.
```

- [ ] **Step 6: Commit**

```bash
git add README.md ROADMAP.md docs/capability-bootstrap-spec.md docs/runtime-spec.md docs/security-and-secrets-spec.md
git commit -m "docs: specify capability bootstrap"
```

---

## Task 12: Final Verification

**Files:**

- No planned file changes.

**SMART DoD:**

- Syntax checks pass.
- JSON generation examples produce valid JSON.
- Secret scan shows no secret values in committed files.
- Existing no-manifest startup path remains a no-op for capabilities.

- [ ] **Step 1: Run syntax checks**

Run:

```bash
bash -n scripts/capability_bootstrap.sh
bash -n scripts/entrypoint.sh
python3 -m json.tool ROADMAP.md >/dev/null
```

Expected:

```text
The two bash commands exit code 0. The json.tool command is expected to fail because ROADMAP.md is Markdown; do not treat that as a repository failure.
```

- [ ] **Step 2: Run manifest no-op check**

Run:

```bash
env -i PATH="$PATH" bash scripts/capability_bootstrap.sh
```

Expected:

```text
capability_bootstrap: no capability manifest configured; skipping
```

- [ ] **Step 3: Run representative manifest check**

Run:

```bash
rm -rf /tmp/capability-home /tmp/pi-agent-final
HOME=/tmp/capability-home PI_CODING_AGENT_DIR=/tmp/pi-agent-final GITHUB_TOKEN=dummy AGENT_CAPABILITIES_JSON='{"version":1,"cli":{"required":["sh"]},"auth":{"github":{"mode":"netrc","token":"secret:GITHUB_TOKEN"}},"pi":{"packages":["npm:@org/pkg@1.0.0"]},"validate":[["command","-v","sh"]]}' bash scripts/capability_bootstrap.sh
python3 -m json.tool /tmp/pi-agent-final/settings.json
stat -c '%a' /tmp/capability-home/.netrc
```

Expected:

```text
capability_bootstrap: capability bootstrap completed
valid formatted JSON output for settings.json
600
```

- [ ] **Step 4: Run secret leakage scan**

Run:

```bash
rg "dummy|real_secret|ghp_|PGPASSWORD=.*[^)]" scripts docs README.md ROADMAP.md
```

Expected:

```text
No committed raw secret values are present. Documentation may mention variable names such as PGPASSWORD but not real values.
```

- [ ] **Step 5: Review staged diff**

Run:

```bash
git diff --check
git status --short
```

Expected:

```text
git diff --check exits code 0
only intentional files are modified or added
```

- [ ] **Step 6: Final commit if needed**

If verification changes documentation or scripts, commit them:

```bash
git add scripts docs README.md ROADMAP.md Dockerfile
git commit -m "chore: verify capability bootstrap"
```

## Edge Cases Covered

- No manifest configured.
- Invalid base64 manifest.
- Invalid JSON manifest.
- Unsupported manifest version.
- Wrong section type.
- Unsafe wrapper command name.
- Missing required binary.
- Missing secret reference value.
- Secret reference with invalid name.
- Wrapper target not absolute.
- Wrapper target not executable.
- GitHub auth mode unsupported.
- Generated Pi settings invalid JSON.
- MCP env secrets referenced via `envFile`, not raw values.
- Validation command failure.
- Existing `codex` and `opencode` no-manifest path remains unchanged.

## Implementation Order

1. Bootstrap no-op skeleton.
2. Manifest validation.
3. Required CLI checks.
4. Secret resolver.
5. Env wrappers.
6. GitHub netrc auth.
7. Pi settings generation.
8. MCP config generation.
9. Validation commands.
10. Entrypoint and Dockerfile integration.
11. Documentation.
12. Final verification.
