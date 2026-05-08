FROM debian:bookworm-slim@sha256:f9c6a2fd2ddbc23e336b6257a5245e31f996953ef06cd13a59fa0a1df2d5c252

ARG TARGETARCH
ARG AGENT
ARG MULTICA_VERSION
ARG NODE_VERSION
ARG PNPM_VERSION
ARG INFISICAL_CLI_VERSION
ARG CODEX_VERSION
ARG OPENCODE_VERSION
ARG OPENCODE_SHA256_X64
ARG OPENCODE_SHA256_ARM64

ENV PATH="/usr/local/lib/nodejs/bin:${PATH}"

RUN set -eu; \
  test -n "$AGENT" || { printf 'Dockerfile: missing required build arg AGENT; expected codex or opencode\n' >&2; exit 1; }; \
  test -n "$MULTICA_VERSION" || { printf 'Dockerfile: missing required build arg MULTICA_VERSION\n' >&2; exit 1; }; \
  test -n "$NODE_VERSION" || { printf 'Dockerfile: missing required build arg NODE_VERSION\n' >&2; exit 1; }; \
  test -n "$PNPM_VERSION" || { printf 'Dockerfile: missing required build arg PNPM_VERSION\n' >&2; exit 1; }; \
  test -n "$INFISICAL_CLI_VERSION" || { printf 'Dockerfile: missing required build arg INFISICAL_CLI_VERSION\n' >&2; exit 1; }; \
  case "$AGENT" in \
    codex) test -n "$CODEX_VERSION" || { printf 'Dockerfile: missing required build arg CODEX_VERSION for AGENT=codex\n' >&2; exit 1; } ;; \
    opencode) \
      test -n "$OPENCODE_VERSION" || { printf 'Dockerfile: missing required build arg OPENCODE_VERSION for AGENT=opencode\n' >&2; exit 1; }; \
      test -n "$OPENCODE_SHA256_X64" || { printf 'Dockerfile: missing required build arg OPENCODE_SHA256_X64 for AGENT=opencode\n' >&2; exit 1; }; \
      test -n "$OPENCODE_SHA256_ARM64" || { printf 'Dockerfile: missing required build arg OPENCODE_SHA256_ARM64 for AGENT=opencode\n' >&2; exit 1; } ;; \
    *) printf 'Dockerfile: unsupported AGENT "%s"; expected codex or opencode\n' "$AGENT" >&2; exit 1 ;; \
  esac

RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    fzf \
    git \
    jq \
    python3 \
    ripgrep \
    tar \
    unzip \
    xz-utils; \
  rm -rf /var/lib/apt/lists/*

RUN set -eux; \
  curl -fsSLo /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"; \
  mkdir -p /usr/local/lib/nodejs; \
  tar -xJf /tmp/node.tar.xz -C /usr/local/lib/nodejs --strip-components=1; \
  rm /tmp/node.tar.xz; \
  ln -s /usr/local/lib/nodejs/bin/node /usr/local/bin/node; \
  ln -s /usr/local/lib/nodejs/bin/npm /usr/local/bin/npm; \
  ln -s /usr/local/lib/nodejs/bin/npx /usr/local/bin/npx; \
  ln -s /usr/local/lib/nodejs/bin/corepack /usr/local/bin/corepack; \
  node --version; \
  npm --version; \
  npx --version; \
  corepack --version; \
  corepack enable; \
  corepack prepare "pnpm@${PNPM_VERSION}" --activate; \
  pnpm --version

RUN set -eux; \
  npm install -g "@infisical/cli@${INFISICAL_CLI_VERSION}"; \
  infisical --version

RUN set -eux; \
  curl -fsSLo /tmp/multica.tar.gz "https://github.com/multica-ai/multica/releases/download/${MULTICA_VERSION}/multica_linux_amd64.tar.gz" || { printf 'Dockerfile: failed to download Multica release asset for %s\n' "$MULTICA_VERSION" >&2; exit 1; }; \
  mkdir -p /tmp/multica; \
  tar -xzf /tmp/multica.tar.gz -C /tmp/multica || { printf 'Dockerfile: failed to extract Multica release asset for %s\n' "$MULTICA_VERSION" >&2; exit 1; }; \
  multica_path="$(find /tmp/multica -type f -name multica -print -quit)"; \
  test -n "$multica_path" || { printf 'Dockerfile: extracted Multica asset for %s did not contain a multica binary\n' "$MULTICA_VERSION" >&2; exit 1; }; \
  install -m 755 "$multica_path" /usr/local/bin/multica || { printf 'Dockerfile: failed to install Multica binary to /usr/local/bin/multica\n' >&2; exit 1; }; \
  rm -rf /tmp/multica /tmp/multica.tar.gz; \
  multica --version

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/setup_multica.sh /usr/local/bin/setup_multica.sh
COPY scripts/setup_agent.sh /usr/local/bin/setup_agent.sh
COPY scripts/health_proxy.py /usr/local/bin/health_proxy.py
RUN chmod 755 /usr/local/bin/entrypoint.sh \
  /usr/local/bin/setup_multica.sh \
  /usr/local/bin/setup_agent.sh \
  /usr/local/bin/health_proxy.py

RUN set -eux; \
  case "$AGENT" in \
    codex) npm install -g "@openai/codex@${CODEX_VERSION}" && codex --version ;; \
    opencode) \
      case "${TARGETARCH:-amd64}" in \
        amd64) opencode_asset="opencode-linux-x64.tar.gz"; opencode_sha256="$OPENCODE_SHA256_X64" ;; \
        arm64) opencode_asset="opencode-linux-arm64.tar.gz"; opencode_sha256="$OPENCODE_SHA256_ARM64" ;; \
        *) printf 'Dockerfile: unsupported TARGETARCH "%s" for OpenCode\n' "${TARGETARCH:-}" >&2; exit 1 ;; \
      esac; \
      curl -fsSLo /tmp/opencode.tar.gz "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/${opencode_asset}" || { printf 'Dockerfile: failed to download OpenCode release asset for %s\n' "$OPENCODE_VERSION" >&2; exit 1; }; \
      printf '%s  /tmp/opencode.tar.gz\n' "$opencode_sha256" | sha256sum -c - || { printf 'Dockerfile: OpenCode release asset checksum mismatch for %s\n' "$OPENCODE_VERSION" >&2; exit 1; }; \
      mkdir -p /tmp/opencode; \
      tar -xzf /tmp/opencode.tar.gz -C /tmp/opencode || { printf 'Dockerfile: failed to extract OpenCode release asset for %s\n' "$OPENCODE_VERSION" >&2; exit 1; }; \
      install -m 755 /tmp/opencode/opencode /usr/local/bin/opencode || { printf 'Dockerfile: failed to install OpenCode binary to /usr/local/bin/opencode\n' >&2; exit 1; }; \
      rm -rf /tmp/opencode /tmp/opencode.tar.gz; \
      opencode --version ;; \
    *) printf 'Dockerfile: unsupported AGENT "%s"; expected codex or opencode\n' "$AGENT" >&2; exit 1 ;; \
  esac

ENV AGENT=$AGENT
ENV MULTICA_VERSION=$MULTICA_VERSION
ENV NODE_VERSION=$NODE_VERSION
ENV PNPM_VERSION=$PNPM_VERSION
ENV INFISICAL_CLI_VERSION=$INFISICAL_CLI_VERSION
ENV CODEX_VERSION=$CODEX_VERSION
ENV OPENCODE_VERSION=$OPENCODE_VERSION

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
