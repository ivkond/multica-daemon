# Railway Template Specification

Date: 2026-05-07

## Goal

Provide one Railway template for a `multica-daemon` runtime service.

The template creates a daemon host. It does not create Multica backend, frontend, Postgres, or pgvector services.

## Service Contract

The service:

- builds the Dockerfile from this repo;
- mounts a Railway Volume at `/data`;
- exposes healthcheck path `/health`;
- uses `$PORT` for the health proxy;
- sets runtime variables for Multica, Vault, and the selected agent.

## Build Variables

Required for every build:

```dotenv
AGENT=codex
MULTICA_VERSION=v0.2.27
NODE_VERSION=22.15.0
PNPM_VERSION=10.10.0
```

Required for Codex:

```dotenv
CODEX_VERSION=0.128.0
```

Required for OpenCode:

```dotenv
OPENCODE_VERSION=0.1.0
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

`VAULT_TOKEN` must be configured as a sealed Railway variable.

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

The volume stores:

- Multica CLI state under `/data/home`;
- workspaces under `/data/workspaces`;
- Codex state under `/data/codex`;
- OpenCode state under `/data/opencode`;
- Pi state under `/data/pi`.

Each named runtime needs its own volume.

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
VAULT_SECRET_PATH=kv/data/multica-daemon/agent-codex-1
MULTICA_DAEMON_ID=agent-codex-1
MULTICA_DAEMON_DEVICE_NAME=agent-codex-1
MULTICA_AGENT_RUNTIME_NAME=Codex Runtime 1
```

OpenCode runtime:

```dotenv
AGENT=opencode
VAULT_SECRET_PATH=kv/data/multica-daemon/agent-opencode-1
MULTICA_DAEMON_ID=agent-opencode-1
MULTICA_DAEMON_DEVICE_NAME=agent-opencode-1
MULTICA_AGENT_RUNTIME_NAME=OpenCode Runtime 1
```

Pi runtime:

```dotenv
AGENT=pi
VAULT_SECRET_PATH=kv/data/multica-daemon/agent-pi-1
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
- each runtime needs its own Vault secret path.

Use separate Railway services for additional daemon capacity.
