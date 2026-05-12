# Security And Secrets Specification

Date: 2026-05-08

## Secret Provider

MVP uses Infisical.

Railway stores only Infisical bootstrap variables:

```dotenv
INFISICAL_TOKEN=railway_sealed_infisical_token
INFISICAL_PROJECT_ID=<project-id>
INFISICAL_ENV=prod
INFISICAL_SECRET_PATH=/multica-daemon/agent-codex-1
INFISICAL_API_URL=https://app.infisical.com/api
```

`INFISICAL_TOKEN` requirements:

- read-only;
- scoped to one runtime secret path;
- stored as Railway sealed variable;
- not printed in logs.

## Infisical CLI Contract

MVP exports secrets with the Infisical CLI:

```bash
INFISICAL_TOKEN="$infisical_token" infisical export \
  --silent \
  --format=json \
  --projectId "$INFISICAL_PROJECT_ID" \
  --env "$INFISICAL_ENV" \
  --path "$INFISICAL_SECRET_PATH"
```

The implementation accepts JSON object exports and array-shaped secret exports. Secret names are normalized to internal setup inputs.

If export fails, returns invalid JSON, or misses required fields, startup fails.

## Secret Shapes

### Codex

```dotenv
MULTICA_TOKEN=mul_replace_with_runtime_token
CODEX_AUTH_JSON_B64=base64_encoded_codex_auth_json
GITHUB_TOKEN=github_pat_or_classic_token_with_read_repo_access
```

Required fields:

- `MULTICA_TOKEN`
- `CODEX_AUTH_JSON_B64`

Optional fields:

- `GITHUB_TOKEN` for private GitHub HTTPS repo clones.

### OpenCode

```dotenv
MULTICA_TOKEN=mul_replace_with_runtime_token
GITHUB_TOKEN=github_pat_or_classic_token_with_read_repo_access
```

Required field:

- `MULTICA_TOKEN`

OpenCode provider API keys are not required in MVP.

Optional fields:

- `GITHUB_TOKEN` for private GitHub HTTPS repo clones.

### Pi

```dotenv
MULTICA_TOKEN=mul_replace_with_runtime_token
PI_AUTH_JSON_B64=base64_encoded_pi_auth_json
GITHUB_TOKEN=github_pat_or_classic_token_with_read_repo_access
```

Required fields:

- `MULTICA_TOKEN`
- `PI_AUTH_JSON_B64`

Optional fields:

- `GITHUB_TOKEN` for private GitHub HTTPS repo clones.

The runtime normalizes `PI_AUTH_JSON_B64` from Infisical to:

```text
PI_AUTH_JSON_B64_FROM_SECRET_STORE
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
- decode Infisical `CODEX_AUTH_JSON_B64` only if `/data/codex/auth.json` is missing;
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
- decode Infisical `PI_AUTH_JSON_B64` from `PI_AUTH_JSON_B64_FROM_SECRET_STORE` only if `/data/pi/agent/auth.json` is missing;
- write `/data/pi/agent/auth.json` with restrictive permissions;
- preserve existing `/data/pi/agent/auth.json` on the Railway volume;
- do not run interactive `/login` in the container.

## Multica Token Handling

`MULTICA_TOKEN` is read from Infisical by the entrypoint and passed as scoped setup input:

```text
MULTICA_TOKEN_FROM_SECRET_STORE
```

`setup_multica.sh` copies it to local `multica_token`, unsets the exported setup input before invoking child `multica` processes, and authenticates with:

```bash
multica login --token "$multica_token"
```

The token must not be printed, persisted outside Multica CLI auth storage, or written to logs.

## GitHub Credential Handling

`GITHUB_TOKEN` is optional and exists only for daemon-side cloning of private GitHub repositories over HTTPS.

Runtime behavior:

- read `GITHUB_TOKEN` from Infisical if present;
- write managed `/data/home/.netrc` and `/data/home/.git-credentials` files with `chmod 600`;
- configure Git's global `credential.helper` to use the managed `/data/home/.git-credentials` store;
- use GitHub login `x-access-token`;
- unset `GITHUB_TOKEN` and `GITHUB_TOKEN_FROM_SECRET_STORE` before launching the daemon;
- remove the managed credential files and unset the Git credential helper on startup when the secret is no longer present.

The token should be a fine-grained GitHub PAT scoped to the specific repo with `Contents: Read-only`.

## Logging Rules

Allowed:

- selected agent;
- daemon id;
- runtime name;
- build versions;
- Infisical secret path;
- health proxy port;
- workspace root.

Forbidden:

- `INFISICAL_TOKEN`;
- `MULTICA_TOKEN`;
- `MULTICA_TOKEN_FROM_SECRET_STORE`;
- `CODEX_AUTH_JSON_B64`;
- `CODEX_AUTH_JSON_B64_FROM_SECRET_STORE`;
- `PI_AUTH_JSON_B64`;
- `PI_AUTH_JSON_B64_FROM_SECRET_STORE`;
- `GITHUB_TOKEN`;
- `GITHUB_TOKEN_FROM_SECRET_STORE`;
- decoded `auth.json`;
- raw Infisical export response;
- provider API keys.

## MVP Security Boundaries

MVP runs the container as `root` because of Railway volume permissions.

Mitigations in MVP:

- one runtime per service;
- one volume per runtime;
- one Infisical path per runtime;
- read-only Infisical token;
- no secret logging;
- restrictive file permissions for credentials;
- no interactive login in container;
- no Railway replicas.

## Incident Handling

If a runtime is suspected compromised:

1. Stop the Railway service.
2. Revoke the runtime Infisical token.
3. Revoke or rotate Multica personal token.
4. Rotate Codex or Pi credential by creating a fresh `auth.json`.
5. Create a new Infisical secret path for the replacement runtime.
6. Attach a fresh Railway volume if workspace trust is uncertain.

## Post-MVP Security Work

Detailed hardening ideas are tracked in `docs/post-mvp-backlog.md`.
