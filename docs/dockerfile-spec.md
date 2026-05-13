# Dockerfile Specification

Date: 2026-05-07

## Goal

Build a reproducible Debian-based runtime image containing:

- Multica CLI;
- one selected agent CLI;
- runtime scripts;
- Infisical CLI;
- minimal tools for Infisical export, health proxy, and diagnostics.

## Base Image

```dockerfile
FROM debian:bookworm-slim@sha256:f9c6a2fd2ddbc23e336b6257a5245e31f996953ef06cd13a59fa0a1df2d5c252
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
ARG INFISICAL_CLI_VERSION
```

Optional agent build args are declared with empty defaults so non-selected agents may leave them empty:

```dockerfile
ARG CODEX_VERSION=
ARG OPENCODE_VERSION=
ARG OPENCODE_SHA256_X64=
ARG OPENCODE_SHA256_ARM64=
ARG PI_VERSION=
```

Required when `AGENT=codex`: `CODEX_VERSION` must be non-empty.

Required when `AGENT=opencode`: `OPENCODE_VERSION`, `OPENCODE_SHA256_X64`, and `OPENCODE_SHA256_ARM64` must be non-empty.

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
ENV INFISICAL_CLI_VERSION=$INFISICAL_CLI_VERSION
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
fzf
git
jq
python3
ripgrep
tar
unzip
xz-utils
```

Node is installed as a pinned `NODE_VERSION`, not through Debian's moving package versions.

## Node And Corepack

The image installs official Node.js Linux binaries for exact `NODE_VERSION`.
The image prepends `/usr/local/lib/nodejs/bin` to `PATH` so global npm binaries, including `codex`, are available at build time and runtime.

The Node tarball URL pattern is:

```text
https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz
```

After Node installation:

```bash
corepack enable
corepack prepare pnpm@${PNPM_VERSION} --activate
```

`PNPM_VERSION` is pinned even if the initial MVP install path for an agent does not require pnpm. This keeps the Node toolchain explicit for future package-manager based installs.

## Infisical CLI Install

The image installs the Infisical CLI through the official npm package path:

```bash
npm install -g @infisical/cli@${INFISICAL_CLI_VERSION}
```

Build verifies:

```bash
infisical --version
```

## Multica Install

The Dockerfile build steps install Multica from official GitHub release artifacts using exact `MULTICA_VERSION`. Runtime script `scripts/setup_multica.sh` is not invoked during build; it remains runtime-only configuration and authentication.

The Multica release asset URL pattern is:

```text
https://github.com/multica-ai/multica/releases/download/${MULTICA_VERSION}/multica_linux_amd64.tar.gz
```

Rules:

- no `latest`;
- no interactive install script;
- no runtime installation;
- binary must end up on `PATH`;
- build verifies `multica --version`.

The implementation must encode the supported release asset naming for Linux amd64 in the build install path and fail clearly if the asset cannot be resolved.

## Agent Install

One image contains one agent CLI.

The Dockerfile installs the selected agent inline during build, based on the `AGENT` build argument and the selected non-empty version/checksum build args.

`scripts/setup_agent.sh` is runtime configuration only. The entrypoint calls it after fetching Infisical state so it can configure the selected agent for runtime credentials and state; it is not used for build-time installation.

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

OpenCode is installed from official `anomalyco/opencode` GitHub release assets with exact `OPENCODE_VERSION`.

The OpenCode release asset URL pattern is:

```text
https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/${opencode_asset}
```

`TARGETARCH=amd64` maps to `opencode-linux-x64.tar.gz`.
`TARGETARCH=arm64` maps to `opencode-linux-arm64.tar.gz`.

The downloaded asset must be verified with the pinned SHA-256 build arg for the selected architecture before extraction:

```bash
sha256sum -c -
```

Verified OpenCode MVP pin:

```dotenv
OPENCODE_VERSION=1.14.41
OPENCODE_SHA256_X64=d27d3c85183a7bd2df4506484a2f508d1897962063b7ccc8466705b493963dc5
OPENCODE_SHA256_ARM64=2ffa63bb6115d7aa193cb1f6fa766eb79e1b399776871a624935a752e4461105
```

Build verifies:

```bash
opencode --version
```

### Pi

Pi is installed through the pinned npm package path:

```bash
npm install -g @earendil-works/pi-coding-agent@${PI_VERSION}
```

Build verifies:

```bash
pi --version
```

## Reproducibility Boundaries

The MVP pins the Debian base image by digest and verifies OpenCode release assets by SHA-256 from GitHub release metadata.

Residual risk: Debian package versions from the pinned base image repositories, Node.js tarball, Multica release tarball, and npm-installed Codex, Pi, and Infisical packages are not yet checksum-pinned in this task. Pinning every Debian package version is intentionally deferred because Bookworm security updates make strict package pins brittle for Railway builds.

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

The image must not require secrets during build, including Infisical-provided Pi auth such as `PI_AUTH_JSON_B64_FROM_SECRET_STORE`.
