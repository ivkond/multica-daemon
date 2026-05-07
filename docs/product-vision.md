# Product Vision

Date: 2026-05-07

## Goal

`multica-daemon` provides a reproducible Docker runtime for running Multica daemon as a standalone worker service. It exists to move the daemon off a local computer and into Railway as an execution node.

The product does not manage Multica backend, frontend, or Postgres. It connects to an existing Multica stack through `MULTICA_SERVER_URL`, `MULTICA_APP_URL`, and a runtime token from Vault.

## User Scenario

The user wants Multica tasks to run outside their laptop:

1. The user already has or deploys a reachable Multica backend and frontend.
2. The user creates a Vault secret for the runtime.
3. The user deploys a Railway service from this repo.
4. The runtime registers in Multica as a named daemon.
5. Multica assigns tasks to the available agent runtime.

## MVP Boundaries

The MVP supports two agent runtimes:

- `codex`
- `opencode`

One Docker image contains one agent CLI. The selected agent is controlled by `AGENT`.

The MVP does not include:

- Multica backend deployment.
- Multica frontend deployment.
- Postgres or pgvector.
- Railway replicas for the daemon service.
- Secret providers other than HashiCorp Vault.
- API key fallback for Codex.
- Provider matrix for OpenCode.
- Test automation.

## Deployment Model

One Railway service corresponds to one named runtime:

```text
agent-codex-1
agent-codex-2
agent-opencode-1
```

Each runtime has:

- a dedicated Railway Volume;
- a dedicated `MULTICA_DAEMON_ID`;
- a dedicated Vault secret path;
- one installed agent CLI.

This approach is used because the daemon is stateful: it has credentials, refreshed tokens, workspace directories, a health port, and stable identity.

## Success Criteria

The MVP is successful when:

- the Docker image builds for `AGENT=codex`;
- the Docker image builds for `AGENT=opencode`;
- the Railway service fetches secrets from Vault on startup;
- Multica CLI authenticates with `multica_token`;
- the Codex runtime uses a ChatGPT subscription credential from Vault;
- the OpenCode runtime starts with default free provider behavior;
- `multica daemon start --foreground` runs as the main container process;
- Railway healthcheck returns `200` only when the daemon is running.

## Architecture Choice

The selected approach is Runtime-First MVP:

- one universal Dockerfile;
- one Railway template;
- one agent per image;
- Vault-only secrets;
- minimal health proxy;
- separate specs and a user-facing README.

This approach keeps scope small and creates a fast path to a working daemon runtime without building an early framework for all future agents and providers.
