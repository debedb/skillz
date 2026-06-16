---
name: macos-bash-3.2-compat
description: |
  Fix bash scripts that fail on macOS with errors like `declare: -A: invalid option`,
  `mapfile: command not found`, or unrecognized parameter expansions. Use when:
  (1) a script written for Linux (bash 4+) fails on macOS /bin/bash,
  (2) the script is sourced from ~/.bash_profile or invoked via `#!/bin/bash`
  shebang and cannot be silently switched to a newer bash,
  (3) `bash --version` on macOS shows 3.2.57. Provides concrete rewrites for the
  most common bash-4-only constructs.
author: Claude Code
version: 1.0.0
date: 2026-04-29
---

# macOS bash 3.2 compatibility

## Problem

macOS ships `/bin/bash` as version 3.2.57 (frozen since 2007 due to Apple's
GPLv3 avoidance). Scripts written for modern Linux distros routinely use
bash 4.0+ features and fail with cryptic errors when run under `/bin/bash`,
even when a newer bash is also installed via Homebrew.

The trap is worst when:
- The script has `#!/bin/bash` (forces 3.2 even if `/opt/homebrew/bin/bash` exists)
- The script is sourced from `~/.bash_profile` (sourcing inherits the parent
  shell, which on macOS Terminal is `/bin/bash` 3.2)
- The user has no Homebrew bash at all

## Trigger conditions

Any of these errors when running a bash script on macOS:

- `declare: -A: invalid option` — associative arrays
- `declare: -n: invalid option` — nameref variables
- `mapfile: command not found` / `readarray: command not found`
- `${var,,}` / `${var^^}` parsed as literal — case modification
- `${var@Q}` / `${var@E}` parsed as literal — parameter transformation
- `&>>` not recognized — append-both-streams redirection
- Globstar `**` not expanding recursively even with `shopt -s globstar`
- `coproc` not recognized
- `wait -n` not recognized

Confirm bash version: `/bin/bash --version | head -1` should show `3.2.57`.

## Solution

**First, decide the strategy.** Two options:

### Option A: Switch to a newer bash (when feasible)

- Install: `brew install bash` (puts `bash` 5.x in `/opt/homebrew/bin/bash`
  on Apple Silicon, `/usr/local/bin/bash` on Intel).
- Change shebang to `#!/usr/bin/env bash`.
- Verify with `head -1 script.sh` and `bash --version`.

**Don't pick this if:** the script is sourced from `~/.bash_profile`, runs
on machines where you can't install Homebrew, or must stay portable.

### Option B: Rewrite to bash 3.2 portable (when Option A isn't feasible)

Concrete rewrites for the most common offenders:

#### `declare -A` (associative arrays) → key=value temp file

```bash
# BEFORE (bash 4+):
declare -A env_vars
env_vars["FOO"]="bar"
for key in "${!env_vars[@]}"; do
    echo "$key=${env_vars[$key]}"
done

# AFTER (bash 3.2 portable):
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
printf '%s=%s\n' "FOO" "bar" >> "$TMP"
while IFS='=' read -r key value; do
    echo "$key=$value"
done < "$TMP"

# Count: $(wc -l < "$TMP" | tr -d ' ')   # replaces ${#env_vars[@]}
```

This is the cleanest rewrite when keys are well-behaved (no `=` in keys, no
embedded newlines in values). For ill-behaved values, use NUL-delimited
records or two parallel indexed arrays instead.

#### `mapfile` / `readarray` → `while read` loop

```bash
# BEFORE:
mapfile -t lines < file.txt

# AFTER:
lines=()
while IFS= read -r line; do
    lines+=("$line")
done < file.txt
```

#### `${var,,}` / `${var^^}` (case) → `tr`

```bash
# BEFORE: lower="${var,,}"
# AFTER:  lower="$(printf '%s' "$var" | tr '[:upper:]' '[:lower:]')"
```

#### `&>>` → explicit redirection

```bash
# BEFORE: cmd &>> log.txt
# AFTER:  cmd >> log.txt 2>&1
```

#### `wait -n` → `wait` for specific PIDs

Track PIDs in an array and wait on each in turn; bash 3.2 has no "wait for
the next one to finish" primitive.

## Verification

After rewriting, force the 3.2 path and re-run:

```bash
/bin/bash ./script.sh --dry-run     # if the script supports it
/bin/bash -n ./script.sh            # syntax-only check
```

`-n` parses without executing, which catches `declare -A` and similar
bash-4-only syntax that 3.2 rejects at parse time.

## Notes

- `set -euo pipefail` works fine on bash 3.2 — it's not a 4.x feature.
- Indexed arrays (`arr=(...)`, `${arr[@]}`, `${#arr[@]}`) work fine on 3.2.
- Process substitution `<(...)` works on 3.2.
- `[[ ... =~ ... ]]` works on 3.2 (the regex engine is older but functional).
- The `IFS='=' read -r key value` idiom never puts `=` into `key` — bash
  splits on the *first* delimiter only — so guards like `[[ "$key" =~ = ]]`
  after such a read are dead code.
- macOS `/bin/sh` is also bash in POSIX mode, so the same constraints apply
  if you change the shebang to `#!/bin/sh`.

## References

- [Bash CHANGES — when each feature landed](https://git.savannah.gnu.org/cgit/bash.git/tree/CHANGES)
- [Apple's bash freeze rationale (GPLv3 avoidance)](https://en.wikipedia.org/wiki/Bash_(Unix_shell)#macOS)
- `man bash` on macOS — section "BASH BUILTIN COMMANDS" → `declare`
