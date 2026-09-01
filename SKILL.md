---
name: devcontainer-mcp
description: Manage dev container environments via MCP tools (DevPod, devcontainer CLI, Codespaces)
tools:
  - auth_status
  - auth_login
  - auth_select
  - auth_logout
  - codespaces_create
  - codespaces_list
  - codespaces_ssh
  - codespaces_stop
  - codespaces_delete
  - codespaces_view
  - codespaces_ports
  - codespaces_file_read
  - codespaces_file_write
  - codespaces_file_edit
  - codespaces_file_list
  - devcontainer_up
  - devcontainer_exec
  - devcontainer_build
  - devcontainer_read_config
  - devcontainer_stop
  - devcontainer_remove
  - devcontainer_status
  - devcontainer_file_read
  - devcontainer_file_write
  - devcontainer_file_edit
  - devcontainer_file_list
  - devpod_up
  - devpod_stop
  - devpod_delete
  - devpod_build
  - devpod_status
  - devpod_list
  - devpod_ssh
  - devpod_logs
  - devpod_provider_list
  - devpod_provider_add
  - devpod_provider_delete
  - devpod_context_list
  - devpod_context_use
  - devpod_container_inspect
  - devpod_container_logs
  - devpod_file_read
  - devpod_file_write
  - devpod_file_edit
  - devpod_file_list
---

# DevContainer MCP Skill

You have access to `devcontainer-mcp`, an MCP server that manages dev container environments across three backends:
- **DevPod** (`devpod_*` tools) — multi-provider: Docker, K8s, AWS, GCP, etc.
- **devcontainer CLI** (`devcontainer_*` tools) — local Docker via the official CLI
- **GitHub Codespaces** (`codespaces_*` tools) — cloud-hosted environments

## Core Rules

**If a project has `.devcontainer/devcontainer.json`, ALL work MUST happen inside a dev container — never install dependencies, run builds, or execute code directly on the host.**

> **Opt-out:** if a `.devcontainer-mcp-disable` marker file exists at the repo root, the host-protection guard is disabled for that repo — the devcontainer is treated as stale/unmaintained and you may work directly on the host.

**Use ONLY the MCP tools listed here.** Do not invoke `docker`, `devcontainer`, `devpod`, or `gh` CLI commands directly — the MCP tools wrap these CLIs with proper error handling, auth resolution, and escaping. Direct CLI usage bypasses these safeguards.

## Authentication

**Before using Codespaces tools, you MUST obtain an auth handle.**

### 1. Check available accounts
```
auth_status(provider: "github")
→ returns accounts with IDs like "github-aniongithub"
```

### 2. If multiple accounts, ask the user which one to use

### 3. If no accounts or missing scopes, initiate login
```
auth_login(provider: "github", scopes: "codespace")
→ opens browser, copies device code to clipboard
→ tell the user: "Approve in the browser, code is on your clipboard"
```

### 4. Pass the auth handle to all codespaces_* tools
```
codespaces_create(auth: "github-aniongithub", repo: "owner/repo", ...)
```

**The agent never sees raw tokens.** Auth handles are opaque IDs resolved by the MCP server.

Supported auth providers: `github`, `aws`, `azure`, `gcloud`, `kubernetes`

## Choosing a Backend

1. **Local Docker + devcontainer CLI** — simplest for local development, no auth needed
2. **DevPod** — when you need multi-provider support or the project uses DevPod
3. **Codespaces** — when you need cloud-hosted environments (requires GitHub auth)

## Workflow: DevPod

> **Use these tools — not raw `devpod` CLI commands.**

### 1. Create or start the workspace
```
devpod_up(args: "/path/to/project --id my-project --provider docker")
```

### 2. Verify the workspace is running
```
devpod_status(workspace: "my-project")
```

### 3. Execute commands inside the workspace
```
devpod_ssh(workspace: "my-project", command: "cargo build")
```

### 4. Stop when done
```
devpod_stop(workspace: "my-project")
```

## Workflow: devcontainer CLI

> **Use these tools — not raw `devcontainer` or `docker` CLI commands.**

### 1. Start the dev container
```
devcontainer_up(workspace_folder: "/path/to/project")
```

