# MVP Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first working `multica-daemon` Railway runtime image for `codex` and `opencode`.

**Architecture:** The project stays docs-first and runtime-first: a small Docker image delegates behavior to focused shell scripts and one Python stdlib health proxy. Runtime scripts fetch Vault secrets, configure Multica and the selected agent, then `exec` the daemon so the container process model stays simple.

**Tech Stack:** Debian bookworm-slim, Bash, Python stdlib, curl, jq, official Node.js binary, Corepack, pnpm, Multica CLI, Codex CLI, OpenCode CLI, Railway `railway.json`.

---

## Scope Decision

Automated tests are intentionally excluded from this implementation plan because this repository is not being treated as a typical code-first project. Validation uses contract review, shell/Python syntax checks, Docker build checks, and explicit runtime smoke scenarios.

The existing specs remain the source of truth:

- `docs/product-vision.md`
- `docs/runtime-spec.md`
- `docs/scripts-spec.md`
- `docs/dockerfile-spec.md`
- `docs/railway-template-spec.md`
- `docs/security-and-secrets-spec.md`
- `README.md`

Context7 Railway documentation check on 2026-05-08 confirmed:

- `railway.json` can set Dockerfile builds with `build.builder = "DOCKERFILE"` and `build.dockerfilePath = "Dockerfile"`.
- `railway.json` can set `deploy.healthcheckPath = "/health"`.
- Service variables and volume mount setup remain deployment/template configuration documented for users.

## File Structure

- Create `Dockerfile`: reproducible image build, pinned build args, system packages, Node, selected agent, runtime scripts.
- Create `scripts/entrypoint.sh`: runtime orchestrator, required env validation, `/data` layout, Vault KV v2 fetch, setup script calls, health proxy start, daemon exec.
- Create `scripts/setup_multica.sh`: Multica CLI config and token login.
- Create `scripts/setup_agent.sh`: selected agent runtime setup for `codex` and `opencode`.
- Create `scripts/health_proxy.py`: Railway-facing health endpoint that proxies local Multica daemon health.
- Create `railway.json`: Railway config-as-code for Dockerfile build and `/health` deploy healthcheck.
- Modify `README.md`: align user instructions with implemented file names and exact build/deploy validation commands only if implementation differs from current docs.

Protected files stay untouched:

- no `.env` changes;
- no `ci/**`;
- no Kubernetes or Terraform files;
- Dockerfile is changed only when the user explicitly proceeds with implementation.

## Global Definition Of Done

The MVP is done when all criteria are verifiably true:

- Codex image builds with `AGENT=codex`, pinned `MULTICA_VERSION`, `NODE_VERSION`, `PNPM_VERSION`, and `CODEX_VERSION`.
- OpenCode image builds with `AGENT=opencode`, pinned `MULTICA_VERSION`, `NODE_VERSION`, `PNPM_VERSION`, and `OPENCODE_VERSION`.
- Startup fails before daemon launch when required runtime env, Vault fields, CLI binaries, or writable `/data` paths are missing.
- Runtime reads HashiCorp Vault KV v2 from `${VAULT_ADDR}/v1/${VAULT_SECRET_PATH}` and never logs secret values.
- Multica CLI receives `server_url`, `app_url`, and token login before daemon launch.
- Codex mode writes `/data/codex/auth.json` from Vault only when missing, preserves an existing file, writes `config.toml`, and unsets API-key env vars before Codex validation.
- Newly decoded Codex `/data/codex/auth.json` is validated with `jq empty`; an existing file is preserved without adding a new existing-file JSON validation gate.
- OpenCode mode requires no provider API key and validates `opencode --version`.
- Health proxy returns `200` only when local daemon health JSON has `status == "running"` and returns `503` otherwise.
- The final container command is `exec multica daemon start --foreground`.
- Railway config uses Dockerfile builder and `/health` healthcheck path.

## Task 1: Health Proxy

