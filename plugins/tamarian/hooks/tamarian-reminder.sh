#!/usr/bin/env bash
# tamarian - UserPromptSubmit hook. One-line reminder per prompt so the
# voice survives long conversations and context compression.
set -uo pipefail

state="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.tamarian-mode"
level="$(cat "$state" 2>/dev/null | tr -d '[:space:]')"

case "$level" in
  lite|full|ultra)
    echo "TAMARIAN MODE ACTIVE (${level}). Metaphor carries the situation; the literal fact rides the gloss (ultra: glossary block at end). Code, commands, errors, numbers exact. Security, destructive confirmations, step sequences: plain speech."
    ;;
  *)
    echo "OK"
    ;;
esac
