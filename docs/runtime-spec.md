# Runtime Specification

Date: 2026-05-08

## Runtime Lifecycle

Container startup follows one sequence:

1. Validate required environment variables.
2. Create persistent directories under `/data`.
3. Fetch runtime secret from Infisical.
4. Run capability bootstrap when `AGENT_CAPABILITIES_JSON` or `AGENT_CAPABILITIES_JSON_B64` is configured.
5. Configure Multica CLI.
6. Configure selected agent.
7. Start Railway health proxy on `$PORT`.
8. Execute `multica daemon start --foreground`.

`entrypoint.sh` must fail fast when any of steps 1-6 fails.

The daemon is launched through `exec` so `multica daemon` becomes the main container process:

```bash
exec multica daemon start --foreground
```

## Runtime Environment

```dotenv
AGENT=opencode
INFISICAL_TOKEN=railway_sealed_infisical_token
INFISICAL_PROJECT_ID=<project-id>
INFISICAL_ENV=prod
INFISICAL_SECRET_PATH=/multica-daemon/agent-opencode-1
# Optional; defaults to https://app.infisical.com/api when omitted.
INFISICAL_API_URL=https://app.infisical.com/api
MULTICA_SERVER_URL=https://api.example.com
MULTICA_APP_URL=https://app.example.com
MULTICA_DAEMON_ID=agent-opencode-1
MULTICA_DAEMON_DEVICE_NAME=agent-opencode-1
MULTICA_AGENT_RUNTIME_NAME=OpenCode Runtime 1
MULTICA_WORKSPACES_ROOT=/data/workspaces
PORT=8080
```

`INFISICAL_API_URL` is optional; when unset, the entrypoint defaults it to `https://app.infisical.com/api`.

`AGENT` must match `MULTICA_IMAGE_AGENT`, the agent baked into the image at build time. If `MULTICA_IMAGE_AGENT` is unset or differs from runtime `AGENT`, startup must fail clearly before Infisical access or setup scripts run.

`AGENT` supported values are:

```text
codex
opencode
pi
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
/data/pi
/data/pi/agent
/data/capabilities
/data/capability-shims
```

Environment:

```bash
HOME=/data/home
MULTICA_WORKSPACES_ROOT=/data/workspaces
CODEX_HOME=/data/codex
OPENCODE_HOME=/data/opencode
PI_CODING_AGENT_DIR=/data/pi/agent
```

`MULTICA_WORKSPACES_ROOT` must resolve to a child path under `/data`, such as `/data/workspaces`. Startup rejects `/data`, `/data/home`, `/data/codex`, `/data/opencode`, `/data/pi`, `/data/pi/agent`, and descendants of those runtime state paths so workspaces cannot collide with CLI state.

Permissions:

```bash
chmod 700 /data/home
chmod 700 /data/workspaces
chmod 700 /data/codex
chmod 700 /data/opencode
chmod 700 /data/pi
chmod 700 /data/pi/agent
chmod 700 /data/capabilities
chmod 700 /data/capability-shims
chmod 600 /data/codex/auth.json
chmod 600 /data/pi/agent/auth.json
```

`/data/codex/auth.json` exists only for `AGENT=codex`.

`/data/pi/agent/auth.json` exists only for `AGENT=pi`.

When capability bootstrap is configured, it may also write `/data/capabilities/manifest.json`, tool-specific env files under `/data/capabilities`, wrapper commands under `/data/capability-shims`, `/data/home/.netrc`, `/data/pi/agent/settings.json`, and `/data/pi/agent/mcp.json`. Because the loaded manifest is persisted at `/data/capabilities/manifest.json`, raw secrets must not be placed anywhere in the manifest, including unknown or future fields. Secret-bearing generated files must use `chmod 600`.

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
- Do not call Infisical during healthchecks.
- Do not print secrets in responses or logs.

The proxy may be implemented with Python stdlib because `python3` is part of the image runtime dependencies.

## Runtime Validation

Minimal startup validation:

- required env variables are set;
- runtime `AGENT` matches image-baked `MULTICA_IMAGE_AGENT`;
- `MULTICA_WORKSPACES_ROOT` resolves under `/data` and does not overlap `/data/home`, `/data/codex`, `/data/opencode`, `/data/pi`, or `/data/pi/agent`;
- `/data` directories exist and are writable;
- Infisical export succeeds;
- selected secret fields are present;
- optional capability bootstrap succeeds after secret fetch and before Multica setup;
- optional GitHub token creates managed `/data/home/.netrc` and `/data/home/.git-credentials` files with `0600` permissions;
- `multica --version` succeeds;
- `multica login --token` succeeds without printing token values;
- `<agent> --version` succeeds.

For Codex:

- `OPENAI_API_KEY` and `CODEX_API_KEY` are silently unset;
- existing `/data/codex/auth.json` is preserved and remains the source of truth after first start;
- `/data/codex/auth.json` is created from Infisical only if missing;
- decoded Codex auth JSON is validated before it is moved into place.

For OpenCode:

- no provider API key is required in MVP;
- only `opencode --version` is required.

For Pi:

- `PI_CODING_AGENT_DIR` is set to `/data/pi/agent`;
- existing `/data/pi/agent/auth.json` is preserved and remains the source of truth after first start;
- `/data/pi/agent/auth.json` is created from Infisical only if missing;
- decoded Pi auth JSON is validated before it is moved into place;
- `PI_AUTH_JSON_B64` is required in Infisical;
- `pi --version` succeeds.

## Failure Behavior

Startup must fail before daemon launch when:

- required env is missing;
- Infisical is unreachable or unauthorized after retry;
- Infisical secret is missing required fields;
- base64 decode fails;
- Multica auth fails;
- selected agent binary is not available;
- `/data` paths are not writable.

Healthcheck failure after startup must not restart secrets setup. Railway handles service health based on `/health`.
