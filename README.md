# multica-daemon

Run a Multica daemon outside your laptop, with Railway as the daemon host.

This repo helps you build and deploy a small runtime service. It connects to your Multica backend, stores workspaces on a Railway Volume, runs the selected agent CLI, and exposes a Railway-friendly healthcheck.

## What This Does

`multica-daemon` builds a Docker image for one agent runtime:

- `codex` - Codex CLI with ChatGPT subscription credentials loaded from HashiCorp Vault.
- `opencode` - OpenCode CLI with default free provider behavior.
- `pi` - Pi CLI with provider credentials restored from a Vault-backed `auth.json` bundle.

Each deployment is a separate named runtime:

```text
agent-codex-1
agent-codex-2
agent-opencode-1
agent-pi-1
```

Use a separate Railway service, volume, daemon id, and Vault path for each runtime.

## How It Works

The container starts as a small orchestrator:

1. Reads Vault connection variables from Railway.
2. Fetches the runtime secret from HashiCorp Vault.
3. Configures Multica CLI with your server and app URLs.
4. Prepares persistent directories under `/data`.
5. Configures the selected agent.
6. Starts a thin health proxy on `$PORT`.
7. Runs `multica daemon start --foreground`.

Your Multica backend and frontend can live anywhere: Railway, a VPS, Vercel, another cloud, or your own infrastructure. The daemon only needs reachable URLs.

## Before You Start

You need:

- a reachable Multica backend URL;
- a reachable Multica frontend URL;
- a Multica personal token for the daemon runtime;
- a HashiCorp Vault secret path for this runtime;
- a Railway service with a volume mounted at `/data`.

For Codex, you also need a prepared `CODEX_HOME/auth.json` created through a ChatGPT subscription login. The container does not perform interactive OAuth.

For Pi, you also need a prepared `~/.pi/agent/auth.json` created through Pi login or API-key configuration. The container restores this bundle from Vault and does not perform interactive login.

## Vault Setup

Store only Vault access variables in Railway:

```dotenv
VAULT_ADDR=https://vault.example.com
VAULT_TOKEN=railway_sealed_vault_token
VAULT_SECRET_PATH=kv/data/multica-daemon/agent-codex-1
```

`VAULT_SECRET_PATH` is the API path after `/v1/` for a KV v2 secret. The runtime reads the payload from `.data.data`.

For a Codex runtime, store this in Vault:

```json
{
  "multica_token": "mul_replace_with_runtime_token",
  "codex_auth_json_b64": "base64_encoded_codex_auth_json"
}
```

For an OpenCode runtime, store this in Vault:

```json
{
  "multica_token": "mul_replace_with_runtime_token"
}
```

For a Pi runtime, store this in Vault:

```json
{
  "multica_token": "mul_replace_with_runtime_token",
  "pi_auth_json_b64": "base64_encoded_pi_auth_json"
}
```

Pi stores provider credentials in `~/.pi/agent/auth.json`. The runtime restores the bundle to `/data/pi/agent/auth.json` and sets `PI_CODING_AGENT_DIR=/data/pi/agent` so Pi config and state live on the persistent volume.

`VAULT_TOKEN` must be read-only and scoped to exactly one runtime path.

## Railway Deploy

The Railway service uses these runtime variables:

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

If your Multica backend and frontend are in the same Railway project, you can use Railway reference variables:

```dotenv
MULTICA_SERVER_URL=https://${{Backend.RAILWAY_PUBLIC_DOMAIN}}
MULTICA_APP_URL=https://${{Frontend.RAILWAY_PUBLIC_DOMAIN}}
```

If your service names differ, replace `Backend` and `Frontend` with the actual names. If your Multica stack is not hosted on Railway, use regular public URLs.

Pinned build variables:

```dotenv
AGENT=codex
MULTICA_VERSION=v0.2.27
NODE_VERSION=22.15.0
PNPM_VERSION=10.10.0
CODEX_VERSION=0.128.0
```

For OpenCode:

```dotenv
AGENT=opencode
MULTICA_VERSION=v0.2.27
NODE_VERSION=22.15.0
PNPM_VERSION=10.10.0
OPENCODE_VERSION=0.1.0
```

For Pi:

```dotenv
AGENT=pi
MULTICA_VERSION=v0.2.27
NODE_VERSION=22.15.0
PNPM_VERSION=10.10.0
PI_VERSION=0.74.0
```

Pi runtime variables:

```dotenv
AGENT=pi
VAULT_SECRET_PATH=kv/data/multica-daemon/agent-pi-1
MULTICA_DAEMON_ID=agent-pi-1
MULTICA_DAEMON_DEVICE_NAME=agent-pi-1
MULTICA_AGENT_RUNTIME_NAME=Pi Runtime 1
```

