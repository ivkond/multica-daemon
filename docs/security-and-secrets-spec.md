# Security And Secrets Specification

Date: 2026-05-07

## Secret Provider

MVP uses HashiCorp Vault.

Railway stores only Vault access variables:

```dotenv
VAULT_ADDR=https://vault.example.com
VAULT_TOKEN=railway_sealed_vault_token
VAULT_SECRET_PATH=kv/data/multica-daemon/agent-codex-1
```

`VAULT_TOKEN` requirements:

- read-only;
- scoped to one runtime secret path;
- stored as Railway sealed variable;
- not printed in logs.

## Vault API Contract

MVP supports Vault KV v2.

Request:

```text
GET ${VAULT_ADDR}/v1/${VAULT_SECRET_PATH}
```

Expected response shape:

```json
{
  "data": {
    "data": {
      "multica_token": "mul_replace_with_runtime_token"
    }
  }
}
```

The implementation reads `.data.data`.

If the response is not KV v2 compatible, startup fails.

## Secret Shapes

### Codex

```json
{
  "multica_token": "mul_replace_with_runtime_token",
  "codex_auth_json_b64": "base64_encoded_codex_auth_json"
}
```

Required fields:

- `multica_token`
- `codex_auth_json_b64`

### OpenCode

```json
{
  "multica_token": "mul_replace_with_runtime_token"
}
```

Required field:

- `multica_token`

OpenCode provider API keys are not required in MVP.

### Pi

```json
{
  "multica_token": "mul_replace_with_runtime_token",
  "pi_auth_json_b64": "base64_encoded_pi_auth_json"
}
```

Required fields:

- `multica_token`
- `pi_auth_json_b64`

The runtime normalizes `pi_auth_json_b64` from Vault to:

```text
PI_AUTH_JSON_B64_FROM_VAULT
```

## Codex Credential Handling

Codex uses ChatGPT subscription credentials.

Bootstrap happens outside CI/CD:

```bash
export CODEX_HOME=/tmp/codex-bootstrap
codex login --device-auth
base64 -w 0 /tmp/codex-bootstrap/auth.json
```

Runtime behavior:

- create `/data/codex` with `chmod 700`;
- decode Vault `codex_auth_json_b64` only if `/data/codex/auth.json` is missing;
- write `/data/codex/auth.json` with `chmod 600`;
- preserve existing `/data/codex/auth.json`;
- write `/data/codex/config.toml`;
- silently unset `OPENAI_API_KEY` and `CODEX_API_KEY`;
- do not run interactive OAuth.

Codex config:

```toml
forced_login_method = "chatgpt"
cli_auth_credentials_store = "file"
```

## Pi Credential Handling

Pi uses an existing Pi Coding Agent `auth.json` credential.

Bootstrap happens outside CI/CD and outside the runtime container. No interactive `/login` is performed inside the container.

Runtime behavior:

- build with pinned `PI_VERSION=0.74.0` and npm package `@earendil-works/pi-coding-agent@${PI_VERSION}`;
- set `PI_CODING_AGENT_DIR=/data/pi/agent`;
- create `/data/pi/agent` with restrictive permissions;
- decode Vault `pi_auth_json_b64` from `PI_AUTH_JSON_B64_FROM_VAULT` only if `/data/pi/agent/auth.json` is missing;
- write `/data/pi/agent/auth.json` with restrictive permissions;
- preserve existing `/data/pi/agent/auth.json` on the Railway volume;
- do not run interactive `/login` in the container.

## Multica Token Handling

`multica_token` is read from Vault and exported only inside the entrypoint process tree as:

```text
MULTICA_TOKEN_FROM_VAULT
```

It is passed to:

```bash
multica login --token "$MULTICA_TOKEN_FROM_VAULT"
```

The token must not be printed, persisted outside Multica CLI auth storage, or written to logs.

## Logging Rules

Allowed:

- selected agent;
- daemon id;
- runtime name;
- build versions;
- Vault secret path;
- health proxy port;
- workspace root.

Forbidden:

- `VAULT_TOKEN`;
- `multica_token`;
- `codex_auth_json_b64`;
- `pi_auth_json_b64`;
- `PI_AUTH_JSON_B64_FROM_VAULT`;
- decoded `auth.json`;
- raw Vault response;
- API keys;
- provider API keys.

## MVP Security Boundaries

MVP runs the container as `root` because of Railway volume permissions.

Mitigations in MVP:

- one runtime per service;
- one volume per runtime;
- one Vault path per runtime;
- read-only Vault token;
- no secret logging;
- restrictive file permissions for credentials;
- no interactive login in container;
- no Railway replicas.

## Incident Handling

If a runtime is suspected compromised:

1. Stop the Railway service.
2. Revoke the runtime Vault token.
3. Revoke or rotate Multica personal token.
4. Rotate Codex or Pi credential by creating a fresh `auth.json`.
5. Create a new Vault secret path for the replacement runtime.
6. Attach a fresh Railway volume if workspace trust is uncertain.

## Post-MVP Security Work

Detailed hardening ideas are tracked in `docs/post-mvp-backlog.md`.
