---
name: continuous-learning
description: |
  Decide whether the just-completed task produced a reusable, verified learning that should be captured as a Codex skill. Prefer updating an existing skill over creating a new one. Most turns end with `No reusable learning.` — only promote to a skill when the work required real discovery, the pattern is likely to recur, the trigger conditions are clear, and the result was verified. Write compact skills with explicit trigger conditions, a minimal worked example, and verification notes. Use this skill at end-of-task retrospectives, when reviewing a debugging session, or when the user asks "what did we learn?". Codex-native counterpart of Claudeception (https://github.com/blader/Claudeception); ships in this repo as part of the `codex-continuous-learning` plugin bundle.
author: Codex
version: 0.1.0
date: 2026-05-15
source: https://github.com/debedb/skillz
source_file: skills/continuous-learning/SKILL.md
---

> **Canonical source.** This skill lives in the repo at
> https://github.com/debedb/skillz (file:
> `skills/continuous-learning/SKILL.md`). Updates go through the
> repo's worktree + PR workflow — open an issue, branch, PR.

# continuous-learning

## Problem

Codex sessions routinely uncover non-obvious facts: a workaround for
a flaky API, an undocumented config flag, a regex that took five
tries to get right, a sequence of commands that fixed a recurring
class of failure. By default that knowledge dies with the session.
The next time the same wall is hit, the next agent starts from
zero.

Capturing every learning is the wrong fix. A noisy retrospective
trains users to mash through the prompt and ignore it. The useful
loop is narrow:

1. work on a real task,
2. detect that something non-obvious was learned,
3. force a brief retrospective,
4. save the reusable result as a future capability — *or* explicitly
   conclude there is nothing reusable.

This skill defines step 4. The Codex hooks in the
`codex-continuous-learning` plugin bundle drive steps 2–3.

## Context / Trigger Conditions

Invoke when:

- A `Stop` hook fires at end-of-task and the agent must decide
  whether to extract a skill before exiting.
- The user asks "what did we learn?", "save this as a skill",
  "extract a skill from this", or similar.
- A debugging-heavy session ends and reusable diagnostic / fix
  patterns emerged.
- A `PostToolUse` signal flagged the current task as
  likely-discovery work (long shell sessions, repeated failed
  commands, multiple file edits across unrelated areas).

Do NOT invoke when:

- The task was a routine code edit with no surprises.
- The "learning" is a public documentation fact already in the
  upstream README.
- The pattern is so narrow it only applies to one commit in one
  repo (no recurrence value).

## Solution

Run a structured retrospective. The default outcome is
`No reusable learning.` — promotion to a skill is the exception, not
the rule.

### 1. Retrospective questions

Answer each in one short line. If any answer is "no" or "unclear",
default to `No reusable learning.` and stop.

1. **Discovery cost?** Did finding the answer require real
   investigation — multiple failing attempts, reading source, asking
   a teammate, instrumenting a system? A direct documentation lookup
   does not count.
2. **Recurrence likelihood?** Is the same situation likely to come
   up again — for this user, this team, or this class of problem?
   One-shot historical facts do not count.
3. **Verifiable trigger?** Can the situation that benefits from this
   learning be described concretely (error string, command shape,
   file pattern, symptom)? "Sometimes things go wrong with X" does
   not count.
4. **Verified result?** Was the fix or workaround actually confirmed
   to work in this session? Speculative ideas do not count.

### 2. Prefer updating an existing skill

Before creating a new skill:

- List installed skills (e.g. inspect `~/.codex/skills/` and any
  repo-local skill directories).
- If a related skill already exists, append a short section or a
  worked example rather than spawning a sibling skill.
- Only create a new skill if no existing one fits and the new
  trigger conditions are genuinely distinct.

A proliferation of near-duplicate skills makes the catalog harder to
search and waters down each skill's trigger criteria. Updating wins.

### 3. Choose the install location

