#!/usr/bin/env bash
set -euo pipefail

# Validate the skillz catalog:
# 1. Every skill referenced in catalog.json has a SKILL.md at its declared path.
# 2. Every SKILL.md begins with a YAML frontmatter block containing `name:`
#    and `description:`.
# 3. Every collection (inline in catalog.json AND in collections/*.json)
#    references known skills.
# 4. install.sh --dry-run works for: default no-arg, --collection pr-loop,
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

    # For each plugin manifest under plugins/<name>/, verify the sibling
    # skills/ dir exists and every symlink in it resolves to a real skill
    # directory under skills/.
    declared_skills = set(p.get("skills", []))
    plugin_dirs = set()
    for key in ("claude_manifest", "codex_manifest"):
        rel = p.get(key)
        if rel and rel.startswith("plugins/"):
            plugin_dirs.add(os.path.dirname(os.path.dirname(rel)))
    for pdir in plugin_dirs:
        skills_dir = os.path.join(root, pdir, "skills")
        if not os.path.isdir(skills_dir):
            errors.append(f"plugin '{pname}' missing skills/ dir: {pdir}/skills")
            continue
        symlink_skills = set()
        for entry in sorted(os.listdir(skills_dir)):
            link_path = os.path.join(skills_dir, entry)
            if not os.path.islink(link_path):
                continue
            target = os.path.realpath(link_path)
            expected_prefix = os.path.realpath(os.path.join(root, "skills"))
            if not target.startswith(expected_prefix):
                errors.append(
                    f"plugin '{pname}' symlink {pdir}/skills/{entry} -> "
                    f"{target} escapes skills/"
                )
                continue
            if not os.path.isdir(target):
                errors.append(
                    f"plugin '{pname}' symlink {pdir}/skills/{entry} broken: "
                    f"{target} not a directory"
                )
                continue
            symlink_skills.add(entry)
        if declared_skills and symlink_skills != declared_skills:
            missing = declared_skills - symlink_skills
            extra = symlink_skills - declared_skills
            if missing:
                errors.append(
                    f"plugin '{pname}' skills/ missing symlinks for: "
                    f"{sorted(missing)}"
                )
            if extra:
                errors.append(
                    f"plugin '{pname}' skills/ has unexpected symlinks: "
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
