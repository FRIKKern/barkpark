#!/usr/bin/env bash
# Refresh the committed fixtures from the live Barkpark store, via the bp CLI.
#
#   bash tooling/paper-excellence/rig/fetch-fixtures.sh [slug …]
#
# This is the ONLY networked step in the rig, and it is a REFRESH tool, not
# part of the gate: the gate renders the committed JSON so it stays hermetic
# and reproducible. Each fixture records the source `_rev` it was taken from,
# so a stale baseline is provable rather than guessable.
set -euo pipefail

RIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLUGS=("$@")
if [ ${#SLUGS[@]} -eq 0 ]; then
  # Every PUBLISHED fixture in the committed panel. eight-minute-erasure was
  # missing from this list, so a bare refresh silently never touched it — that
  # omission is exactly how it drifted (found 2026-08-17, ledger
  # pe-w3-rig-fresh-pixels-drift-and-schema-gaps-2026-08-17.md). design-probe is
  # deliberately absent: it is AUTHORED (BPML, no published paper behind it) and
  # has no live document to refresh from. So is stat-partial-row (authored JSON,
  # the eleven-stat partial-row geometry — see its `_source`).
  SLUGS=(eight-minute-erasure heggemsnes-act hobby-hardening-capstone \
         mechanical-spacing-doctrine paper-excellence-wave-2026-08-12 \
         portabledoc-showcase)
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
