---
name: emacs-batch-package-verify-pitfalls
description: |
  Avoid false-negative failures when verifying an Emacs package install with
  `emacs --batch`. Use when: (1) you installed a package (package.el, use-package
  :ensure, or :vc / package-vc-install) and a batch `(require 'PKG)` fails with
  "Cannot open load file" / file-missing even though the package dir exists under
  ~/.emacs.d/elpa/, (2) a batch check of a variable that a `use-package` :config
  block sets returns "Symbol's value as variable is void" / void-variable,
  (3) you want to confirm an Emacs package actually loads without launching the
  interactive GUI. Root causes: `--batch` does NOT auto-activate installed ELPA
  packages onto load-path (interactive startup does), and `use-package` defers
  loading (so :config never runs) when :bind-keymap / :bind / :commands / :defer
  is present. Neither symptom means the install is broken.
author: Claude Code
version: 1.0.0
date: 2026-05-26
---

# Verifying Emacs Package Installs via --batch: Misleading Failures

## Problem

You install an Emacs package and try to confirm it loads using
`emacs --batch -l ~/.emacs.d/init.el --eval '(require 'PKG)'` (or by checking a
variable the package defines). The batch run reports a failure, but the package
is actually installed correctly and works fine in interactive Emacs. Two distinct
batch-only artifacts cause this.

## Context / Trigger Conditions

- Package directory exists (e.g. `~/.emacs.d/elpa/claude-code/`, `eat-0.9.4/`)
  but batch `(require 'PKG)` errors:
  `Cannot open load file: No such file or directory, PKG` (file-missing).
- A `defcustom`/variable that a `use-package` `:config` form sets reads back as
  `Symbol's value as variable is void: PKG-some-var` (void-variable) in batch.
- The package works correctly once you actually start the GUI Emacs.
- Installing via `package-vc-install`, `use-package ... :vc`, `:straight`, or
  plain `package-install`.

## Root Causes

### 1. `--batch` does not auto-activate installed packages

Interactive Emacs startup calls `package-activate-all` (package autoload +
load-path setup) automatically *before* loading `init.el`. `emacs --batch` does
NOT do this. So even with packages installed on disk, their directories are not
on `load-path` in a batch session, and `(require 'PKG)` fails.

Note the asymmetry that makes this confusing: a *first* batch run that processes
a `use-package ... :ensure`/`:vc` form WILL install the package (install adds it
to load-path mid-session as a side effect), so the install "works." But a
*second* batch run that only tries to `(require 'PKG)` fails, because nothing
re-activated it. The install was fine; activation was missing.

Fix: explicitly activate before requiring.

```elisp
emacs --batch \
  --eval '(progn (require (quote package)) (package-initialize) (require (quote PKG)))'
```

### 2. `use-package` defers load, so `:config` never runs in batch

`:bind-keymap`, `:bind`, `:commands`, `:hook`, and `:defer t` all make
`use-package` defer loading the package until the trigger fires (a keypress,
autoloaded command call, hook, etc.). The `:config` block runs only *after* the
package loads. In a non-interactive batch session no trigger ever fires, so
`:config` never runs. Any `(setq PKG-var ...)` inside `:config` therefore did not
execute, and reading `PKG-var` yields void-variable.

This is NOT an install failure and NOT a config error. To test the variable,
force the load (which is what the interactive trigger would have done):

```elisp
(progn (require 'package) (package-initialize) (require 'PKG)
       (boundp 'PKG-the-var))   ; t once the feature is actually loaded
```

In real interactive use, `M-x THE-COMMAND` (autoloaded) or pressing the
`:bind-keymap` prefix loads the package and runs `:config` normally.

## Solution / Reliable Batch Verification Recipe

Do not load `init.el` for the check (it may trigger `package-refresh-contents`
and network). Activate packages, force-load the feature, assert what you care
about, and print with `princ` (not `message`, which a thrown error can swallow):

```elisp
emacs --batch \
  --eval '(progn
            (require (quote package))
            (package-initialize)
            (require (quote PKG))
            (princ (format "cmd=%s var-bound=%s dep=%s\n"
                           (commandp (quote PKG-main-command))
                           (boundp (quote PKG-some-defcustom))
                           (featurep (quote PKG-dependency)))))' 2>&1 \
  | grep -E "cmd=|Error|error:"
```

`cmd=t var-bound=t dep=t` means the package is installed, on load-path, loads
cleanly, and its commands/customs exist.

## Verification

Empirically confirmed (Emacs 30.1, installing `claude-code.el` 0.4.5 via
`use-package ... :vc` with `:bind-keymap`, eat backend):

- Batch `(require 'claude-code)` without `package-initialize` ->
  `file-missing "Cannot open load file ... claude-code"` despite
  `~/.emacs.d/elpa/claude-code/` existing.
- Reading `claude-code-terminal-backend` (set in `:config`) in batch ->
  `void-variable` because `:bind-keymap` deferred the load.
- After `(package-initialize)` + `(require 'claude-code)`:
  `cmd=t backend-bound=t eat=t` — all green. Interactive `M-x claude-code`
  works regardless, because GUI startup auto-activates and the autoloaded
  command triggers the deferred load + `:config`.

## Notes

- The same two artifacts apply to any package manager that relies on startup
  activation (package.el, package-vc, straight via its bootstrap) and to any
  deferred `use-package` keyword, not just `:bind-keymap`.
- If you genuinely need `:config` side effects under batch (rare), add
  `:demand t` to force eager load — but prefer the explicit `(require ...)` in
  the verification eval instead of changing config just to test it.
- Separate, well-documented macOS gotcha (not covered here because
  `exec-path-from-shell` and osx-env-sync already solve it): Emacs.app launched
  from Spotlight/Finder inherits the `launchctl` PATH, not your interactive
  shell PATH. Packages that shell out to a CLI need that CLI's dir on the
  launchd PATH; check with `launchctl getenv PATH`.

## References

- Emacs manual, Package Installation / `package-initialize` and
  `package-activate-all` (startup activation behavior).
- `use-package` README — deferred loading via `:bind`, `:bind-keymap`,
  `:commands`, `:hook`, `:defer`, and the role of `:config` vs `:init`.
