# Runtime Specification

Date: 2026-05-07

## Runtime Lifecycle

Container startup follows one sequence:

1. Validate required environment variables.
2. Create persistent directories under `/data`.
3. Fetch runtime secret from Vault.
4. Configure Multica CLI.
5. Configure selected agent.
6. Start Railway health proxy on `$PORT`.
7. Execute `multica daemon start --foreground`.

`entrypoint.sh` must fail fast when any of steps 1-5 fails.

The daemon is launched through `exec` so `multica daemon` becomes the main container process:

```bash
exec multica daemon start --foreground
```

## Required Runtime Environment

```dotenv
AGENT=codex
VAULT_ADDR=https://vault.example.com
VAULT_TOKEN=railway_sealed_vault_token
VAULT_SECRET_PATH=kv/data/multica-daemon/agent-codex-1
MULTICA_SERVER_URL=https://api.example.com
MULTICA_APP_URL=https://app.example.com
MULTICA_DAEMON_ID=agent-codex-1
MULTICA_DAEMON_DEVICE_NAME=agent-codex-1
MULTICA_AGENT_RUNTIME_NAME=Codex Runtime 1
MULTICA_WORKSPACES_ROOT=/data/workspaces
PORT=8080
```

`AGENT` must be either:

```text
codex
opencode
```

## Volume Layout

Railway Volume is mounted at:

```text
/data
```

Runtime directories:

```text
/data/home
/data/workspaces
/data/codex
/data/opencode
```

Environment:

```bash
HOME=/data/home
MULTICA_WORKSPACES_ROOT=/data/workspaces
CODEX_HOME=/data/codex
OPENCODE_HOME=/data/opencode
```

Permissions:

```bash
chmod 700 /data/home
chmod 700 /data/workspaces
chmod 700 /data/codex
chmod 700 /data/opencode
chmod 600 /data/codex/auth.json
```

`/data/codex/auth.json` exists only for `AGENT=codex`.

## Multica Daemon Env Pass-Through

The runtime must not invent daemon tuning defaults. It passes existing `MULTICA_*` environment variables through to `multica daemon`.

Supported examples:

```dotenv
MULTICA_DAEMON_POLL_INTERVAL=3s
MULTICA_DAEMON_HEARTBEAT_INTERVAL=15s
MULTICA_DAEMON_MAX_CONCURRENT_TASKS=1
MULTICA_AGENT_TIMEOUT=2h
MULTICA_CODEX_SEMANTIC_INACTIVITY_TIMEOUT=10m
MULTICA_GC_ENABLED=true
MULTICA_GC_TTL=24h
MULTICA_GC_ORPHAN_TTL=72h
MULTICA_GC_ARTIFACT_TTL=12h
MULTICA_GC_ARTIFACT_PATTERNS=node_modules,.next,.turbo
```

These variables are documented for users but not set by the image unless explicitly provided at deploy time.

## Health Proxy

Multica daemon exposes a local endpoint:

```text
http://127.0.0.1:19514/health
```

Source references:

- `server/internal/daemon/health.go` in `multica-ai/multica`
- `server/cmd/multica/cmd_daemon.go` in `multica-ai/multica`

Railway healthchecks need a service endpoint on `$PORT`, so the runtime starts a thin proxy:

```text
GET 0.0.0.0:$PORT/health
  -> GET 127.0.0.1:19514/health
```

Proxy behavior:

- Return `200` if local daemon health JSON has `status == "running"`.
- Return `503` if local daemon health is unreachable or status is not `running`.
- Do not call Vault during healthchecks.
- Do not print secrets in responses or logs.

The proxy may be implemented with Python stdlib because `python3-minimal` is part of the image runtime dependencies.

## Runtime Validation

Minimal startup validation:

- required env variables are set;
- `/data` directories exist and are writable;
- Vault fetch succeeds;
- selected secret fields are present;
- `multica --version` succeeds;
- `multica auth status` succeeds after token login;
- `<agent> --version` succeeds.

For Codex:

- `OPENAI_API_KEY` and `CODEX_API_KEY` are silently unset;
- `/data/codex/auth.json` is created from Vault only if missing;
- existing `/data/codex/auth.json` is preserved.

For OpenCode:

- no provider API key is required in MVP;
- only `opencode --version` is required.

## Failure Behavior

Startup must fail before daemon launch when:

- required env is missing;
- Vault is unreachable after retry;
- Vault secret is missing required fields;
- base64 decode fails;
- Multica auth fails;
- selected agent binary is not available;
- `/data` paths are not writable.

Healthcheck failure after startup must not restart secrets setup. Railway handles service health based on `/health`.
