# Pi Runtime Design

Date: 2026-05-12

## Goal

Add `pi` as a third supported `multica-daemon` agent runtime alongside `codex` and `opencode`.

A Pi runtime is deployed as its own Railway service with its own Railway Volume, daemon identity, and Vault secret path. The container installs a pinned Pi CLI version at build time, restores Pi authentication from Vault at startup, and then runs `multica daemon start --foreground` through the existing runtime lifecycle.

## Scope

In scope:

- Document `AGENT=pi` in README and runtime specs.
- Add Pi to the supported agent list for Docker build and runtime validation.
- Install Pi from npm with a pinned `PI_VERSION`:
  ```bash
  npm install -g @earendil-works/pi-coding-agent@${PI_VERSION}
  ```
- Store Pi credentials in Vault as `pi_auth_json_b64`.
- Restore Pi credentials to the Railway Volume at startup.
- Set `PI_CODING_AGENT_DIR=/data/pi/agent` so Pi config and state live on the persistent volume.
- Validate `pi --version` during build and startup.

Out of scope:

- Interactive `/login` inside the container.
- Per-provider Vault fields such as `anthropic_api_key` or `openai_api_key`.
- Pi package, skill, extension, or theme installation.
- Custom Pi model/provider configuration beyond what is already present in the supplied `auth.json` and persistent volume.

## Chosen Approach

Use a Codex-like credential bundle approach for Pi.

Pi officially stores provider credentials in `~/.pi/agent/auth.json`. The file can contain API-key credentials or OAuth/subscription credentials created through Pi's `/login` flow. Pi also supports `PI_CODING_AGENT_DIR`, which moves this agent config directory away from the default home-relative path.

For the daemon runtime, the user prepares Pi credentials outside CI/CD, base64-encodes the resulting `auth.json`, and stores it in Vault as `pi_auth_json_b64`. At startup, the container writes that file to `/data/pi/agent/auth.json` only if the file does not already exist. After first startup, the Railway Volume is the source of truth so refreshed tokens or user-managed updates are preserved.

This mirrors the existing Codex pattern while keeping Pi provider support generic. A single `auth.json` can support Anthropic, OpenAI, Gemini, Copilot, ChatGPT/Codex, or other Pi-supported providers without adding daemon-specific environment variables for each provider.

## Vault Contract

For `AGENT=pi`, the Vault secret contains:

```json
{
  "multica_token": "mul_replace_with_runtime_token",
  "pi_auth_json_b64": "base64_encoded_pi_auth_json"
}
```

`pi_auth_json_b64` is required for `AGENT=pi`.

The runtime must not log this field, the decoded `auth.json`, or raw Vault responses.

## Runtime Paths

The Pi runtime uses these persistent paths:

```text
/data/pi
/data/pi/agent
/data/workspaces
```

Runtime environment:

```bash
PI_CODING_AGENT_DIR=/data/pi/agent
MULTICA_WORKSPACES_ROOT=/data/workspaces
```

Permissions:

```bash
chmod 700 /data/pi
chmod 700 /data/pi/agent
chmod 600 /data/pi/agent/auth.json
```

`/data/pi/agent/auth.json` is created from Vault only when missing. Existing files are preserved.

## Build Contract

New build variable:

```dotenv
PI_VERSION=0.74.0
```

`PI_VERSION` is required when `AGENT=pi`.

Build validation:

```bash
pi --version
```

## Runtime Validation

For `AGENT=pi`, startup must verify:

- `pi --version` succeeds;
- `/data/pi/agent` exists and is writable;
- `pi_auth_json_b64` exists in Vault;
- base64 decoding succeeds when `auth.json` needs to be created;
- resulting `auth.json` has mode `600`.

No interactive Pi login runs inside the container.

## README User Flow

A user prepares Pi credentials outside CI/CD:

```bash
export PI_CODING_AGENT_DIR=/tmp/pi-bootstrap/agent
pi
# Run /login and select the intended provider, or configure API-key auth.
base64 -w 0 /tmp/pi-bootstrap/agent/auth.json
```

The user stores the resulting base64 value in Vault as `pi_auth_json_b64`, sets `AGENT=pi`, pins `PI_VERSION`, and deploys a dedicated Railway service and volume for the Pi runtime.

## Alternatives Considered

### Provider-specific Vault fields

Store fields such as `anthropic_api_key`, `openai_api_key`, or `gemini_api_key` and generate Pi config at startup.

Rejected because Pi supports many providers and multiple auth shapes. This would make the daemon responsible for tracking Pi provider internals and would not cover OAuth/subscription credentials cleanly.

### OpenCode-like no-secret MVP

Install Pi and only validate `pi --version`.

Rejected because a Pi daemon runtime normally needs provider credentials to execute assigned tasks. Deferring auth would produce a deployable image that is likely unusable for real daemon work.

## Testing Strategy

Documentation/spec verification:

- Confirm README, runtime spec, Dockerfile spec, scripts spec, and Railway template spec consistently include `pi`.
- Confirm Vault field names are consistent: `pi_auth_json_b64` and `PI_AUTH_JSON_B64_FROM_VAULT`.

Implementation verification later:

- Build image with `AGENT=pi` and pinned `PI_VERSION`.
- Run startup with a test Vault payload containing `multica_token` and `pi_auth_json_b64`.
- Confirm `/data/pi/agent/auth.json` is created with `600` permissions.
- Restart with an existing auth file and confirm it is preserved.
- Confirm `pi --version` succeeds during build and startup.
- Confirm secrets are not printed in logs.

## Open Questions

None. The accepted auth model is the Codex-like `auth.json` bundle stored in Vault as `pi_auth_json_b64`.
