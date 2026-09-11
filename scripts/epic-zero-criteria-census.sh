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
# ABSENT KEY vs EMPTY ARRAY — WHY THEY ARE SEPARATE CLASSES HERE.
# `Criteria.progress/1` collapses four different rows onto ONE answer, nil:
# the `acceptance_criteria` key ABSENT, an explicit null, an EMPTY list, and
# non-list garbage (criteria.ex moduledoc, "criteria absent, `nil`, `[]`, or
# non-list garbage → nil"). `criteria_progress` on the wire therefore CANNOT
# tell them apart, and until 2026-09-11 neither could this census: it read
# only `criteria_progress.total`, so an absent-key row and an emptied-out row
# printed on the same list under one count. They are not the same defect and
# they do not have the same remedy:
#   ABSENT      the row was filed by a path that never writes the key at all
#               (a script, an import, an older client). The AUTHORING path is
#               broken — fixing one row fixes nothing.
#   EMPTY       the key exists and someone left `[]` there — a human or a tool
#               deliberately wrote an empty checklist. The ROW is broken.
#   MALFORMED   the key exists holding null or non-list garbage — a WRITER bug
#               that Validation let through; the store now holds a shape no
#               consumer reads.
# So each is printed as its own class, with its own row ids.
#
# WHERE THE SHAPE COMES FROM. `bp task get <epic> -o json` returns children as
# SUMMARIES — `doc_id, lifecycle_status, title, criteria_progress, …` and NO
# nested `doc` (verified 2026-09-11 on cch-instruments-epic: 296 children, 296
# with no `doc` key). The summary literally cannot carry the distinction. So:
#   * a child that carries a nested `doc.content` (a fixture, or a row this
#     script RESOLVED) is classified exactly, absent vs empty vs malformed;
#   * a child that carries only the summary is reported as INDETERMINATE — its
#     own loud class, never folded into either real one;
#   * in LIVE mode every live INDETERMINATE row is then RESOLVED by a per-row
#     `bp task get <doc_id> -o json` (the fetch command is overridable through
#     $BP_TASK_GET_CMD so the self-test can pin it hermetically), and the
#     census re-classifies on the enriched payload.
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
#   1  SCREAM — at least one live child carries zero; they are named, by class
#   2  UNKNOWN — the ledger could not be read, or carried no children key.
#      NEVER green. A census that cannot see is not a census that found
#      nothing; that confusion is the epic's own sixth clause.
#
# USAGE
#   scripts/epic-zero-criteria-census.sh                      # the deploy-reliability epic
#   scripts/epic-zero-criteria-census.sh <epic-task-id>       # any epic
#   scripts/epic-zero-criteria-census.sh --fixture <file>     # hermetic; reads a
#                                                             # saved `bp task get -o json`
#   scripts/epic-zero-criteria-census.sh --no-resolve         # live, but skip the
#                                                             # per-row shape resolution
#   scripts/epic-zero-criteria-census.sh --fixture <f> --resolve
#                                                             # resolve a fixture's
#                                                             # summary rows too (NOT
#                                                             # hermetic: it reads rows)
#   scripts/epic-zero-criteria-census.sh --self-test          # proves it can lose
#
# HERMETIC MODE reads one file — the JSON body of `bp task get <epic> -o json`
# — and touches no network, so the harness can pin both verdicts.

set -uo pipefail

DEFAULT_EPIC="task-fb4fb869490b4213"   # deploy-reliability
EPIC=""
FIXTURE=""
SELF_TEST=0
RESOLVE="auto"   # auto: on for a live read, off for a fixture (hermetic by default)

usage() { sed -n '2,92p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --fixture)    FIXTURE="$2"; shift 2 ;;
    --self-test)  SELF_TEST=1; shift ;;
    --resolve)    RESOLVE=1; shift ;;
    --no-resolve) RESOLVE=0; shift ;;
    -h|--help)    usage; exit 0 ;;
    --*)          echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)            EPIC="$1"; shift ;;
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


def content_of(child):
    # The nested task document, when the payload carries one. A `bp task get
    # <epic>` child is a SUMMARY and carries none; a fixture, or a row this
    # script resolved with a per-row read, does.
    if not isinstance(child, dict):
        return None
    nested = child.get("doc")
    if isinstance(nested, dict) and isinstance(nested.get("content"), dict):
        return nested["content"]
    if isinstance(child.get("content"), dict):
        return child["content"]
    return None


