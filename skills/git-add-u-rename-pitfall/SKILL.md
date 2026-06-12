---
name: git-add-u-rename-pitfall
description: |
  Fix CI compile failures after renaming Java files when git add -u misses the new file path.
  Use when: (1) CI fails with "cannot find symbol" but compiles locally, (2) file was
  renamed with mv command, (3) git add -u was used to stage changes. Root cause: git add -u
  only stages modifications and deletions of tracked files, not new untracked paths from renames.
  The renamed file exists on disk (local compile works) but isn't in git (CI checkout misses it).
author: Claude Code
version: 1.0.0
date: 2026-03-24
---

# git add -u Doesn't Track File Renames

## Problem
After renaming a file with `mv`, `git add -u` stages the deletion of the old path but
does NOT stage the new path (it's untracked). The file compiles locally because it exists
on disk, but CI fails because the file isn't committed.

## Context / Trigger Conditions
- CI compile fails with "cannot find symbol" for a class you just renamed
- `git status` shows the new file as "untracked"
- Local build works perfectly
- You used `mv old.java new.java` then `git add -u`

## Solution
After renaming, explicitly add the new file:

```bash
mv OldName.java NewName.java
git add -u                    # stages deletion of OldName.java
git add NewName.java          # stages creation of NewName.java
```

Or use `git mv` which handles both in one step:

```bash
git mv OldName.java NewName.java
```

## Verification
```bash
git status   # should show "renamed: OldName.java -> NewName.java"
```

## Notes
- `git add -u` is documented as "Update the index just where it already has an entry
  matching <pathspec>" — new paths don't match any existing entry
- This is especially dangerous because local builds succeed (the file is on disk),
  making the CI failure surprising
- Always verify with `git ls-files | grep NewName` after staging renames
