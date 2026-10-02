#!/usr/bin/env bash
# Refresh the committed fixtures from the live Barkpark store, via the bp CLI.
#
#   bash tooling/paper-excellence/rig/fetch-fixtures.sh [slug …]
#   bash tooling/paper-excellence/rig/fetch-fixtures.sh --list   # no network
#
# This is the ONLY networked step in the rig, and it is a REFRESH tool, not
# part of the gate: the gate renders the committed JSON so it stays hermetic
# and reproducible. Each fixture records the source `_rev` it was taken from,
# so a stale baseline is provable rather than guessable.
#
# THE DEFAULT LIST IS DERIVED, NEVER CURATED (task-15d30569241d3542). It used
# to be a hand-written array of slugs, and a hand-written list is a snapshot of
# the panel on the day someone typed it: `eight-minute-erasure` drifted purely
# by being absent from it (2026-08-17, ledger
# pe-w3-rig-fresh-pixels-drift-and-schema-gaps-2026-08-17.md), and
# `agent-flight-recorder-charter` (added 2026-09-10 by #17199) was absent from
# it again three weeks later. `baseline.sh` and `gate.sh --panel` had already
# stopped curating and derive their slug sets from `fixtures/*.json`; this one
# now does too.
#
# THE PREDICATE, not a skip list. Every committed fixture declares exactly one
# provenance key at its top level:
#
#   `source_rev`  PUBLISHED — fetched from a live paper, refreshable. In.
#   `_source`     AUTHORED  — written by hand (BPML or JSON), no live document
#                             stands behind the slug, so `bp doc get` would
#                             404. Out. Today that is `design-probe` and
#                             `stat-partial-row`; naming them here would be a
#                             list again, so nothing is named — the key is.
#
# `fixture-list-check.sh` re-derives the same set independently (node, not
# python) and reds if this script's `--list` and that derivation disagree, or
# if any fixture carries both keys or neither. `gate.sh` runs it on every run,
# so CI reds if the list is ever hand-written back.
set -euo pipefail

RIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Every PUBLISHED fixture in the committed panel, derived from the files.
default_slugs() {
  python3 - "$RIG_DIR/fixtures" <<'PY'
import json, os, sys

fixtures = sys.argv[1]
for name in sorted(os.listdir(fixtures)):
    if not name.endswith(".json"):
        continue
    with open(os.path.join(fixtures, name)) as fh:
        doc = json.load(fh)
    published = "source_rev" in doc
    authored = "_source" in doc
    if published == authored:
        sys.exit(
            "fixtures/%s must carry exactly one of `source_rev` (published) or "
            "`_source` (authored) — it carries %s"
            % (name, "both" if published else "neither")
        )
    if published:
        print(name[: -len(".json")])
PY
}

LIST_ONLY=0
if [ "${1:-}" = "--list" ]; then
  [ $# -eq 1 ] || { echo "fetch-fixtures: --list takes no other arguments" >&2; exit 2; }
  LIST_ONLY=1
  shift
fi

# ONE resolution path. `--list` prints the slugs a bare run would fetch by
# walking the SAME branch a bare run walks — if it read `default_slugs`
# directly it would report on a derivation nobody uses, and a hand-written
# array reinstated below would print derived and fetch curated
# (caught 2026-09-12 when the first mutation proof came back green).
SLUGS=("$@")
if [ ${#SLUGS[@]} -eq 0 ]; then
  while IFS= read -r slug; do
    SLUGS+=("$slug")
  done < <(default_slugs)
  [ ${#SLUGS[@]} -gt 0 ] || { echo "fetch-fixtures: no published fixtures under $RIG_DIR/fixtures" >&2; exit 2; }
fi

if [ "$LIST_ONLY" = 1 ]; then
  printf '%s\n' "${SLUGS[@]}"
  exit 0
fi

mkdir -p "$RIG_DIR/fixtures"
for slug in "${SLUGS[@]}"; do
  bp doc get paper "$slug" -o json | FIXTURE_DIR="$RIG_DIR/fixtures" python3 -c '
import sys, json, os, collections
d = json.load(sys.stdin)
if not d.get("blocks"):
    sys.exit("no blocks for %s" % d.get("_id"))
out = {"_id": d["_id"], "title": d["title"], "style": d.get("style"),
       "source_rev": d["_rev"], "blocks": d["blocks"]}
path = os.path.join(os.environ["FIXTURE_DIR"], d["_id"] + ".json")
with open(path, "w") as fh:
    json.dump(out, fh, indent=2, ensure_ascii=False, sort_keys=True)
    fh.write("\n")
print("%-36s %3d blocks  %s" % (d["_id"], len(d["blocks"]),
      " ".join(sorted(set(b.get("type","?") for b in d["blocks"])))))
'
done
