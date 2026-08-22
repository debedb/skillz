---
name: agent-traffic-log
description: |
  An append-only event log of agent-to-agent traffic, plus a live pane over it,
  so a fleet of agents has an org-wide view instead of N private conversations.
  Every session appends JSONL; no daemon, no lock, no coordination. Use when:
  (1) agents message each other and you want one place showing who asked whom,
  about what, and whether it was answered; (2) a per-workspace status pill tells
  you about one session but you need the whole run; (3) you want a durable
  record of how a run went, not just its outcome - the retrospective input that
  is otherwise lost when contexts end; (4) you need "who is blocked right now"
  derived from history rather than tracked separately; (5) you are about to add
  a lock or a daemon to make concurrent appends safe and want to know why
  neither is needed. Ships `scripts/xs`: log, tail, recent, status, prune.
author: Claude Code
version: 1.0.0
date: 2026-08-21
source: https://github.com/voitta-ai/skillz
source_file: skills/agent-traffic-log/SKILL.md
---

> **Canonical source.** This skill lives in the repo at
> https://github.com/voitta-ai/skillz (file:
> `skills/agent-traffic-log/SKILL.md`). Updates go through the repo's worktree
> + PR workflow - open an issue, branch, PR.

# agent-traffic-log

## Why events, not state

A status pill answers "what is *this* session doing". It cannot answer "what is
the *run* doing", because a pill is per-workspace and a run is many workspaces.

Recording **events** rather than current state costs almost nothing extra and
buys two things state cannot:

- **The org view.** Current state is a fold over events, so events subsume it -
  `xs status` derives who is waiting on whom from the log rather than tracking
  it separately, which means the two can never disagree.
- **A retrospective input.** When a context ends, everything it knew about how
  the run went goes with it. An append-only log outlives the sessions that
  wrote it, which is the difference between "the run succeeded" and "here is
  where it stalled".

## The log

```
${XDG_STATE_HOME:-~/.local/state}/agent-xs/events.jsonl
```

JSONL, one event per line, mode 0600. Read it with anything.

```json
{"ts":"2026-08-21T20:38:49-0700","ev":"send","from":"main","to":"api-worker",
 "kind":"Q","topic":"which port for dev server","ws":"2E7F43AF-..."}
```

| Field | Meaning |
|---|---|
| `ev` | `send` `recv` `answered` `expired` `note` |
| `kind` | `Q` question, `WO` work order, `FYI` status, `RE` reply |
| `from` / `to` | agent names, matching what `ListAgents` shows |
| `topic` | short human-readable subject |
| `ws` | `$CMUX_WORKSPACE_ID`, so an event maps back to a surface |

## Why there is no lock and no daemon

Many sessions append to one file concurrently. That is safe because POSIX
guarantees a single `write()` of at most `PIPE_BUF` bytes to a descriptor
opened `O_APPEND` is not interleaved with another writer's.

So the writer does exactly that: `os.open(..., O_WRONLY|O_APPEND|O_CREAT)`, one
`os.write()`, close. Lines are capped at 2048 bytes, comfortably under the
4096-byte `PIPE_BUF` floor, and the cap is enforced by **truncating the topic**
rather than rejecting the event - a dropped event is worse than a clipped
topic, because the log's whole value is being complete.

**Measured, not assumed:** 24 concurrent writers x 40 events = 960 lines
produced 960 parseable lines, 0 torn, 960 distinct. If you change the writer,
re-run that test; it is the only property the design depends on.

Two consequences worth knowing:

- A reader may see a partial *file* but never a partial *line*, so `tail` is
  safe at any moment.
- `prune` rewrites via temp + `os.replace`, which is atomic, but an appender
  racing a prune can lose a line. Prune when the fleet is quiet.

## Commands

```bash
xs log send --to api-worker --kind Q --topic "which port for dev server"
xs log recv --to main       --kind Q --topic "which port for dev server"
xs log answered --to api-worker --kind RE --topic "port is 5173"
xs log expired  --to db-worker            --topic "no reply within subscription"

xs recent -n 20      # last N, formatted
xs tail              # follow - this is what a traffic pane runs
xs status            # who is waiting on whom, derived from events
xs path              # where the log lives
xs prune --keep 5000
```

Identity comes from `$XS_NAME`, else `$CMUX_TAB_TITLE`, else
`$CMUX_WORKSPACE_NAME`, else a short workspace id. Set `XS_NAME` to the same
name `ListAgents` shows and the log lines up with the address book.

## The pane

```bash
cmux new-workspace --name traffic --command "xs tail"
```

or as a split beside what you are watching:

```bash
cmux new-split right --command "xs tail"
```

`tail` polls rather than using inotify/kqueue: no dependency, and since the
file only grows by appends a byte offset stays valid. It restarts cleanly if
the file shrinks under it (a prune), rather than replaying everything.

## How this fits with the other two halves

Three layers, each useful alone:

| Layer | Surface | Answers |
|---|---|---|
| Envelope | the message itself | what is this about |
| Pill | one workspace's sidebar | is *this* session blocked |
| **Log** | one pane, or any reader | what is the *run* doing, and what happened |

See [[cmux-cross-session-visibility]] for the envelope and pill, and
[[claude-code-cross-session-messaging]] for the transport underneath. Log the
same `kind` you put in the message summary, so a pane line and a transcript
line describe the same event in the same vocabulary.

`expired` is worth logging explicitly. An idle subscription that expires means
*unknown*, not answered - recording it is what stops `xs status` from showing a
wait that nobody is actually waiting on.

## Acceptance test

Static tests prove the writer; only a real run proves the conventions. Run this
on a **fresh cmux launch**, not a resumed one - resumed panes have neither
`$TMUX` nor the shim directory, so a team spawned from one behaves differently
(see [[cmux-agent-tabs]]).

**1. A team, per the documented shape.** From the palette, launch
`cmux claude-teams`, give the main agent a task, and let it spawn a squad:
architect first (its deliverable is the parallel set), then per work item a
developer in its own worktree, an **adversarial reviewer that is a different
agent**, an SDET, and a productivity engineer. The dev/reviewer split is the
load-bearing part; the instant the context that wrote the code also reviews it,
the review is theater.

Expected in the traffic pane: `send`/`recv` pairs between main and each
teammate, `kind=WO` for delegated work, `answered` when each reports back.

**2. Cross-workspace question.** With workspace 1 / tab 1 mid-task, have
workspace 2 / tab 2 ask it a question. Expected: one `send` from ws2, one `recv`
on ws1, one `answered`, and `xs status` showing the ask outstanding in between
and nothing after.

**Passes if:** every message that happened appears exactly once; `xs status` is
empty when the run is idle; no torn lines; and reading the pane alone tells you
what the run did without opening a transcript.

**Fails informatively if** agents forget to log. That is the known weakness -
there is no hook on message send, so this is discipline, not instrumentation.
Gaps in the log during a real run are the signal to wire it to a host hook if
one exists.

## Caveats

- **No hook, so no guarantee.** Nothing observes `SendMessage`. An agent that
  does not call `xs log` leaves no trace, and the log silently under-reports
  rather than erroring.
- **Identity is best-effort.** Two sessions can pick the same name. `ws`
  disambiguates after the fact.
- **Not a security boundary.** Mode 0600 keeps it to your user; topics are
  written by agents, so keep secrets out of them exactly as you would a commit
  message.
- **`status` is a fold, so it inherits gaps.** An unlogged `answered` leaves a
  wait outstanding forever. Prefer logging `expired` over logging nothing.