- **Cross-project learnings** (tooling quirks, language-level
  patterns, host-level behavior): user-global.
  - Codex: `~/.codex/skills/<name>/SKILL.md`
  - Claude Code: `~/.claude/skills/<name>/SKILL.md`
- **Repo-specific learnings** (build system quirks, internal
  conventions, project-only workflow): repo-local skill directory.
- **Org-wide learnings**: contribute back to the team's shared
  catalog (e.g. a repo like `debedb/skillz`) via the normal
  worktree + PR workflow.

When in doubt, prefer user-global over repo-local — repo-local
learnings tend to leak into other repos eventually.

### 4. Skill shape

A captured skill is a single `SKILL.md` with YAML frontmatter and
a tight body. Required sections:

- Frontmatter: `name`, `description`, `author`, `version`, `date`,
  `source`, `source_file`. Description must be specific enough that
  an LLM picking from a long catalog can decide if this skill
  applies. Avoid generic phrasings like "helps with X".
- `## Problem` — one paragraph, what hurts and why.
- `## Context / Trigger Conditions` — the *exact* situations where
  this skill applies. Use bullet points starting with verbs:
  "Invoked when...", "Used when...". Include the failure mode or
  symptom that should make a future agent reach for this skill.
- `## Solution` — the steps, in order. Keep it short. Inline a
  worked command example.
- `## Verification` — how to know the fix worked. Specific output,
  exit code, or observable system change.
- `## Notes` (optional) — only what does not fit above and is still
  load-bearing.
- `## References` (optional) — direct links only; no synthesis.

What does NOT belong:

- Background tutorials. Skills are reference, not pedagogy.
- Multiple problems bundled together — split into separate skills.
- Aspirations or todos.

### 5. Stop-hook escape hatch

If the four retrospective questions all answer "no", emit exactly:

```
No reusable learning.
```

…and exit. Do not pad with apologies, justifications, or
"interesting observations". The escape hatch is the point: it makes
the hook cheap enough to leave on by default.

### 6. When the user disagrees

If the user says "save this anyway" after the agent concluded
`No reusable learning.`, save it as requested. The user has context
the retrospective questions cannot capture. Do not argue.

If the user says "skip the retrospective today", honor that for the
session. Do not silently re-enter the loop on the next stop.

## Verification

A successful retrospective run produces exactly one of:

- A new `SKILL.md` written to the chosen install path, with all
  required frontmatter and section headings. Path printed in the
  reply.
- An edit to an existing skill. Diff (or path + section name)
  printed in the reply.
- The literal line `No reusable learning.` and nothing else.

If the output is anything else (waffly summary, "here's what we
might do later", recap of the task), the retrospective was not
followed.

## Notes

- **Conservative bias is intentional.** The retrospective is the
  user's last line of defense against skill-catalog rot. Erring
  toward `No reusable learning.` is the correct default.
- **Stop hook vs prompt hook.** The `UserPromptSubmit` hook in the
  bundle injects a one-line reminder so the agent keeps an eye out
  for learnings as it works. The `Stop` hook forces the
  retrospective at end-of-task. Together they are cheap; alone the
  prompt hook tends to be ignored and the stop hook tends to feel
  abrupt.
- **PostToolUse refinement.** A future v2 may gate the stop hook on
  a `PostToolUse` signal (e.g. only require the retrospective after
  ≥N tool calls, or after a shell session with ≥M failed commands).
  v1 keeps the stop hook unconditional and relies on the
  `No reusable learning.` escape for cheap exits.
- **Updating beats creating.** If the learning belongs in an
  existing skill, append. The catalog should grow in depth, not
  surface area.
- **Codex-native, not faux cross-host.** The skill itself is
  host-agnostic prose, but the hook layer in the plugin bundle is
  Codex-specific. A Claude Code equivalent would use Claude Code
  hooks and live in a separate bundle.

## References

- Claudeception (the Claude Code reference implementation):
  https://github.com/blader/Claudeception
- skillz catalog: https://github.com/debedb/skillz
- Multi-skill catalog refactor that this bundle depends on: #16
  (closed in this repo).
