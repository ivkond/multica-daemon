# Deploy-Time Harness Tooling Research

Date: 2026-05-13

## Problem

Agents can miss important capabilities at runtime: CLI utilities, skills, Pi extensions, MCP integrations, credentials, and provider-specific helper tools. The current daemon model mostly fixes capabilities at image build time, so changing the agent toolbox requires a rebuild or manual runtime changes.

The goal is to support deploy-time capability selection while keeping runtime startup reproducible, secure, and observable.

## Current Findings

- `multica-daemon` is designed around one selected agent runtime per image/deployment.
- Current documentation covers `codex` and `opencode`; the implementation worktree also contains `pi` runtime support.
- Pi's default tool surface is intentionally small: `read`, `write`, `edit`, `bash`, `grep`, `find`, and `ls`.
- Pi adds capabilities through:
  - TypeScript extensions, including custom tools;
  - skills loaded from configured directories or packages;
  - Pi packages that bundle extensions, skills, prompts, and themes.
- Pi does not include MCP as a built-in feature. MCP should be integrated through an extension/package if needed.
- System CLI tools are separate from agent tools. If a Pi extension or skill expects `gh`, `psql`, `kubectl`, `terraform`, or another binary, that binary must exist in the container image or be installed before agent startup.

## Design Principle

Separate capabilities into two layers:

1. **System tool layer** — binaries and OS/runtime dependencies available on `PATH`.
2. **Agent capability layer** — skills, extensions, Pi packages, prompts, MCP server config, and generated settings.

System tools should usually be installed at build time. Agent capabilities can often be attached at deploy time through a validated manifest.

## Option 1: Build-Time Toolbox Images

Build different image variants with required CLI tools and default packages baked in.

Example variables:

```dotenv
AGENT=pi
PI_VERSION=0.74.0
RUNTIME_FLAVOR=web-fullstack
APT_PACKAGES=ripgrep,fd-find,gh,postgresql-client
NPM_GLOBAL_PACKAGES=@foo/pi-tools@1.2.3
PI_PACKAGES=npm:@org/pi-fullstack@1.4.2,git:github.com/org/agent-skills@v1
```

Build scripts would install pinned tools, write default Pi settings, and validate versions.

Pros:

- Reproducible and easier to audit.
- Faster and more reliable startup.
- Good fit for production defaults and security review.

Cons:

- Changing tools requires rebuild/redeploy.
- Too many variants can create image sprawl.

Best for stable profiles such as `base`, `web-fullstack`, `infra`, and `data`.

## Option 2: Deploy-Time Capability Manifest

Store a capability manifest in deployment variables or the secret store. The entrypoint reads it, validates it, prepares settings, optionally installs allowed packages, and then starts the daemon.

Example manifest:

```json
{
  "version": 1,
  "profile": "web-fullstack",
  "pi": {
    "packages": ["npm:@org/pi-agent-toolbox@1.0.0"],
    "skills": [],
    "extensions": []
  },
  "cli": {
    "required": ["git", "rg", "gh", "node", "pnpm"]
  },
  "mcp": {
    "enabled": true,
    "configSecretKey": "MCP_CONFIG_JSON"
  }
}
```

Startup sequence:

1. Fetch manifest from environment or secret store.
2. Validate schema, allowed sources, pins, and checksums where applicable.
3. Generate `/data/pi/agent/settings.json`.
4. Run smoke checks for required commands and Pi package availability.
5. Fail fast if declared capabilities are unavailable.
6. Start `multica daemon start --foreground`.

Pros:

- One universal image can serve many runtime profiles.
- Capability changes can happen at deploy time.
- Good fit for skills, extensions, package references, and MCP configuration.

Cons:

- Runtime installation from the network can slow or break startup.
- Higher supply-chain and secret-handling risk.
- Requires strict allowlists and pinning.

Best first step: support deploy-time Pi settings generation without runtime OS package installation.

