#!/usr/bin/env python3
"""Advisory catalog-health report (issue #222).

The BLOCKING half of #222 lives in validate-catalog.sh: reference resolution,
canonical heading, per-skill plugin, README row, bundle membership. Those are
gates because each was already at 100% when it was written.

This is the other half - the numbers that cannot block, because failing every
PR until `## Related` coverage reaches 100% would stop the work that gets it
there. It exits 0 always. Promote a line into validate-catalog.sh once it hits
100% and stays there; that is the whole lifecycle.

Deliberately NOT reported: staleness. Last-commit date is not obsolescence, and
a report that ranks skills by age invites retiring them for being old rather
than wrong (#222).
"""

import collections
import json
import os
import pathlib
import re
import subprocess
import sys

REF_RE = re.compile(r"(?m)^[-*] +`([a-z0-9][a-z0-9-]{3,})`")
SECTION_RE = re.compile(r"(?ms)^## Related\s*\n(.*?)(?=\n##\s|\Z)")
STOP = set(
    "the a an and or of to in for that with when use this it is are on at by "
    "as not you your from if into than then them they there here what which "
    "who why how can will would could should".split()
)


def words(text):
    """Content words of a summary, for the trigger-collision proxy."""
    retval = {w for w in re.findall(r"[a-z][a-z0-9-]{3,}", text.lower())} - STOP
    return retval


def load(root):
    retval = json.loads((root / "catalog.json").read_text())
    return retval


def related_graph(root, catalog):
    """(coverage, edges, isolated) over `## Related` sections."""
    names = {s["name"] for s in catalog["skills"]}
    edges = collections.defaultdict(set)
    covered = 0
    for s in catalog["skills"]:
        path = root / s["path"]
        if not path.is_file():
            continue
        section = SECTION_RE.search(path.read_text())
        if not section:
            continue
        covered += 1
        for ref in set(REF_RE.findall(section.group(1))):
            if ref in names:
                edges[s["name"]].add(ref)
                edges[ref].add(s["name"])
    isolated = sorted(n for n in names if not edges[n])
    retval = (covered, edges, isolated)
    return retval


def components(names, edges):
    """Connected components of the Related graph - the catalog's de facto
    topic clusters (see #260). Reported, not acted on."""
    seen, out = set(), []
    for n in sorted(names):
        if n in seen:
            continue
        stack, comp = [n], []
        while stack:
            cur = stack.pop()
            if cur in seen:
                continue
            seen.add(cur)
            comp.append(cur)
            stack.extend(edges[cur] - seen)
        out.append(sorted(comp))
    retval = sorted(out, key=len, reverse=True)
    return retval


def collisions(catalog, edges, threshold=0.20):
    """Pairs whose summaries overlap enough to route the same prompt. A proxy
    for #207's trigger collisions: it flags candidates, it cannot read prose."""
    desc = {s["name"]: words(s.get("summary", "")) for s in catalog["skills"]}
    out = []
    names = sorted(desc)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            x, y = desc[a], desc[b]
            if not x or not y:
                continue
            j = len(x & y) / len(x | y)
            if j >= threshold:
                out.append((round(j, 3), a, b, b in edges[a]))
    retval = sorted(out, reverse=True)
    return retval


def host_split(catalog):
    retval = [
        (s["name"], s.get("hosts", []))
        for s in catalog["skills"]
        if len(s.get("hosts", [])) < 2
    ]
    return retval


def render(root):
    catalog = load(root)
    skills = catalog["skills"]
    total = len(skills)
    names = {s["name"] for s in skills}
    covered, edges, isolated = related_graph(root, catalog)
    comps = components(names, edges)
    clustered = sum(len(c) for c in comps if len(c) > 1)
    pairs = collisions(catalog, edges)
    unlinked = [p for p in pairs if not p[3]]

    lines = []
    lines.append("## Catalog health")
    lines.append("")
    lines.append("Advisory. The blocking half of #222 runs in "
                 "`validate-catalog.sh` on every PR; these are the numbers "
                 "that cannot block yet.")
    lines.append("")
    lines.append("| | |")
    lines.append("|---|---|")
    lines.append(f"| skills | {total} |")
    lines.append(f"| plugins | {len(catalog['plugins'])} |")
    pct = 100 * covered // total if total else 0
    lines.append(f"| `## Related` sections | {covered}/{total} ({pct}%) |")
    lines.append(f"| in a cross-referenced cluster | {clustered}/{total} |")
    lines.append(f"| isolated skills | {len(isolated)} |")
    lines.append(f"| host-only skills | {len(host_split(catalog))} |")
    lines.append(f"| overlapping pairs not cross-referenced | {len(unlinked)} |")
    lines.append("")

    if unlinked:
        lines.append("### Overlapping pairs worth a cross-reference")
        lines.append("")
        lines.append("Summary-word overlap only — a candidate list, not a "
                     "verdict. Two skills can legitimately share vocabulary "
                     "and route different prompts.")
        lines.append("")
        for j, a, b, _ in unlinked[:10]:
            lines.append(f"- `{a}` <-> `{b}` ({j})")
        lines.append("")

    if isolated:
        lines.append("### Skills with no `## Related` section")
        lines.append("")
        lines.append("Each is invisible to the reference checker and to anyone "
                     "navigating between neighbours.")
        lines.append("")
        for chunk in (isolated[i:i + 4] for i in range(0, len(isolated), 4)):
            lines.append("- " + ", ".join(f"`{n}`" for n in chunk))
        lines.append("")

    lines.append("### Clusters")
    lines.append("")
    for comp in comps:
        if len(comp) > 1:
            lines.append(f"- **{len(comp)}** — " + ", ".join(f"`{n}`" for n in comp))
    lines.append("")
    sha = subprocess.run(
        ["git", "rev-parse", "--short", "HEAD"],
        capture_output=True, text=True, cwd=root
    ).stdout.strip()
    lines.append(f"<sub>Generated from `{sha}` by "
                 f"`scripts/catalog-health.py`. Body rewritten in place each "
                 f"run — a fresh issue every week is unread by week three.</sub>")
    retval = "\n".join(lines)
    return retval


def main():
    root = pathlib.Path(__file__).resolve().parent.parent
    print(render(root))
    return 0


if __name__ == "__main__":
    sys.exit(main())
