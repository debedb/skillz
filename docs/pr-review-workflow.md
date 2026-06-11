# PR review workflow stack

How to combine this repo's PR-loop skills with subagents, Agent Teams,
and the Agent SDK. The short version: treat the pieces as a **workflow
stack**, not as one permanent "agent team." Each layer has a job, and
the cheapest layer that does the job wins.

- [The four layers](#the-four-layers)
- [Key rule: subagents cannot spawn subagents](#key-rule-subagents-cannot-spawn-subagents)
- [Best working shape](#best-working-shape)
- [Recommended reviewer prompt](#recommended-reviewer-prompt)
- [Using PR Review Toolkit agents directly](#using-pr-review-toolkit-agents-directly)
- [What to avoid](#what-to-avoid)
- [When an Agent Team is worth it](#when-an-agent-team-is-worth-it)
- [SDK guidance](#sdk-guidance)
- [GitHub identity caveat](#github-identity-caveat)
- [Decision rule](#decision-rule)
- [References](#references)

## The four layers

| Layer | Mechanism | Job |
|---|---|---|
| Workflow loop | Skills: [work-on-pr](../skills/work-on-pr/SKILL.md), [review-pr-loop](../skills/review-pr-loop/SKILL.md) | The long-running author / reviewer procedures — when to act, what to compare against across rounds, when to wait. |
| Specialist analysis | Subagents: PR Review Toolkit (`code-reviewer`, `silent-failure-hunter`, `pr-test-analyzer`, `comment-analyzer`, `type-design-analyzer`, `code-simplifier`) | A focused, single-concern pass that returns evidence. |
| Multi-session debate | Agent Team | Several independent sessions that argue, compare hypotheses, and converge — escalation only. |
| External automation | Claude Agent SDK | A daemon, GitHub Action, CI bot, or orchestration service outside the interactive terminal. |

`work-on-pr` is the author-side loop: watch feedback, implement fixes,
run tests, commit, push, reply with the commit SHA. `review-pr-loop` is
the reviewer-side loop: re-read the linked issue(s) and all prior
reviews / comments / inline threads each round, then review only the new
diff or the author's latest response. Both are **protocol loops**, not
collaborative swarms — which is why a skill, not a team, is the right
container.

## Key rule: subagents cannot spawn subagents

> **Do not make `review-pr-loop` itself a subagent if it needs to call
> other agents.**

Only the main thread (or a main-session agent) can spawn subagents via
the `Agent` tool. A subagent cannot spawn another subagent. So if the
reviewer loop is going to delegate a first-round sweep to PR Review
Toolkit specialists, the loop must run in the main session — not nested
inside another agent.

## Best working shape

| Responsibility | Mechanism | Where it runs | Notes |
|---|---|---|---|
| Author loop | `/work-on-pr <issue-or-pr>` | Session A | Owns implementation, tests, commits, pushes, replies |
| Reviewer loop | `/review-pr-loop <pr>` | Session B | Owns review state, re-reads all prior context, posts the review |
| Specialist review | `pr-review-toolkit:*` agents | Spawned by the reviewer session | Private advisory pass; does not post directly |
| True multi-agent debate | Agent Team | Rare escalation | Large or ambiguous PRs only |

A PR author/reviewer exchange is best mediated through **GitHub comments
and reviews**, not private teammate chat — the audit trail matters. The
reviewer loop posts one coherent review; the author loop responds with
commits and SHAs.

## Recommended reviewer prompt

Use this in the reviewer session to make the specialist-sweep policy
explicit:

```text
/review-pr-loop 123

Reviewer policy for this PR:
- You are the only actor allowed to post GitHub reviews or comments.
- On the first review round, run a private specialist sweep using PR Review Toolkit:
  - code-reviewer always
  - pr-test-analyzer if tests or behavior changed
  - silent-failure-hunter if error handling, fallbacks, retries, logging, or catch blocks changed
  - comment-analyzer if comments/docs changed
  - type-design-analyzer if types/models/interfaces changed
- Treat specialist outputs as advisory evidence, not final review text.
- Deduplicate findings.
- Verify every finding against the actual PR diff and linked issue requirements.
- Post one structured review: REQUEST_CHANGES, COMMENT, or APPROVE.
- On later rounds, do not rerun all specialists by default; only rerun the relevant specialist for the changed area.
```

This matches `review-pr-loop`'s intended behavior: re-read issue context
and all prior comments every round, review only the new diff after the
first round, and optionally delegate the first-round quality pass to PR
Review Toolkit.

## Using PR Review Toolkit agents directly

The `@` autocomplete entries in Claude Code are direct **subagent
invocations**, not Agent Team members. Each one should return findings
only — it must **not** post to GitHub. The reviewer loop synthesizes and
posts.

Targeted silent-failure pass:

```text
@"pr-review-toolkit:silent-failure-hunter (agent)"
Review PR #123 for silent failures, inadequate error handling, swallowed exceptions,
fallbacks that hide failure, missing logging, and retry behavior. Return findings only.
Do not post to GitHub.
```

Test-focused pass:

```text
@"pr-review-toolkit:pr-test-analyzer (agent)"
Review PR #123 for behavioral test coverage gaps. Focus only on changed behavior.
Return findings only. Do not post to GitHub.
```

The main `review-pr-loop` session then deduplicates, verifies against the
diff and the linked issue, and posts one review.

## What to avoid

Do **not** make this the default design:

```text
Create an agent team with author, reviewer, test reviewer, error reviewer,
and type reviewer, and have them work continuously on PR #123.
```

It sounds attractive but is usually worse:

- The author and reviewer may coordinate privately instead of through GitHub.
- The review specialists may produce overlapping or contradictory comments.
- The team may lose durable task state in ways that are bad for a watch loop.
- Agent Teams are still experimental and carry operational limitations.
- Continuous PR iteration needs a public audit trail, not internal chatter.

Also avoid letting specialists post independently. Specialist agents
produce **evidence**, not final GitHub comments.

## When an Agent Team is worth it

Use an Agent Team for a **big first-round review** where independent
reviewers need to argue, compare hypotheses, and converge:

```text
Create an agent team for PR #123.

Roles:
- security reviewer using pr-review-toolkit:silent-failure-hunter style reasoning
- test reviewer using pr-review-toolkit:pr-test-analyzer style reasoning
- architecture reviewer
- reviewer lead

Rules:
- Nobody posts to GitHub.
- Each teammate reviews independently first.
- Then compare findings and eliminate duplicates.
- The lead produces a final review draft only.
- A human decides whether to post it.
```

Good cases: high-risk PRs, architecture changes, security-sensitive
flows, concurrency / distributed-systems bugs, large cross-cutting
refactors, or any situation where several independent hypotheses are
useful. For normal review iteration, a team is overkill.

## SDK guidance

Do **not** use the Claude Agent SDK for the normal terminal workflow.
Use it only for an external automation layer: a PR-review daemon, a
GitHub Action, a CI bot, a custom orchestration service, or a tool that
programmatically defines and invokes agents. For interactive use, the
native setup is better:

```text
skills = reusable workflows, checklists, loops
agents = reusable specialist workers
teams  = occasional multi-session coordination
SDK    = custom app / automation layer
```

## GitHub identity caveat

If the author loop and reviewer loop use the **same GitHub identity**,
GitHub will not treat the reviewer as an independent approver of their
own PR (it rejects `--approve` / `--request-changes` on your own PR). In
that case the reviewer loop posts a normal comment with explicit intent:

```text
LGTM from automated/self-review perspective.
```

or:

```text
Blocking issue: this still needs a fix before merge.
```

For a true author/reviewer loop, use separate GitHub identities.
Otherwise treat the reviewer loop as advisory. See `review-pr-loop`'s
"Reviewing your own PR" notes for how the paired `work-on-pr` skill reads
that intent.

There is a second, subtler consequence of a shared identity: the
**comment-filtering** step in both loops. `work-on-pr` and
`review-pr-loop` decide "what's new since I last acted" by filtering
each comment / review to `author != self`. That test is implemented by
GitHub **login**, so under a shared identity it filters out the *other*
loop's posts too — the author loop stops seeing the reviewer's reviews,
and the reviewer loop stops seeing the author's replies. The watch loop
then looks permanently idle even while feedback is landing. Under a
shared identity, discriminate by `timestamp > anchor` plus the model
tag (`[claude]` vs `[codex]`) in the body rather than by login; reserve
the login-based `author != self` filter for genuinely separate
identities. Both skills document this in their "Determine what's new"
step.

## Decision rule

```text
Need durable PR behavior over time?
  -> Use skills: work-on-pr and review-pr-loop.

Need focused specialist analysis?
  -> Use PR Review Toolkit agents as subagents (advisory; they do not post).

Need multiple independent sessions to debate and coordinate?
  -> Use an Agent Team, but only for large / high-risk reviews.

Need external automation?
  -> Use the Claude Agent SDK.
```

Bottom line:

```text
Reviewer Claude session
  /review-pr-loop <pr>
    - optionally invokes pr-review-toolkit:* specialists (advisory)
    - verifies and deduplicates findings
    - posts one coherent GitHub review

Author Claude session
  /work-on-pr <issue-or-pr>
    - watches feedback, implements fixes, runs tests
    - commits and pushes
    - replies with SHAs and rationale
```

That gives regular collaboration without paying the complexity cost of a
permanent Agent Team.

## References

- [Claude Code subagents](https://docs.anthropic.com/en/docs/claude-code/sub-agents)
- [Claude Code Agent Teams](https://code.claude.com/docs/en/agent-teams)
- [Claude Agent SDK subagents](https://code.claude.com/docs/en/agent-sdk/subagents)
- [Anthropic PR Review Toolkit plugin](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/pr-review-toolkit)
- [work-on-pr skill](../skills/work-on-pr/SKILL.md)
- [review-pr-loop skill](../skills/review-pr-loop/SKILL.md)
