# multica-daemon

Run a Multica daemon outside your laptop, with Railway as the daemon host.

This repo builds and deploys a small runtime service. It connects to an existing Multica backend, stores workspaces on a Railway Volume, reads runtime secrets from Infisical, runs the selected agent CLI, and exposes a Railway-friendly healthcheck.

## What This Does

`multica-daemon` builds a Docker image for one agent runtime:

- `codex` - Codex CLI with ChatGPT subscription credentials loaded from Infisical.
- `opencode` - OpenCode CLI with default free provider behavior.
- `pi` - Pi CLI with provider credentials restored from an Infisical-backed `auth.json` bundle.

Each deployment is a separate named runtime:

```text
agent-codex-1
agent-codex-2
agent-opencode-1
agent-pi-1
```

Use a separate Railway service, volume, daemon id, and Infisical secret path for each runtime.

## How It Works

The container starts as a small orchestrator:

1. Reads Infisical bootstrap variables from Railway.
2. Exports the runtime secret from Infisical as JSON.
3. Prepares persistent directories under `/data`.
4. Runs capability bootstrap when a manifest is configured.
5. Configures Multica CLI with your server and app URLs.
6. Configures the selected agent.
7. Starts a thin health proxy on `$PORT`.
8. Runs `multica daemon start --foreground`.

Your Multica backend and frontend can live anywhere: Railway, a VPS, Vercel, another cloud, or your own infrastructure. The daemon only needs reachable URLs.

## Runtime Files

- `Dockerfile` builds the selected `codex`, `opencode`, or `pi` runtime image and installs the Infisical CLI.
- `scripts/entrypoint.sh` validates environment, prepares `/data`, fetches Infisical secrets, runs setup scripts, starts the health proxy, and execs the daemon.
- `scripts/setup_multica.sh` configures Multica CLI URLs and token auth.
- `scripts/setup_agent.sh` configures Codex, OpenCode, or Pi runtime state.
- `scripts/health_proxy.py` exposes Railway `/health` on `$PORT`.
- `railway.json` configures Dockerfile build and Railway `/health` healthcheck only.

## Before You Start

You need:

- a reachable Multica backend URL;
- a reachable Multica frontend URL;
- a Multica personal token for the daemon runtime;
- an Infisical project, environment slug, and secret path for this runtime;
- an Infisical service token or machine identity access token with read access to that path;
- a Railway service with a volume mounted at `/data`.

For Codex, you also need a prepared `CODEX_HOME/auth.json` created through a ChatGPT subscription login. The container does not perform interactive OAuth.

For Pi, you also need a prepared `~/.pi/agent/auth.json` created through Pi login or API-key configuration. The container restores this bundle from Infisical and does not perform interactive login.

Do not put secret values in committed files. Store only the Infisical bootstrap token as a sealed Railway variable, and store runtime secrets in Infisical.

## Capability Bootstrap

Capability bootstrap lets a deployment declare tool checks and deploy-time auth/config preparation before the daemon starts. See the [capability bootstrap specification](docs/capability-bootstrap-spec.md) for the full manifest contract.

Provide the manifest with `AGENT_CAPABILITIES_JSON` or base64-encoded `AGENT_CAPABILITIES_JSON_B64`. The loaded manifest is persisted at `/data/capabilities/manifest.json`, so never put raw secret values anywhere in it, including unknown or future fields. Secret-bearing fields use `secret:NAME` references that resolve from the runtime secret environment after Infisical fetch.

Minimal manifest example:

```json
{
  "version": 1,
  "cli": {
    "required": ["git"]
  },
  "pi": {
    "packages": ["npm:@org/pi-agent-toolbox@1.0.0"]
  }
}
```

System binaries listed in `cli.required` still need to be present in the selected image flavor unless they are otherwise explicitly preinstalled. Bootstrap does not install operating-system packages at runtime. Secrets are materialized only into tool-specific files with restrictive permissions, such as generated capability env files or `/data/home/.netrc`.

For normal private GitHub HTTPS workspace clones, the existing automatic `GITHUB_TOKEN` entrypoint handling is sufficient: add `GITHUB_TOKEN` to the runtime Infisical path and the entrypoint configures Git credentials. Use capability `auth.github` only when a deployment explicitly wants bootstrap-managed GitHub `.netrc` behavior or custom validation around that setup; it uses the same `secret:GITHUB_TOKEN` reference and is not required in addition to automatic `GITHUB_TOKEN` setup.

## Infisical Setup

Create one Infisical path per runtime, for example:

```text
/multica-daemon/agent-codex-1
/multica-daemon/agent-opencode-1
/multica-daemon/agent-pi-1
```

For a Codex runtime, store:

