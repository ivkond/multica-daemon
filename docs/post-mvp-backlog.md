# What You Can Build Next

Date: 2026-05-07

These ideas are outside the MVP. They can turn one reliable daemon runtime into a managed runtime fleet.

## 1. More Agents

Candidate agents beyond Codex, OpenCode, and Pi:

- `kilocode`
- `deepseek-cli`
- `mistral-vibe`
- `cursor`

Definition of Done:

- documented official install source for each agent;
- pinned version variable for each agent;
- `setup_agent.sh <agent>` support;
- `<agent> --version` startup validation;
- Vault secret shape example if the agent needs credentials;
- README deployment example for at least one additional agent.

## 2. Secret Provider Options

Add secret provider abstraction while keeping Vault compatibility.

Candidate providers:

- HashiCorp Vault;
- Doppler;
- 1Password Secrets Automation;
- AWS Secrets Manager;
- GCP Secret Manager;
- Azure Key Vault;
- Railway sealed variables.

Definition of Done:

- `SECRETS_PROVIDER` selects implementation;
- Vault remains the default;
- all providers normalize to the same internal fields;
- secret values remain redacted in logs;
- docs include provider setup examples.

## 3. Codex API Key Mode

Add explicit API key fallback for deployments that do not use ChatGPT subscription credentials.

Definition of Done:

- `CODEX_AUTH_MODE=subscription` keeps current behavior;
- `CODEX_AUTH_MODE=api_key` allows `OPENAI_API_KEY` or `CODEX_API_KEY`;
- conflicting auth settings fail-fast;
- README explains billing implications;
- Vault secret shape includes API key mode.

## 4. OpenCode Provider Profiles

OpenCode can grow beyond default free provider behavior.

Candidate profiles:

- OpenAI;
- Anthropic;
- OpenRouter;
- DeepSeek;
- Mistral;
- custom OpenAI-compatible endpoint.

Definition of Done:

- `OPENCODE_PROVIDER` selects provider profile;
- each provider has required secret field documentation;
- config generation is deterministic;
- provider-specific secrets are not logged;
- OpenCode default provider path remains simple.

## 5. Non-Root Runtime

Move from root container runtime to a dedicated non-root user.

Definition of Done:

- Dockerfile creates a `multica` user;
- entrypoint prepares mounted volume ownership safely;
- `/data` remains writable;
- credentials keep `600` permissions;
- daemon and agent CLIs run as non-root.

## 6. Agent-Specific Dockerfiles

Keep one universal Dockerfile until dependencies diverge. Add agent-specific Dockerfiles only when needed.

Triggers:

- conflicting Node, Go, Python, or system dependencies;
- heavy native dependencies;
- browser or GUI requirements;
- different security profiles;
- direct release assets that need incompatible install logic.

Definition of Done:

- common base remains shared;
- agent-specific files only contain real differences;
- Railway template documents which image to use;
- build variables remain consistent.

## 7. Test And Validation Automation

MVP does not include test automation. Add it when implementation stabilizes.

Candidate checks:

```bash
bash -n scripts/entrypoint.sh
bash -n scripts/setup_multica.sh
bash -n scripts/setup_agent.sh
```

Docker smoke checks:

```bash
docker run --rm multica-daemon:codex multica --version
docker run --rm multica-daemon:codex codex --version
docker run --rm multica-daemon:opencode multica --version
docker run --rm multica-daemon:opencode opencode --version
docker run --rm multica-daemon:pi multica --version
docker run --rm multica-daemon:pi pi --version
```

Definition of Done:

- no-secret checks run in CI;
- runtime checks are separated from build checks;
- CI matrix covers `AGENT=codex`, `AGENT=opencode`, and `AGENT=pi` with `PI_VERSION=0.74.0`;
- optional shell test framework is introduced only after explicit decision.

## 8. Runtime Diagnostics

Add a safe diagnostics command for support and operations.

Definition of Done:

- `scripts/diagnostics.sh` prints versions, daemon id, paths, and health status;
- no secret values are printed;
- diagnostics detects missing volume directories;
- diagnostics can be run in Railway shell;
- README includes troubleshooting examples based on diagnostics output.

## 9. Credential Rotation Workflow

Make credential rotation explicit and safe.

Definition of Done:

- documented Codex `auth.json` rotation;
- documented Multica token rotation;
- optional controlled reseed mode;
- reseed mode requires two explicit env flags;
- rotation can be tested on one named runtime without affecting others.

## 10. Workspace Cleanup And Quotas

Add operational guidance for keeping Railway volumes healthy.

Definition of Done:

- documented GC env examples;
- volume usage command in diagnostics;
- recommended artifact patterns;
- clear guidance for task workspace retention;
- warning when `/data` usage crosses configured threshold.

## 11. Production Security Review

Before a larger runtime fleet, run a focused security review.

Definition of Done:

- threat model covers Vault token, Multica token, Codex OAuth credentials, workspaces, and agent shell access;
- logs are checked for secret leakage;
- each runtime has a unique daemon id, Vault path, and volume;
- replicas are disabled for stateful runtime services;
- incident response steps are documented and rehearsed.