## Option 3: Pi Packages as Capability Bundles

Package skills, extensions, prompts, and MCP gateway code as a versioned Pi package.

Example `package.json`:

```json
{
  "name": "@org/pi-agent-toolbox",
  "keywords": ["pi-package"],
  "pi": {
    "extensions": ["./extensions"],
    "skills": ["./skills"],
    "prompts": ["./prompts"]
  },
  "dependencies": {
    "@modelcontextprotocol/sdk": "x.y.z"
  }
}
```

Runtime settings can then reference:

```json
{
  "packages": ["npm:@org/pi-agent-toolbox@1.0.0"]
}
```

Pros:

- Native Pi extension mechanism.
- Versioned and shareable.
- Skills and custom tools travel together.

Cons:

- Applies mainly to Pi runtime.
- System binaries still need image support.
- MCP still requires an extension implementation.

Best for reusable agent capability bundles.

## Option 4: MCP Gateway Extension

Implement MCP as a Pi extension rather than adding MCP directly to the daemon.

Architecture:

```text
Secret store
  -> MCP config and server secrets
entrypoint
  -> writes /data/pi/agent/mcp.json
Pi MCP gateway extension
  -> starts/connects MCP servers
  -> registers discovered MCP tools through pi.registerTool()
```

The extension should:

- read a generated MCP config file;
- support stdio and HTTP/SSE servers as needed;
- pass only server-specific environment variables;
- register tools dynamically;
- truncate tool output;
- provide diagnostics for connected/failed servers;
- close child processes on session shutdown.

Pros:

- Matches Pi's extension model.
- Keeps MCP optional and packageable.
- Allows one gateway to support many MCP servers.

Cons:

- Requires implementation and maintenance.
- Needs careful output truncation and process lifecycle handling.
- Security review is required because MCP tools can execute broad actions.

## Recommended Path

### Phase 1: Capability Manifest and Pi Settings Generation

Add deploy-time manifest support for Pi runtime:

- `AGENT_CAPABILITIES_JSON` or `AGENT_CAPABILITIES_JSON_B64` from secret store or environment;
- manifest schema validation;
- generation of `/data/pi/agent/settings.json`;
- support for `pi.packages`, `pi.skills`, and `pi.extensions`;
- `cli.required` smoke checks with `command -v`;
- fail-fast startup if declared capabilities are missing.

Do not add runtime apt installs in this phase.

### Phase 2: Prebuilt Tool Flavors

Add image flavors with common system tools installed at build time:

- `base`;
- `web-fullstack`;
- `infra`;
- `data`.

Each flavor should document included binaries and run version checks during build.

### Phase 3: Pi MCP Gateway Package

Build a versioned Pi package, for example `@org/pi-mcp-gateway`, that reads generated MCP config and registers MCP tools.

### Phase 4: Controlled Runtime Installation

Only if needed, add deploy-time installation with strict controls:

- pinned npm/git refs only;
- pinned binary URLs with SHA-256;
- allowlisted apt packages only;
- no `latest` or unpinned package sources;
- clear startup diagnostics and redacted logs.

## Security Requirements

- Treat Pi packages, extensions, and skills as trusted code with full runtime access.
- Require pinned package versions or git refs.
- Do not log secrets, raw manifests containing secrets, or generated auth files.
- Keep secret material in the secret store and write only minimal runtime config files.
- Separate MCP server secrets per server.
- Validate required tools before launching the daemon.
- Prefer build-time installation for privileged/system dependencies.

## Minimal Acceptance Criteria

A first implementation is useful if:

- a deployment can declare Pi packages, skills, extensions, and required CLI binaries in one manifest;
- startup generates valid Pi settings;
- startup fails clearly when required binaries or packages are unavailable;
- no secret values are logged;
- existing `codex` and `opencode` behavior is unchanged;
- Pi runtime can be redeployed with a different capability manifest without editing the image.
