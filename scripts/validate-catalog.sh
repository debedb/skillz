#!/usr/bin/env bash
set -euo pipefail

# Validate the skillz catalog:
# 1. Every skill referenced in catalog.json has a SKILL.md at its declared path.
# 2. Every SKILL.md begins with a YAML frontmatter block containing `name:`
#    and `description:`.
# 3. Every skill directory on disk is declared in catalog.json (the reverse of
#    check 1 - an undeclared dir is invisible to install.sh, the bundle
#    plugin, and the README, so it ships as a silent no-op).
# 4. Every collection (inline in catalog.json AND in collections/*.json)
#    references known skills.
# 5. install.sh --dry-run works for: default no-arg, --collection pr-loop,
#    --skill work-on-pr, --all.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT/catalog.json"

if [[ ! -f "$CATALOG" ]]; then
  echo "error: $CATALOG not found" >&2
  exit 2
fi

fail=0
note() { echo "  $*"; }
err()  { echo "ERROR: $*" >&2; fail=1; }

echo "Validating catalog at $CATALOG"

CATALOG_JSON="$(cat "$CATALOG")" ROOT="$ROOT" python3 <<'PY'
import json, os, re, sys

root = os.environ["ROOT"]
catalog = json.loads(os.environ["CATALOG_JSON"])

errors = []

skills = catalog.get("skills", [])
skill_names = set()
for s in skills:
    name = s.get("name")
    path = s.get("path")
    if not name or not path:
        errors.append(f"skill entry missing name/path: {s}")
        continue
    skill_names.add(name)
    abs_path = os.path.join(root, path)
    if not os.path.isfile(abs_path):
        errors.append(f"skill '{name}' path does not exist: {path}")
        continue
    with open(abs_path) as f:
        head = f.read(4096)
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n", head, re.DOTALL)
    if not m:
        errors.append(f"skill '{name}' SKILL.md missing YAML frontmatter block")
        continue
    fm = m.group(1)
    if not re.search(r"(?m)^name\s*:", fm):
        errors.append(f"skill '{name}' frontmatter missing `name:`")
    if not re.search(r"(?m)^description\s*:", fm):
        errors.append(f"skill '{name}' frontmatter missing `description:`")

skill_hosts = {s.get("name"): s.get("hosts", []) for s in skills}

# Reverse of the check above: every skill dir on disk must be declared.
# An undeclared dir is invisible to install.sh (including --all), to the
# skillz bundle plugin, and to the README table - it ships as a silent no-op,
# so the author thinks it landed and review sees a green check.
#
# Declared paths are matched rather than directory names, since a catalog
# entry's `name` and its directory need not agree.
declared_dirs = {
    os.path.normpath(os.path.dirname(s["path"]))
    for s in skills
    if s.get("path")
}
skills_root = os.path.join(root, "skills")
if os.path.isdir(skills_root):
    for entry in sorted(os.listdir(skills_root)):
        entry_path = os.path.join(skills_root, entry)
        # Plain files at the top level are left alone, so a future
        # skills/README.md describing the layout would not trip this.
        if not os.path.isdir(entry_path):
            continue
        rel = os.path.normpath(os.path.join("skills", entry))
        if not os.path.isfile(os.path.join(entry_path, "SKILL.md")):
            errors.append(
                f"'{rel}' has no SKILL.md - not a skill; remove it or add one"
            )
            continue
        if rel not in declared_dirs:
            errors.append(
                f"'{rel}' has a SKILL.md but no catalog.json entry - it will "
                f"not install; add it to catalog.json or delete the directory"
            )

# Inline collections in catalog.json
for c in catalog.get("collections", []):
    cname = c.get("name", "<unnamed>")
    for sn in c.get("skills", []):
        if sn not in skill_names:
            errors.append(f"collection '{cname}' references unknown skill '{sn}'")
    cpath = c.get("path")
    if cpath:
        abs_path = os.path.join(root, cpath)
        if not os.path.isfile(abs_path):
            errors.append(f"collection '{cname}' path does not exist: {cpath}")
        else:
            with open(abs_path) as f:
                cdata = json.load(f)
            for sn in cdata.get("skills", []):
                if sn not in skill_names:
                    errors.append(f"collection file '{cpath}' references unknown skill '{sn}'")

