# Pi Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update the public runtime documentation and specs so `multica-daemon` supports `AGENT=pi` alongside `codex` and `opencode`.

**Architecture:** This repository currently contains documentation/spec contracts rather than runtime source files. The implementation is therefore a docs/spec contract update: README explains the user-facing Pi runtime flow, while the spec files define the exact Docker, script, Railway, Vault, path, and validation behavior future runtime code must implement.

**Tech Stack:** Markdown docs, Railway deployment variables, Debian Docker runtime contract, bash script contracts, npm-installed Pi CLI package `@earendil-works/pi-coding-agent`.

---

## Source Requirements

- Design spec: `docs/superpowers/specs/2026-05-12-pi-runtime-design.md`
- Existing canonical docs to update:
  - `README.md`
  - `docs/runtime-spec.md`
  - `docs/dockerfile-spec.md`
  - `docs/scripts-spec.md`
  - `docs/railway-template-spec.md`

## File Structure

- Modify `README.md`: user-facing support matrix, Vault examples, Railway variables, Pi credential bootstrap, troubleshooting, and next-build list.
- Modify `docs/runtime-spec.md`: supported agents, volume layout, exported env, and runtime validation for Pi.
- Modify `docs/dockerfile-spec.md`: Pi build arg/env/install contract.
- Modify `docs/scripts-spec.md`: Pi runtime setup contract, normalized Vault variable, forbidden log fields, and path exports.
- Modify `docs/railway-template-spec.md`: Pi build variables, runtime examples, and volume contents.

---

### Task 1: Update README Pi Runtime User Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read the approved design and current README**

Run:

```bash
read docs/superpowers/specs/2026-05-12-pi-runtime-design.md
read README.md
```

Expected: the design shows `pi_auth_json_b64`, `PI_VERSION`, `PI_CODING_AGENT_DIR=/data/pi/agent`, and `/data/pi/agent/auth.json`; README currently documents only `codex` and `opencode`.

- [ ] **Step 2: Update the runtime list and deployment examples**

Edit `README.md` so every supported-agent list includes `pi`:

```text
- `codex` - Codex CLI with ChatGPT subscription credentials loaded from HashiCorp Vault.
- `opencode` - OpenCode CLI with default free provider behavior.
- `pi` - Pi CLI with provider credentials restored from a Vault-backed `auth.json` bundle.
```

Update example daemon names to include:

```text
agent-pi-1
```

- [ ] **Step 3: Add Vault setup for Pi**

In the Vault Setup section, after the OpenCode example, add:

```json
{
  "multica_token": "mul_replace_with_runtime_token",
  "pi_auth_json_b64": "base64_encoded_pi_auth_json"
}
```

Add explanatory text:

```text
For a Pi runtime, `pi_auth_json_b64` is a base64-encoded Pi `auth.json` file prepared outside CI/CD. Pi stores provider credentials in `~/.pi/agent/auth.json`; the runtime restores that file to `/data/pi/agent/auth.json` and sets `PI_CODING_AGENT_DIR=/data/pi/agent`.
```

- [ ] **Step 4: Add Railway variables for Pi**

In the pinned build variables section, add a Pi example:

```dotenv
AGENT=pi
MULTICA_VERSION=v0.2.27
NODE_VERSION=22.15.0
PNPM_VERSION=10.10.0
PI_VERSION=0.74.0
```

Add or update runtime examples so a Pi daemon can be configured as:

```dotenv
AGENT=pi
VAULT_SECRET_PATH=kv/data/multica-daemon/agent-pi-1
MULTICA_DAEMON_ID=agent-pi-1
MULTICA_DAEMON_DEVICE_NAME=agent-pi-1
MULTICA_AGENT_RUNTIME_NAME=Pi Runtime 1
```

- [ ] **Step 5: Add Pi Runtime section**

Add a section named `## Pi Runtime` after the OpenCode section:

```markdown
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
```

- [ ] **Step 6: Update environment variable and troubleshooting text**

Ensure required runtime variable docs say `AGENT` can be `codex`, `opencode`, or `pi`.

Add troubleshooting entry:

```markdown
**Pi runtime starts but Pi tasks fail**

Check that `/data/pi/agent/auth.json` exists, has `600` permissions, and was created from the intended Pi login or API-key configuration. Confirm the selected Pi provider/model works locally before encoding the file for Vault.
```

Update the `What You Can Build Next` list so it no longer implies adding more agent CLIs is entirely future work; phrase it as `additional agent CLIs beyond Codex, OpenCode, and Pi`.

- [ ] **Step 7: Verify README consistency**

Run:

```bash
rg -n "codex|opencode|pi|PI_VERSION|pi_auth_json_b64|PI_CODING_AGENT_DIR|agent-pi-1" README.md
```

Expected: README contains the Pi runtime list item, Vault field, pinned `PI_VERSION`, bootstrap commands, Pi deployment example, and troubleshooting entry.

- [ ] **Step 8: Commit Task 1**

Run:

```bash
git add README.md
git commit -m "docs: document pi runtime"
```

Expected: commit succeeds with only `README.md` changed for this task.

---

### Task 2: Update Runtime Contract Specs for Pi

**Files:**
- Modify: `docs/runtime-spec.md`
- Modify: `docs/dockerfile-spec.md`
- Modify: `docs/scripts-spec.md`
- Modify: `docs/railway-template-spec.md`

- [ ] **Step 1: Read the approved design and current spec files**

Run:

