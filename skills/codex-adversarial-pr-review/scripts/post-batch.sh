#!/bin/bash
#
# post-batch.sh -- post the payloads saved by batch-review.sh as GitHub PR reviews.
#
# Each pr-N.json produced by `--dry-run` is byte-for-byte the review POST body,
# so this needs no Codex pass at all.
#
# Usage:
#   post-batch.sh --repo owner/name --out DIR [--dry-run]
#
# To drop a finding you judged a false positive before posting, edit the payload:
#   jq '.comments |= map(select((.body|test("PATTERN"))|not))' pr-N.json > tmp && mv tmp pr-N.json
set -uo pipefail

REPO=""; OUT=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO=$2; shift 2;;
    --out) OUT=$2; shift 2;;
    --dry-run) DRY=1; shift;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done
[ -n "$REPO" ] && [ -n "$OUT" ] || { echo "--repo and --out are required" >&2; exit 2; }

ok=0; fail=0
for p in $(find "$OUT/payloads" -name 'pr-*.json' -size +0 | sort -V); do
  n=$(basename "$p" .json); n=${n#pr-}
  if [ "$DRY" = 1 ]; then
    v=$(jq -r '.body' "$p" | grep -m1 '^## Codex' | sed 's/.*— //')
    echo "would post $n ($v, $(jq '.comments|length' "$p") inline)"
    continue
  fi
  if gh api "repos/$REPO/pulls/$n/reviews" --method POST --input "$p" \
       >/dev/null 2>"$OUT/logs/post-$n.err"; then
    echo "posted $n"; ok=$((ok+1))
  else
    echo "FAILED $n: $(tail -2 "$OUT/logs/post-$n.err" | tr '\n' ' ')"; fail=$((fail+1))
  fi
done
[ "$DRY" = 1 ] || echo "posted=$ok failed=$fail"
