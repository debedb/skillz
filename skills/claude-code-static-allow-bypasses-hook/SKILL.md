---
name: claude-code-static-allow-bypasses-hook
description: |
  Diagnose a Claude Code PreToolUse hook (especially Bash) that "never
  fires" for certain commands while firing fine for others. Use when:
  (1) your PreToolUse hook works in unit tests but doesn't run in a
  real CC session for some Bash commands, (2) some commands auto-allow
  with no hook log line / no hook-emitted reason in the UI, (3) you're
  designing a hook and want to know why your decisions are sometimes
  ignored. Root cause: static `Bash(<glob>)` entries in
  `~/.claude/settings.json#permissions.allow` short-circuit the
  PreToolUse hook entirely — the outer matcher decides before the hook
  is invoked. Covers: how to verify the hook is firing, how to QA the
  hook deterministically despite the short-circuit, and command shapes
  that categorically force the hook to run.
author: Claude Code
version: 1.0.0
date: 2026-05-11
---

# Claude Code: Static `permissions.allow` Rules Bypass PreToolUse Hooks

## Problem

Your `PreToolUse` hook on `Bash` (or any tool) is registered, works in
unit tests via piped JSON payloads, but in a real Claude Code session
it's invisible for some commands. The user runs `aws ec2 describe-instances`
and the agent gets a green light with no "YOLT:" / your-hook-prefix
showing in the UI's decision reason. Yet `rm -rf /tmp/foo` correctly
goes through your hook and asks for confirmation.

You're not crazy. Some commands route around your hook entirely.

## Context / Trigger Conditions

- You have a `PreToolUse` hook registered (via plugin `hooks.json` or
  manual `settings.json` block).
- The hook unit tests pass: piping a hook payload to your entry
  produces the expected decision JSON.
- In real CC sessions, the hook fires for some commands but not
  others.
- The "missing" commands tend to have a common shape: simple,
  single-token invocations like `aws ec2 describe-instances`,
  `gh pr list`, `git status`.
- The user has a `~/.claude/settings.json` (or project-scoped
  `settings.json`) with `permissions.allow` entries.

## Solution

A static `Bash(<glob>)` entry in `permissions.allow` short-circuits
the `PreToolUse` hook. Claude Code's outer matcher applies the static
rule first and only invokes the hook for commands that DON'T match
any static allow rule. This is documented behavior but easy to miss
when you're debugging.

### Confirm the diagnosis

```bash
# What allow rules are scoped to the user?
cat ~/.claude/settings.json | python3 -c '
import json,sys
data = json.load(sys.stdin)
for entry in data.get("permissions",{}).get("allow",[]):
    print(entry)
' | grep -i Bash
```

Look for entries like `Bash(aws *)`, `Bash(gh *)`, `Bash(python3 *)`.
Those wildcards categorically bypass your hook for any matching cmd.

### Make QA deterministic

Two patterns help.

**1. Add a log file in your hook.** Have the hook write JSONL records
for every fire to a known location (e.g. `~/.cache/myplugin/log`).
When QA'ing, `tail -f` the log in another terminal. Commands that
appear in the log fired the hook; commands missing from the log were
either non-Bash or short-circuited by the allow rule.

**2. Use command shapes that categorically force the hook.** The
outer matcher does literal glob matching on the command string. The
following shapes can't be covered by a wildcard like `Bash(aws *)`:

```
bash -c "ls /tmp"                        # outer is bash, inner is ls
for x in 1 2 3; do echo $x; done         # outer is "for ... done"
diff <(echo a) <(echo b)                 # process substitution
TOKEN=$(date +%s); echo $TOKEN           # variable_assignment + list
```

If your hook handles these correctly in QA, you have confidence in
the AST/decision logic. Static-allow short-circuiting doesn't affect
them because the user would have to allowlist the outer wrapper
literally.

### When the short-circuit is the bug, not the feature

If you don't want allowlist rules to bypass your hook, the user must
remove the wildcard entries from `permissions.allow`. There is no
way for the hook to override the static-allow decision — the hook
isn't invoked at all in that case.

## Verification

1. Pick a command you've observed the hook NOT firing for (e.g. `git status`).
2. Check `~/.claude/settings.json#permissions.allow` for a matching
   pattern (likely `Bash(git *)`).
3. Temporarily move the entry out: `mv ~/.claude/settings.json
   ~/.claude/settings.json.bak`.
4. Restart Claude Code session.
5. Run the command. Hook fires, log line appears.
6. Restore: `mv ~/.claude/settings.json.bak ~/.claude/settings.json`.

## Notes

- This applies to all `PreToolUse` hooks across all tool types, not
  just Bash. `Read(*.md)` allows would short-circuit a `Read` hook
  the same way.
- The hook is also bypassed for commands explicitly denied (the
  `permissions.deny` list).
- This is intentional design: static allowlists are meant to be a
  fast-path for trusted commands. Hooks layer on top of, not under,
  the static rules.
- If you control the user's settings (e.g. a setup script), prefer
  narrow allowlist patterns. `Bash(aws ec2 describe-instances)` is
  fine; `Bash(aws *)` is too broad and lets mutating ops bypass any
  safety hook.

## Example

YOLT (https://github.com/voitta-ai/voitta-yolt) hit this during
dogfood QA. The QA log showed `aws ec2 describe-instances` and
`git status` had no log entries, while `rm -rf` and compound forms
like `for ... do ... done` did. Root cause was the developer's
own `~/.claude/settings.json` containing `Bash(aws *)` and
`Bash(git --no-pager *)`. YOLT shipped a logging mechanism
(`YOLT_LOG_FILE`) specifically to surface this so QA isn't confused
when the UI hides the hook's contribution.

## References

- [Claude Code permissions](https://code.claude.com/docs/en/permissions)
- [Claude Code hooks](https://code.claude.com/docs/en/hooks)
- YOLT log-feature PR: https://github.com/voitta-ai/voitta-yolt/pull/6
