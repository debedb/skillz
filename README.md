# PR iteration loop skills for Claude Code and Codex

Two paired skills that drive the iterative back-and-forth of a GitHub
pull request review cycle:

- **work-on-pr**: author-side loop. Watch for new review comments,
  issue comments, and inline threads; wait when feedback has not
  landed yet; address each in a worktree; run tests; commit; push;
  post a reply with the commit SHA; then keep waiting.
- **review-pr-loop**: reviewer-side loop. Every round, re-read the
  linked issue(s) and all prior reviews, issue comments, and inline
  threads before reviewing only the new diff or the author's latest
  response.

The skill markdown is shared across both hosts. `install.sh` can
install into Codex (`~/.codex/skills`), Claude Code (`~/.claude/skills`),
or both, so one gist stays the source of truth.

## Install (one-liner)

```bash
bash < (curl -sL https://gist.githubusercontent.com/debedb/5f606018eb36a75dc292016268f08e7c/raw/install.sh)
```

## Install targets

By default, `install.sh` uses `--target auto`:

- installs to `~/.codex/skills` when Codex is configured or present
- installs to `~/.claude/skills` when Claude Code is configured or present
- installs to both default roots when neither home exists yet

You can force a target explicitly:

```bash
bash <(curl -sL https://gist.githubusercontent.com/debedb/5f606018eb36a75dc292016268f08e7c/raw/install.sh) -- --target codex
bash <(curl -sL https://gist.githubusercontent.com/debedb/5f606018eb36a75dc292016268f08e7c/raw/install.sh) -- --target claude
bash <(curl -sL https://gist.githubusercontent.com/debedb/5f606018eb36a75dc292016268f08e7c/raw/install.sh) -- --target both
```

You can also override the destination directly with `SKILLS_DEST_ROOT`.
`CODEX_HOME` and `CLAUDE_SKILLS_DIR` are both honored.

## Install (from a clone)

```bash
git clone https://gist.github.com/debedb/5f606018eb36a75dc292016268f08e7c.git /tmp/pr-loop-skills
cd /tmp/pr-loop-skills
./install.sh --target both
```

## Verify

```bash
ls ~/.codex/skills/work-on-pr/SKILL.md ~/.codex/skills/review-pr-loop/SKILL.md
ls ~/.claude/skills/work-on-pr/SKILL.md ~/.claude/skills/review-pr-loop/SKILL.md
```

Check only the host(s) you actually use.

## Usage

Author side, after opening PR #N:

```text
/work-on-pr N
```

Reviewer side, on someone else's PR #N:

```text
/review-pr-loop N
```

Each skill owns the watch loop. If `ScheduleWakeup` is available, it
uses that between polls; otherwise it sleeps and re-polls in-process.
Invoking before comments exist is expected, and an idle poll is not
completion.