## Codex Runtime

Codex uses ChatGPT subscription credentials, not `OPENAI_API_KEY`.

Create the credential outside CI/CD:

```bash
export CODEX_HOME=/tmp/codex-bootstrap
codex login --device-auth
base64 -w 0 /tmp/codex-bootstrap/auth.json
```

Store the result in Vault as `codex_auth_json_b64`.

At startup, the container writes `/data/codex/auth.json` only if the file does not already exist. After the first start, the Railway Volume becomes the source of truth so Codex can refresh credentials normally.

If `OPENAI_API_KEY` or `CODEX_API_KEY` exists in the environment, the entrypoint silently unsets it for Codex subscription mode.

## OpenCode Runtime

OpenCode is installed through its upstream-supported pinned install path. In the MVP runtime, it does not require provider API keys and uses default free provider behavior.

Provider-specific OpenCode secrets can be added later without changing the Multica daemon contract.

## Pi Runtime

Pi is installed from the pinned npm package `@earendil-works/pi-coding-agent`.

Prepare credentials outside CI/CD:

```bash
export PI_CODING_AGENT_DIR=/tmp/pi-bootstrap/agent
pi
# Run /login and select the intended provider, or configure API-key auth.
base64 -w 0 /tmp/pi-bootstrap/agent/auth.json
```

Store the base64 output in Vault as `pi_auth_json_b64`.

At startup, the container writes `/data/pi/agent/auth.json` only if the file does not already exist. After the first start, the Railway Volume becomes the source of truth so Pi can preserve refreshed credentials and local state.

## Environment Variables

Required runtime variables:

| Variable | Purpose |
| --- | --- |
| `AGENT` | `codex`, `opencode`, or `pi` |
| `VAULT_ADDR` | Vault base URL |
| `VAULT_TOKEN` | Read-only Vault token for this runtime |
| `VAULT_SECRET_PATH` | KV v2 API path for the runtime secret |
| `MULTICA_SERVER_URL` | Multica backend URL |
| `MULTICA_APP_URL` | Multica frontend URL |
| `MULTICA_DAEMON_ID` | Stable daemon identity |
| `MULTICA_DAEMON_DEVICE_NAME` | Human-readable device name |
| `MULTICA_AGENT_RUNTIME_NAME` | Runtime display name in Multica |
| `MULTICA_WORKSPACES_ROOT` | Usually `/data/workspaces` |
| `PORT` | Railway healthcheck port |

Multica daemon options pass through environment variables. Examples:

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

The image does not set daemon tuning defaults itself. Use these variables only when you want to override Multica defaults.

## Healthcheck

Multica daemon exposes a local health endpoint:

```text
http://127.0.0.1:19514/health
```

Railway needs a service endpoint on `$PORT`, so the image starts a thin proxy:

```text
0.0.0.0:$PORT/health -> 127.0.0.1:19514/health
```

Railway healthcheck path:

```text
/health
```

The proxy returns `200` only when the daemon reports `status == "running"`. Vault is not called during healthchecks.

## Troubleshooting

**Vault fetch fails**

Check `VAULT_ADDR`, `VAULT_TOKEN`, and `VAULT_SECRET_PATH`. The token must have read-only access to the configured path.

**Codex runtime starts but Codex tasks fail**

Check that `/data/codex/auth.json` exists and was created with `codex login --device-auth` using the intended ChatGPT account.

**OpenCode runtime is not detected**

Check Railway logs for the startup check `opencode --version`. Multica daemon discovers agent CLIs through `PATH`.

**Pi runtime starts but Pi tasks fail**

Check that `/data/pi/agent/auth.json` exists, has `600` permissions, and was created from the intended Pi login or API-key configuration. Confirm the selected Pi provider/model works locally before encoding the file for Vault.

**Daemon does not appear in Multica**

Check `MULTICA_SERVER_URL`, `MULTICA_DAEMON_ID`, `MULTICA_DAEMON_DEVICE_NAME`, `MULTICA_AGENT_RUNTIME_NAME`, and the Vault field `multica_token`.

**Healthcheck fails**

Check the local daemon endpoint:

```bash
curl -fsS http://127.0.0.1:19514/health
```

Then check the Railway-facing endpoint:

```bash
curl -fsS http://127.0.0.1:${PORT}/health
```

## What You Can Build Next

Once one Codex, OpenCode, or Pi runtime is stable, the same pattern can expand into:

- more named daemon services;
- additional agent CLIs beyond Codex, OpenCode, and Pi;
- provider-specific OpenCode profiles;
- alternative secret providers;
- non-root hardening;
- build matrix automation;
- richer diagnostics and rotation workflows.

The starting formula stays simple: one runtime, one volume, one Vault path, one daemon identity.
