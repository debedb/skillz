#!/usr/bin/env bash
set -euo pipefail

SKILLS=(
  "work-on-pr"
  "review-pr-loop"
)

DRY_RUN=0
TARGET="auto"

usage() {
  cat <<'EOF'
Install the paired PR-loop skills into Codex, Claude Code, or both.

Usage:
  install.sh [--target auto|codex|claude|both] [--dry-run]

Environment:
  SKILLS_DEST_ROOT   Install into exactly this root and ignore --target.
  CODEX_HOME         Used for the Codex root (defaults to ~/.codex).
  CLAUDE_SKILLS_DIR  Used for the Claude root (defaults to ~/.claude/skills).
  GIST_RAW_BASE      Override the raw gist base URL.
EOF
}

while (($#)); do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --target)
      if (($# < 2)); then
        echo "error: --target requires a value" >&2
        exit 2
      fi
      TARGET="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

DEFAULT_CODEX_ROOT="${CODEX_HOME:-$HOME/.codex}/skills"
DEFAULT_CLAUDE_ROOT="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
GIST_RAW_BASE="${GIST_RAW_BASE:-https://gist.githubusercontent.com/debedb/5f606018eb36a75dc292016268f08e7c/raw}"
SCRIPT_DIR=""
DEST_ROOTS=()

add_dest_root() {
  local candidate="$1"
  [[ -n "$candidate" ]] || return 0
  local existing
  for existing in "${DEST_ROOTS[@]:-}"; do
    [[ "$existing" == "$candidate" ]] && return 0
  done
  DEST_ROOTS+=("$candidate")
}

if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [[ -n "${SKILLS_DEST_ROOT:-}" ]]; then
  add_dest_root "$SKILLS_DEST_ROOT"
else
  case "$TARGET" in
    auto)
      [[ -n "${CODEX_HOME:-}" || -d "$HOME/.codex" ]] && add_dest_root "$DEFAULT_CODEX_ROOT"
      [[ -n "${CLAUDE_SKILLS_DIR:-}" || -d "$HOME/.claude" ]] && add_dest_root "$DEFAULT_CLAUDE_ROOT"
      if [[ ${#DEST_ROOTS[@]} -eq 0 ]]; then
        add_dest_root "$DEFAULT_CODEX_ROOT"
        add_dest_root "$DEFAULT_CLAUDE_ROOT"
      fi
      ;;
    codex)
      add_dest_root "$DEFAULT_CODEX_ROOT"
      ;;
    claude)
      add_dest_root "$DEFAULT_CLAUDE_ROOT"
      ;;
    both)
      add_dest_root "$DEFAULT_CODEX_ROOT"
      add_dest_root "$DEFAULT_CLAUDE_ROOT"
      ;;
    *)
      echo "error: invalid --target '$TARGET' (expected auto, codex, claude, or both)" >&2
      exit 2
      ;;
  esac
fi

fetch_to() {
  local src_name="$1"
  local dest_path="$2"
  if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/$src_name" ]]; then
    if (( DRY_RUN )); then
      echo "DRY: cp $SCRIPT_DIR/$src_name -> $dest_path"
    else
      cp "$SCRIPT_DIR/$src_name" "$dest_path"
    fi
    return 0
  fi
  if (( DRY_RUN )); then
    echo "DRY: curl $GIST_RAW_BASE/$src_name -> $dest_path"
  else
    curl -fsSL "$GIST_RAW_BASE/$src_name" -o "$dest_path"
  fi
}

for root in "${DEST_ROOTS[@]}"; do
  for name in "${SKILLS[@]}"; do
    dest_dir="$root/$name"
    dest_file="$dest_dir/SKILL.md"
    if (( DRY_RUN )); then
      echo "DRY: mkdir -p $dest_dir"
    else
      mkdir -p "$dest_dir"
    fi
    fetch_to "SKILL_${name}.md" "$dest_file"
    echo "installed: $dest_file"
  done
done

echo
echo "Done. Installed roots:"
for root in "${DEST_ROOTS[@]}"; do
  echo "- $root"
done