def total(child):
    # criteria_progress is ABSENT (not zero) on a row with no criteria at all,
    # which is precisely the shape being hunted. `or {}` collapses both the
    # missing key and an explicit null onto the same answer.
    return (child.get("criteria_progress") or {}).get("total", 0) or 0


def shape(child):
    # Returns one of: has | absent | empty | malformed | indeterminate.
    # Read the DOCUMENT when it is there — criteria_progress cannot tell
    # absent from empty and never could (criteria.ex: absent, nil, [] and
    # garbage all return nil).
    content = content_of(child)
    if content is None:
        return "has" if total(child) > 0 else "indeterminate"
    if "acceptance_criteria" not in content:
        return "absent"
    value = content["acceptance_criteria"]
    if isinstance(value, list):
        return "has" if value else "empty"
    return "malformed"


CLASS_ORDER = ("absent", "empty", "malformed", "indeterminate")
CLASS_HEADING = {
    "absent": "ABSENT acceptance_criteria key — the AUTHORING path never wrote "
              "it; fixing one row fixes nothing",
    "empty": "EMPTY acceptance_criteria array — the key exists holding []; the "
             "ROW is broken",
    "malformed": "MALFORMED acceptance_criteria — the key exists holding null "
                 "or non-list garbage; a WRITER bug",
    "indeterminate": "INDETERMINATE — this payload carries only the summary "
                     "(criteria_progress), which collapses absent and empty "
                     "onto one nil; resolve with `bp task get <id> -o json`",
}

classified = [(shape(c), c) for c in children if isinstance(c, dict)]
zero = [(s, c) for s, c in classified if s != "has"]
live_zero = [(s, c) for s, c in zero if c.get("lifecycle_status") in LIVE]
dead_zero = [(s, c) for s, c in zero if c.get("lifecycle_status") not in LIVE]

print("epic %s — %d children, %d carry zero acceptance criteria"
      % (label, len(children), len(zero)))

if dead_zero:
    print("")
    print("  context, NOT counted (%d) — done rows predate the requirement, "
          "cancelled rows owe a reason rather than criteria:" % len(dead_zero))
    for s, c in sorted(dead_zero, key=lambda sc: sc[1].get("doc_id", "")):
        print("    %-13s %-12s %s"
              % (s, c.get("lifecycle_status", "?"), c.get("doc_id", "?")))

print("")
print("LIVE ZERO-CRITERIA: %d" % len(live_zero))
for name in CLASS_ORDER:
    rows = [c for s, c in live_zero if s == name]
    if not rows:
        continue
    print("")
    print("  %s (%d) — %s" % (name.upper(), len(rows), CLASS_HEADING[name]))
    for c in sorted(rows, key=lambda c: c.get("doc_id", "")):
        print("    %-12s %-46s %s"
              % (c.get("lifecycle_status", "?"), c.get("doc_id", "?"),
                 (c.get("title") or "")[:70]))

if live_zero:
    print("")
    print("SCREAM: a live task with no criteria cannot be PROVEN done on a "
          "turn boundary (cmux_hook.go), is demoted out of tier-1 by "
          "fleet-run.sh, and renders as vacuously green on every board. "
          "Give each row above at least one concrete, evidence-bearing "
          "criterion — or, if it is genuinely dead, close or cancel it with "
          "a reason so it leaves this population honestly. An ABSENT class "
          "with rows in it is a bigger finding than the rows: some writer is "
          "filing published tasks without the key at all.")
    sys.exit(1)

print("SILENT: every live child carries at least one acceptance criterion.")
sys.exit(0)
'

classify() {
  python3 -c "$CLASSIFY_PY" "$1"
}

# ---------------------------------------------------------------------------
# Shape resolution. The epic read hands back SUMMARIES, which cannot separate
# an absent key from an empty array — so live INDETERMINATE rows get one
# per-row `bp task get <doc_id> -o json` each and the fetched `doc` is grafted
# onto the child before classification. The fetch is a variable so the
# self-test can substitute a stub and pin this path without a network.
# ---------------------------------------------------------------------------
BP_TASK_GET_CMD="${BP_TASK_GET_CMD:-bp task get}"

# shellcheck disable=SC2016  # python source, not shell
RESOLVE_PY='
import json, os, sys

mode = sys.argv[1]
raw = sys.stdin.read()
try:
    doc = json.loads(raw)
except Exception:
    sys.stdout.write(raw if mode == "merge" else "")
    sys.exit(0)

