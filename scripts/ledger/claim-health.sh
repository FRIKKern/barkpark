#!/usr/bin/env bash
# claim-health.sh — read the ledger's SESSION attribution and report collisions.
#
# THE DEFECT (task-f79e39f4992749a5). A worker id is LANE-scoped: every session
# of the cli lane claims, pulses and closes as `lead-cli`. A predecessor that
# wakes on an inbox message therefore writes a ledger BYTE-INDISTINGUISHABLE
# from the live lead's, and no reader could separate them — not because readers
# were careless but because the discriminator was never written down.
#
# THE FIELD THIS READS. `Barkpark.Tasks.SessionId` stores, on the claim itself:
#
#   claim.session         the session that made the LAST write to this lease
#   claim.session_origin  the session that CREATED it
#   claim.closed_session  the session that sealed it
#
# Each is a one-way HMAC of a secret the client holds and the server never
# stores, so it is neither guessable nor replayable off the row. It is
# ATTRIBUTION, never a fence: the CAS still fences on worker + epoch alone, and
# this script reports — it refuses nothing.
#
# ARMS
#   --worker <id>        rows whose claim.worker is <id>            (required)
#   --session <id>       attribute only rows written by <id>; repeatable
#   --held <file>        reconcile a held file against the claimed set, BOTH
#                        directions (in file but not claimed; claimed but not
#                        in file — the silent-lapse mode)
#   --from-file <json>   read rows from a JSON array instead of the server, so
#                        the two discrimination arms are reproducible offline
#   --json               machine output
#
# EXIT: 0 clean · 3 a collision or a held-file gap was reported · 2 usage
#       · 4 UNREADABLE PAGE — rows fetched but no claim found at any known
#         position (never a silent zero; see CLAIM_POSITIONS).
set -uo pipefail

usage() { sed -n '2,30p' "$0"; exit 2; }

WORKER=""; HELD=""; FROM_FILE=""; JSON=0; SESSIONS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --worker)    WORKER="${2:-}"; shift 2 ;;
    --session)   SESSIONS+=("${2:-}"); shift 2 ;;
    --held)      HELD="${2:-}"; shift 2 ;;
    --from-file) FROM_FILE="${2:-}"; shift 2 ;;
    --json)      JSON=1; shift ;;
    -h|--help)   usage ;;
    *)           echo "claim-health: unknown argument $1" >&2; usage ;;
  esac
done
[ -n "$WORKER" ] || { echo "claim-health: --worker is required" >&2; usage; }

# ROWS. --from-file is a literal JSON array of task documents (the `doc` shape
# `bp task get -o json` returns). Without it we ask the server for the rows this
# worker holds. The offline arm exists so the discrimination proof is a RUN with
# fixed input, not a story about a live ledger that moves under the test.
if [ -n "$FROM_FILE" ]; then
  [ -r "$FROM_FILE" ] || { echo "claim-health: cannot read $FROM_FILE" >&2; exit 2; }
  ROWS_JSON="$(cat "$FROM_FILE")"
else
  ROWS_JSON="$(env -u BARKPARK_TOKEN bp task list --assignee "$WORKER" -o json 2>/dev/null \
    | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print("[]"); raise SystemExit
print(json.dumps(d.get("tasks") or d.get("docs") or d.get("items") or d.get("in_progress") or []))')"
fi

SESSION_FILTER="$(printf '%s\n' "${SESSIONS[@]+"${SESSIONS[@]}"}" | grep -v '^$' | paste -sd, - 2>/dev/null || true)"

HELD_IDS=""
if [ -n "$HELD" ]; then
  if [ -r "$HELD" ]; then
    HELD_IDS="$(sed 's/#.*//' "$HELD" | awk 'NF{print $1}' | paste -sd, - 2>/dev/null || true)"
  else
    echo "claim-health: held file $HELD is not readable — the pulse loop reads it too" >&2
    exit 3
  fi
fi

WORKER="$WORKER" SESSION_FILTER="$SESSION_FILTER" HELD="$HELD" HELD_IDS="$HELD_IDS" JSON="$JSON" \
python3 - "$ROWS_JSON" <<'PY'
import json, os, sys

rows = json.loads(sys.argv[1] or "[]")
if isinstance(rows, dict):
    # `in_progress` is `bp task prime`'s carrier: a FOURTH read shape, flat rows
    # with no `docs` key. A hand-listed pair missed it entirely.
    rows = (rows.get("tasks") or rows.get("docs") or rows.get("items")
            or rows.get("in_progress") or [rows])

worker = os.environ["WORKER"]
wanted = [s for s in os.environ.get("SESSION_FILTER", "").split(",") if s]
held_path = os.environ.get("HELD", "")
held_ids = [s for s in os.environ.get("HELD_IDS", "").split(",") if s]
as_json = os.environ.get("JSON") == "1"

# THE CLAIM IS RESOLVED BY SHAPE, NOT BY A PATH (task-3c638f0e2fd435f8).
# This script shipped reading `.content.claim` and reported a CONFIDENT ZERO on
# a page where every row was held: measured 19 of 19 rows carrying a `content`
# key, 19 of 19 carrying `.claim.worker`, and ZERO carrying `.content.claim`.
# It was not missing data -- the claim simply is not in `content`.
#
# There are at least THREE wrong paths in this family (`.doc.claim` on a flat
# row, `.doc.content.claim`, `.content.claim`) and FOUR read shapes that carry a
# claim, so an enumeration of paths is a snapshot. The rule instead: unwrap the
# `doc` envelope if there is one, then take the FIRST position that holds a
# CLAIM-SHAPED object -- a dict carrying a `worker` key. A position that holds
# something else is not a claim, whatever it is called.
#
# THE WIRE SHAPE IS NOT TOUCHED, deliberately. Presence-of-`doc` is the
# load-bearing discriminator that nine shipped readers dispatch on via
# `row.get("doc", row)` -- including this file -- so planting a claim at
# `.doc.claim` on a flat row would CREATE a `doc` key and drop every row in
# those readers. The reader changes; the payload does not.
CLAIM_POSITIONS = (
    ("claim",            lambda d: d.get("claim")),
    ("content.claim",    lambda d: (d.get("content") or {}).get("claim")),
)

