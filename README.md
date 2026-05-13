# Claude Code skills — PR iteration loops

Two paired Claude Code skills that drive the iterative back-and-forth
of a GitHub pull request review cycle:

- **work-on-pr** — author-side loop. Poll for new review comments /
  issue comments / inline threads, address each in a worktree, run
  tests, commit, push, post a reply with the commit SHA, sleep,
  repeat. Exits on approval (`reviewDecision == APPROVED`, or an
  approval-phrase comment), PR merge / close, or user stop. Uses
  adaptive `ScheduleWakeup` pacing keyed to the Anthropic prompt-cache
  TTL (270s after a push, 1200–1800s when idle).
- **review-pr-loop** — reviewer-side loop. **Every round** re-reads
  the linked issue(s) AND all prior reviews + issue comments +
  inline threads, then diffs only the commits since your last review,
  synthesizes severity-tagged findings, and leaves
  REQUEST_CHANGES / COMMENT / APPROVE. Same adaptive pacing.

Both use the same `gh` API surfaces and the `--body-file` convention
to avoid shell-quoting traps.

## Install (one-liner)

```bash
bash <(curl -sL https://gist.githubusercontent.com/debedb/5f606018eb36a75dc292016268f08e7c/raw/install.sh)
```

If the process-substitution form can't locate the sibling SKILL files
(some `curl | bash` setups don't expose them), set `GIST_RAW_BASE`:

```bash
GIST_RAW_BASE=https://gist.githubusercontent.com/debedb/5f606018eb36a75dc292016268f08e7c/raw \
  bash <(curl -sL https://gist.githubusercontent.com/debedb/5f606018eb36a75dc292016268f08e7c/raw/install.sh)
```

Replace `debedb/5f606018eb36a75dc292016268f08e7c` with this gist's coordinates.

## Install (from a clone)

```bash
git clone https://gist.github.com/debedb/5f606018eb36a75dc292016268f08e7c.git /tmp/skills-gist
cd /tmp/skills-gist
./install.sh
```

## Install destination

Defaults to `~/.claude/skills/<name>/SKILL.md`. Override with the
`CLAUDE_SKILLS_DIR` env var:

```bash
CLAUDE_SKILLS_DIR=/some/other/path ./install.sh
```

## Verify

```bash
ls ~/.claude/skills/work-on-pr/SKILL.md ~/.claude/skills/review-pr-loop/SKILL.md
```

Then in Claude Code, the two skill names should appear in the skills
index (restart the session or run `/reload-plugins` if not).

## Usage

Author side, after opening PR #N:

```
/work-on-pr N
```

Reviewer side, on someone else's PR #N:

```
/review-pr-loop N
```

Each skill runs one iteration end-to-end (poll, act, reply, schedule)
and reschedules itself via `ScheduleWakeup`. Interrupt at any time to
stop the loop.

## Source

Extracted from review iterations on
[voitta-ai/voitta-yolt](https://github.com/voitta-ai/voitta-yolt)
PR #20.