### 2. Execute commands
```
devcontainer_exec(workspace_folder: "/path/to/project", command: "npm test")
```

### 3. Stop when done
```
devcontainer_stop(workspace_folder: "/path/to/project")
```

## Workflow: Codespaces

> **Use these tools — not raw `gh codespace` CLI commands.**

### 1. Authenticate
```
auth_status(provider: "github")
# If no accounts: auth_login(provider: "github", scopes: "codespace")
# If multiple: ask the user which account
```

### 2. Create a codespace — ask user for machine type
```
codespaces_create(auth: "github-USERNAME", repo: "owner/repo", machine: "basicLinux32gb")
```
Machine types: `basicLinux32gb` (2 cores, 8 GB), `standardLinux32gb` (4 cores, 16 GB), `premiumLinux` (8 cores, 32 GB), `largePremiumLinux` (16 cores, 64 GB)

### 3. Execute commands
```
codespaces_ssh(auth: "github-USERNAME", codespace: "codespace-name", command: "npm test")
```

### 4. Stop when done
```
codespaces_stop(auth: "github-USERNAME", codespace: "codespace-name")
```

## Self-Healing

If `devpod_up`, `devcontainer_up`, or `codespaces_create` returns errors:
1. Read the error output carefully
2. Fix the `Dockerfile` or `devcontainer.json`
3. Call the up/create command again
4. Repeat until successful

## What NOT to do

- ❌ Do NOT install packages on the host
- ❌ Do NOT run builds on the host
- ❌ Do NOT modify the host's global config
- ❌ Do NOT run `docker`, `devcontainer`, `devpod`, or `gh` CLI commands directly — use the MCP tools
- ✅ DO authenticate before using codespaces tools
- ✅ DO ask the user which account/machine type to use
- ✅ DO use `devpod_ssh`, `devcontainer_exec`, or `codespaces_ssh` for everything
- ✅ DO check `.devcontainer/devcontainer.json` first

> **Note:** Host-protection hooks are installed for supported agent environments (Claude Code, GitHub Copilot CLI) that automatically block shell commands when a devcontainer is detected. If a command is blocked, use the appropriate MCP tool instead.

## File Operations

**All backends support built-in file operations — no need to construct shell commands.**

These tools mirror familiar editing tools (read, write, edit, list) and handle escaping, encoding, and directory creation automatically.

### Reading files
```
devpod_file_read(workspace: "my-ws", path: "/workspaces/project/src/main.rs")
devcontainer_file_read(workspace_folder: "/path/to/project", path: "/workspaces/project/src/main.rs")
codespaces_file_read(auth: "github-user", codespace: "name", path: "src/main.rs")
```
Supports optional `start_line` and `end_line` for reading specific ranges.

### Writing files
```
devpod_file_write(workspace: "my-ws", path: "/workspaces/project/new_file.rs", content: "fn main() {}")
devcontainer_file_write(workspace_folder: "/path/to/project", path: "new_file.rs", content: "fn main() {}")
codespaces_file_write(auth: "github-user", codespace: "name", path: "src/new.rs", content: "...")
```
Creates parent directories automatically.

### Editing files (surgical replacement)
```
devpod_file_edit(workspace: "my-ws", path: "src/main.rs", old_str: "fn old()", new_str: "fn new()")
devcontainer_file_edit(workspace_folder: "/path/to/project", path: "src/lib.rs", old_str: "v1", new_str: "v2")
codespaces_file_edit(auth: "github-user", codespace: "name", path: "src/lib.rs", old_str: "TODO", new_str: "DONE")
```
`old_str` must match exactly once in the file. Include surrounding context to make it unique.

### Listing directories
```
devpod_file_list(workspace: "my-ws", path: "/workspaces/project/src")
devcontainer_file_list(workspace_folder: "/path/to/project", path: "src")
codespaces_file_list(auth: "github-user", codespace: "name", path: ".")
```
Shows non-hidden files up to 2 levels deep.

### When to use file tools vs exec/ssh
- ✅ **Use file tools** for reading, writing, and editing source files
- ✅ **Use exec/ssh** for running builds, tests, and commands
- ❌ **Don't** construct `sed`, `cat`, or `echo` commands via exec for file editing
