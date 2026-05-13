#!/usr/bin/env bash
# Install Claude Code skills from this gist into ~/.claude/skills/<name>/SKILL.md.
#
# Usage:
#   bash <(curl -sL https://gist.githubusercontent.com/<USER>/<GIST_ID>/raw/install.sh)
#
# Or, having already cloned the gist:
#   git clone https://gist.github.com/<USER>/<GIST_ID>.git && cd <hash> && ./install.sh
#
# Idempotent: re-running overwrites existing SKILL.md with the gist version.
# Pass --dry-run to print what would happen without writing.

set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

SKILLS=(
  "work-on-pr"
  "review-pr-loop"
)

DEST_ROOT="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"

# Resolve the directory this script lives in. Works whether invoked via
# `bash <(curl ...)` (script is a fifo, no useful dir) or from a local
# clone. When the script has no resolvable dir, fetch each file via raw URL.
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# When run via process substitution we need a raw URL base. The gist's raw
# URL is identical across files; the installer string-replaces the install.sh
# segment with the target filename. If GIST_RAW_BASE is provided, use it
# directly; otherwise try to recover from the script path.
GIST_RAW_BASE="${GIST_RAW_BASE:-https://gist.githubusercontent.com/debedb/5f606018eb36a75dc292016268f08e7c/raw}"

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
  if [[ -z "$GIST_RAW_BASE" ]]; then
    echo "error: cannot locate $src_name. Either run from a clone of the gist or set GIST_RAW_BASE to https://gist.githubusercontent.com/<USER>/<GIST_ID>/raw" >&2
    return 1
  fi
  if (( DRY_RUN )); then
    echo "DRY: curl $GIST_RAW_BASE/$src_name -> $dest_path"
  else
    curl -fsSL "$GIST_RAW_BASE/$src_name" -o "$dest_path"
  fi
}

for name in "${SKILLS[@]}"; do
  dest_dir="$DEST_ROOT/$name"
  dest_file="$dest_dir/SKILL.md"
  if (( DRY_RUN )); then
    echo "DRY: mkdir -p $dest_dir"
  else
    mkdir -p "$dest_dir"
  fi
  fetch_to "SKILL_${name}.md" "$dest_file"
  echo "installed: $dest_file"
done

echo
echo "Done. Restart Claude Code (or run /reload-plugins) so the new skills are indexed."
