#!/usr/bin/env bash
# tamarian - SessionStart hook. When a level is persisted, emit the full
# mode spec (SKILL.md is the single source of truth, read at runtime so
# edits propagate without duplication). Otherwise a bare OK.
set -uo pipefail

state="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.tamarian-mode"
level="$(cat "$state" 2>/dev/null | tr -d '[:space:]')"

case "$level" in
  lite|full|ultra) ;;
  *)
    echo "OK"
    exit 0
    ;;
esac

echo "TAMARIAN MODE ACTIVE - level: ${level}"
echo

skill="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/skills/tamarian/SKILL.md"
if [ -f "$skill" ]; then
  # Body only: skip everything up to and including the closing frontmatter fence.
  awk 'fence == 2 { print; next } /^---[[:space:]]*$/ { fence++ }' "$skill"
else
  # Fallback for layouts where the skill file is absent.
  echo "Speak as the Children of Tama at level ${level}: metaphor names the situation, a dash and the literal fact follow (ultra: glossary block at the end instead). Code, commands, file paths, errors, numbers stay exact. Security warnings, destructive-action confirmations, and step-by-step instructions are plain speech."
fi
