---
name: claude-code-el-macos-home-trust-exit1
description: |
  Fix `M-x claude-code` (claude-code.el on Emacs) dying with
  `Process claude:~/:default exited abnormally with code 1` right after the
  "Quick safety check: Is this a project you created or one you trust?" /
  "Yes, I trust this folder" prompt renders. Use when: (1) claude-code.el opens
  an eat/vterm buffer, shows Claude Code's trust dialog for your HOME dir
  (`/Users/<you>`), then exits code 1 before you can answer, (2) the same
  `claude` CLI runs fine in a terminal (or via cmux) but breaks from Emacs,
  (3) you want `M-x claude-code` to start without the trust prompt. Root cause:
  claude-code.el launches bare `claude` in `default-directory`, which is HOME
  when the buffer is not inside a project; HOME has
  `hasTrustDialogAccepted=false` in `~/.claude.json`, so Claude renders the
  interactive trust dialog, which does not survive in the eat-launched pty and
  exits 1. Fix: pre-trust the directory in `~/.claude.json` (or launch in an
  already-trusted project). Also covers restoring Emacs buffers after a reboot
  with `desktop-save-mode`.
author: Claude Code
version: 1.0.0
date: 2026-06-17
---

# claude-code.el: HOME trust prompt -> "exited abnormally with code 1"

## Problem

`M-x claude-code` opens its terminal buffer (named `*claude:~/:default*`),
prints Claude Code's workspace trust prompt for your HOME directory:

```
Accessing workspace:
/Users/<you>
Quick safety check: Is this a project you created or one you trust? ...
  1. Yes, I trust this folder
  2.
Enter to confirm * Esc to cancel
Process claude:~/:default exited abnormally with code 1
```

The dialog renders dim/greyed and the process is already dead — pressing `1`
does nothing. The `claude` CLI works fine in Terminal/iTerm or under cmux.

## Root cause

- claude-code.el runs bare `claude` (`claude-code-program` = `"claude"`, no
  switches) in `default-directory`. With no project open (`project-current`
  returns nil — fresh Emacs, `*scratch*`, no file visited) `default-directory`
  is your HOME `~/`. The `claude:~/:default` instance name shows it ran in `~`.
- In `~/.claude.json`, `projects["/Users/<you>"].hasTrustDialogAccepted` is
  `false`, so Claude must show the interactive "trust this folder" dialog.
- That interactive raw-keyboard dialog does not survive in the pty that
  claude-code.el spawns via eat, so Claude exits with code 1 before the menu
  is answerable.
- CLI sessions in HOME work only because they were started with a trust bypass
  (e.g. the cmux launcher / a `--dangerously-skip-permissions` path), not the
  plain binary Emacs execs.

So the fix is to make the launch directory **already trusted** so the dialog
never appears.

## Fix A (chosen): pre-trust the directory in ~/.claude.json

Trust state lives only in `~/.claude.json` under
`projects.<abs-dir>.hasTrustDialogAccepted`. Flip it to `true` for the dir you
launch in (here, HOME). Back up and write atomically — the file is large
(hundreds of KB) and is rewritten live by running sessions:

```bash
python3 - <<'PY'
import json, os, shutil, tempfile
p = os.path.expanduser("~/.claude.json")
d = os.path.expanduser("~")                 # the dir to trust (HOME here)
shutil.copy2(p, p + ".bak-pretrust")
data = json.load(open(p))
data["projects"][d]["hasTrustDialogAccepted"] = True
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p), prefix=".claude.json.", suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, p)                          # atomic on same filesystem
print("trusted:", d, "->", json.load(open(p))["projects"][d]["hasTrustDialogAccepted"])
PY
```

If the dir is not yet a key under `projects`, create it:
`data["projects"].setdefault(d, {})["hasTrustDialogAccepted"] = True`.

`M-x claude-code` now starts immediately in that dir — no prompt, no exit.

### Clobber caveat

A **running** Claude Code session whose cwd equals the trusted dir may rewrite
`~/.claude.json` on exit and can revert `hasTrustDialogAccepted` to the value it
read at startup. Apply the edit when no such session is active, or just re-run
the one-liner afterward. Verify it stuck:

```bash
python3 -c "import json,os;p=os.path.expanduser('~/.claude.json');d=os.path.expanduser('~');print(json.load(open(p))['projects'][d]['hasTrustDialogAccepted'])"
```

### Security note

Trusting HOME is broad: Claude then gets read/edit/exec across everything under
`~` with no prompt. That is fine if you already run Claude in HOME anyway
(matches a cmux session that runs there). If you want a narrower blast radius,
prefer Fix B.

## Fix B (narrower): launch in an already-trusted project, never HOME

Leave HOME untrusted and start claude-code where a project is already trusted,
so no dialog appears:

- `C-u C-u M-x claude-code` -> prompts for a project directory; pick a repo
  (e.g. `~/g/git.clickagy/<repo>`), answer "1. Yes, I trust this folder" once.
- Or open any file inside the target repo first (`C-x C-f .../repo/file`) so
  `default-directory` is the project root (project.el finds it via VCS), then
  `M-x claude-code`.

## Bonus: restore Emacs buffers + layout after a reboot

Unrelated to the trust bug, but commonly wanted alongside it. Add to
`~/.emacs.d/init.el`:

```elisp
;; Restore previous session's buffers and window layout after restart/reboot.
(setq desktop-save t                     ; save on exit without asking
      desktop-load-locked-desktop t      ; load even if a stale lock exists (post-reboot)
      desktop-restore-frames t)          ; restore frame/window layout too
(desktop-save-mode 1)
```

Caveat: `desktop-save-mode` restores file-visiting buffers (and a few others)
plus the window layout. It cannot restore **live process buffers** — eat/vterm
Claude Code terminals, shells, comint — because their subprocesses are gone
after a reboot. Those buffers simply won't reappear; re-run `M-x claude-code`.

## Verification

- `python3 -c "...hasTrustDialogAccepted"` (above) prints `True` for the dir.
- Launch GUI Emacs, `M-x claude-code` (or `C-c c c`): a session starts in the
  dir with no trust prompt and no immediate exit.
- For the buffer-restore: `emacs --batch -Q` reader check that init.el parses,
  then restart Emacs and confirm file buffers + layout return.

## Related

- `emacs-batch-package-verify-pitfalls` — verifying the claude-code.el / eat
  install non-interactively without false negatives.

## References

- claude-code.el: https://github.com/stevemolitor/claude-code.el
- Claude Code trust state: `~/.claude.json` `projects.<dir>.hasTrustDialogAccepted`
- Emacs `desktop-save-mode` (`desktop-save`, `desktop-load-locked-desktop`,
  `desktop-restore-frames`).