children = doc.get("children") if isinstance(doc, dict) else None
if not isinstance(children, list):
    sys.stdout.write(raw if mode == "merge" else "")
    sys.exit(0)

LIVE = ("open", "in_progress")


def needs_resolution(child):
    if not isinstance(child, dict):
        return False
    if child.get("lifecycle_status") not in LIVE:
        return False
    nested = child.get("doc")
    if isinstance(nested, dict) and isinstance(nested.get("content"), dict):
        return False
    if isinstance(child.get("content"), dict):
        return False
    return not ((child.get("criteria_progress") or {}).get("total", 0) or 0)


if mode == "ids":
    for c in children:
        if needs_resolution(c) and c.get("doc_id"):
            print(c["doc_id"])
    sys.exit(0)

# merge: graft each fetched row document onto its child.
fetched_dir = os.environ["RESOLVE_DIR"]
for c in children:
    if not needs_resolution(c):
        continue
    path = os.path.join(fetched_dir, "%s.json" % c.get("doc_id", ""))
    if not os.path.exists(path):
        continue
    try:
        with open(path) as fh:
            row = json.load(fh)
    except Exception:
        continue
    nested = row.get("doc") if isinstance(row, dict) else None
    if isinstance(nested, dict) and isinstance(nested.get("content"), dict):
        c["doc"] = nested
json.dump(doc, sys.stdout)
'

resolve_shapes() { # stdin: ledger json -> stdout: enriched ledger json
  local ledger ids dir id out
  ledger="$(cat)"
  ids="$(printf '%s' "$ledger" | python3 -c "$RESOLVE_PY" ids)"
  if [ -z "$ids" ]; then
    printf '%s' "$ledger"
    return 0
  fi
  dir="$(mktemp -d)"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    # shellcheck disable=SC2086  # BP_TASK_GET_CMD is a command + args, split on purpose
    out="$($BP_TASK_GET_CMD "$id" -o json 2>/dev/null)"
    if [ -n "$out" ]; then
      printf '%s' "$out" >"$dir/$id.json"
    else
      echo "  note: could not resolve the criteria shape of $id (per-row read failed); it stays INDETERMINATE" >&2
    fi
  done <<EOF
$ids
EOF
  printf '%s' "$ledger" | RESOLVE_DIR="$dir" python3 -c "$RESOLVE_PY" merge
  rm -rf "$dir"
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

  expect() { # name haystack needle
    case "$2" in
      *"$3"*) echo "  ok    $1" ;;
      *) echo "  FAIL  $1 — expected to find: $3"; echo "$2"; fails=$((fails + 1)) ;;
    esac
  }

  refute() { # name haystack needle
    case "$2" in
      *"$3"*) echo "  FAIL  $1 — did NOT expect: $3"; echo "$2"; fails=$((fails + 1)) ;;
      *) echo "  ok    $1" ;;
    esac
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
  expect "it names both summary-shaped rows" "$out" "LIVE ZERO-CRITERIA: 2"

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
  expect "done + cancelled are shown as context, not counted" "$out" "context, NOT counted (2)"

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

  # 5. THE ABSENT-KEY ARM. Two PUBLISHED rows, identical on the wire summary
  #    (criteria_progress is nil for both — criteria.ex collapses absent, nil,
  #    [] and garbage onto nil), different in the document: one has no
  #    `acceptance_criteria` key at all, one holds []. They must print as two
  #    SEPARATE classes, each naming its own row id. Fold the absent arm into
  #    the empty one — make `shape()` return "empty" for a missing key — and
  #    the ABSENT assertions below go red while the count stays 2.
  cat >"$tmp/absent-vs-empty.json" <<'JSON'
{"children": [
  {"doc_id": "row-absent-key", "lifecycle_status": "open", "title": "key never written",
   "doc": {"status": "published", "content": {"title": "t", "description": "d"}}},
  {"doc_id": "row-empty-array", "lifecycle_status": "open", "title": "key holds []",
   "doc": {"status": "published", "content": {"title": "t", "acceptance_criteria": []}}},
  {"doc_id": "row-null-criteria", "lifecycle_status": "in_progress", "title": "key holds null",
   "doc": {"status": "published", "content": {"acceptance_criteria": null}}},
  {"doc_id": "row-has-criteria", "lifecycle_status": "open", "title": "fine",
   "doc": {"status": "published",
           "content": {"acceptance_criteria": [{"criterion": "a", "met": false}]}}}
]}
JSON
  out="$(classify absent-vs-empty <"$tmp/absent-vs-empty.json")"; rc=$?
  check "absent + empty + malformed rows red" 1 "$rc"
  expect "three live zero rows counted" "$out" "LIVE ZERO-CRITERIA: 3"
  expect "ABSENT is its own class, sized 1" "$out" "ABSENT (1)"
  expect "ABSENT names the absent-key row" \
    "$out" "row-absent-key"
  expect "EMPTY is its own class, sized 1" "$out" "EMPTY (1)"
  expect "MALFORMED is its own class, sized 1" "$out" "MALFORMED (1)"
  # The fold detector: if absent collapsed into empty, EMPTY would be 2 and
  # ABSENT would not be printed at all.
  refute "the absent row is NOT folded into EMPTY" "$out" "EMPTY (2)"
  refute "a row with real criteria is not listed" "$out" "row-has-criteria"

  # 6. A SUMMARY-shaped zero row (the real `bp task get <epic>` payload) is
  #    INDETERMINATE — the census must not GUESS which of the two it is.
  out="$(classify dirty <"$tmp/dirty.json")"
  expect "summary-only zero rows are INDETERMINATE, not absent/empty" \
    "$out" "INDETERMINATE (2)"
  refute "a summary row is never reported as ABSENT" "$out" "ABSENT ("

  # 7. RESOLUTION. Given the same summary-shaped ledger, the per-row read turns
  #    INDETERMINATE into the real classes. $BP_TASK_GET_CMD is stubbed, so this
  #    arm is hermetic — no bp, no network.
  cat >"$tmp/stub-bp" <<'STUB'