**Files:**

- Create: `scripts/health_proxy.py`

**SMART DoD:**

- By the end of this task, `python3 -m py_compile scripts/health_proxy.py` succeeds.
- The script accepts `--listen-host`, `--port`, and `--target-url` with defaults matching the runtime spec.
- `GET /health` returns `200` only when target JSON contains `"status": "running"`.
- Any target connection error, invalid JSON, missing status, or non-running status returns `503`.
- Responses never include Vault, Multica, Codex, OpenCode, or provider secret values.

- [ ] **Step 1: Create `scripts/health_proxy.py`**

Use Python stdlib only. The script must expose one endpoint and suppress default request logging.

Key contract:

```python
DEFAULT_LISTEN_HOST = "0.0.0.0"
DEFAULT_TARGET_URL = "http://127.0.0.1:19514/health"

def health_status_from_target(target_url: str, timeout_seconds: float) -> tuple[int, bytes]:
    request = urllib.request.Request(target_url, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, ValueError, json.JSONDecodeError):
        return 503, b'{"status":"unavailable"}\n'

    if payload.get("status") == "running":
        return 200, b'{"status":"running"}\n'

    return 503, b'{"status":"unavailable"}\n'
```

- [ ] **Step 2: Add CLI parsing and server startup**

The script must run as:

```bash
python3 /usr/local/bin/health_proxy.py --port "$PORT"
```

Accepted CLI options:

```text
--listen-host default 0.0.0.0
--port required integer from entrypoint
--target-url default http://127.0.0.1:19514/health
--timeout-seconds default 2.0
```

- [ ] **Step 3: Validate syntax**

Run:

```bash
python3 -m py_compile scripts/health_proxy.py
```

Expected result:

```text
command exits with code 0
```

- [ ] **Step 4: Manual smoke validation**

Run a fake daemon health endpoint on `127.0.0.1:19514` in a temporary local shell and then run:

```bash
python3 scripts/health_proxy.py --listen-host 127.0.0.1 --port 18080
curl -i http://127.0.0.1:18080/health
```

Expected result for `{"status":"running"}`:

```text
HTTP/1.0 200 OK
{"status":"running"}
```

Expected result for any other target status:

```text
HTTP/1.0 503 Service Unavailable
{"status":"unavailable"}
```

Expected result for a malformed non-JSON target response with HTTP 2xx, including HTML or plain text:

```text
HTTP/1.0 503 Service Unavailable
{"status":"unavailable"}
```

## Task 2: Multica Setup Script

**Files:**

- Create: `scripts/setup_multica.sh`

**SMART DoD:**

- By the end of this task, `bash -n scripts/setup_multica.sh` succeeds.
- The script fails fast when `MULTICA_SERVER_URL`, `MULTICA_APP_URL`, or `MULTICA_TOKEN_FROM_VAULT` is unset or empty.
- The script runs `multica --version`, configures server and app URLs, authenticates with `multica login --token`, and verifies `multica auth status`.
- The script does not print `MULTICA_TOKEN_FROM_VAULT`.

- [ ] **Step 1: Create strict Bash script header and helpers**

Required header:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

Required helper behavior:

```bash
die() {
  printf 'setup_multica: %s\n' "$1" >&2
  exit 1
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    die "required environment variable is empty: ${name}"
  fi
}
```

- [ ] **Step 2: Add required env checks**

The script must call:

```bash
require_env "MULTICA_SERVER_URL"
require_env "MULTICA_APP_URL"
require_env "MULTICA_TOKEN_FROM_VAULT"
```

- [ ] **Step 3: Add Multica CLI configuration flow**

Use these commands in this order:

```bash
multica --version
multica config set server_url "$MULTICA_SERVER_URL"
multica config set app_url "$MULTICA_APP_URL"
multica login --token "$MULTICA_TOKEN_FROM_VAULT"
multica auth status
```

Allowed log lines:

