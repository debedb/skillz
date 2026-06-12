---
name: gh-workflow-run-matching
description: |
  Fix for GitHub Actions workflow polling latching onto the wrong run when
  multiple pushes occur on the same branch. Use when: (1) gh run list returns
  a completed run but you expected an in-progress one, (2) CI automation
  reports success immediately after pushing a new commit, (3) polling for
  workflow completion after a revert/second push on the same branch. Covers
  gh CLI run listing, headSha filtering, and multi-push branch scenarios.
author: Claude Code
version: 1.0.0
date: 2026-04-10
---

# GitHub Actions Workflow Run Matching by Commit SHA

## Problem
When polling GitHub Actions workflow runs via `gh run list` on a branch with
multiple pushes, `--limit 1` may return the already-completed run from an
earlier push rather than the in-progress run from the latest push. This causes
automation to falsely report success without waiting for the actual workflow.

## Context / Trigger Conditions
- A branch has had multiple pushes (e.g., initial commit + revert commit)
- `gh run list --branch <branch> --limit 1` returns a run with status "completed"
- But you just pushed a new commit seconds ago and expect an "in_progress" or "queued" run
- Your automation exits early thinking the workflow succeeded
- Common in tools that apply changes, wait, then revert via the same branch

## Solution

1. After pushing the commit you want to track, capture its SHA:
   ```bash
   git rev-parse HEAD
   ```

2. When polling `gh run list`, request `headSha` in the JSON fields and fetch
   more than 1 result:
   ```bash
   gh run list --branch <branch> --limit 5 \
     --json databaseId,status,conclusion,headSha
   ```

3. Filter the results to only match runs whose `headSha` equals your target commit:
   ```python
   for run in runs:
       if head_sha and run.get("headSha") != head_sha:
           continue
       run_id = run["databaseId"]
       break
   ```

4. If no matching run is found yet, keep polling -- the new run may take up to
   2 minutes to appear in the API.

## Verification
- The matched `run_id` corresponds to a run with `headSha` equal to your pushed commit
- The polling loop waits for the run to reach `status: completed` before proceeding
- Workflow logs show the expected terraform plan/apply/destroy for the correct commit

## Example

Before (broken):
```python
# Latches onto the first run it finds -- could be from an earlier push
result = run_cmd(["gh", "run", "list", "--branch", branch, "--limit", "1",
                  "--json", "databaseId,status,conclusion"])
runs = json.loads(result.stdout)
if runs:
    run_id = runs[0]["databaseId"]  # Wrong run!
```

After (fixed):
```python
result = run_cmd(["gh", "run", "list", "--branch", branch, "--limit", "5",
                  "--json", "databaseId,status,conclusion,headSha"])
runs = json.loads(result.stdout)
for run in runs:
    if head_sha and run.get("headSha") != head_sha:
        continue
    run_id = run["databaseId"]  # Correct run
    break
```

## Notes
- GitHub may trigger duplicate runs for the same `headSha` (observed in practice).
  Both will have the same SHA, so the filter still works -- it picks whichever appears first.
- The `[skip ci]` marker in commit messages is not always honored by GitHub Actions,
  which can contribute to extra runs.
- Increase `--limit` beyond 1 to account for multiple runs on the branch.
- Increase the polling timeout (e.g., 120s) since new runs can take time to register.
