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

Required when `AGENT=codex`:

```dockerfile
ARG CODEX_VERSION
```

Required when `AGENT=opencode`:

```dockerfile
ARG OPENCODE_VERSION
```

Required when `AGENT=pi`:

```dockerfile
ARG PI_VERSION
```

Build must fail-fast when required args are empty or when `AGENT` is unsupported. Supported `AGENT` values are `codex`, `opencode`, and `pi`.

## Runtime Env Export

Build args are persisted as image env for logging and validation:

```dockerfile
ENV AGENT=$AGENT
ENV MULTICA_VERSION=$MULTICA_VERSION
ENV NODE_VERSION=$NODE_VERSION
ENV PNPM_VERSION=$PNPM_VERSION
ENV CODEX_VERSION=$CODEX_VERSION
ENV OPENCODE_VERSION=$OPENCODE_VERSION
ENV PI_VERSION=$PI_VERSION
```

These env values are not used to install software at runtime.

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

`setup_multica.sh` installs Multica from official GitHub release artifacts using exact `MULTICA_VERSION`.

Rules:

- no `latest`;
- no interactive install script;
- no runtime installation;
- binary must end up on `PATH`;
- build verifies `multica --version`.

The implementation must encode the supported release asset naming for Linux amd64 in the script and fail clearly if the asset cannot be resolved.

## Agent Install

One image contains one agent CLI.

Build invokes:

```dockerfile
RUN ./scripts/setup_agent.sh "$AGENT"
```

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

The image must not require secrets during build.