# Plugin assets referenced by manifests
for p in catalog.get("plugins", []):
    pname = p.get("name", "<unnamed>")
    for key in (
        "claude_manifest",
        "claude_marketplace",
        "codex_manifest",
        "codex_marketplace",
    ):
        rel = p.get(key)
        if rel and not os.path.isfile(os.path.join(root, rel)):
            errors.append(f"plugin '{pname}' missing {key}: {rel}")

    # For each host manifest (claude_manifest -> claude, codex_manifest ->
    # codex), read that manifest's own `skills` path and verify the dir it
    # points at holds exactly the host-applicable subset of the plugin's
    # declared skills. A claude-only skill must not appear in the codex
    # manifest's dir, and vice versa. Every symlink must resolve under
    # skills/.
    declared_skills = list(p.get("skills", []))
    for key, host in (("claude_manifest", "claude"), ("codex_manifest", "codex")):
        rel = p.get(key)
        if not rel or not rel.startswith("plugins/"):
            continue
        manifest_path = os.path.join(root, rel)
        if not os.path.isfile(manifest_path):
            continue  # missing-manifest already reported above
        plugin_root = os.path.dirname(os.path.dirname(rel))
        try:
            with open(manifest_path) as mf:
                manifest = json.load(mf)
        except ValueError as e:
            errors.append(f"plugin '{pname}' {key} is not valid JSON: {e}")
            continue
        skills_field = manifest.get("skills", "./skills/")
        skills_paths = (
            skills_field if isinstance(skills_field, list) else [skills_field]
        )
        # Claude Code always also scans a default skills/ dir alongside any
        # listed dir, so a leftover skills/ would re-expose every skill even
        # when the manifest points elsewhere. Guard against that.
        norm_paths = {pp.strip("./").rstrip("/") for pp in skills_paths}
        if "skills" not in norm_paths and os.path.isdir(
            os.path.join(root, plugin_root, "skills")
        ):
            errors.append(
                f"plugin '{pname}' {key} points at {skills_paths} but a "
                f"default {plugin_root}/skills/ dir still exists "
                f"(always-scanned; would re-expose skills)"
            )
        expected = {s for s in declared_skills if host in skill_hosts.get(s, [])}
        symlink_skills = set()
        for sp in skills_paths:
            skills_dir = os.path.normpath(os.path.join(root, plugin_root, sp))
            reldir = os.path.relpath(skills_dir, root)
            if not os.path.isdir(skills_dir):
                errors.append(f"plugin '{pname}' {key} skills dir missing: {reldir}")
                continue
            for entry in sorted(os.listdir(skills_dir)):
                link_path = os.path.join(skills_dir, entry)
                if not os.path.islink(link_path):
                    continue
                target = os.path.realpath(link_path)
                expected_prefix = os.path.realpath(os.path.join(root, "skills"))
                if not target.startswith(expected_prefix):
                    errors.append(
                        f"plugin '{pname}' symlink {reldir}/{entry} -> "
                        f"{target} escapes skills/"
                    )
                    continue
                if not os.path.isdir(target):
                    errors.append(
                        f"plugin '{pname}' symlink {reldir}/{entry} broken: "
                        f"{target} not a directory"
                    )
                    continue
                symlink_skills.add(entry)
        if declared_skills and symlink_skills != expected:
            missing = expected - symlink_skills
            extra = symlink_skills - expected
            if missing:
                errors.append(
                    f"plugin '{pname}' {key} dir missing symlinks for: "
                    f"{sorted(missing)}"
                )
            if extra:
                errors.append(
                    f"plugin '{pname}' {key} dir has unexpected symlinks: "
                    f"{sorted(extra)}"
                )

if errors:
    for e in errors:
        print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)

print("catalog OK: %d skill(s), %d collection(s), %d plugin(s)" % (
    len(skills),
    len(catalog.get("collections", [])),
    len(catalog.get("plugins", [])),
))
PY

note "running install.sh --dry-run smoke tests"
"$ROOT/install.sh" --dry-run --target codex >/dev/null \
  || err "default no-arg dry-run failed"
"$ROOT/install.sh" --dry-run --target codex --collection pr-loop >/dev/null \
  || err "--collection pr-loop dry-run failed"
"$ROOT/install.sh" --dry-run --target codex --skill work-on-pr >/dev/null \
  || err "--skill work-on-pr dry-run failed"
"$ROOT/install.sh" --dry-run --target codex --all >/dev/null \
  || err "--all dry-run failed"

if (( fail )); then
  exit 1
fi

echo "OK"