```bash
printf 'setup_multica: configuring Multica CLI\n' >&2
printf 'setup_multica: Multica auth verified\n' >&2
```

- [ ] **Step 4: Validate syntax**

Run:

```bash
bash -n scripts/setup_multica.sh
```

Expected result:

```text
command exits with code 0
```

- [ ] **Step 5: Manual secret-redaction review**

Review the file and confirm the literal string below appears only in variable expansion passed to `multica login` and never in an `echo`, `printf`, or command trace statement:

```text
MULTICA_TOKEN_FROM_VAULT
```

## Task 3: Agent Setup Script

**Files:**

- Create: `scripts/setup_agent.sh`

**SMART DoD:**

- By the end of this task, `bash -n scripts/setup_agent.sh` succeeds.
- `scripts/setup_agent.sh codex` creates `/data/codex`, writes `config.toml`, decodes `auth.json` only when missing, sets `auth.json` permission to `600`, and validates `codex --version`.
- A newly decoded Codex `auth.json` is validated with `jq empty "${CODEX_HOME}/auth.json"` before Codex validation.
- An existing Codex `auth.json` is preserved as-is except for permission normalization to `600`; the script does not add JSON validation for an existing file in this MVP.
- `scripts/setup_agent.sh opencode` creates `/data/opencode` and validates `opencode --version`.
- Unsupported agent names fail before any agent-specific state is written.
- Codex mode unsets `OPENAI_API_KEY` and `CODEX_API_KEY` before running `codex --version`.

- [ ] **Step 1: Create strict Bash script header and helpers**

Required header and helpers:

```bash
#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'setup_agent: %s\n' "$1" >&2
  exit 1
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    die "required environment variable is empty: ${name}"
  fi
}
```

- [ ] **Step 2: Add argument contract**

The script must require one argument:

```bash
if [[ "$#" -ne 1 ]]; then
  die "usage: setup_agent.sh codex|opencode"
fi

agent="$1"
```

- [ ] **Step 3: Add Codex setup function**

The Codex branch must perform these actions:

```bash
require_env "CODEX_HOME"
require_env "CODEX_AUTH_JSON_B64_FROM_VAULT"

unset OPENAI_API_KEY
unset CODEX_API_KEY

mkdir -p "$CODEX_HOME"
chmod 700 "$CODEX_HOME"

if [[ ! -f "${CODEX_HOME}/auth.json" ]]; then
  printf '%s' "$CODEX_AUTH_JSON_B64_FROM_VAULT" | base64 -d > "${CODEX_HOME}/auth.json"
  jq empty "${CODEX_HOME}/auth.json"
fi

chmod 600 "${CODEX_HOME}/auth.json"

cat > "${CODEX_HOME}/config.toml" <<'EOF'
forced_login_method = "chatgpt"
cli_auth_credentials_store = "file"
EOF

codex --version
```

- [ ] **Step 4: Add OpenCode setup function**

The OpenCode branch must perform these actions:

```bash
require_env "OPENCODE_HOME"

mkdir -p "$OPENCODE_HOME"
chmod 700 "$OPENCODE_HOME"

opencode --version
```

- [ ] **Step 5: Add agent dispatch**

Use exact supported values:

```bash
case "$agent" in
  codex)
    setup_codex
    ;;
  opencode)
    setup_opencode
    ;;
  *)
    die "unsupported AGENT: ${agent}"
    ;;
esac
```

- [ ] **Step 6: Validate syntax**

Run:

```bash
bash -n scripts/setup_agent.sh
```

Expected result:

```text
command exits with code 0
```

- [ ] **Step 7: Manual preservation scenario**

Create `/data/codex/auth.json` with known content in a disposable container or local Linux environment, run Codex setup with a different Vault payload, and confirm the file content remains unchanged while permission becomes `600`.

## Task 4: Entrypoint Orchestrator

**Files:**

- Create: `scripts/entrypoint.sh`

