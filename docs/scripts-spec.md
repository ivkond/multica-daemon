# Scripts Specification

Date: 2026-05-07

## File Layout

```text
scripts/
  entrypoint.sh
  setup_multica.sh
  setup_agent.sh
```

All scripts use one mode. There are no `install` or `runtime` subcommands in MVP.

## Shared Rules

All scripts must:

- use `#!/usr/bin/env bash`;
- use `set -euo pipefail`;
- fail-fast with actionable error messages;
- avoid printing secret values;
- avoid interactive prompts;
- avoid runtime package installation from the network, except Vault fetch and service health calls.

## `entrypoint.sh`

Responsibility: runtime orchestration.

Steps:

1. Validate required runtime env, including that `AGENT` matches image-baked `MULTICA_IMAGE_AGENT`.
2. Export runtime paths:
   ```bash
   export HOME=/data/home
   export MULTICA_WORKSPACES_ROOT="${MULTICA_WORKSPACES_ROOT}"
   export CODEX_HOME=/data/codex
   export OPENCODE_HOME=/data/opencode
   export PI_CODING_AGENT_DIR=/data/pi/agent
   ```
3. Create runtime directories.
4. Fetch Vault secret with retry.
5. Export normalized secret values for child setup scripts.
6. Call `setup_multica.sh`.
7. Call `setup_agent.sh "$AGENT"`.
8. Start health proxy on `$PORT`.
9. Execute `multica daemon start --foreground`.

Required env:

```text
AGENT
MULTICA_IMAGE_AGENT
VAULT_ADDR
VAULT_TOKEN
VAULT_SECRET_PATH
MULTICA_SERVER_URL
MULTICA_APP_URL
MULTICA_DAEMON_ID
MULTICA_DAEMON_DEVICE_NAME
MULTICA_AGENT_RUNTIME_NAME
MULTICA_WORKSPACES_ROOT
PORT
```

`entrypoint.sh` must fail clearly before Vault fetch when `MULTICA_IMAGE_AGENT` is missing or differs from runtime `AGENT`.

Supported agents:

```text
codex
opencode
pi
```

Vault fetch:

- use `curl`;
- parse with `jq`;
- support KV v2 response at `.data.data`;
- retry 3 times;
- do not log raw response;
- expose only required normalized shell variables.

Normalized variables:

```text
MULTICA_TOKEN_FROM_VAULT
CODEX_AUTH_JSON_B64_FROM_VAULT
PI_AUTH_JSON_B64_FROM_VAULT
```

`CODEX_AUTH_JSON_B64_FROM_VAULT` is required only for `AGENT=codex`.

`PI_AUTH_JSON_B64_FROM_VAULT` is sourced from Vault field `pi_auth_json_b64` and is required only for `AGENT=pi`.

Health proxy:

- listen on `0.0.0.0:$PORT`;
- check `http://127.0.0.1:19514/health`;
- return `200` only when JSON status is `running`;
- return `503` otherwise.

Daemon launch:

```bash
exec multica daemon start --foreground
```

## `setup_multica.sh`

Responsibility: Multica CLI runtime configuration and auth.

Inputs:

```text
MULTICA_SERVER_URL
MULTICA_APP_URL
MULTICA_TOKEN_FROM_VAULT
```

Steps:

1. Verify `multica --version`.
2. Configure server URL:
   ```bash
   multica config set server_url "$MULTICA_SERVER_URL"
   ```
3. Configure app URL:
   ```bash
   multica config set app_url "$MULTICA_APP_URL"
   ```
4. Authenticate with token:
   ```bash
   multica login --token "$MULTICA_TOKEN_FROM_VAULT"
   ```
5. Verify:
   ```bash
   multica auth status
   ```

This script does not start the daemon.

## `setup_agent.sh <agent>`

Responsibility: selected agent runtime configuration.

Supported values:

```text
codex
opencode
pi
```

Unsupported values fail-fast.

Common validation:

```bash
<agent> --version
```

### Codex

Inputs:

```text
CODEX_HOME=/data/codex
CODEX_AUTH_JSON_B64_FROM_VAULT
```

Rules:

- silently unset `OPENAI_API_KEY`;
- silently unset `CODEX_API_KEY`;
- create `CODEX_HOME` with `chmod 700`;
- write `CODEX_HOME/auth.json` only when missing;
- keep existing `auth.json` untouched;
- write `CODEX_HOME/config.toml`;
- set `auth.json` permission to `600`;
- do not run `codex login`.

Config:

```toml
forced_login_method = "chatgpt"
cli_auth_credentials_store = "file"
```

Validation:

```bash
codex --version
```

`codex login status` is not required as a startup gate in MVP because OAuth refresh behavior may depend on runtime network and account state. Runtime failures should surface through daemon logs and task execution. A stronger Codex auth readiness check belongs in post-MVP validation work.

### OpenCode

Inputs:

```text
OPENCODE_HOME=/data/opencode
```

Rules:

- create `OPENCODE_HOME` with `chmod 700`;
- do not require provider API keys in MVP;
- do not generate provider-specific config in MVP.

Validation:

```bash
opencode --version
```

### Pi

Inputs:

```text
PI_CODING_AGENT_DIR=/data/pi/agent
PI_AUTH_JSON_B64_FROM_VAULT
```

Rules:

- create `/data/pi` with `chmod 700`;
- create `PI_CODING_AGENT_DIR` with `chmod 700`;
- write `PI_CODING_AGENT_DIR/auth.json` only when missing;
- preserve existing `auth.json`;
- set `auth.json` permission to `600`;
- do not run interactive `pi` or `/login`.

Validation:

```bash
pi --version
```

## Logging Contract

Allowed startup log fields:

```text
agent
daemon_id
device_name
runtime_name
multica_version
node_version
codex_version
opencode_version
pi_version
vault_secret_path
workspace_root
```

Forbidden log fields:

```text
VAULT_TOKEN
MULTICA_TOKEN_FROM_VAULT
CODEX_AUTH_JSON_B64_FROM_VAULT
PI_AUTH_JSON_B64_FROM_VAULT
auth.json content
raw Vault response
API keys
```
