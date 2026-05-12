# Dockerfile Specification

Date: 2026-05-07

## Goal

Build a reproducible Debian-based runtime image containing:

- Multica CLI;
- one selected agent CLI;
- runtime scripts;
- minimal tools for Vault fetch, health proxy, and diagnostics.

## Base Image

```dockerfile
FROM debian:bookworm-slim
```

Rationale:

- smaller than Ubuntu;
- safer than Alpine for native CLI dependencies;
- compatible with official Linux binaries and shell tooling.

## Required Build Args

Always required:

```dockerfile
ARG AGENT
ARG MULTICA_VERSION
ARG NODE_VERSION
ARG PNPM_VERSION
```

Optional agent version args are declared with empty defaults so non-selected agents may leave them empty:

```dockerfile
ARG CODEX_VERSION=
ARG OPENCODE_VERSION=
ARG PI_VERSION=
```

Required when `AGENT=codex`: `CODEX_VERSION` must be non-empty.

Required when `AGENT=opencode`: `OPENCODE_VERSION` must be non-empty.

Required when `AGENT=pi`: `PI_VERSION` must be non-empty.

Build must fail-fast when the selected agent version arg is empty or when `AGENT` is unsupported. Supported `AGENT` values are `codex`, `opencode`, and `pi`.

## Runtime Env Export

Build args are persisted as image env for logging and validation:

```dockerfile
ENV AGENT=$AGENT
ENV MULTICA_IMAGE_AGENT=$AGENT
ENV MULTICA_VERSION=$MULTICA_VERSION
ENV NODE_VERSION=$NODE_VERSION
ENV PNPM_VERSION=$PNPM_VERSION
ENV CODEX_VERSION=$CODEX_VERSION
ENV OPENCODE_VERSION=$OPENCODE_VERSION
ENV PI_VERSION=$PI_VERSION
```

These env values are not used to install software at runtime. `MULTICA_IMAGE_AGENT` records the agent baked into the image; entrypoint validation must fail clearly if runtime `AGENT` differs from `MULTICA_IMAGE_AGENT`.

## System Dependencies

Required Debian packages:

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

Node is installed as a pinned `NODE_VERSION`, not through Debian's moving package versions.

## Node And Corepack

The image installs official Node.js Linux binaries for exact `NODE_VERSION`.

After Node installation:

```bash
corepack enable
corepack prepare pnpm@${PNPM_VERSION} --activate
```

`PNPM_VERSION` is pinned even if the initial MVP install path for an agent does not require pnpm. This keeps the Node toolchain explicit for future package-manager based installs.

## Multica Install

The Dockerfile build steps, or build-only helper scripts, install Multica from official GitHub release artifacts using exact `MULTICA_VERSION`. Runtime script `scripts/setup_multica.sh` is not invoked during build; it remains runtime-only configuration and authentication.

Rules:

- no `latest`;
- no interactive install script;
- no runtime installation;
- binary must end up on `PATH`;
- build verifies `multica --version`.

The implementation must encode the supported release asset naming for Linux amd64 in the build install path and fail clearly if the asset cannot be resolved.

## Agent Install

One image contains one agent CLI. The Dockerfile build steps, or build-only helper scripts, install only the selected agent CLI using the selected non-empty version arg. Runtime script `scripts/setup_agent.sh` is not invoked during build; it remains runtime-only agent configuration.

### Codex

Codex is installed through the official npm package path:

```bash
npm install -g @openai/codex@${CODEX_VERSION}
```

Build verifies:

```bash
codex --version
```

### OpenCode

OpenCode is installed through its upstream-supported Linux install path with exact version:

```bash
curl -fsSL https://raw.githubusercontent.com/opencode-ai/opencode/refs/heads/main/install | VERSION=${OPENCODE_VERSION} bash
```

Build verifies:

```bash
opencode --version
```

If this install path becomes unsuitable for reproducible builds, post-MVP work should replace it with direct official release asset download.

### Pi

Pi is installed through the pinned npm package path:

```bash
npm install -g @earendil-works/pi-coding-agent@${PI_VERSION}
pi --version
```

## Runtime User

MVP runs as `root`.

Rationale:

- Railway volumes are commonly root-owned at mount time;
- MVP avoids ownership bootstrap complexity;
- secret file permissions are still restricted.

Post-MVP hardening should introduce a dedicated non-root user.

## Entrypoint

The Dockerfile copies scripts into the image and sets:

```dockerfile
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

The image must not require secrets during build, including Vault-provided Pi auth such as `PI_AUTH_JSON_B64_FROM_VAULT`.