```dotenv
MULTICA_TOKEN=mul_replace_with_runtime_token
CODEX_AUTH_JSON_B64=base64_encoded_codex_auth_json
# Optional, required only when workspace repos are private GitHub HTTPS repos.
GITHUB_TOKEN=github_pat_or_classic_token_with_read_repo_access
```

For an OpenCode runtime, store:

```dotenv
MULTICA_TOKEN=mul_replace_with_runtime_token
# Optional, required only when workspace repos are private GitHub HTTPS repos.
GITHUB_TOKEN=github_pat_or_classic_token_with_read_repo_access
```

Example dummy values for an OpenCode runtime:

```bash
infisical secrets set MULTICA_TOKEN=dummy-multica-token \
  --projectId=<project-id> \
  --env=prod \
  --path=/multica-daemon/agent-opencode-1
```

For a Pi runtime, store:

```dotenv
MULTICA_TOKEN=mul_replace_with_runtime_token
PI_AUTH_JSON_B64=base64_encoded_pi_auth_json
# Optional, required only when workspace repos are private GitHub HTTPS repos.
GITHUB_TOKEN=github_pat_or_classic_token_with_read_repo_access
```

Pi stores provider credentials in `~/.pi/agent/auth.json`. The runtime restores the bundle to `/data/pi/agent/auth.json` and sets `PI_CODING_AGENT_DIR=/data/pi/agent` so Pi config and state live on the persistent volume.

For private GitHub repos, add a fine-grained GitHub PAT with repository `Contents: Read-only` access:

```bash
infisical secrets set GITHUB_TOKEN=<github-token> \
  --projectId=<project-id> \
  --env=prod \
  --path=/multica-daemon/agent-opencode-1
```

Example read-only service token:

```bash
infisical service-token create \
  --projectId <project-id> \
  --scope prod:/multica-daemon/agent-opencode-1 \
  --access-level read \
  --expiry-seconds 0 \
  --token-only
```

Store the returned token in Railway as `INFISICAL_TOKEN`.

## Railway Deploy

`railway.json` configures only:

- Dockerfile builder with `Dockerfile`;
- Railway healthcheck path `/health`.

It does not create or attach a Railway Volume, and it does not define service variables. Configure variables in the Railway UI or template, and manually attach a Railway Volume mounted at `/data`.

The Railway service uses these runtime variables:

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

`MULTICA_WORKSPACES_ROOT` must be a child path under `/data`, for example `/data/workspaces`. Startup rejects `/data`, `/data/home`, `/data/codex`, `/data/opencode`, `/data/pi`, and descendants of those runtime state paths.

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
INFISICAL_CLI_VERSION=0.43.82
CODEX_VERSION=0.128.0
```

For OpenCode:

```dotenv
AGENT=opencode
MULTICA_VERSION=v0.2.27
NODE_VERSION=22.15.0
PNPM_VERSION=10.10.0
INFISICAL_CLI_VERSION=0.43.82
OPENCODE_VERSION=1.14.41
OPENCODE_SHA256_X64=d27d3c85183a7bd2df4506484a2f508d1897962063b7ccc8466705b493963dc5
OPENCODE_SHA256_ARM64=2ffa63bb6115d7aa193cb1f6fa766eb79e1b399776871a624935a752e4461105
```

## Docker Build

Build a Codex image with pinned versions:

```bash
docker build \
  --build-arg AGENT=codex \
  --build-arg MULTICA_VERSION=v0.2.27 \
  --build-arg NODE_VERSION=22.15.0 \
  --build-arg PNPM_VERSION=10.10.0 \
  --build-arg INFISICAL_CLI_VERSION=0.43.82 \
  --build-arg CODEX_VERSION=0.128.0 \
  -t multica-daemon:codex .
```

Build an OpenCode image with pinned versions:

```bash
docker build \
  --build-arg AGENT=opencode \
  --build-arg MULTICA_VERSION=v0.2.27 \
  --build-arg NODE_VERSION=22.15.0 \
  --build-arg PNPM_VERSION=10.10.0 \
  --build-arg INFISICAL_CLI_VERSION=0.43.82 \
  --build-arg OPENCODE_VERSION=1.14.41 \
  --build-arg OPENCODE_SHA256_X64=d27d3c85183a7bd2df4506484a2f508d1897962063b7ccc8466705b493963dc5 \
  --build-arg OPENCODE_SHA256_ARM64=2ffa63bb6115d7aa193cb1f6fa766eb79e1b399776871a624935a752e4461105 \
  -t multica-daemon:opencode .
```

For Pi:

```dotenv
AGENT=pi
MULTICA_VERSION=v0.2.27
NODE_VERSION=22.15.0
PNPM_VERSION=10.10.0
INFISICAL_CLI_VERSION=0.43.82
PI_VERSION=0.74.0
```

Pi runtime variables:

```dotenv
AGENT=pi
INFISICAL_SECRET_PATH=/multica-daemon/agent-pi-1
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

