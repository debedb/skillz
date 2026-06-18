---
name: claude-code-plugin-update-flow
description: |
  Correctly update an installed Claude Code plugin from its remote
  marketplace. Use when: (1) `/plugin update <plugin>@<marketplace>`
  opens the plugin-discovery picker instead of updating the plugin,
  (2) you ran `/plugin marketplace update <name>` but the running
  session is still on the old plugin code, (3) you're not sure
  whether `/plugin update`, `/reload-plugins`, or a session restart
  is needed. Root cause: in many Claude Code versions there is no
  `/plugin update <plugin>@<marketplace>` subcommand — it falls
  through to the discovery picker. The actual upgrade flow is
  `/plugin marketplace update <name>` + `/reload-plugins` (or session
  restart).
author: Claude Code
version: 1.0.0
date: 2026-05-11
---

# Claude Code: Updating an Installed Plugin

## Problem

You installed a plugin via
`/plugin marketplace add OWNER/REPO` + `/plugin install NAME@MARKETPLACE`.
Now the upstream repo has new commits and you want them in your running
Claude Code session. You type `/plugin update NAME@MARKETPLACE` and
Claude Code opens the plugin-discovery picker — a list of public
plugins — instead of updating anything.

Or you ran `/plugin marketplace update NAME` and got
"✔ Updated 1 marketplace", but your session's hooks / commands /
skills still behave like the old version.

## Context / Trigger Conditions

- You installed a CC plugin from a GitHub marketplace.
- You ran `/plugin update <plugin>@<marketplace>` expecting an upgrade.
- Instead: the discovery picker showed up
  (`Discover plugins (1/N) / Search...`).
- Or: you ran `/plugin marketplace update <name>`, the marketplace
  refresh succeeded, but your running session didn't pick up the new
  code (old hook still firing, old slash commands still listed).

## Solution

```
/plugin marketplace update <marketplace-name>
/reload-plugins
```

The two-step is the reliable upgrade path. The first command pulls
the latest code into your local marketplace clone (typically under
`~/.claude/plugins/marketplaces/<name>/`). The second reloads all
installed plugins from the local marketplace clones into the running
session.

If `/reload-plugins` isn't available or doesn't fully pick up the
change (some plugin updates require an environment reset), restart
the Claude Code session.

### Why `/plugin update` doesn't work

Some Claude Code versions don't have a `/plugin update` subcommand at
all. Typing `/plugin update <anything>` falls through the slash-command
matcher and lands on the default behavior, which is the discovery
picker. The picker is for *installing* plugins from a list; it's not
the update flow.

### How to verify the upgrade landed

```bash
# Check that the marketplace clone is at the expected commit:
git -C ~/.claude/plugins/marketplaces/<marketplace>/ --no-pager log --oneline -1

# Check that a file from the new version is present:
ls ~/.claude/plugins/marketplaces/<marketplace>/<expected-new-file>
```

If `git log` shows the new tip but your session still acts old, you
ran `marketplace update` but skipped `/reload-plugins` / didn't
restart.

## Verification

After running the two-step:

1. `git -C ~/.claude/plugins/marketplaces/<marketplace>/ rev-parse HEAD`
   matches the upstream `origin/<default-branch>` tip.
2. New hooks fire / new slash commands appear in `/help`.
3. Any session-cached old behavior is gone.

## Notes

- `/plugin marketplace update <name>` is a `git pull` on the
  marketplace clone. If you've edited files in
  `~/.claude/plugins/marketplaces/<name>/` locally (you shouldn't!),
  the pull may fail or merge unexpectedly.
- For plugins distributed across multiple marketplaces (rare), each
  marketplace clone has its own `git` history and needs its own
  `marketplace update`.
- The "discovery picker" surfacing is a UX symptom; nothing actually
  broke. Just hit Escape and run the right command.
- If the plugin you wrote has a `pre-tool-use.sh` or similar wrapper
  that caches state (e.g., a bootstrap-deps marker), the new code
  may need to invalidate that cache — content-hash the cache key on
  the relevant file (e.g., `requirements.txt`) so a dep bump
  re-bootstraps automatically.

## Example

A plugin hit this during dogfood: `/plugin update <plugin>@<marketplace>`
opened the picker. Once the developer realized the subcommand didn't exist,
the correct flow was documented in the README's "Updating" section:

> `/plugin marketplace update <marketplace>` pulls the latest code into
> your local marketplace clone. Then either `/reload-plugins` or
> restart Claude Code so the running session picks up the new code.

## References

- [Claude Code plugins](https://code.claude.com/docs/en/plugins)
