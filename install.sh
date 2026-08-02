#!/usr/bin/env bash
set -euo pipefail

# devcontainer-mcp installer
# Downloads the latest release binary.
# Backend CLIs (devcontainer, devpod, gh) are detected only; if missing,
# the MCP server returns a helpful error message and the installer prints
# install URLs. Nothing is downloaded silently on your behalf.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/aniongithub/devcontainer-mcp/main/install.sh | bash
#   curl -fsSL ... | bash -s -- --install-dir /usr/local/bin

REPO="aniongithub/devcontainer-mcp"
INSTALL_DIR="${HOME}/.local/bin"
SKIP_MCP_CONFIG=false

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)       INSTALL_DIR="$2"; shift 2 ;;
    --skip-mcp-config)   SKIP_MCP_CONFIG=true; shift ;;
    --help|-h)
      echo "Usage: install.sh [--install-dir DIR] [--skip-mcp-config]"
      echo "  --install-dir       Installation directory (default: ~/.local/bin)"
      echo "  --skip-mcp-config   Skip MCP client configuration (used by install.ps1)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Detect OS and architecture
detect_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *)      echo "Error: Unsupported OS: $os"; exit 1 ;;
  esac

  case "$arch" in
    x86_64|amd64)  arch="x64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)             echo "Error: Unsupported architecture: $arch"; exit 1 ;;
  esac

  echo "${os}-${arch}"
}

# Get latest release tag from GitHub
get_latest_version() {
  curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep '"tag_name"' \
    | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
}

PLATFORM="$(detect_platform)"
echo "==> Detected platform: ${PLATFORM}"

VERSION="$(get_latest_version)"
if [[ -z "$VERSION" ]]; then
  echo "Error: Could not determine latest release version."
  echo "Check: https://github.com/${REPO}/releases"
  exit 1
fi
echo "==> Latest version: ${VERSION}"

TARBALL_NAME="devcontainer-mcp-${PLATFORM}.tar.gz"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${TARBALL_NAME}"

# Create install directory
mkdir -p "$INSTALL_DIR"

echo "==> Downloading ${TARBALL_NAME}..."
curl -fsSL "$DOWNLOAD_URL" | tar xz -C "${INSTALL_DIR}"
chmod +x "${INSTALL_DIR}/devcontainer-mcp"

# macOS: ad-hoc codesign to avoid Gatekeeper "Killed: 9"
if [[ "$(uname -s)" == "Darwin" ]]; then
  codesign -s - "${INSTALL_DIR}/devcontainer-mcp" 2>/dev/null && \
    echo "==> Codesigned binary for macOS" || true
fi

echo "==> Installed devcontainer-mcp to ${INSTALL_DIR}/devcontainer-mcp"

# Verify
if "${INSTALL_DIR}/devcontainer-mcp" --version >/dev/null 2>&1; then
  echo "==> $(${INSTALL_DIR}/devcontainer-mcp --version)"
else
  echo "Warning: Binary downloaded but failed to run. Check platform compatibility."
fi

# Check PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
  echo ""
  echo "Note: ${INSTALL_DIR} is not in your PATH. Add it with:"
  echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
fi

# Install SKILL.md for agent discovery
SKILL_URL="https://raw.githubusercontent.com/${REPO}/main/SKILL.md"
SKILL_DIRS=(
  "${HOME}/.copilot/skills/devcontainer-mcp"
  "${HOME}/.claude/skills/devcontainer-mcp"
  "${HOME}/.agents/skills/devcontainer-mcp"
  "${HOME}/.config/opencode/skills/devcontainer-mcp"
)

echo ""
echo "==> Installing SKILL.md for agent discovery..."
for dir in "${SKILL_DIRS[@]}"; do
  mkdir -p "$dir"
  curl -fsSL -o "${dir}/SKILL.md" "$SKILL_URL" 2>/dev/null && \
    echo "    ${dir}/SKILL.md" || true
done

# ---------------------------------------------------------------------------
# Install host-protection hooks
# ---------------------------------------------------------------------------

HOOK_URL="https://raw.githubusercontent.com/${REPO}/main/.github/hooks/devcontainer-guard.sh"
LOADER_URL="https://raw.githubusercontent.com/${REPO}/main/.github/hooks/devcontainer-skill-loader.sh"
HOOK_DIR="${HOME}/.local/share/devcontainer-mcp/hooks"
HOOK_PATH="${HOOK_DIR}/devcontainer-guard.sh"
LOADER_PATH="${HOOK_DIR}/devcontainer-skill-loader.sh"

echo ""
echo "==> Installing host-protection hook..."
mkdir -p "$HOOK_DIR"
curl -fsSL -o "$HOOK_PATH" "$HOOK_URL" 2>/dev/null && \
  chmod +x "$HOOK_PATH" && \
  echo "    ${HOOK_PATH}" || echo "    ⚠ Could not download hook script"

