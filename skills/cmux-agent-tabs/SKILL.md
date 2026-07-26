---
name: cmux-agent-tabs
description: |
  Make AI coding agents show up as watchable tabs/panes in cmux, and explain
  why some do and some don't. Use when: (1) you spawned Claude Code agents
  (teammates or Agent-tool subagents) but no cmux tabs appeared, even though
  Codex subagents tab automatically; (2) you want every agent in a multi-agent
  run to be a visible cmux surface you can watch; (3) you set
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and expected cmux splits but got
  none; (4) you need to name/rename agent tabs consistently from the CLI. Key
  fact: the bridge is the `cmux claude-teams` launch wrapper (it prepends a
  private tmux shim to PATH); the env var alone is NOT enough. Codex tabs come
  from `cmux codex-teams` / `cmux hooks setup codex`. Also covers the two other
  causes of "no tabs": subagents spawned via the Agent tool never tab even under
  `cmux claude-teams` (they surface in Claude Code's native agent list), and the
  tmux shim can be on PATH while the `cmux` CLI itself is not installed.
author: Claude Code
version: 1.1.0
date: 2026-07-25
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
surface. **Codex** subagents show up automatically. **Claude Code** agents often
do **not** - either because the session wasn't launched through the
`cmux claude-teams` wrapper, or because they were spawned via the **Agent tool**,
whose subagents run in Claude Code's own subagent runtime and never become cmux
tabs at all. The runtimes integrate with cmux asymmetrically.

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

## The other cause: Agent-tool subagents never tab
Missing tabs are **not** always a launch-wrapper problem. Subagents spawned via
Claude Code's **Agent tool** run in Claude Code's own subagent runtime, which
does not shell out to `tmux` at all. Launching correctly through
`cmux claude-teams` does not make them tab - a run started that way, with the
shim on PATH and `TMUX` set, can spawn six Agent-tool subagents and produce zero
new windows:
```bash
~/.cmuxterm/claude-teams-bin/tmux list-windows -a   # only your pre-existing windows
```
They are still watchable and steerable - just elsewhere. They render in Claude
Code's in-TUI agent list under the `main` node with live elapsed time, and are
addressable by name via `SendMessage`:
```
● main
○ yolt-67-dev  You are the DEVELOPER for issue #67 ...   2m 59s
○ yolt-68-dev  You are the DEVELOPER for issue #68 ...   2m 34s
```
So: **teammate spawning + `cmux claude-teams` => cmux tabs; Agent tool => native
agent list.** Diagnose the spawn path before re-launching the session.

## Diagnose in 5 seconds
Run inside the session's shell:
```bash
echo "AGENT_TEAMS=${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-<unset>}  TMUX=${TMUX:-<unset>}"
which tmux        # the cmux claude-teams shim, if active
which cmux        # the cmux CLI itself - separate from the shim
```
- `tmux: command not found` and/or `TMUX` unset => the `claude-teams` shim is
  **not** active => Claude teammates will NOT tab. (The env var may still be set
  and is a red herring on its own.)
- Shim present and `TMUX` set, but `cmux: command not found` => you are inside a
  claude-teams session with **no CLI to drive it**: `cmux tree --all` and
  `cmux tab-action` are both unavailable, so surfaces cannot be listed or named.
  Install the `cmux` CLI, or proceed without tab naming.
- Shim present, `TMUX` set, `cmux` CLI present, and **still** no new tabs => the
  agents were spawned through **Claude Code's Agent tool**, not teammate
  spawning. See the section above - this is a different cause and the launch
  wrapper is not the problem.

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
- The tmux shim and the `cmux` CLI install separately. The shim can be on PATH
  (so you're demonstrably in a claude-teams session) while `which cmux` returns
  `command not found`, leaving `cmux tree` / `cmux tab-action` unusable.
- "No tabs" has three distinct causes - wrong launch path, Agent-tool spawn
  path, or missing `cmux` CLI. Only the first is fixed by re-launching.
- `cmux open <path-or-url>` opens files/dirs/URLs (markdown/file/browser
  previews); it is **not** a way to spawn a terminal running a chosen command in
  a titled tab. Don't reach for it to "open an agent in a tab."
- The shim translates a supported subset of tmux window/pane commands; exotic
  tmux usage may not map.

## Quick reference
| Goal | Command |
|---|---|
| Claude teammates -> cmux tabs | launch via `cmux claude-teams ...` |
| Claude Agent-tool subagents | never tab - watch in the native agent list, steer via `SendMessage` |
| Codex agents -> cmux tabs | `cmux codex-teams ...` or `cmux hooks setup codex` |
| Is the Claude bridge active? | `which tmux` (shim present) + `TMUX` set |
| Can I name tabs at all? | `which cmux` (CLI present, separate from the shim) |
| List surfaces + refs | `cmux tree --all` |
| Rename a tab | `cmux tab-action --action rename --tab surface:N --title "..."` |
