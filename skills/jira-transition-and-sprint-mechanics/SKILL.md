---
name: jira-transition-and-sprint-mechanics
description: |
  Move Jira issues through a customised workflow via the REST API without
  guessing at transition ids, required fields, or sprint membership. Use when:
  (1) a transition POST fails and you are about to conclude the target status
  does not exist, (2) you hardcoded a transition id that worked once and now
  returns 400, (3) you moved issues to a status and someone asks "are they in
  the sprint?" - and they are not, (4) a field value you need is missing from
  the transition screen's `allowedValues` and you are about to report it
  unavailable, (5) you need to move issues from a backlog status straight to a
  late status and there is no direct edge. Core facts: transition ids are
  per-SOURCE-status (the same destination has a different id from a different
  status), sprint is an ordinary field completely independent of status, and
  transition-screen metadata UNDER-reports what a field will actually accept.
  Covers discovering the graph, multi-hop walks, setting required fields at
  the right hop, sprint assignment, and verifying by read-back.
author: Claude Code
version: 1.0.0
date: 2026-08-26
source_file: skills/jira-transition-and-sprint-mechanics/SKILL.md
---

> **Canonical source.** This skill lives in the repo at
> https://github.com/voitta-ai/skillz (file: `skills/jira-transition-and-sprint-mechanics/SKILL.md`).

# Jira transitions and sprints over the REST API

## Problem

Customised Jira workflows break every assumption a script makes. Transition
ids look like stable constants and are not. The status you want may not be
reachable in one hop. And moving an issue to "in test" does not put it in the
sprint - reviewers see the board, not your API calls.

## Context / Trigger Conditions

- `POST /issue/KEY/transitions` returns 400 for an id that worked on another
  issue.
- The status you want is absent from `GET /transitions` and you are about to
  say the workflow does not support it.
- You transitioned a batch of issues successfully and the sprint board is
  still empty.
- A picklist value you need is not in the transition screen's `allowedValues`.

## Solution

### 1. Never hardcode a transition id - it is per-source-status

A transition id identifies an **edge**, not a destination. The same
destination reached from two different statuses has two different ids.

Verified on one project's workflow:

```
from Backlog:           31  -> In Progress
from In Staging Test:  631  -> In Progress     # same destination, different id
```

Always resolve it against the issue's current status, immediately before use:

```bash
TID=$(curl -s -u "$AUTH" "$J/rest/api/3/issue/$KEY/transitions" \
      | jq -r --arg to "In Progress" '.transitions[] | select(.to.name==$to) | .id')
```

If that comes back empty, the edge does not exist **from where the issue is
now** - which is a routing problem, not a missing status.

### 2. Walk multi-hop; there is often no direct edge

Workflows commonly forbid jumping from a backlog status to a late status. The
fix is to walk, resolving the id at each hop:

```bash
for TO in "In Progress" "In Staging"; do
  TID=$(curl -s -u "$AUTH" "$J/rest/api/3/issue/$KEY/transitions" \
        | jq -r --arg to "$TO" '.transitions[]|select(.to.name==$to)|.id')
  [ -n "$TID" ] || { echo "no edge to $TO from current status"; break; }
  curl -s -u "$AUTH" -X POST -H 'Content-Type: application/json' \
    -d "{\"transition\":{\"id\":\"$TID\"},\"fields\":{...}}" \
    "$J/rest/api/3/issue/$KEY/transitions"
done
```

Note the destination status name and the transition's own name often differ
(a transition named "In Staging" landing the issue in "In Staging Test").
**Match on `.to.name`, never on the transition's label.**

Different hops demand different required fields. Send each hop's fields on
that hop - batching them all onto the last one fails.

### 3. Status and sprint are independent - transitioning does NOT add to a sprint

This is the one that silently produces wrong-looking work. Sprint is an
ordinary custom field (`customfield_1xxxx`, name `Sprint`). An issue can sit
in "In Test" and belong to no sprint at all, which is invisible from the
issue view and glaring on the board.

Find the field id from the field list, or by shape - it is the custom field
whose value is an array of objects carrying `boardId`:

```bash
curl -s -u "$AUTH" "$J/rest/api/3/field" | jq -r '.[]|select(.name=="Sprint")|.id'
```

Set it with the sprint's **numeric id**, not its name:

```bash
curl -s -u "$AUTH" -X PUT -H 'Content-Type: application/json' \
  -d '{"fields":{"customfield_10007": 20826}}' "$J/rest/api/3/issue/$KEY"
```

Read the current sprint id off any issue already in it, or from the board's
sprint endpoint. Expect `204 No Content` on success.

### 4. `allowedValues` on a transition screen is a SUBSET, not the vocabulary

A transition screen's field metadata (`GET /transitions?expand=transitions.fields`)
returns an `allowedValues` list that can be truncated - a large picklist may
return hundreds of entries while the field genuinely accepts more.

**Do not conclude a value is unavailable because it is missing there.** Check
whether any existing issue already uses it:

```bash
curl -s -u "$AUTH" -G "$J/rest/api/3/search/jql" \
  --data-urlencode 'jql=project=PROJ AND "Services" = "the-value"' \
  --data-urlencode 'fields=customfield_16168' --data-urlencode 'maxResults=1'
```

An issue carrying the value proves the value exists and gives you its id.

Treat the metadata's `required` flags with the same suspicion: the list can be
empty for a transition that a project-level validator still rejects. Discover
what a transition needs by attempting it and reading the 400 body, which names
the offending fields.

### 5. Verify by read-back, over the whole batch

A 204 means the write was accepted, not that the board looks right. Loop the
batch and print status **and** sprint together:

```bash
for K in "${KEYS[@]}"; do
  curl -s -u "$AUTH" "$J/rest/api/3/issue/$K?fields=status,customfield_10007" \
   | jq -r '"\(.key)  \(.fields.status.name)  \(
       [.fields.customfield_10007[]?|"\(.name) [\(.state)]"]|join("; ") // "(none)")"'
done
```

Printing them in one table is what surfaces the "right status, no sprint"
case. Reading status alone hides it.

## Verification

Every issue in the batch shows the intended status **and** the intended active
sprint, in one read-back table.

## Example

Six issues moved to a late test status. Status transitions all succeeded, and
a read-back of status alone looked clean. Adding the sprint column to the same
table showed four of the six in no sprint at all - they had been created
outside the sprint, and transitioning had not changed that. One PUT each on
the Sprint field fixed it.

Had the read-back only covered status, the board would have shown two of six
in the sprint and the work would have looked half-done.

## Notes

- `GET /transitions` reflects the caller's permissions. An edge missing for
  your token may exist for someone else.
- Screen configuration is per project *and* issue type. A recipe verified on a
  Story can fail on a Bug in the same project.
- Sprint accepts a bare numeric id on write, but reads back as an array of
  objects - do not round-trip the read value into a write.
- Prefer the issue's own field values as your source of truth for picklist
  ids: `GET /issue/KEY?fields=customfield_x` on a correctly-populated
  neighbour beats any metadata endpoint.

## References

- Jira Cloud REST v3, Issue transitions:
  https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/#api-rest-api-3-issue-issueidorkey-transitions-post
- Jira Cloud REST v3, Fields:
  https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-fields/

## Related

- `confluence-rovo-mcp-readonly-rest-fallback` — the same Atlassian shape from
  the Confluence side: the MCP surface covers reads, and the write you need
  lives in the REST API, so you drop to REST for the half that is missing.