**SMART DoD:**

- By the end of this task, `bash -n scripts/entrypoint.sh` succeeds.
- Startup validates all required env vars before network or CLI work.
- Startup creates `/data/home`, `/data/workspaces`, `/data/codex`, and `/data/opencode` with `700` permissions.
- Startup rejects `MULTICA_WORKSPACES_ROOT` unless it is under `/data`.
- Vault fetch retries exactly 3 times and reads KV v2 fields from `.data.data`.
- Codex requires `codex_auth_json_b64`; OpenCode does not.
- Health proxy starts in background before daemon launch.
- Final line that launches the daemon uses `exec multica daemon start --foreground`.

- [ ] **Step 1: Create strict Bash script header and constants**

Required header:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

Required constants:

```bash
readonly DATA_ROOT="/data"
readonly DEFAULT_CODEX_HOME="/data/codex"
readonly DEFAULT_OPENCODE_HOME="/data/opencode"
readonly VAULT_RETRY_COUNT=3
readonly VAULT_RETRY_DELAY_SECONDS=2
```

- [ ] **Step 2: Add helpers**

Required helper names and behavior:

```bash
die() {
  printf 'entrypoint: %s\n' "$1" >&2
  exit 1
}

log() {
  printf 'entrypoint: %s\n' "$1" >&2
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    die "required environment variable is empty: ${name}"
  fi
}
```

- [ ] **Step 3: Validate runtime env**

Required env list:

```text
AGENT
VAULT_ADDR
VAULT_TOKEN
VAULT_SECRET_PATH
MULTICA_SERVER_URL
MULTICA_APP_URL
MULTICA_DAEMON_ID
MULTICA_DAEMON_DEVICE_NAME
MULTICA_AGENT_RUNTIME_NAME
MULTICA_WORKSPACES_ROOT
PORT
```

Supported agent dispatch must reject anything except:

```text
codex
opencode
```

- [ ] **Step 4: Export runtime paths**

Use:

```bash
export HOME="/data/home"
export CODEX_HOME="$DEFAULT_CODEX_HOME"
export OPENCODE_HOME="$DEFAULT_OPENCODE_HOME"
export MULTICA_WORKSPACES_ROOT="${MULTICA_WORKSPACES_ROOT}"
```

- [ ] **Step 5: Create and validate runtime directories**

Required directories:

```bash
[[ "$MULTICA_WORKSPACES_ROOT" == /data/* ]] || die "MULTICA_WORKSPACES_ROOT must be under /data"

mkdir -p "$HOME" "$MULTICA_WORKSPACES_ROOT" "$CODEX_HOME" "$OPENCODE_HOME"
chmod 700 "$HOME" "$MULTICA_WORKSPACES_ROOT" "$CODEX_HOME" "$OPENCODE_HOME"

[[ -w "$HOME" ]] || die "HOME is not writable"
[[ -w "$MULTICA_WORKSPACES_ROOT" ]] || die "MULTICA_WORKSPACES_ROOT is not writable"
[[ -w "$CODEX_HOME" ]] || die "CODEX_HOME is not writable"
[[ -w "$OPENCODE_HOME" ]] || die "OPENCODE_HOME is not writable"
```

- [ ] **Step 6: Fetch Vault KV v2 secret with retry**

Vault retry loop contract:

- Exactly 3 attempts are made.
- Each attempt uses `curl -fsS`.
- HTTP 4xx, HTTP 5xx, and network failures are retried.
- A two-second delay occurs between failed attempts.
- Raw Vault responses are never logged.
- Failure after the third attempt exits with a non-secret message.
- Only a successful response is assigned to `vault_response`.

Required request inside the retry loop:

