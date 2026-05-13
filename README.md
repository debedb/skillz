# Claude Code skills — PR iteration loops

Two paired Claude Code skills that drive the iterative back-and-forth
of a GitHub pull request review cycle:

- **work-on-pr** — author-side loop. Watch for new review comments /
  issue comments / inline threads, wait when feedback has not landed
  yet, address each in a worktree, run tests, commit, push, post a
  reply with the commit SHA, then keep waiting. Exits on approval
  (`reviewDecision == APPROVED`, or an approval-phrase comment), PR
  merge / close, or user stop.
- **review-pr-loop** — reviewer-side loop. Every round re-read the
  linked issue(s) AND all prior reviews + issue comments + inline
  threads, then review the new diff or author's latest response. If
  the author has not responded yet, keep waiting rather than exiting.
  Leaves REQUEST_CHANGES / COMMENT / APPROVE and keeps watching until
  approve / merge / close / user stop.

Both use the same `gh` API surfaces and the `--body-file` convention
to avoid shell-quoting traps.

## Install (one-liner)

```bash
bash <(curl -sL https://gist.githubusercontent.com/debedb/5f606018eb36a75dc292016268f08e7c/raw/install.sh)
```

`install.sh` knows the gist raw URL and downloads each SKILL file
into `~/.claude/skills/<name>/SKILL.md` automatically.

GitHub's raw CDN sometimes serves a stale `install.sh` for a few
minutes after a gist edit. If the one-liner above fails or doesn't
have the latest behaviour, pin to the most recent revision SHA:

```bash
REV=$(gh api gists/5f606018eb36a75dc292016268f08e7c --jq '.history[0].version')
bash <(curl -sL "https://gist.githubusercontent.com/debedb/5f606018eb36a75dc292016268f08e7c/raw/${REV}/install.sh")
```

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

Each skill owns the watch loop. If `ScheduleWakeup` is available, it
uses that between polls; otherwise it sleeps and re-polls in-process.
Invoking before comments exist is expected.

## Source

Extracted from review iterations on
[voitta-ai/voitta-yolt](https://github.com/voitta-ai/voitta-yolt)
PR #20.
