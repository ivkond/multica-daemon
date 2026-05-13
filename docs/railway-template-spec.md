# Railway Template Specification

Date: 2026-05-08

## Goal

Provide one Railway template for a `multica-daemon` runtime service.

The template creates a daemon host. It does not create Multica backend, frontend, Postgres, or pgvector services.

## Service Contract

The service:

- builds the Dockerfile from this repo;
- exposes healthcheck path `/health`;
- uses `$PORT` for the health proxy;
- requires runtime variables for Multica, Infisical, and the selected agent to be configured outside `railway.json`;
- requires a Railway Volume to be attached manually at `/data`.

`railway.json` configures only Dockerfile build and Railway `/health` healthcheck. It does not define variables and it does not create or mount the volume.

## Build Variables

Required for every build:

```dotenv
AGENT=opencode
MULTICA_VERSION=v0.2.27
NODE_VERSION=22.15.0
PNPM_VERSION=10.10.0
INFISICAL_CLI_VERSION=0.43.82
```

Required for Codex:

```dotenv
CODEX_VERSION=0.128.0
```

Required for OpenCode:

```dotenv
OPENCODE_VERSION=1.14.41
OPENCODE_SHA256_X64=d27d3c85183a7bd2df4506484a2f508d1897962063b7ccc8466705b493963dc5
OPENCODE_SHA256_ARM64=2ffa63bb6115d7aa193cb1f6fa766eb79e1b399776871a624935a752e4461105
```

Required for Pi:

```dotenv
PI_VERSION=0.74.0
```

`AGENT` supported values are:

```text
codex
opencode
pi
```

## Runtime Variables

```dotenv
AGENT=opencode
INFISICAL_TOKEN=railway_sealed_infisical_token
INFISICAL_PROJECT_ID=<project-id>
INFISICAL_ENV=prod
INFISICAL_SECRET_PATH=/multica-daemon/agent-opencode-1
INFISICAL_API_URL=https://app.infisical.com/api
MULTICA_SERVER_URL=https://api.example.com
MULTICA_APP_URL=https://app.example.com
MULTICA_DAEMON_ID=agent-opencode-1
MULTICA_DAEMON_DEVICE_NAME=agent-opencode-1
MULTICA_AGENT_RUNTIME_NAME=OpenCode Runtime 1
MULTICA_WORKSPACES_ROOT=/data/workspaces
PORT=8080
```

`INFISICAL_TOKEN` must be configured as a sealed Railway variable.

## Reference Variables

If Multica backend and frontend are Railway services in the same project/environment, users can use Railway reference variables:

```dotenv
MULTICA_SERVER_URL=https://${{Backend.RAILWAY_PUBLIC_DOMAIN}}
MULTICA_APP_URL=https://${{Frontend.RAILWAY_PUBLIC_DOMAIN}}
```

Service names are examples. The template documentation must instruct users to replace `Backend` and `Frontend` with their actual service names.

When Multica is hosted outside Railway, users provide normal URLs.

## Volume

Mount path:

```text
/data
```

The volume is configured outside `railway.json` and must be manually attached to the Railway service.

The volume stores:

- Multica CLI state under `/data/home`;
- workspaces under `/data/workspaces`;
- Codex state under `/data/codex`;
- OpenCode state under `/data/opencode`;
- Pi state under `/data/pi`.

Each named runtime needs its own volume.

`MULTICA_WORKSPACES_ROOT` must be a child path under `/data`, for example `/data/workspaces`. Startup validation rejects `/data`, `/data/home`, `/data/codex`, `/data/opencode`, `/data/pi`, `/data/pi/agent`, and descendants of those runtime state paths.

## Healthcheck

Railway healthcheck:

```text
Path: /health
Port: $PORT
```

The service health proxy maps this to Multica daemon local health:

```text
127.0.0.1:19514/health
```

## Deployment Examples

Codex runtime:

```dotenv
AGENT=codex
INFISICAL_SECRET_PATH=/multica-daemon/agent-codex-1
MULTICA_DAEMON_ID=agent-codex-1
MULTICA_DAEMON_DEVICE_NAME=agent-codex-1
MULTICA_AGENT_RUNTIME_NAME=Codex Runtime 1
```

OpenCode runtime:

```dotenv
AGENT=opencode
INFISICAL_SECRET_PATH=/multica-daemon/agent-opencode-1
MULTICA_DAEMON_ID=agent-opencode-1
MULTICA_DAEMON_DEVICE_NAME=agent-opencode-1
MULTICA_AGENT_RUNTIME_NAME=OpenCode Runtime 1
```

Pi runtime:

```dotenv
AGENT=pi
INFISICAL_SECRET_PATH=/multica-daemon/agent-pi-1
MULTICA_DAEMON_ID=agent-pi-1
MULTICA_DAEMON_DEVICE_NAME=agent-pi-1
MULTICA_AGENT_RUNTIME_NAME=Pi Runtime 1
```

## Replicas

Railway replicas are not part of the MVP deployment model.

Reason:

- daemon identity must be stable;
- credentials live on a volume;
- workspace directories are stateful;
- each runtime needs its own Infisical secret path.

Use separate Railway services for additional daemon capacity.