```bash
vault_response=""
for attempt in 1 2 3; do
  if vault_response_candidate="$(curl -fsS \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR%/}/v1/${VAULT_SECRET_PATH}")"; then
    vault_response="$vault_response_candidate"
    break
  fi

  if [[ "$attempt" -lt "$VAULT_RETRY_COUNT" ]]; then
    sleep "$VAULT_RETRY_DELAY_SECONDS"
  fi
done

[[ -n "$vault_response" ]] || die "Vault secret fetch failed after 3 attempts"
```

Required field extraction:

```bash
MULTICA_TOKEN_FROM_VAULT="$(printf '%s' "$vault_response" | jq -er '.data.data.multica_token // empty')"
CODEX_AUTH_JSON_B64_FROM_VAULT="$(printf '%s' "$vault_response" | jq -er '.data.data.codex_auth_json_b64 // empty')"
```

OpenCode must tolerate an empty Codex field. Codex must fail if the Codex field is empty.

- [ ] **Step 7: Export normalized secret variables**

Use:

```bash
export MULTICA_TOKEN_FROM_VAULT
export CODEX_AUTH_JSON_B64_FROM_VAULT
```

Never print:

```text
VAULT_TOKEN
MULTICA_TOKEN_FROM_VAULT
CODEX_AUTH_JSON_B64_FROM_VAULT
raw Vault response
```

- [ ] **Step 8: Call setup scripts**

Use absolute runtime paths after Dockerfile installation:

```bash
/usr/local/bin/setup_multica.sh
/usr/local/bin/setup_agent.sh "$AGENT"
```

- [ ] **Step 9: Start health proxy**

Use:

```bash
python3 /usr/local/bin/health_proxy.py --port "$PORT" &
```

Keep the proxy process as a child of the entrypoint process tree. Do not call Vault from health proxy code.

- [ ] **Step 10: Launch daemon**

Final daemon launch:

```bash
exec multica daemon start --foreground
```

- [ ] **Step 11: Validate syntax**

Run:

```bash
bash -n scripts/entrypoint.sh
```

Expected result:

```text
command exits with code 0
```

## Task 5: Dockerfile

**Files:**

- Create: `Dockerfile`

**SMART DoD:**

- By the end of this task, Docker builds fail fast for missing required build args or unsupported `AGENT`.
- The image uses `debian:bookworm-slim`.
- Node.js is installed from the official pinned Linux x64 tarball for `NODE_VERSION`.
- Corepack activates pinned `pnpm`.
- Multica installs from pinned GitHub release asset for `MULTICA_VERSION`.
- Codex image installs `@openai/codex@${CODEX_VERSION}` and verifies `codex --version`.
- OpenCode image installs exact `OPENCODE_VERSION` through the documented upstream install path and verifies `opencode --version`.
- The OpenCode installer-from-main path is accepted as an MVP reproducibility risk because the current spec requires the upstream-supported install path; mitigation is exact `OPENCODE_VERSION`, build-time `opencode --version`, and post-MVP replacement if direct release assets become required.
- Unsupported `AGENT` validation prints an actionable stderr message naming the accepted values before exiting non-zero.
- Runtime scripts are copied to `/usr/local/bin` and the entrypoint is `/usr/local/bin/entrypoint.sh`.

- [ ] **Step 1: Add base image and build args**

Required Dockerfile opening:

```dockerfile
FROM debian:bookworm-slim

ARG AGENT
ARG MULTICA_VERSION
ARG NODE_VERSION
ARG PNPM_VERSION
ARG CODEX_VERSION
ARG OPENCODE_VERSION
```

- [ ] **Step 2: Add build arg validation**

Validation must reject empty required values and unsupported agents:

```dockerfile
RUN test -n "$AGENT" \
  && test -n "$MULTICA_VERSION" \
  && test -n "$NODE_VERSION" \
  && test -n "$PNPM_VERSION" \
  && case "$AGENT" in \
    codex) test -n "$CODEX_VERSION" ;; \
    opencode) test -n "$OPENCODE_VERSION" ;; \
    *) printf 'Dockerfile: unsupported AGENT "%s"; expected codex or opencode\n' "$AGENT" >&2; exit 1 ;; \
  esac
```

