#!/usr/bin/env bash
# fixture-from-live.sh — turn a LIVE published paper into a rig fixture, then
# print the width-law gate command that photographs it. (ledger: pe-w7-rig-binding-proof)
#
#   bash tooling/paper-excellence/harness/fixture-from-live.sh <slug> [out-dir]
#
# The cold run publishes a paper; to width-check it we render the SAME blocks
# the reader renders, hermetically, through the committed rig. This script is
# the binding between the live store and that rig:
#
#   bp doc get paper <slug> -o json
#     -> the fetch-fixtures.sh python transform (identical shape: _id, title,
#        style, source_rev, blocks — so a harness fixture and a committed panel
#        fixture are byte-compatible and render through the same render.exs)
#     -> a SCRATCH fixture dir (never the committed fixtures/ — a cold-run paper
#        is evidence for one run, not a permanent panel member)
#     -> echo the exact, width-law-pinned gate command to run next.
#
# SHOT_WIDTHS is pinned to 1920,1280,768 so the gate photographs the desktop,
# laptop, and tablet columns the width law is judged at — the same triple the
# verify round used. The gate itself stays hermetic (no server, no network);
# this is the one networked step, exactly like the rig's fetch-fixtures.sh.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/../../.." && pwd)"
RIG_DIR="$REPO_ROOT/tooling/paper-excellence/rig"

SLUG="${1:?usage: fixture-from-live.sh <slug> [out-dir]}"
OUT_DIR="${2:-${FIXTURE_OUT:-${TMPDIR:-/tmp}/pe-cold-fixtures}}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

BP="${BP:-bp}"

echo "fixture-from-live: fetching $SLUG -> $OUT_DIR"
"$BP" doc get paper "$SLUG" -o json | FIXTURE_DIR="$OUT_DIR" python3 -c '
import sys, json, os
d = json.load(sys.stdin)
if not d.get("blocks"):
    sys.exit("fixture-from-live: no blocks for %s (unpublished? wrong slug?)" % d.get("_id"))
out = {"_id": d["_id"], "title": d["title"], "style": d.get("style"),
       "source_rev": d["_rev"], "blocks": d["blocks"]}
path = os.path.join(os.environ["FIXTURE_DIR"], d["_id"] + ".json")
with open(path, "w") as fh:
    json.dump(out, fh, indent=2, ensure_ascii=False, sort_keys=True)
    fh.write("\n")
print("%-36s %3d blocks  %s" % (d["_id"], len(d["blocks"]),
      " ".join(sorted(set(b.get("type","?") for b in d["blocks"])))))
'

FIXTURE="$OUT_DIR/$SLUG.json"
[ -f "$FIXTURE" ] || { echo "fixture-from-live: FAIL — no fixture written at $FIXTURE" >&2; exit 1; }

echo "fixture-from-live: PASS — $FIXTURE"
echo
echo "  Width-law gate (hermetic render + photograph at desktop/laptop/tablet):"
echo
echo "    SHOT_WIDTHS='1920,1280,768' bash $RIG_DIR/gate.sh $FIXTURE $OUT_DIR/shots"
echo