echo ""
echo "==> Installing skill-loader hook..."
curl -fsSL -o "$LOADER_PATH" "$LOADER_URL" 2>/dev/null && \
  chmod +x "$LOADER_PATH" && \
  echo "    ${LOADER_PATH}" || echo "    ⚠ Could not download skill-loader hook"

# The host-protection hooks parse their JSON payload with jq. Without jq the
# hooks fail open (they allow commands through) so they can never block your
# shell — but host protection is effectively disabled until jq is installed.
command -v jq >/dev/null 2>&1 \
  && echo "  ✓ jq (host-protection hooks active)" \
  || echo "  ✗ jq            — hooks INACTIVE until installed — https://jqlang.github.io/jq/download/"

# Install SKILL.md alongside hooks for the loader to find
SKILL_DATA_PATH="${HOME}/.local/share/devcontainer-mcp/SKILL.md"
curl -fsSL -o "$SKILL_DATA_PATH" "$SKILL_URL" 2>/dev/null && \
  echo "    ${SKILL_DATA_PATH}" || true

# Configure Claude Code PreToolUse + SessionStart hooks
configure_claude_hook() {
  local settings_file="${HOME}/.claude/settings.json"
  local hook_command="$HOOK_PATH"
  local loader_command="$LOADER_PATH"

  if [ ! -f "$settings_file" ]; then
    mkdir -p "$(dirname "$settings_file")"
    cat > "$settings_file" << CLAUDEEOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "${hook_command}",
            "timeout": 5
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${loader_command}",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
CLAUDEEOF
    echo "  ✓ Claude Code — created ${settings_file}"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json, sys

path = '${settings_file}'
hook_cmd = '${hook_command}'
loader_cmd = '${loader_command}'

with open(path) as f:
    data = json.load(f)

hooks = data.setdefault('hooks', {})

# --- PreToolUse: devcontainer-guard ---
pre_tool = hooks.setdefault('PreToolUse', [])
already_guard = False
for group in pre_tool:
    for h in group.get('hooks', []):
        if 'devcontainer-guard' in h.get('command', ''):
            already_guard = True
            break

if not already_guard:
    pre_tool.append({
        'matcher': 'Bash',
        'hooks': [{
            'type': 'command',
            'command': hook_cmd,
            'timeout': 5
        }]
    })
    print('  ✓ Claude Code — added PreToolUse hook to ${settings_file}')
else:
    print('  ✓ Claude Code — PreToolUse hook already configured')

# --- SessionStart: skill-loader ---
session_start = hooks.setdefault('SessionStart', [])
already_loader = False
for group in session_start:
    for h in group.get('hooks', []):
        if 'skill-loader' in h.get('command', ''):
            already_loader = True
            break

if not already_loader:
    session_start.append({
        'hooks': [{
            'type': 'command',
            'command': loader_cmd,
            'timeout': 5
        }]
    })
    print('  ✓ Claude Code — added SessionStart hook to ${settings_file}')
else:
    print('  ✓ Claude Code — SessionStart hook already configured')

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || echo "  ⚠ Claude Code — could not update ${settings_file}"
  else
    echo "  ⚠ Claude Code — exists but python3 not available to merge"
  fi
}

# Configure Copilot CLI preToolUse + sessionStart hooks
configure_copilot_hook() {
  local hooks_dir="${HOME}/.copilot/hooks"

  mkdir -p "$hooks_dir"

  cat > "${hooks_dir}/devcontainer-guard.json" << COPILOTEOF
{
  "version": 1,
  "hooks": {
    "preToolUse": [
      {
        "type": "command",
        "bash": "${HOOK_PATH}",
        "timeoutSec": 5
      }
    ]
  }
}
COPILOTEOF
  echo "  ✓ Copilot CLI — created ${hooks_dir}/devcontainer-guard.json"

  cat > "${hooks_dir}/devcontainer-skill-loader.json" << COPILOTEOF
{
  "version": 1,
  "hooks": {
    "sessionStart": [
      {
        "type": "command",
        "bash": "${LOADER_PATH}",
        "timeoutSec": 5
      }
    ]
  }
}
COPILOTEOF
  echo "  ✓ Copilot CLI — created ${hooks_dir}/devcontainer-skill-loader.json"
}

echo ""
echo "==> Configuring agent host-protection hooks..."
configure_claude_hook
configure_copilot_hook

# Detect available backends
echo ""
echo "Backend CLIs detected (install as needed — MCP server gives helpful errors if missing):"
command -v devpod       >/dev/null 2>&1 && echo "  ✓ devpod"       || echo "  ✗ devpod        — https://devpod.sh/docs/getting-started/install"

