---
name: claude-code-claudemd-symlink-write-refused
description: |
  Fix the Edit/Write tool refusal `Refusing to write through symlink:
  /Users/<user>/.claude/CLAUDE.md. Resolve the symlink and pass the
  real target path explicitly.` Use when: (1) editing the user's
  global Claude Code CLAUDE.md fails with that exact error string,
  (2) any Edit/Write call against a path where Claude Code detects
  a symlink and refuses, (3) you're about to edit a file under
  ~/.claude/ and unsure whether it's a symlink to a real repo
  (common pattern: ~/.claude/CLAUDE.md → some checked-in dotfiles
  repo so the global prompt is versioned). The fix is to resolve
  the symlink with `readlink -f` once and edit the real target —
  not to follow the symlink with cp/mv/sudo or to disable the
  refusal. Also explains why the refusal exists: editing through
  a symlink can silently bypass version control or write to a
  shared file the user didn't intend to modify.
author: Claude Code
version: 1.0.0
date: 2026-05-19
---

# CLAUDE.md (or other ~/.claude/* files) is a symlink — Edit/Write refuses

## Problem

Calling Edit or Write on a path that is a symlink returns:

```
Refusing to write through symlink: /Users/<user>/.claude/CLAUDE.md.
Resolve the symlink and pass the real target path explicitly.
```

The tool refuses by design to prevent silently writing through a
symlink — which could bypass version control, hit a shared file the
user didn't intend to modify, or skip a checked-in dotfiles repo.

## Context / Trigger Conditions

- Editing global `~/.claude/CLAUDE.md` and hitting the refusal
- Editing any `~/.claude/skills/<name>/SKILL.md` from a synced
  skills repo (e.g. via the `skillz` installer pattern)
- Editing any `~/.claude/settings.json`, `.claude.json`, or other
  config file that might be a symlink to a dotfiles repo
- The user's bash_profile mentions a dotfiles / skillz repo and
  their `~/.claude/` looks like a sync target

## Solution

Resolve the symlink once, then edit the real file.

```bash
readlink -f ~/.claude/CLAUDE.md
# → /Users/<user>/repos/prompts/base-prompt.md   (real target)
```

Then pass the resolved path to Edit/Write/Read.

Common real-target patterns:
- `~/.claude/CLAUDE.md` → `~/repos/prompts/base-prompt.md` (a prompt repo)
- `~/.claude/skills/<skill>/SKILL.md` → `~/repos/skillz/skills/<skill>/SKILL.md`
- `~/.claude/settings.json` → `~/dotfiles/claude/settings.json`

## Verification

After resolving:
```bash
ls -la <resolved-path>     # confirm not also a symlink (chained symlinks possible)
```

Then Read tool on the resolved path succeeds; Edit proceeds.

## Example

```
Edit tool call: file_path=/Users/<user>/.claude/CLAUDE.md
→ Error: Refusing to write through symlink: /Users/<user>/.claude/CLAUDE.md.
  Resolve the symlink and pass the real target path explicitly.

readlink -f ~/.claude/CLAUDE.md
→ /Users/<user>/repos/prompts/base-prompt.md

Read /Users/<user>/repos/prompts/base-prompt.md   # works
Edit  /Users/<user>/repos/prompts/base-prompt.md  # works
```

Next session change to global prompt: edit `~/repos/prompts/base-prompt.md`
directly, not `~/.claude/CLAUDE.md`.

## Notes

- Don't `chmod`, `cp -L`, or `sudo` around the refusal — those silently
  break the user's intent (version control bypass, lost edits on next
  sync, etc.). Just edit the real target.
- `readlink -f` on macOS works on coreutils 8+. On stock BSD `readlink`
  (no `-f`), use `readlink ~/.claude/CLAUDE.md` (returns one level)
  and chase manually, or install GNU coreutils via brew.
- After editing the real target, the symlink reflects the change
  immediately (it's the same inode-resolved file). No sync step needed.
- If the symlink points into a git repo, **commit the change there** —
  don't leave it as dirty working tree; the user's dotfiles workflow
  may auto-sync and either reset or push uncommitted edits.

## Related

- [[claude-code-piebald-lsp-binary-on-path]] — different but adjacent:
  another "Claude Code config layer routes elsewhere than you'd guess"
  trap.
