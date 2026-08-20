#!/usr/bin/env bash
# epic-zero-criteria-census.sh — counts the LIVE children of an epic that carry
# ZERO acceptance criteria, and reds while any remain. A census that can lose.
#
# THE DEFECT IT EXISTS FOR, measured 2026-08-07 on the deploy-reliability epic
# (task-fb4fb869490b4213). The epic had 196 children and SEVENTEEN carried no
# acceptance criteria at all — while the epic's own earlier census, written by
# hand into a decision row, said fifteen. It was stale by sixteen rows within
# hours of being written, because TWO of the seventeen were filed by the very
# wave that counted fifteen. The class reproduces faster than a hand count gets
# written down, so the count has to be a COMMAND, not a paragraph.
#
# AND IT IS NOT PAPERWORK. A zero-criteria task is structurally broken in three
# live consumers, each of which fails SILENTLY:
#   internal/cli/cmux_hook.go   returns (0, false) for an absent criteria list —
#                               its own comment says a task with no criteria can
#                               never be PROVEN done on a turn boundary. So the
#                               row is unclosable by the hook and lease-expires
#                               instead of finishing.
#   tooling/fleet/fleet-run.sh  silently demotes such a row from tier-1
#                               PATH-READ to tier-3.
#   api/lib/barkpark/tasks/criteria.ex
#                               returns nil when criteria are absent, which is
#                               exactly how seventeen rows stayed invisible to
#                               every board that renders percent-complete.
# A row with no criteria therefore reads as "0 of 0" — vacuously green — on the
# surfaces, while being unfinishable on the machinery.
#
# WHAT COUNTS AS LIVE, and why the population is narrow on purpose.
# Only lifecycle_status open or in_progress. A DONE row that predates the
# criteria requirement is history and cannot be repaired by writing criteria
# at it; a CANCELLED row owes a REASON, not criteria, and manufacturing
# criteria for it would invent an obligation nobody intends to discharge.
# Those two are printed as CONTEXT, never counted — a number that quietly
# includes rows nobody will ever act on is a number that gets ignored.
#
# THIS SCRIPT IS A CENSUS, NOT A PUBLISH WALL. It does not stop a criteria-less
# task from being CREATED — that is a different seam (the AuthoringWall
# publish-time guard) whose grandfathering of the legacy corpus is unverified
# and is filed separately. This instrument answers "how many are there right
# now, and which ones", repeatably, after the fact.
#
# EXIT CODES
#   0  SILENT — every live child of the epic carries at least one criterion
#   1  SCREAM — at least one live child carries zero; they are named
#   2  UNKNOWN — the ledger could not be read, or carried no children key.
#      NEVER green. A census that cannot see is not a census that found
#      nothing; that confusion is the epic's own sixth clause.
#
# USAGE
#   scripts/epic-zero-criteria-census.sh                      # the deploy-reliability epic
#   scripts/epic-zero-criteria-census.sh <epic-task-id>       # any epic
#   scripts/epic-zero-criteria-census.sh --fixture <file>     # hermetic; reads a
#                                                             # saved `bp task get -o json`
#   scripts/epic-zero-criteria-census.sh --self-test          # proves it can lose
#
# HERMETIC MODE reads one file — the JSON body of `bp task get <epic> -o json`
# — and touches no network, so the harness can pin both verdicts.

set -uo pipefail

DEFAULT_EPIC="task-fb4fb869490b4213"   # deploy-reliability
EPIC=""
FIXTURE=""
SELF_TEST=0