#!/usr/bin/env bash
# stub of `bp task get <id> -o json`
case "$1" in
  bare-open)        printf '{"doc":{"status":"published","content":{"title":"t"}}}' ;;
  bare-in-progress) printf '{"doc":{"status":"published","content":{"acceptance_criteria":[]}}}' ;;
  *)                exit 1 ;;
esac
STUB
  chmod +x "$tmp/stub-bp"
  out="$(BP_TASK_GET_CMD="$tmp/stub-bp" resolve_shapes <"$tmp/dirty.json" | classify resolved)"; rc=$?
  check "a resolved corpus still reds" 1 "$rc"
  expect "resolution splits the two summary rows into ABSENT" "$out" "ABSENT (1)"
  expect "resolution splits the two summary rows into EMPTY" "$out" "EMPTY (1)"
  refute "nothing stays INDETERMINATE once resolved" "$out" "INDETERMINATE ("

  # 8. A resolution that FAILS must leave the row INDETERMINATE, never silently
  #    reclassify it. A read you could not make is not an answer.
  cat >"$tmp/stub-dead" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$tmp/stub-dead"
  out="$(BP_TASK_GET_CMD="$tmp/stub-dead" resolve_shapes <"$tmp/dirty.json" 2>/dev/null | classify unresolved)"
  expect "an unresolvable row stays INDETERMINATE" "$out" "INDETERMINATE (2)"

  # 9. --fixture stays HERMETIC by default: even with a working fetcher on
  #    $BP_TASK_GET_CMD it must not reach for rows unless --resolve says so.
  #    Otherwise the harness's "no network" claim is a word, not a property.
  out="$(BP_TASK_GET_CMD="$tmp/stub-bp" bash "$0" --fixture "$tmp/dirty.json" hermetic)"
  expect "a bare --fixture run does not resolve (hermetic by default)" \
    "$out" "INDETERMINATE (2)"
  out="$(BP_TASK_GET_CMD="$tmp/stub-bp" bash "$0" --fixture "$tmp/dirty.json" --resolve optin)"; rc=$?
  check "--fixture --resolve still reds" 1 "$rc"
  expect "--resolve opts a fixture into the per-row read" "$out" "ABSENT (1)"

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
  if [ "$RESOLVE" = "1" ]; then
    # Opt-in only: a bare --fixture run stays hermetic.
    resolve_shapes <"$FIXTURE" | classify "$EPIC"
    exit "${PIPESTATUS[1]}"
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

# The epic read hands back summaries; resolve the live zero rows so ABSENT and
# EMPTY are reported as what they are rather than as one INDETERMINATE blob.
if [ "$RESOLVE" != "0" ]; then
  ledger="$(printf '%s' "$ledger" | resolve_shapes)"
fi

printf '%s' "$ledger" | classify "$EPIC"
