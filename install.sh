#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=0
TARGET="auto"
declare -a REQ_SKILLS=()
declare -a REQ_COLLECTIONS=()
INSTALL_ALL=0

usage() {
  cat <<'EOF'
Install skills from the skillz catalog into Codex, Claude Code, or both.

Usage:
  install.sh [--target auto|codex|claude|both]
             [--skill NAME]... [--collection NAME]... [--all]
             [--dry-run]

  No selection flags  => install the default collection (pr-loop).

Flags:
  --skill NAME        Install a single skill by name. Repeatable.
  --collection NAME   Install every skill in a collection. Repeatable.
  --all               Install every skill in the catalog.
  --target ...        auto (default), codex, claude, or both.
  --dry-run           Print actions, do not touch the filesystem.
  -h, --help          Show this help.

Environment:
  SKILLS_DEST_ROOT   Install into exactly this root and ignore --target.
  CODEX_HOME         Used for the Codex root (defaults to ~/.codex).
  CLAUDE_SKILLS_DIR  Used for the Claude root (defaults to ~/.claude/skills).
  SKILLZ_RAW_BASE    Override the raw repo base URL.
  GIST_RAW_BASE      Deprecated alias for SKILLZ_RAW_BASE.
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
    --skill)
      if (($# < 2)); then
        echo "error: --skill requires a value" >&2
        exit 2
      fi
      REQ_SKILLS+=("$2")
      shift
      ;;
    --collection)
      if (($# < 2)); then
        echo "error: --collection requires a value" >&2
        exit 2
      fi
      REQ_COLLECTIONS+=("$2")
      shift
      ;;
    --all)
      INSTALL_ALL=1
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
SKILLZ_RAW_BASE="${SKILLZ_RAW_BASE:-${GIST_RAW_BASE:-https://raw.githubusercontent.com/debedb/skillz/master}}"
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

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to parse the catalog manifest" >&2
  exit 2
fi

CATALOG_JSON=""
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/catalog.json" ]]; then
  CATALOG_JSON="$(cat "$SCRIPT_DIR/catalog.json")"
else
  CATALOG_JSON="$(curl -fsSL "$SKILLZ_RAW_BASE/catalog.json")"
fi

resolve_skills() {
  CATALOG="$CATALOG_JSON" \
  REQ_S="$(printf '%s\n' "${REQ_SKILLS[@]:-}")" \
  REQ_C="$(printf '%s\n' "${REQ_COLLECTIONS[@]:-}")" \
  ALL="$1" \
    python3 <<'PY'
import json, os, sys

catalog = json.loads(os.environ["CATALOG"])
req_s = [s for s in os.environ.get("REQ_S", "").splitlines() if s.strip()]
req_c = [c for c in os.environ.get("REQ_C", "").splitlines() if c.strip()]
all_flag = os.environ.get("ALL") == "1"

skills_by_name = {s["name"]: s for s in catalog.get("skills", [])}
colls_by_name  = {c["name"]: c for c in catalog.get("collections", [])}
default_coll   = catalog.get("defaults", {}).get("no_arg_install", "")

selected = []
seen = set()

def add(name):
    if name not in skills_by_name:
        print(f"error: unknown skill '{name}'", file=sys.stderr); sys.exit(3)
    if name in seen:
        return
    seen.add(name); selected.append(skills_by_name[name])

if all_flag:
    for n in skills_by_name:
        add(n)
else:
    if not req_s and not req_c:
        if default_coll and default_coll in colls_by_name:
            req_c = [default_coll]
        else:
            print("error: no selection and no default collection configured", file=sys.stderr)
            sys.exit(3)
    for c in req_c:
        if c not in colls_by_name:
            print(f"error: unknown collection '{c}'", file=sys.stderr); sys.exit(3)
        for n in colls_by_name[c].get("skills", []):
            add(n)
    for n in req_s:
        add(n)

for s in selected:
    print(f'{s["name"]}\t{s["path"]}')
PY
}

SKILL_LINES=()
while IFS= read -r _line; do
  [[ -n "$_line" ]] || continue
  SKILL_LINES+=("$_line")
done < <(resolve_skills "$INSTALL_ALL")

if [[ ${#SKILL_LINES[@]} -eq 0 ]]; then
  echo "error: no skills resolved from selection" >&2
  exit 3
fi

fetch_to() {
  local src_rel="$1"
  local dest_path="$2"
  if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/$src_rel" ]]; then
    if (( DRY_RUN )); then
      echo "DRY: cp $SCRIPT_DIR/$src_rel -> $dest_path"
    else
      cp "$SCRIPT_DIR/$src_rel" "$dest_path"
    fi
    return 0
  fi
  if (( DRY_RUN )); then
    echo "DRY: curl $SKILLZ_RAW_BASE/$src_rel -> $dest_path"
  else
    curl -fsSL "$SKILLZ_RAW_BASE/$src_rel" -o "$dest_path"
  fi
}

for root in "${DEST_ROOTS[@]}"; do
  for line in "${SKILL_LINES[@]}"; do
    name="${line%%$'\t'*}"
    src_path="${line#*$'\t'}"
    dest_dir="$root/$name"
    dest_file="$dest_dir/SKILL.md"
    if (( DRY_RUN )); then
      echo "DRY: mkdir -p $dest_dir"
    else
      mkdir -p "$dest_dir"
    fi
    fetch_to "$src_path" "$dest_file"
    echo "installed: $dest_file"
  done
done

echo
echo "Done. Installed roots:"
for root in "${DEST_ROOTS[@]}"; do
  echo "- $root"
done
