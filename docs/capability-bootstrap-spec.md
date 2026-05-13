# Capability Bootstrap Specification

Date: 2026-05-13

## Purpose

Capability bootstrap prepares declared agent tooling after runtime secrets are fetched and before `multica daemon` starts. It can verify expected CLIs, render tool-specific auth/config files, generate command shims, and write Pi settings.

Capability bootstrap does not install arbitrary operating-system packages at runtime. System binaries still belong in image flavors unless they are explicitly preinstalled in the selected runtime image.

## Inputs

The manifest is optional. When neither manifest variable is configured, bootstrap is a no-op.

- `AGENT_CAPABILITIES_JSON_B64`: base64-encoded JSON manifest. When set, this takes precedence over `AGENT_CAPABILITIES_JSON`.
- `AGENT_CAPABILITIES_JSON`: raw JSON manifest.
- `secret:NAME` references: manifest values that resolve from runtime environment variable `NAME` after the secret-store fetch step. Secret names must be valid environment variable names.

The manifest must be JSON with `"version": 1`.

## Minimal Example

```json
{
  "version": 1,
  "cli": {
    "required": ["git"]
  },
  "auth": {
    "github": {
      "mode": "netrc",
      "token": "secret:GITHUB_TOKEN"
    }
  },
  "pi": {
    "packages": ["npm:@org/pi-agent-toolbox@1.0.0"]
  }
}
```

## Generated Paths

- `/data/capabilities/manifest.json`: loaded manifest copy.
- `/data/capabilities`: capability-specific auth/config root, mode `700`.
- `/data/capabilities/<wrapper>/env`: environment file for a CLI wrapper, mode `600`.
- `/data/capabilities/mcp/<server>/env`: environment file for an MCP server, mode `600`.
- `/data/capability-shims`: generated wrapper command directory, mode `700`.
- `/data/capability-shims/<wrapper>`: wrapper executable, mode `755`.
- `/data/home/.netrc`: GitHub HTTPS auth file when `auth.github.mode` is `netrc`, mode `600`.
- `/data/pi/agent/settings.json`: Pi package/skill/extension settings, mode `600`.
- `/data/pi/agent/mcp.json`: generated MCP server config with `envFile` references, mode `600`.

`PI_CODING_AGENT_DIR` can override `/data/pi/agent` when the runtime sets a different Pi agent directory.

## Supported Sections

### `cli.required`

Array of command names that must be available on `PATH`. Startup fails before auth files or wrappers are rendered when a required command is missing.

Use image flavors or explicit image preinstallation for required system binaries. The manifest only verifies their presence.

### `cli.wrappers`

Array of wrapper definitions. Each wrapper has:

- `name`: safe command name to create under `/data/capability-shims`.
- `target`: absolute path to an existing executable.
- `env`: object whose values are `secret:NAME` references.

Bootstrap writes a tool-specific env file and a shim that sources that env file before executing the target with original arguments.

### `auth.github`

Supports `mode: "netrc"`. The `token` field must be a `secret:NAME` reference. Bootstrap writes `${HOME}/.netrc` for GitHub HTTPS access using login `x-access-token`.

### `pi`

Generates Pi settings when any of these arrays are present and non-empty:

- `packages`
- `skills`
- `extensions`

These values are written to `settings.json`. Package declarations are Pi settings only; they are not runtime OS package installation.

### `mcp.servers`

Object keyed by MCP server name. Each server supports:

- `command`: safe command name.
- `args`: optional string array.
- `env`: object whose values are `secret:NAME` references.

Bootstrap writes secret values to `/data/capabilities/mcp/<server>/env` and writes `mcp.json` with an `envFile` path. Raw secret values are not written to `mcp.json`.

### `validate`

Array of command arrays run after rendering wrappers, auth, Pi settings, and MCP config. Standard output and standard error from validation commands are suppressed by the bootstrap script. Failure stops startup.

## Security Rules

- Manifests must contain secret references, not raw secret values.
- Secrets are not logged by bootstrap.
- Secrets are materialized only into tool-specific files, such as `/data/capabilities/<wrapper>/env`, `/data/capabilities/mcp/<server>/env`, or `/data/home/.netrc`.
- Generated secret-bearing files use `600` permissions.
- Capability directories use restrictive directory permissions.
- Validation command output is suppressed to avoid leaking command output.
- Runtime operating-system package installation is not supported.