- [ ] **Step 3: Install system dependencies**

Install exactly these packages:

```text
bash
ca-certificates
curl
git
jq
python3-minimal
tar
unzip
xz-utils
```

Clean apt metadata in the same layer.

- [ ] **Step 4: Install Node.js and Corepack**

Use the official Linux x64 tarball:

```dockerfile
RUN curl -fsSLo /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
  && mkdir -p /usr/local/lib/nodejs \
  && tar -xJf /tmp/node.tar.xz -C /usr/local/lib/nodejs --strip-components=1 \
  && rm /tmp/node.tar.xz \
  && ln -s /usr/local/lib/nodejs/bin/node /usr/local/bin/node \
  && ln -s /usr/local/lib/nodejs/bin/npm /usr/local/bin/npm \
  && ln -s /usr/local/lib/nodejs/bin/npx /usr/local/bin/npx \
  && corepack enable \
  && corepack prepare "pnpm@${PNPM_VERSION}" --activate
```

- [ ] **Step 5: Install Multica CLI**

Install from the exact release tag. The implementation must encode supported Linux amd64 asset naming, fail clearly if the asset download fails, and document the observed exact pattern in README or `docs/dockerfile-spec.md` if it differs from current spec wording. Do not invent an unverified release asset name during planning.

Required validation:

```dockerfile
RUN multica --version
```

- [ ] **Step 6: Copy runtime scripts**

Use:

```dockerfile
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/setup_multica.sh /usr/local/bin/setup_multica.sh
COPY scripts/setup_agent.sh /usr/local/bin/setup_agent.sh
COPY scripts/health_proxy.py /usr/local/bin/health_proxy.py

RUN chmod 755 /usr/local/bin/entrypoint.sh \
  /usr/local/bin/setup_multica.sh \
  /usr/local/bin/setup_agent.sh \
  /usr/local/bin/health_proxy.py
```

- [ ] **Step 7: Install selected agent**

Codex branch:

```dockerfile
RUN if [ "$AGENT" = "codex" ]; then npm install -g "@openai/codex@${CODEX_VERSION}" && codex --version; fi
```

OpenCode branch:

```dockerfile
RUN if [ "$AGENT" = "opencode" ]; then curl -fsSL https://raw.githubusercontent.com/opencode-ai/opencode/refs/heads/main/install | VERSION="${OPENCODE_VERSION}" bash && opencode --version; fi
```

Scope note: the OpenCode installer-from-main command is retained for MVP because it is the upstream-supported install path required by the current spec. The reproducibility mitigation is the exact `OPENCODE_VERSION`, build-time `opencode --version`, and a post-MVP replacement trigger if direct release assets become required.

- [ ] **Step 8: Persist build metadata and entrypoint**

Use:

```dockerfile
ENV AGENT=$AGENT
ENV MULTICA_VERSION=$MULTICA_VERSION
ENV NODE_VERSION=$NODE_VERSION
ENV PNPM_VERSION=$PNPM_VERSION
ENV CODEX_VERSION=$CODEX_VERSION
ENV OPENCODE_VERSION=$OPENCODE_VERSION

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 9: Build validation**

Run Codex build:

```bash
docker build \
  --build-arg AGENT=codex \
  --build-arg MULTICA_VERSION=v0.2.27 \
  --build-arg NODE_VERSION=22.15.0 \
  --build-arg PNPM_VERSION=10.10.0 \
  --build-arg CODEX_VERSION=0.128.0 \
  -t multica-daemon:codex .
```

Run OpenCode build:

```bash
docker build \
  --build-arg AGENT=opencode \
  --build-arg MULTICA_VERSION=v0.2.27 \
  --build-arg NODE_VERSION=22.15.0 \
  --build-arg PNPM_VERSION=10.10.0 \
  --build-arg OPENCODE_VERSION=0.1.0 \
  -t multica-daemon:opencode .