usage() { sed -n '2,58p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --fixture)   FIXTURE="$2"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    --*)         echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)           EPIC="$1"; shift ;;
  esac
done

[ -n "$EPIC" ] || EPIC="$DEFAULT_EPIC"

# The classifier IS python, so its absence must land on this script's own
# UNKNOWN contract rather than on a bare 127 that a caller would read as an
# unrelated crash. Checked before any mode runs, --self-test included.
if ! command -v python3 >/dev/null 2>&1; then
  echo "UNKNOWN: python3 is not on PATH, so the ledger cannot be classified." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# The classifier. Reads the ledger JSON on stdin and prints a report. Kept in
# one python block because the whole judgement is "which rows are live, and
# which of those have an EMPTY criteria list" — splitting that across jq and
# shell is how the empty-vs-absent distinction gets lost.
# ---------------------------------------------------------------------------
#
# The program is passed with `python3 -c`, NOT a heredoc: a heredoc IS stdin,
# so `python3 - <<PY` would eat the ledger and every classification would come
# back UNKNOWN. The self-test below caught exactly that, which is the point of
# having one.
# shellcheck disable=SC2016  # single quotes are the point: this is python source, not shell
CLASSIFY_PY='
import json, sys

label = sys.argv[1]
raw = sys.stdin.read()

try:
    doc = json.loads(raw)
except Exception as exc:
    print("UNKNOWN: ledger for %s is not JSON (%s)" % (label, exc))
    sys.exit(2)

# `bp task get` puts children beside the doc, not inside its content.
if not isinstance(doc, dict) or "children" not in doc:
    # An epic with genuinely no children still carries the key. Its ABSENCE
    # means the read failed or the shape changed — do not read that as zero.
    print("UNKNOWN: ledger for %s carries no `children` key — read failed or "
          "the payload shape changed. Refusing to report a count." % label)
    sys.exit(2)

children = doc["children"]
if not isinstance(children, list):
    print("UNKNOWN: `children` for %s is %s, not a list."
          % (label, type(children).__name__))
    sys.exit(2)

LIVE = ("open", "in_progress")


def total(child):
    # criteria_progress is ABSENT (not zero) on a row with no criteria at all,
    # which is precisely the shape being hunted. `or {}` collapses both the
    # missing key and an explicit null onto the same answer.
    return (child.get("criteria_progress") or {}).get("total", 0) or 0


zero = [c for c in children if total(c) == 0]
live_zero = [c for c in zero if c.get("lifecycle_status") in LIVE]
dead_zero = [c for c in zero if c.get("lifecycle_status") not in LIVE]

print("epic %s — %d children, %d carry zero acceptance criteria"
      % (label, len(children), len(zero)))

if dead_zero:
    print("")
    print("  context, NOT counted (%d) — done rows predate the requirement, "
          "cancelled rows owe a reason rather than criteria:" % len(dead_zero))
    for c in sorted(dead_zero, key=lambda c: c.get("doc_id", "")):
        print("    %-12s %s" % (c.get("lifecycle_status", "?"), c.get("doc_id", "?")))

print("")
print("LIVE ZERO-CRITERIA: %d" % len(live_zero))
for c in sorted(live_zero, key=lambda c: c.get("doc_id", "")):
    print("  %-12s %-46s %s"
          % (c.get("lifecycle_status", "?"), c.get("doc_id", "?"),
             (c.get("title") or "")[:70]))

if live_zero:
    print("")
    print("SCREAM: a live task with no criteria cannot be PROVEN done on a "
          "turn boundary (cmux_hook.go), is demoted out of tier-1 by "
          "fleet-run.sh, and renders as vacuously green on every board. "
          "Give each row above at least one concrete, evidence-bearing "
          "criterion — or, if it is genuinely dead, close or cancel it with "
          "a reason so it leaves this population honestly.")
    sys.exit(1)

print("SILENT: every live child carries at least one acceptance criterion.")
sys.exit(0)
'

classify() {
  python3 -c "$CLASSIFY_PY" "$1"
}

# ---------------------------------------------------------------------------
# Self-test — the gate has to be able to LOSE, and that is proved by running it
# against a corpus that SHOULD red, not by reading the code.
# ---------------------------------------------------------------------------
if [ "$SELF_TEST" = "1" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  fails=0

  check() { # name expected_rc actual_rc
    if [ "$2" = "$3" ]; then
      echo "  ok    $1 (exit $3)"
    else
      echo "  FAIL  $1 — expected exit $2, got $3"
      fails=$((fails + 1))
    fi
  }

  echo "self-test: epic-zero-criteria-census.sh"

  # 1. A dirty corpus must SCREAM. If this ever returns 0 the gate is decorative.
  cat >"$tmp/dirty.json" <<'JSON'
{"children": [
  {"doc_id": "has-criteria", "lifecycle_status": "open",
   "criteria_progress": {"met": 0, "total": 3}, "title": "fine"},
  {"doc_id": "bare-open", "lifecycle_status": "open", "title": "no criteria"},
  {"doc_id": "bare-in-progress", "lifecycle_status": "in_progress",
   "criteria_progress": null, "title": "explicit null"}
]}
JSON
  out="$(classify dirty <"$tmp/dirty.json")"; rc=$?
  check "a dirty corpus reds" 1 "$rc"
  case "$out" in
    *"LIVE ZERO-CRITERIA: 2"*) echo "  ok    it names both shapes (absent key AND explicit null)" ;;
    *) echo "  FAIL  expected 2 live zero-criteria rows; got:"; echo "$out"; fails=$((fails + 1)) ;;
  esac

  # 2. A clean corpus must go green — otherwise the gate can never be satisfied
  #    and will be routed around within a wave.
  cat >"$tmp/clean.json" <<'JSON'
{"children": [
  {"doc_id": "has-criteria", "lifecycle_status": "open",
   "criteria_progress": {"met": 1, "total": 3}, "title": "fine"},
  {"doc_id": "legacy-done", "lifecycle_status": "done", "title": "predates the rule"},
  {"doc_id": "dropped", "lifecycle_status": "cancelled", "title": "owes a reason"}
]}
JSON
  out="$(classify clean <"$tmp/clean.json")"; rc=$?
  check "a clean corpus goes green" 0 "$rc"
  case "$out" in
    *"context, NOT counted (2)"*) echo "  ok    done + cancelled are shown as context, not counted" ;;
    *) echo "  FAIL  expected the 2 dead rows reported as uncounted context"; fails=$((fails + 1)) ;;
  esac

  # 3. An unreadable ledger must be UNKNOWN, never green. This is the case that
  #    matters most: reporting 0 for "I could not look" is the exact failure
  #    this epic exists to stop.
  printf 'not json at all' >"$tmp/garbage.json"
  classify garbage <"$tmp/garbage.json" >/dev/null; rc=$?
  check "unreadable ledger is UNKNOWN, not green" 2 "$rc"

  printf '{"doc_id":"epic","title":"no children key"}' >"$tmp/shapeless.json"
  classify shapeless <"$tmp/shapeless.json" >/dev/null; rc=$?
  check "a payload with no children key is UNKNOWN, not zero" 2 "$rc"

  printf '{"children": {"doc_id": "not-a-list"}}' >"$tmp/wrongtype.json"
  classify wrongtype <"$tmp/wrongtype.json" >/dev/null; rc=$?
  check "a non-list children key is UNKNOWN" 2 "$rc"

  # 4. An epic with genuinely no children is green, not UNKNOWN — the empty
  #    list and the absent key must not collapse onto one answer.
  printf '{"children": []}' >"$tmp/empty.json"
  classify empty <"$tmp/empty.json" >/dev/null; rc=$?
  check "an epic with zero children is green (empty list != absent key)" 0 "$rc"

  echo ""
  if [ "$fails" -eq 0 ]; then
    echo "self-test: PASS"
    exit 0
  fi
  echo "self-test: $fails FAILED"
  exit 1
fi

# ---------------------------------------------------------------------------
# Live run.
# ---------------------------------------------------------------------------
if [ -n "$FIXTURE" ]; then
  if [ ! -r "$FIXTURE" ]; then
    echo "UNKNOWN: fixture $FIXTURE is not readable." >&2
    exit 2
  fi
  classify "$EPIC" <"$FIXTURE"
  exit $?
fi

if ! command -v bp >/dev/null 2>&1; then
  echo "UNKNOWN: bp is not on PATH, so the ledger cannot be read." >&2
  exit 2
fi

# The read is deliberately NOT piped straight into the classifier: a pipeline
# swallows bp's own exit status, and a transport failure that printed nothing
# would then be classified as unparseable rather than reported as what it is.
ledger="$(bp task get "$EPIC" -o json 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ] || [ -z "$ledger" ]; then
  echo "UNKNOWN: \`bp task get $EPIC -o json\` failed (exit $rc) or returned nothing." >&2
  exit 2
fi

printf '%s' "$ledger" | classify "$EPIC"
