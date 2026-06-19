---
name: cmux-agent-tabs
description: |
  Make AI coding agents show up as watchable tabs/panes in cmux, and explain
  why some do and some don't. Use when: (1) you spawned Claude Code teammates
  (Agent tool / agent-teams) but no cmux tabs appeared, even though Codex
  subagents tab automatically; (2) you want every agent in a multi-agent run to
  be a visible cmux surface you can watch; (3) you set
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and expected cmux splits but got
  none; (4) you need to name/rename agent tabs consistently from the CLI. Key
  fact: the bridge is the `cmux claude-teams` launch wrapper (it prepends a
  private tmux shim to PATH); the env var alone is NOT enough. Codex tabs come
  from `cmux codex-teams` / `cmux hooks setup codex`.
author: Claude Code
version: 1.0.0
date: 2026-06-18
source: https://github.com/voitta-ai/skillz
source_file: skills/cmux-agent-tabs/SKILL.md
---

> **Canonical source.** This skill lives in the repo at
> https://github.com/voitta-ai/skillz (file: `skills/cmux-agent-tabs/SKILL.md`).
> Updates go through the repo's worktree + PR workflow - open an issue,
> branch, PR.
>
> Companion: the [cmux setup](https://blog.debedb.com/2026/06/17/cmux-setup/)
> post covers running Claude Teams + OMX (Oh My Codex) workspaces and surviving
> reboots; this skill covers why agents do/don't appear as tabs.

# cmux-agent-tabs

## Problem
You run a multi-agent session and want each agent visible as its own cmux
surface. **Codex** subagents show up automatically. **Claude Code** teammates
(spawned via the Agent tool with agent-teams enabled) often do **not** - they
run inside Claude Code's own teammate runtime and never become separate cmux
tabs. The two runtimes integrate with cmux asymmetrically.

## Why the asymmetry
- **Codex:** `cmux codex-teams` starts a private Codex app-server, watches live
  Codex thread-spawn subagents, and opens them (up to depth 2) as native cmux
  splits. Tabs appear with no extra work.
- **Claude Code:** the bridge is the **`cmux claude-teams` launch wrapper**, not
  an environment variable. That wrapper:
  - defaults Claude teammate mode to `auto`,
  - sets a tmux-like environment, and
  - **prepends a private tmux shim to PATH** that translates tmux window/pane
    commands into cmux workspace/split operations.

  Claude's auto teammate mode creates splits by shelling out to `tmux`; the shim
  is what turns those into cmux surfaces. If the session was started *without*
  `cmux claude-teams`, the shim is absent and teammates never reach cmux - even
  when `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` is set.

## Diagnose in 5 seconds
Run inside the session's shell:
```bash
echo "AGENT_TEAMS=${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-<unset>}  TMUX=${TMUX:-<unset>}"
which tmux        # the cmux claude-teams shim, if active
```
- `tmux: command not found` and/or `TMUX` unset => the `claude-teams` shim is
  **not** active => Claude teammates will NOT tab. (The env var may still be set
  and is a red herring on its own.)

## Fix
- **Claude agents as tabs:** launch the root session through the wrapper:
  ```bash
  cmux claude-teams [claude-args...]      # e.g. cmux claude-teams --model opus
  ```
  Then teammate spawns auto-open as cmux splits. There is no config-file toggle;
  it must be in the launch path. (Claude Code cmux hooks are injected
  automatically by this wrapper.)
- **Codex agents as tabs:** run under `cmux codex-teams`, or install the hook:
  ```bash
  cmux hooks setup codex        # also: grok, gemini, opencode, amp, cursor, ...
  ```

## Name and rename tabs from the CLI
Consistent naming makes a multi-agent run legible. A useful convention is
`<project>-<issue>-<role>` (e.g. `dd-93-dev`, `dd-93-rev`, `dd-93-qa`).
```bash
cmux tree --all                                              # list surfaces + refs
cmux tab-action --action rename --tab surface:16 --title "dd-integrator"
cmux tab-action --action clear-name --tab surface:16        # revert to auto title
```
`--tab` accepts `surface:<n>` or `tab:<n>`; defaults to `$CMUX_TAB_ID` /
`$CMUX_SURFACE_ID` / the focused tab.

## Caveats
- `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` being present does **not** imply the
  cmux bridge is active - always check for the tmux shim.
- `cmux open <path-or-url>` opens files/dirs/URLs (markdown/file/browser
  previews); it is **not** a way to spawn a terminal running a chosen command in
  a titled tab. Don't reach for it to "open an agent in a tab."
- The shim translates a supported subset of tmux window/pane commands; exotic
  tmux usage may not map.

## Quick reference
| Goal | Command |
|---|---|
| Claude agents -> cmux tabs | launch via `cmux claude-teams ...` |
| Codex agents -> cmux tabs | `cmux codex-teams ...` or `cmux hooks setup codex` |
| Is the Claude bridge active? | `which tmux` (shim present) + `TMUX` set |
| List surfaces + refs | `cmux tree --all` |
| Rename a tab | `cmux tab-action --action rename --tab surface:N --title "..."` |
