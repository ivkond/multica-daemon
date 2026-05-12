# Cross-Review: MVP Runtime Implementation Plan

## Metadata

- Reviewed plan: `docs/superpowers/plans/2026-05-08-mvp-runtime.md`
- Reviewers requested: OpenCode (`opencode`), Cursor CLI (`agent`)
- Reviewers completed: OpenCode completed; Cursor CLI blocked by missing authentication
- Timestamp: 2026-05-08T00:21:41+03:00
- Working directory: `C:\projects\github\ivkond\multica-daemon`

## OpenCode Review

OpenCode returned the following condensed Markdown review.

### Verdict

Approve with blockers. The plan is well-structured and covers the core specs, but OpenCode identified blocking issues and follow-up findings to address before implementation.

### Strengths

- Clear spec alignment: each task maps to `docs/scripts-spec.md`, `docs/dockerfile-spec.md`, and `docs/runtime-spec.md` with explicit DoD criteria.
- Docs-first approach: intentional test exclusion with contract-based validation matches the project direction.
- Security posture: forbidden log fields, read-only Vault token scoping, `auth.json` preservation, and secret redaction checks are explicit.
- Fail-fast design: required env validation, unsupported agent rejection, and missing secret checks are specified before daemon launch.
- Edge case coverage: missing env, unwritable paths, Vault retries, base64 decode failures, and related startup failures are covered.

### Findings

#### Blocking

1. Dockerfile build arg validation should explicitly reject unsupported `AGENT` values before or inside the validation case. The current plan exits non-zero, but the error is not actionable.

   Suggested change: add explicit unsupported-agent validation with a clear error message.

2. Vault retry behavior needs an explicit loop contract. The plan says retry three times but does not fully define which `curl` failures are retried and how HTTP failures are handled.

   Suggested change: specify a concrete retry loop using `curl -fsS`, three attempts, the configured two-second delay, no raw response logging, and clear final failure behavior.

3. OpenCode install via `curl ... | VERSION=... bash` is fragile because the script is fetched from `main`.

   Suggested change: either pin the installer to a specific commit/release asset or explicitly accept this as an MVP risk with validation and post-MVP replacement criteria.

4. Health proxy smoke scenarios should explicitly include malformed non-JSON 2xx target responses, such as HTML from an intermediate proxy.

   Suggested change: add a manual validation scenario proving malformed JSON returns `503`.

#### Medium

5. Railway volume configuration is outside `railway.json`, but Task 7 should explicitly require README guidance for attaching a volume at `/data`.

6. `MULTICA_WORKSPACES_ROOT` is validated for writability but not constrained to `/data`; a misconfigured path could escape the intended Railway volume boundary.

   Suggested change: add an entrypoint check such as `[[ "$MULTICA_WORKSPACES_ROOT" == /data/* ]]`.

7. Codex `auth.json` is base64-decoded but not validated as JSON.

   Suggested change: add `jq empty "$CODEX_HOME/auth.json"` after decode while preserving the existing-file behavior.

8. Multica release asset naming is intentionally left to implementation, but the plan should make the expected Linux amd64 asset pattern explicit or require documenting it during implementation.

#### Questions

- What is the operator procedure for corrupted or detached `/data` volumes?
- Does Vault token rotation require a service restart?
- Are Railway default healthcheck interval and timeout values acceptable for daemon startup time?
- Is `OPENCODE_VERSION=0.1.0` confirmed to exist upstream?

### Top Actionable Changes From OpenCode

1. Clarify Dockerfile unsupported-agent validation and error messages.
2. Specify the exact Vault retry loop and failure semantics.
3. Decide whether OpenCode installer-from-main is accepted MVP risk or should be pinned now.
4. Add malformed JSON health proxy validation.
5. Add README volume mount guidance and consider `/data/*` workspace-root validation.

## Cursor Agent Review

Cursor CLI (`agent`) was available but could not run the review because it was not authenticated.

Blocker details:

```text
Command: agent --print --mode=ask --trust --workspace C:\projects\github\ivkond\multica-daemon "Read the review prompt file at C:\Users\ivkon\AppData\Local\Temp\multica-mvp-runtime-review-prompt.md and perform the requested cross-review. Do not modify files. Return concise Markdown only."
Exit code: 1
Error: Authentication required. Please run 'agent login' first, or set CURSOR_API_KEY environment variable.
```

Authentication check:

```text
Command: agent status
Exit code: 0
Result: Not logged in
```

No login, installation, or interactive setup was attempted.

## Consensus Summary

### Agreed Strengths

- The plan is strongly aligned with the specs and keeps the MVP runtime-first.
- Secret handling is treated as a first-class concern: Vault-only runtime secrets, no secret logging, restrictive `auth.json` permissions, and Codex API-key unsetting are all specified.
- The task order is reasonable: health proxy and setup scripts are defined before the entrypoint and Dockerfile tie them together.
- Validation is explicit despite excluding automated tests: syntax checks, JSON validation, Docker builds, binary checks, smoke scenarios, and security review are listed.

