#!/usr/bin/env python3
"""Resolve catalog.json / marketplace.json / README.md conflicts when rebasing
a stale skill-adding branch onto master.

Why this exists
---------------
A skill-adding PR touches four shared registry files, and every other such PR
touches the same four. Rebase a branch that has sat for a few weeks and git's
3-way merge produces conflicts that look mergeable and are not: the entry
lists get reordered and re-summarised upstream, and the bundle plugin's
description is a single line enumerating every skill. Taking "both sides"
yields a registry that is valid JSON, passes a quick eyeball, and is wrong -
it reintroduces skills master deliberately removed and pins a months-old
skill list into the bundle description.

Observed for real: rebasing a branch cut before `git-worktree-convention`
absorbed `git-worktree-add-relative-path-nests-inside-repo` re-added the
absorbed skill, because the stale branch's catalog still listed it and a text
merge has no way to know the deletion was intentional.

So do not merge these files as text. Take the base side wholesale and
re-splice only the entries the branch actually adds, keeping only those whose
files exist in the rebased tree - that last filter is what respects an
upstream deletion.

Usage
-----
Mid-rebase, after git reports conflicts in the registry files:

    python3 scripts/merge-skill-registry.py
    git add catalog.json .claude-plugin/marketplace.json \\
            .codex-plugin/marketplace.json README.md
    git rebase --continue

For a branch with several commits, each conflicted commit needs its own pass,
and every pass after the first must base on what is already applied:

    python3 scripts/merge-skill-registry.py HEAD

Otherwise resolving commit 2 discards commit 1's entries. Re-run
scripts/validate-catalog.sh afterwards; it is the actual check.

What this does NOT resolve
--------------------------
The bundle plugin's version. A stale branch almost always also conflicts in
plugins/skillz/.claude-plugin/plugin.json and .codex-plugin/plugin.json, because
the branch bumped the version when it was cut and master has bumped it several
times since. This script deliberately leaves those alone - it cannot know which
bump the rebased branch deserves.

Resolve them by hand to a version ABOVE master's, identical in both manifests.
Taking either conflict side is wrong: HEAD's version is master's, already
released, so the branch's own change ships invisibly; the branch's version is
older than master's and moves the bundle backwards. Keeping the two manifests in
lockstep matters because Claude and Codex pin independently, and drifting them
freezes one host with no error anywhere.

Then verify:

    bash scripts/validate-catalog.sh
    python3 scripts/check-plugin-version-bumps.py origin/master

Pass that base ref explicitly. The default is FETCH_HEAD, which CI has and a
local checkout usually does not - without it the check dies with
"cannot diff against FETCH_HEAD" rather than telling you anything useful.
"""

import json
import pathlib
import subprocess
import sys

DEFAULT_BASE = "origin/master"
PR_REF = "REBASE_HEAD"

REGISTRIES = [".claude-plugin/marketplace.json", ".codex-plugin/marketplace.json"]


def show(ref, path):
    """File contents at a ref, or None when the file is absent there."""
    proc = subprocess.run(
        ["git", "show", f"{ref}:{path}"], capture_output=True, text=True
    )
    retval = proc.stdout if proc.returncode == 0 else None
    return retval


def load(ref, path):
    blob = show(ref, path)
    retval = json.loads(blob) if blob else None
    return retval


def write(path, data):
    pathlib.Path(path).write_text(json.dumps(data, indent=2) + "\n")


def splice_catalog(base_ref):
    """Base catalog plus the branch's genuinely-new entries. Returns the names
    added, or None if either side is unreadable."""
    pr_cat = load(PR_REF, "catalog.json")
    base_cat = load(base_ref, "catalog.json")
    if pr_cat is None or base_cat is None:
        return None

    base_skills = {s["name"] for s in base_cat["skills"]}
    base_plugins = {p["name"] for p in base_cat["plugins"]}

    # "Absent from base" is not sufficient: base may have REMOVED a skill the
    # stale branch still lists. Only re-add what exists in the rebased tree.
    new_skills = [
        s
        for s in pr_cat["skills"]
        if s["name"] not in base_skills and pathlib.Path(s["path"]).exists()
    ]
    new_plugins = [
        p
        for p in pr_cat["plugins"]
        if p["name"] not in base_plugins
        and pathlib.Path(p.get("claude_manifest", "nonexistent")).exists()
    ]

    base_cat["skills"].extend(new_skills)
    base_cat["plugins"].extend(new_plugins)

    bundle = next(p for p in base_cat["plugins"] if p["name"] == "skillz")
    for skill in new_skills:
        if skill["name"] not in bundle["skills"]:
            bundle["skills"].append(skill["name"])

    write("catalog.json", base_cat)
    print("new skills :", ", ".join(s["name"] for s in new_skills) or "(none)")
    print("new plugins:", ", ".join(p["name"] for p in new_plugins) or "(none)")

    retval = [s["name"] for s in new_skills] + [p["name"] for p in new_plugins]
    return retval


def splice_marketplaces(base_ref, added):
    for path in REGISTRIES:
        base_mkt = load(base_ref, path)
        if base_mkt is None:
            continue
        pr_mkt = load(PR_REF, path)
        have = {p["name"] for p in base_mkt["plugins"]}
        if pr_mkt:
            for entry in pr_mkt["plugins"]:
                if entry["name"] in added and entry["name"] not in have:
                    base_mkt["plugins"].append(entry)
        write(path, base_mkt)
        print(f"{path}: {len(base_mkt['plugins'])} plugins")


def splice_readme(base_ref, added):
    """Base README plus the branch's catalog-table rows for the new entries."""
    pr_readme = show(PR_REF, "README.md")
    base_readme = show(base_ref, "README.md")
    if not pr_readme or not base_readme:
        return

    base_lines = base_readme.splitlines()
    present = set(base_lines)
    extra = [
        line
        for line in pr_readme.splitlines()
        if line.startswith("|")
        and line not in present
        and any(name in line for name in added)
    ]
    if extra:
        last_row = max(i for i, line in enumerate(base_lines) if line.startswith("| ["))
        base_lines[last_row + 1 : last_row + 1] = extra
        print(f"README.md: +{len(extra)} row(s)")
    pathlib.Path("README.md").write_text("\n".join(base_lines) + "\n")


def main():
    base_ref = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_BASE

    if show(PR_REF, "catalog.json") is None:
        print(
            f"::error::cannot read {PR_REF} - this script expects a rebase in "
            "progress (REBASE_HEAD is the commit being applied)",
            file=sys.stderr,
        )
        return 1

    added = splice_catalog(base_ref)
    if added is None:
        print(f"::error::cannot read catalog.json at {base_ref}", file=sys.stderr)
        return 1

    splice_marketplaces(base_ref, added)
    splice_readme(base_ref, added)

    print("\nnow: git add the registry files, git rebase --continue, then")
    print("     bash scripts/validate-catalog.sh")
    return 0


if __name__ == "__main__":
    sys.exit(main())