# devcontainer CLI: detect only. Installing @devcontainers/cli fetches from
# the npm registry (registry.npmjs.org), which some corporate egress
# policies block, so the installer never downloads it silently — it just
# reports whether it is present, like the other backends.
if command -v devcontainer >/dev/null 2>&1; then
  echo "  ✓ devcontainer"
else
  echo "  ✗ devcontainer   — https://github.com/devcontainers/cli#install-script (or 'brew install devcontainer')"
fi

command -v gh           >/dev/null 2>&1 && echo "  ✓ gh (codespaces)" || echo "  ✗ gh (codespaces) — https://cli.github.com/"

# ---------------------------------------------------------------------------
# Auto-configure MCP clients (skipped when called from install.ps1)
# ---------------------------------------------------------------------------

if [ "$SKIP_MCP_CONFIG" = true ]; then
  echo ""
  echo "==> Skipping MCP client configuration (--skip-mcp-config)"
  echo ""
  echo "Done! devcontainer-mcp binary is installed."
  exit 0
fi

configure_mcp_client() {
  local config_file="$1"
  local client_name="$2"

  if [ ! -f "$config_file" ]; then
    mkdir -p "$(dirname "$config_file")"
    cat > "$config_file" << MCPEOF
{
  "mcpServers": {
    "devcontainer-mcp": {
      "command": "${INSTALL_DIR}/devcontainer-mcp",
      "args": ["serve"]
    }
  }
}
MCPEOF
    echo "  ✓ ${client_name} — created ${config_file}"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json
path = '${config_file}'
with open(path) as f:
    data = json.load(f)
servers = data.setdefault('mcpServers', {})
if 'devcontainer-mcp' not in servers:
    servers['devcontainer-mcp'] = {'command': '${INSTALL_DIR}/devcontainer-mcp', 'args': ['serve']}
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
    print('  ✓ ${client_name} — added to ${config_file}')
else:
    print('  ✓ ${client_name} — already configured')
" 2>/dev/null || echo "  ⚠ ${client_name} — could not update ${config_file}"
  else
    echo "  ⚠ ${client_name} — exists but python3 not available to merge"
  fi
}

# opencode uses a different config schema (mcp key, type: "local", combined
# command array, enabled: true) and a different file path.
configure_opencode_mcp() {
  local config_file="${HOME}/.config/opencode/opencode.json"
  local bin_path="${INSTALL_DIR}/devcontainer-mcp"

  if [ ! -f "$config_file" ]; then
    mkdir -p "$(dirname "$config_file")"
    cat > "$config_file" << OPENCODEEOF
{
  "\$schema": "https://opencode.ai/config.json",
  "mcp": {
    "devcontainer-mcp": {
      "type": "local",
      "command": ["${bin_path}", "serve"],
      "enabled": true
    }
  }
}
OPENCODEEOF
    echo "  ✓ opencode — created ${config_file}"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json
path = '${config_file}'
with open(path) as f:
    data = json.load(f)
servers = data.setdefault('mcp', {})
if 'devcontainer-mcp' not in servers:
    servers['devcontainer-mcp'] = {
        'type': 'local',
        'command': ['${bin_path}', 'serve'],
        'enabled': True,
    }
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
    print('  ✓ opencode — added to ${config_file}')
else:
    print('  ✓ opencode — already configured')
" 2>/dev/null || echo "  ⚠ opencode — could not update ${config_file}"
  else
    echo "  ⚠ opencode — exists but python3 not available to merge"
  fi
}

echo ""
echo "==> Configuring MCP clients..."

# GitHub Copilot CLI — check if .copilot dir exists
if [ -d "${HOME}/.copilot" ]; then
  configure_mcp_client "${HOME}/.copilot/mcp-config.json" "GitHub Copilot"
fi

# VS Code — check if VS Code config dir exists
if [[ "$(uname -s)" == "Darwin" ]]; then
  VSCODE_DIR="${HOME}/Library/Application Support/Code/User"
else
  VSCODE_DIR="${HOME}/.config/Code/User"
fi
if [ -d "$VSCODE_DIR" ]; then
  configure_mcp_client "${VSCODE_DIR}/mcp.json" "VS Code"
fi

# Cursor — only if Cursor is installed
if [ -d "${HOME}/.cursor" ]; then
  configure_mcp_client "${HOME}/.cursor/mcp.json" "Cursor"
fi

# Claude Code — ~/.claude.json
configure_mcp_client "${HOME}/.claude.json" "Claude Code"

# opencode — ~/.config/opencode/opencode.json (uses different schema)
configure_opencode_mcp

echo ""
echo "Done! devcontainer-mcp is ready to use."
