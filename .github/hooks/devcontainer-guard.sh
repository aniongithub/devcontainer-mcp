#!/usr/bin/env bash
# devcontainer-guard.sh — PreToolUse hook for Claude Code & GitHub Copilot CLI
#
# Blocks bash/shell tool calls when .devcontainer/devcontainer.json exists in
# the working directory, forcing agents to use devcontainer-mcp MCP tools
# instead of running commands directly on the host.
#
# Read-only tools (view, grep, glob) and file edits are allowed through — only
# command execution is blocked.
#
# Host-safe commands (git, gh, curl, etc.) are allowlisted and always permitted
# since they operate on the repo/host, not the project's build environment.
#
# Bypass: include USER_CONFIRMED_HOST_OPERATION=1 in the command.
#
# Supports both agent payload formats:
#   Claude Code:  { tool_name, tool_input, cwd, ... }
#   Copilot CLI:  { toolName, toolArgs, cwd, ... }

# Fail open by design. The ONLY way this hook blocks a command is by printing a
# "deny" decision to stdout — blocking is NEVER signaled through the exit code.
# All decision logic runs in a subshell (`decide`) whose stdout we capture: if
# anything unexpected fails inside it (jq missing, an unparseable payload, a
# failing helper), the subshell exits non-zero and we fall through to ALLOW.
# This matters because an agent treats a non-zero hook exit as "deny", which
# would block every command on the host — even in repos with no devcontainer.
#
# NOTE: we deliberately do NOT rely on an ERR trap + `exit`, because macOS ships
# bash 3.2, where `exit` inside an ERR trap fired by a `var=$(cmd)` assignment
# does not terminate the script. Capturing the subshell's exit status is the
# portable way to fail open.

# Agent hosts often spawn hooks with a minimal PATH that omits Homebrew
# (/opt/homebrew/bin) and /usr/local/bin, where jq is commonly installed.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# Extract all meaningful commands from a shell string, skipping env vars
# (KEY=VALUE) and cd/pushd/popd. Splits on &&, ||, ;, and | to catch every
# command in a chain or pipeline.
all_commands() {
  local cmd="$1"
  while IFS= read -r segment; do
    segment="${segment#"${segment%%[![:space:]]*}"}"
    [ -z "$segment" ] && continue
    for token in $segment; do
      if [[ "$token" == *=* && "$token" != -* ]]; then
        continue
      fi
      case "$token" in
        cd|pushd|popd) break ;;
      esac
      basename "$token"
      break
    done
  done < <(echo "$cmd" | sed 's/ *&& */\n/g; s/ *|| */\n/g; s/ *; */\n/g; s/ *| */\n/g')
}

# Prints a "deny" JSON decision to stdout ONLY when the tool call must be
# blocked; prints nothing for every allow case. Runs with `set -e` so that a
# missing dependency (jq) or malformed input aborts with a non-zero status,
# which the caller turns into a fail-open ALLOW.
decide() {
  set -euo pipefail
  local input="$1"
  local tool_name cwd tool_input cmd_string reason
  local all_allowed had_cmd cmd_name allowed found

  # Try Claude Code fields first (snake_case), fall back to Copilot CLI (camelCase)
  tool_name=$(printf '%s' "$input" | jq -r '.tool_name // .toolName // empty')
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

  # Only guard bash/shell tool calls — allow everything else through
  case "$tool_name" in
    Bash|bash|shell|powershell|Shell|PowerShell) ;;
    *) return 0 ;;
  esac

  tool_input=$(printf '%s' "$input" | jq -r '(.tool_input // .toolArgs // {}) | tostring')

  # Bypass: allow when the operator explicitly confirmed a host operation
  if printf '%s' "$tool_input" | grep -q 'USER_CONFIRMED_HOST_OPERATION=1'; then
    return 0
  fi

  # No cwd in payload — can't determine context, allow through
  [ -n "$cwd" ] || return 0

  # No devcontainer in the working directory — allow through
  [ -f "${cwd}/.devcontainer/devcontainer.json" ] || return 0

  # --- Devcontainer exists: allow only if every command is host-safe ---
  cmd_string=$(printf '%s' "$input" | jq -r '(.tool_input.command // .toolArgs.command // "") | tostring')

  # Commands that are safe to run on the host even when a devcontainer exists.
  # These operate on the repo/host itself, not on the project's build environment.
  local ALLOWED_HOST_COMMANDS=(git gh)

  all_allowed=true
  had_cmd=false
  while IFS= read -r cmd_name; do
    [ -z "$cmd_name" ] && continue
    had_cmd=true
    found=false
    for allowed in "${ALLOWED_HOST_COMMANDS[@]}"; do
      if [ "$cmd_name" = "$allowed" ]; then
        found=true
        break
      fi
    done
    if [ "$found" = false ]; then
      all_allowed=false
      break
    fi
  done < <(all_commands "$cmd_string")

  # Every command in the chain was on the allowlist — allow through
  if [ "$all_allowed" = true ] && [ "$had_cmd" = true ]; then
    return 0
  fi

  # --- Block: emit a deny decision in the right agent format ---
  reason="Host execution blocked. This project has a devcontainer. Use devcontainer-mcp tools (devcontainer_exec, devpod_ssh, codespaces_ssh, and file operation tools) instead of running commands directly on the host."

  if [ -n "$(printf '%s' "$input" | jq -r '.tool_name // empty')" ]; then
    # Claude Code format
    jq -n --arg reason "$reason" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
  else
    # Copilot CLI format
    jq -n --arg reason "$reason" '{
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }'
  fi
}

INPUT=$(cat)

if DECISION=$(decide "$INPUT"); then
  # decide completed cleanly: DECISION is a deny JSON (block) or empty (allow)
  [ -n "$DECISION" ] && printf '%s\n' "$DECISION"
else
  # decide crashed (jq missing, unparseable payload, ...): FAIL OPEN (allow)
  echo "devcontainer-guard: hook error; allowing tool call (install jq to enable host protection)." >&2
fi

exit 0