```

Expected result:

```text
both commands exit with code 0
```

## Task 6: Railway Config

**Files:**

- Create: `railway.json`

**SMART DoD:**

- By the end of this task, `railway.json` is valid JSON.
- The file uses Railway schema URL.
- The file configures Dockerfile builder and `/health` healthcheck path.
- The file does not include secrets, Vault token examples, or environment variable values.

- [ ] **Step 1: Create Railway config-as-code file**

Use this exact structure:

```json
{
  "$schema": "https://railway.com/railway.schema.json",
  "build": {
    "builder": "DOCKERFILE",
    "dockerfilePath": "Dockerfile"
  },
  "deploy": {
    "healthcheckPath": "/health"
  }
}
```

- [ ] **Step 2: Validate JSON**

Run:

```bash
python3 -m json.tool railway.json
```

Expected result:

```text
command exits with code 0
```

- [ ] **Step 3: Confirm secrets are absent**

Review `railway.json` and confirm it contains none of these strings:

```text
VAULT_TOKEN
MULTICA_TOKEN
CODEX_AUTH
OPENAI_API_KEY
CODEX_API_KEY
```

## Task 7: Documentation Alignment

**Files:**

- Modify: `README.md`
- Modify: `docs/runtime-spec.md` only if implementation intentionally narrows or clarifies runtime behavior.
- Modify: `docs/dockerfile-spec.md` only if the Multica release asset naming differs from the current assumption.
- Modify: `docs/railway-template-spec.md` only if Railway config-as-code requires wording beyond the current template spec.

**SMART DoD:**

- By the end of this task, README commands match the implemented Dockerfile, scripts, and Railway config.
- README includes exact Codex and OpenCode build commands.
- README clearly states that the Railway Volume must be manually attached at `/data`.
- README clearly states that Railway service variables are configured outside `railway.json`.
- README clearly states that `railway.json` configures build and healthcheck only; it does not create the volume or variables.
- README does not tell users to put secret values in committed files.
- Any spec change is a clarification of implemented behavior, not scope expansion.

- [ ] **Step 1: Add build commands only if missing or mismatched**

README must include the Codex and OpenCode `docker build` commands from Task 5 with pinned versions.

- [ ] **Step 2: Add runtime file map only if useful**

If README references scripts indirectly, add a concise section:

```text
Runtime files:
- Dockerfile builds the selected runtime image.
- scripts/entrypoint.sh orchestrates startup.
- scripts/setup_multica.sh configures Multica CLI auth.
- scripts/setup_agent.sh configures Codex or OpenCode.
- scripts/health_proxy.py exposes Railway /health.
- railway.json selects Dockerfile build and /health healthcheck.
```

- [ ] **Step 3: Preserve security guidance**

Confirm README still states:

```text
Railway stores Vault access variables.
Runtime secrets live in Vault.
Codex auth.json is stored as base64 in Vault.
Vault token must be read-only and scoped to one runtime path.
```

- [ ] **Step 4: Document Railway runtime setup boundaries**

README must explicitly state:

```text
Railway Volume is manually attached at /data.
Railway service variables are created by the operator outside railway.json.
railway.json configures Dockerfile build and /health only.
railway.json does not create the Railway Volume or service variables.
```

- [ ] **Step 5: Validate docs links and commands by review**

Manual review must confirm every referenced file exists after implementation and every command uses the actual file names.

## Task 8: Final Validation Run

**Files:**

- No new files.

**SMART DoD:**

- By the end of this task, all syntax checks, JSON validation, Docker builds, and documented smoke scenarios have been run or explicitly blocked by missing local prerequisites.
- Any blocker is recorded with the exact command, exact error, and required operator action.
- No secret values are printed in validation output captured in notes.

- [ ] **Step 1: Run static validation**

Run:

```bash
bash -n scripts/entrypoint.sh
bash -n scripts/setup_multica.sh
bash -n scripts/setup_agent.sh
python3 -m py_compile scripts/health_proxy.py
python3 -m json.tool railway.json
```

Expected result:

```text
all commands exit with code 0
```

- [ ] **Step 2: Build both images**

Run the two Docker build commands from Task 5.

Expected result:

```text
multica-daemon:codex image exists locally
multica-daemon:opencode image exists locally
```

- [ ] **Step 3: Validate image binaries**

Run:

```bash
docker run --rm --entrypoint multica multica-daemon:codex --version
docker run --rm --entrypoint codex multica-daemon:codex --version
docker run --rm --entrypoint multica multica-daemon:opencode --version
docker run --rm --entrypoint opencode multica-daemon:opencode --version
```

Expected result:

```text
all commands exit with code 0 and print version output
```

- [ ] **Step 4: Validate startup fail-fast behavior without secrets**

Run:

```bash
docker run --rm multica-daemon:codex
```

Expected result:

```text
container exits non-zero before Vault, Multica login, or daemon launch
stderr identifies the first missing required environment variable
```

- [ ] **Step 5: Validate health proxy behavior**

Run the manual smoke scenario from Task 1.

Expected result:

```text
running target status returns 200
all other target statuses return 503
malformed health JSON, HTML, or plain text target responses return 503
```

- [ ] **Step 6: Validate runtime edge cases**

Run targeted manual checks or Docker build checks for these contracts:

```text
MULTICA_WORKSPACES_ROOT outside /data exits non-zero with "MULTICA_WORKSPACES_ROOT must be under /data".
Unsupported AGENT exits non-zero with an actionable message naming codex and opencode.
Newly decoded Codex auth JSON validation runs jq empty "${CODEX_HOME}/auth.json".
Existing Codex auth.json is preserved without existing-file JSON validation.
OpenCode installer-from-main accepted risk is documented with OPENCODE_VERSION and build-time opencode --version mitigation.
```

- [ ] **Step 7: Final security review**

Search the implementation for secret-printing risk:

```bash
rg "VAULT_TOKEN|MULTICA_TOKEN_FROM_VAULT|CODEX_AUTH_JSON_B64_FROM_VAULT|auth.json|OPENAI_API_KEY|CODEX_API_KEY" Dockerfile scripts README.md docs
```

Expected result:

```text
matches are limited to required env validation, secret variable passing, docs examples, and Codex auth file handling
no command prints secret values
```

## Edge Cases Covered

- Missing required env var.
- Unsupported `AGENT`.
- `/data` path not writable.
- `MULTICA_WORKSPACES_ROOT` outside `/data`.
- Vault unreachable after 3 attempts.
- Vault retry uses exactly 3 attempts, `curl -fsS`, two-second delay between failed attempts, no raw response logging, and final non-secret failure.
- Vault KV v2 response missing `.data.data`.
- `multica_token` missing for any agent.
- `codex_auth_json_b64` missing for Codex.
- Invalid Codex base64 payload.
- Newly decoded Codex auth JSON fails `jq empty`.
- Existing Codex `auth.json` must be preserved.
- `OPENAI_API_KEY` and `CODEX_API_KEY` must not affect Codex subscription mode.
- OpenCode installer-from-main accepted risk remains documented with mitigation.
- OpenCode must start without provider API keys.
- Local daemon health endpoint unreachable.
- Local daemon health endpoint returns invalid JSON.
- Local daemon health endpoint returns malformed non-JSON HTTP 2xx response.
- Local daemon health endpoint returns non-running status.
- Railway healthcheck must not call Vault.

## Implementation Order

1. Health proxy.
2. Multica setup script.
3. Agent setup script.
4. Entrypoint orchestrator.
5. Dockerfile.
6. Railway config.
7. Documentation alignment.
8. Final validation run.

This order keeps the runtime pieces independently reviewable before the Docker image ties them together.
