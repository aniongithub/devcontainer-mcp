#!/usr/bin/env bash
# devcontainer-skill-loader.sh — SessionStart hook for Claude Code & Copilot CLI
#
# When a session starts in a directory with .devcontainer/devcontainer.json,
# injects the devcontainer-mcp SKILL.md content as additionalContext so the
# agent automatically knows how to use devcontainer-mcp tools.
#
# Opt-out: a `.devcontainer-mcp-disable` marker file at the repo root skips the
# injection (mirrors the devcontainer-guard opt-out).
#
# Supports both agent payload formats:
#   Claude Code:  { tool_name, tool_input, cwd, ... }
#   Copilot CLI:  { toolName, toolArgs, cwd, ... }

# Fail open by design: this hook only *adds* context and must never disrupt
# session startup. All logic runs in a subshell (`build_context`) whose stdout
# we capture; if anything unexpected fails inside it (jq missing, unparseable
# payload), the subshell exits non-zero and we simply start the session without
# injected context.
#
# NOTE: we deliberately do NOT rely on an ERR trap + `exit`, because macOS ships
# bash 3.2, where `exit` inside an ERR trap fired by a `var=$(cmd)` assignment
# does not terminate the script. Capturing the subshell's exit status is the
# portable way to fail open.

# Agent hosts often spawn hooks with a minimal PATH that omits Homebrew
# (/opt/homebrew/bin) and /usr/local/bin, where jq is commonly installed.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# Prints the additionalContext JSON to stdout when a devcontainer + SKILL.md are
# found; prints nothing otherwise. Runs with `set -e` so a missing dependency
# (jq) or malformed input aborts non-zero and the caller injects no context.
build_context() {
  set -euo pipefail
  local input="$1"
  local cwd skill_path skill_content p
  local SEARCH_PATHS

  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

  [ -n "$cwd" ] || return 0
  [ -f "${cwd}/.devcontainer/devcontainer.json" ] || return 0

  # Per-repo opt-out: if the guard is disabled for this repo, don't inject the
  # container-only skill context either — the agent is expected to work locally.
  [ ! -f "${cwd}/.devcontainer-mcp-disable" ] || return 0

  # Look for SKILL.md in order of preference
  SEARCH_PATHS=(
    "${HOME}/.local/share/devcontainer-mcp/SKILL.md"
    "${HOME}/.copilot/skills/devcontainer-mcp/SKILL.md"
    "${HOME}/.claude/skills/devcontainer-mcp/SKILL.md"
    "${HOME}/.agents/skills/devcontainer-mcp/SKILL.md"
  )

  skill_path=""
  for p in "${SEARCH_PATHS[@]}"; do
    if [ -f "$p" ]; then
      skill_path="$p"
      break
    fi
  done

  [ -n "$skill_path" ] || return 0

  skill_content=$(cat "$skill_path")
  jq -n --arg ctx "$skill_content" '{ "additionalContext": $ctx }'
}

INPUT=$(cat)

if CONTEXT=$(build_context "$INPUT"); then
  [ -n "$CONTEXT" ] && printf '%s\n' "$CONTEXT"
fi

exit 0
