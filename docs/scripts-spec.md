# Scripts Specification

Date: 2026-05-08

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
- avoid runtime package installation from the network, except Infisical export and service health calls.

## `entrypoint.sh`

Responsibility: runtime orchestration.

Steps:

1. Validate required runtime env.
2. Export runtime paths:
   ```bash
   export HOME=/data/home
   export MULTICA_WORKSPACES_ROOT="${MULTICA_WORKSPACES_ROOT}"
   export CODEX_HOME=/data/codex
   export OPENCODE_HOME=/data/opencode
   ```
3. Normalize `MULTICA_WORKSPACES_ROOT` and reject `/data`, `/data/home`, `/data/codex`, `/data/opencode`, and descendants of those runtime state paths.
4. Create runtime directories.
5. Fetch Infisical secret with retry.
6. Export normalized secret values for child setup scripts.
7. Call `setup_multica.sh`.
8. Call `setup_agent.sh "$AGENT"`.
9. Start health proxy on `$PORT`.
10. Execute `multica daemon start --foreground`.

Required env:

```text
AGENT
INFISICAL_TOKEN
INFISICAL_PROJECT_ID
INFISICAL_ENV
INFISICAL_SECRET_PATH
MULTICA_SERVER_URL
MULTICA_APP_URL
MULTICA_DAEMON_ID
MULTICA_DAEMON_DEVICE_NAME
MULTICA_AGENT_RUNTIME_NAME
MULTICA_WORKSPACES_ROOT
PORT
```

Optional env:

```text
INFISICAL_API_URL
```

Supported agents:

```text
codex
opencode
```

Infisical fetch:

- use `infisical export --format=json`;
- parse with `jq`;
- retry 3 times;
- do not log raw response;
- expose only required normalized shell variables.

Normalized variables:

```text
MULTICA_TOKEN_FROM_SECRET_STORE
CODEX_AUTH_JSON_B64_FROM_SECRET_STORE
GITHUB_TOKEN_FROM_SECRET_STORE
```

`CODEX_AUTH_JSON_B64_FROM_SECRET_STORE` is required only for `AGENT=codex`.
`GITHUB_TOKEN_FROM_SECRET_STORE` is optional and used only to create managed `/data/home/.netrc` and `/data/home/.git-credentials` files for private GitHub repo clones.

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
MULTICA_TOKEN_FROM_SECRET_STORE
```

Steps:

1. Copy `MULTICA_TOKEN_FROM_SECRET_STORE` to local `multica_token`.
2. Unset exported `MULTICA_TOKEN_FROM_SECRET_STORE` before invoking child processes.
3. Verify `multica --version`.
4. Configure server URL:
   ```bash
   multica config set server_url "$MULTICA_SERVER_URL"
   ```
5. Configure app URL:
   ```bash
   multica config set app_url "$MULTICA_APP_URL"
   ```
6. Authenticate with token:
   ```bash
   multica login --token "$multica_token"
   ```
7. Unset local `multica_token`.
8. Treat successful `multica login --token` completion as the startup authentication gate. Do not run `multica auth status` in startup logs because it can expose a token prefix.

This script does not start the daemon.

## `setup_agent.sh <agent>`

Responsibility: selected agent runtime configuration.

Supported values:

```text
codex
opencode
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
CODEX_AUTH_JSON_B64_FROM_SECRET_STORE
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
infisical_secret_path
workspace_root
```

Forbidden log fields:

```text
INFISICAL_TOKEN
MULTICA_TOKEN_FROM_SECRET_STORE
CODEX_AUTH_JSON_B64_FROM_SECRET_STORE
auth.json content
raw Infisical export response
API keys
```