### Agreed Concerns

- Some validation contracts need sharper, executable wording: Vault retry semantics, malformed health payloads, and Dockerfile unsupported-agent failures.
- Railway realism depends on documentation outside `railway.json`, especially the `/data` volume mount and service variables.
- The OpenCode install path is a reproducibility risk because it relies on an upstream install script fetched from `main`.
- Runtime path safety could be improved by constraining `MULTICA_WORKSPACES_ROOT` to the intended `/data` volume.

### Divergent Views

- OpenCode called several findings blockers. Since Cursor review was blocked, there is no second external reviewer to confirm or dispute severity.
- OpenCode suggested a Dockerfile `die` helper style for unsupported agents; in a Dockerfile, the actionable fix should be adapted to shell syntax available inside `RUN`, for example printing a clear message to stderr before `exit 1`.
- OpenCode suggested documenting a post-MVP non-root path; the current user constraints and protected-file scope do not require changing backlog/docs in this review pass.

### Actionable Changes To Consider

1. Amend Task 4 Step 6 to define the exact Vault retry loop: three attempts, two-second delay, `curl -fsS`, no raw response logging, and clear failure after the third attempt.
2. Amend Task 1 manual smoke validation to include malformed JSON or HTML target responses returning `503`.
3. Amend Task 5 validation to print a clear unsupported `AGENT` error during Docker build.
4. Amend Task 7 to require README guidance for Railway `/data` volume attachment and separation from `railway.json`.
5. Decide whether to accept the OpenCode installer-from-main risk for MVP or pin the installer/release asset before implementation.
6. Consider adding `/data/*` validation for `MULTICA_WORKSPACES_ROOT` and JSON validation for newly decoded Codex `auth.json`.

## Verification Notes

Commands run without secrets:

```text
git status --short
```

Result: succeeded. Output showed `?? docs/superpowers/` and git ignore permission warnings for `C:\Users\ivkon/.config/git/ignore`.

```text
where.exe opencode
```

Result: succeeded. Found `C:\ProgramData\chocolatey\bin\opencode.exe`.

```text
where.exe agent
```

Result: failed. `where.exe` could not find files for the given pattern.

```text
Get-Command agent -ErrorAction SilentlyContinue
```

Result: succeeded. Found `agent.ps1` under `C:\Users\ivkon\AppData\Local\cursor-agent...`.

```text
opencode --help
```

Result: failed in default config location with `EEXIST: file already exists, mkdir 'C:\Users\ivkon\.config\opencode'`.

```text
$env:XDG_CONFIG_HOME = Join-Path $env:TEMP 'multica-opencode-config'; $env:XDG_CACHE_HOME = Join-Path $env:TEMP 'multica-opencode-cache'; opencode --help
```

Result: succeeded. Confirmed `opencode run [message..]`.

```text
agent --help
```

Result: succeeded. Confirmed `--print`, `--mode ask`, `--mode plan`, `--trust`, and `--workspace`.

```text
agent --version
```

Result: succeeded. Version: `2026.04.16-2d20146`.

```text
Get-Content C:\Users\ivkon\.agents\skills\using-superpowers\SKILL.md
Get-Content C:\Users\ivkon\.claude\RULES.md
Get-Content RULES.md
Get-Content RULES.MD
Get-Content README.md
Get-Content docs\product-vision.md
Get-Content docs\runtime-spec.md
Get-Content docs\scripts-spec.md
Get-Content docs\dockerfile-spec.md
Get-Content docs\railway-template-spec.md
Get-Content docs\security-and-secrets-spec.md
Get-Content docs\superpowers\plans\2026-05-08-mvp-runtime.md
```

Result: specs and global rules were read successfully. Project-root `RULES.md` and `RULES.MD` were not found.

```text
Set-Content/Add-Content to C:\Users\ivkon\AppData\Local\Temp\multica-mvp-runtime-review-prompt.md
```

Result: succeeded. Prompt file contained the review instructions, specs, README, and reviewed plan.

```text
Get-Content C:\Users\ivkon\AppData\Local\Temp\multica-mvp-runtime-review-prompt.md -Raw | opencode run -
```

Result: failed inside sandbox. Error: `EPERM: operation not permitted, uv_spawn 'git'`.

```text
Get-Content C:\Users\ivkon\AppData\Local\Temp\multica-mvp-runtime-review-prompt.md -Raw | opencode run -
```

Result: succeeded after approved escalated rerun. Review output was written to `C:\Users\ivkon\AppData\Local\Temp\multica-mvp-runtime-opencode-review.md`.

```text
agent --print --mode=ask --trust --workspace C:\projects\github\ivkond\multica-daemon "Read the review prompt file at C:\Users\ivkon\AppData\Local\Temp\multica-mvp-runtime-review-prompt.md and perform the requested cross-review. Do not modify files. Return concise Markdown only."
```

Result: failed. Cursor Agent requires authentication.

```text
agent status
```

Result: succeeded. Cursor Agent reported `Not logged in`.

No commits were created.