Store the result in Infisical as `CODEX_AUTH_JSON_B64`.

At startup, the container preserves an existing `/data/codex/auth.json`. If the file is missing, it decodes the Infisical `CODEX_AUTH_JSON_B64` value to a temporary file, validates it as JSON, then moves it into place. After the first start, the Railway Volume copy is the source of truth so Codex can refresh credentials normally.

If `OPENAI_API_KEY` or `CODEX_API_KEY` exists in the environment, the entrypoint silently unsets it for Codex subscription mode.

## OpenCode Runtime

OpenCode is installed from pinned official `anomalyco/opencode` GitHub release assets and verified with the release asset SHA-256 digest. In the MVP runtime, it does not require provider API keys and uses default free provider behavior.

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

Store the base64 output in Infisical as `PI_AUTH_JSON_B64`.

At startup, the container writes `/data/pi/agent/auth.json` only if the file does not already exist. After the first start, the Railway Volume becomes the source of truth so Pi can preserve refreshed credentials and local state.

## Environment Variables

Required runtime variables:

| Variable                     | Purpose                                                            |
| ---------------------------- | ------------------------------------------------------------------ |
| `AGENT`                      | `codex`, `opencode`, or `pi`                                       |
| `INFISICAL_TOKEN`            | Read-only Infisical service token or machine identity access token |
| `INFISICAL_PROJECT_ID`       | Infisical project id                                               |
| `INFISICAL_ENV`              | Infisical environment slug, for example `prod`                     |
| `INFISICAL_SECRET_PATH`      | Infisical folder path for this runtime                             |
| `MULTICA_SERVER_URL`         | Multica backend URL                                                |
| `MULTICA_APP_URL`            | Multica frontend URL                                               |
| `MULTICA_DAEMON_ID`          | Stable daemon identity                                             |
| `MULTICA_DAEMON_DEVICE_NAME` | Human-readable device name                                         |
| `MULTICA_AGENT_RUNTIME_NAME` | Runtime display name in Multica                                    |
| `MULTICA_WORKSPACES_ROOT`    | Usually `/data/workspaces`                                         |
| `PORT`                       | Railway healthcheck port                                           |

Optional runtime variables:

| Variable            | Purpose                                                        |
| ------------------- | -------------------------------------------------------------- |
| `INFISICAL_API_URL` | Infisical API URL; defaults to `https://app.infisical.com/api` |

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
LOG_LEVEL=info
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

The proxy returns `200` only when the daemon reports `status == "running"`. Infisical is not called during healthchecks.

## Troubleshooting

**Infisical fetch fails**

Check `INFISICAL_TOKEN`, `INFISICAL_PROJECT_ID`, `INFISICAL_ENV`, `INFISICAL_SECRET_PATH`, and `INFISICAL_API_URL`. The token must have read access to the configured path.

**Codex runtime starts but Codex tasks fail**

Check that `/data/codex/auth.json` exists and was created with `codex login --device-auth` using the intended ChatGPT account.

**OpenCode runtime is not detected**

Check Railway logs for the startup check `opencode --version`. Multica daemon discovers agent CLIs through `PATH`.

**Pi runtime starts but Pi tasks fail**

Check that `/data/pi/agent/auth.json` exists, has `600` permissions, and was created from the intended Pi login or API-key configuration. Confirm the selected Pi provider/model works locally before encoding the file for Infisical.

**Daemon does not appear in Multica**

Check `MULTICA_SERVER_URL`, `MULTICA_DAEMON_ID`, `MULTICA_DAEMON_DEVICE_NAME`, `MULTICA_AGENT_RUNTIME_NAME`, and the Infisical secret `MULTICA_TOKEN`.

**Private GitHub repo clone fails**

Add `GITHUB_TOKEN` to the runtime Infisical path. For normal private GitHub HTTPS workspace clones, no capability manifest `auth.github` section is required: the entrypoint writes managed `/data/home/.netrc` and `/data/home/.git-credentials` files with `0600` permissions, configures Git's credential helper, and removes the token from the process environment before starting the daemon. Capability `auth.github` is optional and explicit for bootstrap-managed `.netrc` behavior or custom validation, using the same `secret:GITHUB_TOKEN` reference.

**Task wakeup WebSocket shows `bad handshake`**

The Multica daemon keeps polling for tasks when WebSocket wakeup is unavailable. Set `LOG_LEVEL=info` to suppress repeated debug messages while keeping normal task execution logs.

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

The starting formula stays simple: one runtime, one volume, one Infisical path, one daemon identity.