```bash
read docs/superpowers/specs/2026-05-12-pi-runtime-design.md
read docs/runtime-spec.md
read docs/dockerfile-spec.md
read docs/scripts-spec.md
read docs/railway-template-spec.md
```

Expected: existing specs mention only `codex` and `opencode`; the design defines exact Pi names and paths.

- [ ] **Step 2: Update `docs/runtime-spec.md`**

Make these contract updates:

```text
AGENT must be one of:
- codex
- opencode
- pi
```

Add `/data/pi` and `/data/pi/agent` to the volume layout.

Add runtime environment line:

```bash
PI_CODING_AGENT_DIR=/data/pi/agent
```

Add permissions:

```bash
chmod 700 /data/pi
chmod 700 /data/pi/agent
chmod 600 /data/pi/agent/auth.json
```

Add Pi validation behavior:

```text
For Pi:
- `PI_CODING_AGENT_DIR` is set to `/data/pi/agent`;
- `/data/pi/agent/auth.json` is created from Vault only if missing;
- existing `/data/pi/agent/auth.json` is preserved;
- `pi_auth_json_b64` is required in Vault;
- `pi --version` succeeds.
```

- [ ] **Step 3: Update `docs/dockerfile-spec.md`**

Add Pi-specific build arg:

```dockerfile
ARG PI_VERSION
```

State it is required when `AGENT=pi`.

Persist env:

```dockerfile
ENV PI_VERSION=$PI_VERSION
```

Add Pi install contract under Agent Install:

```bash
npm install -g @earendil-works/pi-coding-agent@${PI_VERSION}
pi --version
```

Ensure supported `AGENT` values are documented as `codex`, `opencode`, and `pi`.

- [ ] **Step 4: Update `docs/scripts-spec.md`**

Add `pi` to every supported-agent list.

Add runtime export:

```bash
export PI_CODING_AGENT_DIR=/data/pi/agent
```

Add normalized Vault variable:

```text
PI_AUTH_JSON_B64_FROM_VAULT
```

State that `PI_AUTH_JSON_B64_FROM_VAULT` is required only for `AGENT=pi`.

Add Pi setup contract under `setup_agent.sh <agent>`:

```text
### Pi

Inputs:
- `PI_CODING_AGENT_DIR=/data/pi/agent`
- `PI_AUTH_JSON_B64_FROM_VAULT`

Rules:
- create `/data/pi` and `PI_CODING_AGENT_DIR` with `chmod 700`;
- write `PI_CODING_AGENT_DIR/auth.json` only when missing;
- preserve existing `auth.json`;
- set `auth.json` permission to `600`;
- do not run interactive `pi` or `/login`.

Validation:
- `pi --version`
```

Add forbidden log field:

```text
PI_AUTH_JSON_B64_FROM_VAULT
```

- [ ] **Step 5: Update `docs/railway-template-spec.md`**

Add Pi build variable example:

```dotenv
AGENT=pi
MULTICA_VERSION=v0.2.27
NODE_VERSION=22.15.0
PNPM_VERSION=10.10.0
PI_VERSION=0.74.0
```

Add `pi` to supported `AGENT` values.

Add `/data/pi` to volume contents.

Add deployment example:

```dotenv
AGENT=pi
VAULT_SECRET_PATH=kv/data/multica-daemon/agent-pi-1
MULTICA_DAEMON_ID=agent-pi-1
MULTICA_DAEMON_DEVICE_NAME=agent-pi-1
MULTICA_AGENT_RUNTIME_NAME=Pi Runtime 1
```

- [ ] **Step 6: Verify cross-file consistency**

Run:

```bash
rg -n "AGENT.*codex|AGENT.*opencode|AGENT.*pi|PI_VERSION|pi_auth_json_b64|PI_AUTH_JSON_B64_FROM_VAULT|PI_CODING_AGENT_DIR|/data/pi|agent-pi-1" README.md docs/runtime-spec.md docs/dockerfile-spec.md docs/scripts-spec.md docs/railway-template-spec.md
```

Expected: all five canonical docs include Pi where appropriate and use exact agreed names.

- [ ] **Step 7: Check for stale supported-agent statements**

Run:

```bash
rg -n "codex.*opencode|opencode.*codex|must be either|Supported values|supported agents" README.md docs/runtime-spec.md docs/dockerfile-spec.md docs/scripts-spec.md docs/railway-template-spec.md
```

Expected: no statement claims the only supported agents are `codex` and `opencode`; any list that names supported agents also includes `pi`.

- [ ] **Step 8: Commit Task 2**

Run:

```bash
git add docs/runtime-spec.md docs/dockerfile-spec.md docs/scripts-spec.md docs/railway-template-spec.md
git commit -m "docs: add pi runtime contracts"
```

Expected: commit succeeds with only the four spec files changed for this task.

---

## Final Verification

After both tasks complete, run:

```bash
git status --short
rg -n "pi_auth_json_b64|PI_AUTH_JSON_B64_FROM_VAULT|PI_VERSION|PI_CODING_AGENT_DIR|/data/pi/agent/auth.json|agent-pi-1" README.md docs/runtime-spec.md docs/dockerfile-spec.md docs/scripts-spec.md docs/railway-template-spec.md docs/superpowers/specs/2026-05-12-pi-runtime-design.md
```

Expected:

- `git status --short` shows no unintended tracked-file changes.
- The agreed Pi names and paths appear consistently.
- No secrets or raw credential values are present.