def _claim_shaped(v):
    return isinstance(v, dict) and "worker" in v

def claim_of(row):
    doc = row.get("doc") if isinstance(row.get("doc"), dict) else row
    doc_id = doc.get("doc_id") or row.get("doc_id") or "?"
    for _name, get in CLAIM_POSITIONS:
        v = get(doc)
        if _claim_shaped(v):
            return v, doc_id
    return {}, doc_id

def _looks_claimable(row):
    """A row that SHOULD carry a claim: it is a task document, not a stray."""
    doc = row.get("doc") if isinstance(row.get("doc"), dict) else row
    return isinstance(doc, dict) and bool(doc.get("doc_id") or row.get("doc_id"))

attributed, collisions, unattributed = [], [], []
claimed_ids = []

# A FAILED READ MUST NOT BE BYTE-IDENTICAL TO A CLEAN BILL OF HEALTH. If this
# page has rows that look like task documents and NOT ONE of them yields a
# claim-shaped object at any position we know, the page is UNREADABLE and the
# honest answer is a refusal naming where we looked -- not "0 claimed row(s)",
# which is exactly what a healthy empty page prints.
claimable = [r for r in rows if _looks_claimable(r)]
resolved = [r for r in claimable if claim_of(r)[0]]
if claimable and not resolved:
    where = ", ".join(name for name, _ in CLAIM_POSITIONS)
    print(f"claim-health: CANNOT READ -- {len(claimable)} task row(s) fetched and "
          f"NOT ONE carries a claim-shaped object (a dict with a `worker` key) at "
          f"any position this reader knows: {where}. This is an UNREADABLE PAGE, "
          f"not a clean one: a confident zero here is indistinguishable from the "
          f"defect that made this refusal necessary (task-3c638f0e2fd435f8). "
          f"Add the position to CLAIM_POSITIONS, or check the verb -- "
          f"`bp task get/show` nest under `doc`, `ls`/`ready`/`prime` are flat, "
          f"and the claim itself lives at `.claim`.", file=sys.stderr)
    sys.exit(4)

for row in rows:
    claim, doc_id = claim_of(row)
    if claim.get("worker") != worker:
        continue
    claimed_ids.append(doc_id)
    sess = claim.get("session")
    origin = claim.get("session_origin")
    # THE COLLISION. Two sessions of ONE lane touched this lease: the session
    # holding it now is not the one that took it. Reported, never refused --
    # a same-lane re-claim is legitimate, and only the ledger knowing it
    # happened was ever missing.
    if sess and origin and sess != origin:
        collisions.append({"doc_id": doc_id, "worker": worker,
                           "session": sess, "session_origin": origin})
    if not sess:
        # Pre-session rows and sessionless clients. NOT a collision: an absent
        # discriminator is an absent measurement, and saying otherwise would
        # make every claim taken before this shipped look like a conflict.
        unattributed.append({"doc_id": doc_id, "worker": worker})
        continue
    if wanted and sess not in wanted:
        continue
    attributed.append({"doc_id": doc_id, "worker": worker, "session": sess,
                       "session_origin": origin})

missing_from_file, not_claimed = [], []
if held_path:
    # BOTH DIRECTIONS. A row claimed but absent from the held file is the
    # measured silent-lapse mode (task-f0e49432f1653c2f): never pulsed, lease
    # gone, and the handover still called it claimed. A row in the file that
    # this worker does NOT hold is the mirror -- the loop pulses a row it lost.
    missing_from_file = [d for d in claimed_ids if d not in held_ids]
    not_claimed = [d for d in held_ids if d not in claimed_ids]

problem = bool(collisions or missing_from_file or not_claimed)

if as_json:
    print(json.dumps({"worker": worker, "sessions_filtered": wanted,
                      "attributed": attributed, "collisions": collisions,
                      "unattributed": unattributed,
                      "held_file": held_path or None,
                      "claimed_not_in_held_file": missing_from_file,
                      "in_held_file_not_claimed": not_claimed,
                      "ok": not problem}, indent=2))
else:
    print(f"worker {worker}: {len(claimed_ids)} claimed row(s)")
    if wanted:
        print(f"  session filter: {', '.join(wanted)}")
    for a in attributed:
        print(f"  {a['doc_id']}  session={a['session']}  origin={a['session_origin']}")
    for u in unattributed:
        print(f"  {u['doc_id']}  session=<none>  (pre-session row; not a collision)")
    for c in collisions:
        print(f"  SESSION COLLISION {c['doc_id']}: claimed by {c['session_origin']}, "
              f"last written by {c['session']} -- two sessions of worker {worker}")
    if held_path:
        for d in missing_from_file:
            print(f"  HELD-FILE GAP {d}: claimed by {worker} but NOT in {held_path} "
                  f"-- it will never be pulsed and the lease will lapse silently")
        for d in not_claimed:
            print(f"  HELD-FILE STALE {d}: in {held_path} but {worker} does not hold it")
    print("RESULT: " + ("PROBLEMS REPORTED" if problem else "clean"))

sys.exit(3 if problem else 0)
PY
