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
# DEPTH — THE DENOMINATOR IS PART OF THE VERDICT (added 2026-09-11).
# `bp task get <epic> -o json` renders ONE level: `child_tasks/2` in
# tasks_controller.ex is a query filtered on `parent_id == <epic>`. A row
# parented to a SUB-PARENT of the epic was therefore outside the population and
# could not be seen — and re-parenting is a DOCUMENTED ROUTINE here (335 rows of
# the deploy-reliability epic carry "Adopted by dr-backlog-never-started for
# ROSTER HEADROOM (charter S-4c) … Disposition stays OPEN"). A housekeeping move
# made for a page-limit reason used to empty the census population and flip the
# verdict to SILENT with no defect fixed and no code change. So:
#   * the census DESCENDS. Each row that is itself a parent is expanded with
#     `bp task ls --parent <id> --all -o json`, which — unlike the child
#     summaries on the epic read — carries `child_count` AND the full `content`,
#     so one call per sub-parent both finds the next level and classifies it
#     exactly. The classifier was already depth-agnostic: it takes a flat list.
#   * the printed line STATES its own depth, its walked/unwalked sub-parent
#     counts and its denominator, because a count that omits half the tree and
#     does not say so is the defect.
#   * a bare SILENT is IMPOSSIBLE while any sub-parent is unwalked. Unwalked
#     subtree + nothing found on the walked rail is UNKNOWN (exit 2), never 0.
# The sub-parent signal is `child_count`, which the epic read's child summaries
# do NOT carry (verified 2026-09-11: child keys are doc_id, lifecycle_status,
# title, criteria_progress, execution_class, inserted_at, updated_at). That is
# why descent uses `bp task ls --parent` rather than the epic payload.
#
# EXIT CODES
#   0  SILENT — every live row in a FULLY WALKED tree carries a criterion
#   1  SCREAM — at least one live row carries zero; they are named, by class
#   2  UNKNOWN — the ledger could not be read, carried no children key, or the
#      tree was not walked to the bottom (a sub-parent stayed unexpanded).
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
#   scripts/epic-zero-criteria-census.sh --no-descend         # live, but stay at
#                                                             # depth 1 (then a
#                                                             # sub-parent forces
#                                                             # UNKNOWN, not SILENT)
#   scripts/epic-zero-criteria-census.sh --fixture <f> --descend
#                                                             # walk a fixture's
#                                                             # sub-parents too (NOT
#                                                             # hermetic: it reads rows)
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
DESCEND="auto"   # auto: on for a live read, off for a fixture (hermetic by default)
MAX_DEPTH="${CENSUS_MAX_DEPTH:-6}"

usage() { sed -n '2,127p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --fixture)    FIXTURE="$2"; shift 2 ;;
    --self-test)  SELF_TEST=1; shift ;;
    --resolve)    RESOLVE=1; shift ;;
    --no-resolve) RESOLVE=0; shift ;;
    --descend)    DESCEND=1; shift ;;
    --no-descend) DESCEND=0; shift ;;
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

# DEPTH. A row that is itself a parent hides a subtree; unless that subtree was
# walked, this population is not the epic roster and must not be spoken of as
# though it were. `child_count` arrives from the `bp task ls --parent` descent
# (the epic-read child summaries do not carry it).
meta = doc.get("_census")
if not isinstance(meta, dict):
    meta = {}
walked = set(meta.get("walked") or [])
depth = int(meta.get("depth") or 1)
sub_parents = sorted(
    c.get("doc_id") or "?"
    for c in children
    if isinstance(c, dict) and (c.get("child_count") or 0) > 0)
unwalked = sorted(i for i in sub_parents if i not in walked)
if meta.get("roster_read_failed"):
    # child_count is unknown for every row, so "no sub-parents" would be a
    # guess. Name the epic itself as the node whose shape was never read.
    unwalked = unwalked + ["%s (parent-scoped roster read FAILED)" % label]
elif (meta.get("descent_skipped") and children
      and not any(isinstance(c, dict) and "child_count" in c for c in children)):
    # Descent was off and NOT ONE row carries child_count — so "I saw no
    # sub-parent" is not an observation, it is the absence of one. The epic
    # epic-read child summaries never carry the key (see the DEPTH note above).
    unwalked = unwalked + [
        "%s (tree not walked and no row carries child_count — "
        "sub-parents are UNKNOWABLE from this payload)" % label]

print("epic %s — %d rows in the population, read to DEPTH %d "
      "(%d sub-parents seen, %d walked, %d UNWALKED), "
      "%d carry zero acceptance criteria"
      % (label, len(children), depth, len(sub_parents),
         len([i for i in sub_parents if i in walked]), len(unwalked),
         len(zero)))

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
    if unwalked:
        print("")
        print("  AND THE COUNT IS A FLOOR: %d sub-parent(s) were not walked "
              "(%s), so their subtrees are outside this denominator."
              % (len(unwalked), ", ".join(unwalked)))
    sys.exit(1)

if unwalked:
    print("")
    print("UNKNOWN — REFUSING A BARE SILENT: %d of the rows in this population "
          "are themselves PARENTS and their subtrees were NOT walked (%s). "
          "This census read depth %d only, so the %d-row denominator above is "
          "not the epic roster. Nothing was found on the rail that WAS read "
          "— that is not the same finding as \"this epic has no criteria-less "
          "live rows\", and re-parenting a row one level down is a documented "
          "housekeeping move here. Re-run without --no-descend, or walk those "
          "ids, before reading this as green."
          % (len(unwalked), ", ".join(unwalked), depth, len(children)))
    sys.exit(2)

print("SILENT: every live row carries at least one acceptance criterion "
      "(%d rows, depth %d, %d sub-parents walked — the whole tree)."
      % (len(children), depth, len(sub_parents)))
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
# Descent. The epic read is ONE level; a row parented to a sub-parent of the
# epic is invisible to it. Each row that is itself a parent (child_count > 0)
# is expanded with `bp task ls --parent <id> --all -o json`, whose rows carry
# child_count AND the full content — so one call per sub-parent finds the next
# level and classifies it exactly, with no per-row resolution. The fetch is a
# variable so the self-test can pin this path without a network.
# ---------------------------------------------------------------------------
BP_TASK_LS_CMD="${BP_TASK_LS_CMD:-bp task ls}"

# shellcheck disable=SC2016  # python source, not shell
DESCEND_PY='
import json, os, sys

mode = sys.argv[1]
raw = sys.stdin.read()
try:
    doc = json.loads(raw)
except Exception:
    sys.stdout.write(raw if mode in ("absorb", "mark") else "")
    sys.exit(0)

children = doc.get("children") if isinstance(doc, dict) else None
if not isinstance(children, list):
    sys.stdout.write(raw if mode in ("absorb", "mark") else "")
    sys.exit(0)

meta = doc.get("_census")
if not isinstance(meta, dict):
    meta = {}
    doc["_census"] = meta
walked = set(meta.get("walked") or [])

if mode == "mark":
    # The tree was NOT walked on this run. Record it: the classifier must not
    # read "I saw no sub-parent" off a payload that could not carry one.
    meta["descent_skipped"] = True
    json.dump(doc, sys.stdout)
    sys.exit(0)

if mode == "frontier":
    for c in children:
        if not isinstance(c, dict):
            continue
        if (c.get("child_count") or 0) > 0 and c.get("doc_id") not in walked:
            print(c["doc_id"])
    sys.exit(0)

# absorb: graft each fetched level onto the flat children list.
fetched_dir = os.environ["ABSORB_DIR"]
level = int(os.environ.get("ABSORB_LEVEL", "1"))
index = {}
for c in children:
    if isinstance(c, dict) and c.get("doc_id"):
        index[c["doc_id"]] = c

for name in sorted(os.listdir(fetched_dir)):
    if not name.endswith(".json"):
        continue
    parent_id = name[:-5]
    try:
        with open(os.path.join(fetched_dir, name)) as fh:
            page = json.load(fh)
    except Exception:
        # A page we could not parse is a subtree we did not walk: leave the
        # parent OUT of `walked` so the classifier refuses a bare SILENT.
        continue
    rows = page.get("docs") if isinstance(page, dict) else page
    if not isinstance(rows, list):
        continue
    walked.add(parent_id)
    for row in rows:
        if not isinstance(row, dict) or not row.get("doc_id"):
            continue
        existing = index.get(row["doc_id"])
        if existing is not None:
            # Same level, already listed by the epic read: enrich it rather
            # than duplicating it. child_count is the whole point.
            if "child_count" in row:
                existing["child_count"] = row["child_count"]
            if isinstance(row.get("content"), dict) and not isinstance(
                    existing.get("content"), dict):
                nested = existing.get("doc")
                if not (isinstance(nested, dict)
                        and isinstance(nested.get("content"), dict)):
                    existing["content"] = row["content"]
            continue
        row["_census_parent"] = parent_id
        children.append(row)
        index[row["doc_id"]] = row

meta["walked"] = sorted(walked)
meta["depth"] = max(int(meta.get("depth") or 1), level)
if level == 1 and os.environ.get("ROSTER_FAILED") == "1":
    # The parent-scoped read of the epic itself failed, so `child_count` is
    # unknown for EVERY row: we cannot even tell whether a sub-parent exists.
    # That is a blind census, not a clean one.
    meta["roster_read_failed"] = True
json.dump(doc, sys.stdout)
'

descend_tree() { # stdin: ledger json -> stdout: ledger json with the tree flattened in
  local ledger dir frontier id out level roster_failed
  ledger="$(cat)"
  level=1
  roster_failed=0
  while [ "$level" -le "$MAX_DEPTH" ]; do
    if [ "$level" -eq 1 ]; then
      # Level one exists already, but only as summaries with no child_count —
      # read it again through `ls --parent` purely to learn who is a parent.
      frontier="$EPIC"
    else
      frontier="$(printf '%s' "$ledger" | python3 -c "$DESCEND_PY" frontier)"
    fi
    [ -n "$frontier" ] || break
    dir="$(mktemp -d)"
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      # shellcheck disable=SC2086  # BP_TASK_LS_CMD is a command + args, split on purpose
      out="$($BP_TASK_LS_CMD --parent "$id" --all -o json 2>/dev/null)"
      if [ -n "$out" ]; then
        printf '%s' "$out" >"$dir/$id.json"
      else
        echo "  note: could not read the children of $id; its subtree stays UNWALKED" >&2
        [ "$level" -eq 1 ] && roster_failed=1
      fi
    done <<EOF
$frontier
EOF
    ledger="$(printf '%s' "$ledger" | ABSORB_DIR="$dir" ABSORB_LEVEL="$level" \
      ROSTER_FAILED="$roster_failed" python3 -c "$DESCEND_PY" absorb)"
    rm -rf "$dir"
    level=$((level + 1))
  done
  printf '%s' "$ledger"
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

  # 10. DEPTH. A child that is ITSELF A PARENT hides a subtree. A census that
  #     stopped at depth 1 must not print a bare SILENT about it — before this
  #     arm existed the script printed exactly that, and the verdict was only
  #     ever about the direct rail.
  cat >"$tmp/depth-blind.json" <<'JSON'
{"children": [
  {"doc_id": "plain-row", "lifecycle_status": "open", "child_count": 0,
   "criteria_progress": {"met": 0, "total": 2}, "title": "fine"},
  {"doc_id": "sub-parent", "lifecycle_status": "open", "child_count": 2,
   "criteria_progress": {"met": 0, "total": 1}, "title": "is itself a parent"}
]}
JSON
  out="$(bash "$0" --fixture "$tmp/depth-blind.json" depthfix)"; rc=$?
  check "an unwalked sub-parent is UNKNOWN, never a bare SILENT" 2 "$rc"
  expect "the refusal names the depth hole" "$out" "REFUSING A BARE SILENT"
  expect "the printed line states its own depth" "$out" "read to DEPTH 1"
  expect "the printed line states its denominator and unwalked count" \
    "$out" "2 rows in the population"
  expect "the unwalked sub-parent is named" "$out" "sub-parent"
  refute "no bare SILENT is printed while a sub-parent is unwalked" \
    "$out" "SILENT: every live row"

  # 11. THE CONTROL for arm 10: the refusal is about UNWALKED subtrees, not a
  #     blanket ban on green. Same corpus, every row a leaf -> SILENT, exit 0.
  cat >"$tmp/depth-clean.json" <<'JSON'
{"children": [
  {"doc_id": "plain-row", "lifecycle_status": "open", "child_count": 0,
   "criteria_progress": {"met": 0, "total": 2}, "title": "fine"},
  {"doc_id": "leaf-row", "lifecycle_status": "open", "child_count": 0,
   "criteria_progress": {"met": 0, "total": 1}, "title": "also fine"}
]}
JSON
  out="$(bash "$0" --fixture "$tmp/depth-clean.json" depthclean)"; rc=$?
  check "a fully-leaf corpus still goes green" 0 "$rc"
  expect "the green line states depth and denominator too" \
    "$out" "2 rows, depth 1, 0 sub-parents walked"

  # 12. THE MUTATION PROOF — re-parenting, fixture-simulated (never on the live
  #     ledger). BEFORE: a criteria-less live row sits on the epic's direct
  #     rail and the census SCREAMS it. AFTER: the same row is adopted by a
  #     sub-parent ("ROSTER HEADROOM", the documented housekeeping move) and
  #     leaves the depth-1 payload entirely. No defect was fixed. The census
  #     must not go green — and with descent it must still NAME the row.
  cat >"$tmp/reparent-before.json" <<'JSON'
{"children": [
  {"doc_id": "sub-parent", "lifecycle_status": "open", "child_count": 1,
   "criteria_progress": {"met": 0, "total": 1}, "title": "adopter"},
  {"doc_id": "adopted-zero-row", "lifecycle_status": "open", "child_count": 0,
   "title": "no criteria, still on the direct rail"}
]}
JSON
  cat >"$tmp/reparent-after.json" <<'JSON'
{"children": [
  {"doc_id": "sub-parent", "lifecycle_status": "open",
   "criteria_progress": {"met": 0, "total": 1}, "title": "adopter"}
]}
JSON
  cat >"$tmp/stub-ls" <<'STUB'
#!/usr/bin/env bash
# stub of `bp task ls --parent <id> --all -o json`
case "$2" in
  reparented)
    printf '%s' '{"docs":[{"doc_id":"sub-parent","lifecycle_status":"open","child_count":1,"title":"adopter","content":{"acceptance_criteria":[{"criterion":"a"}]}}]}' ;;
  sub-parent)
    printf '%s' '{"docs":[{"doc_id":"adopted-zero-row","lifecycle_status":"open","child_count":0,"title":"adopted for ROSTER HEADROOM","content":{"title":"t","description":"d"}}]}' ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$tmp/stub-ls"
  out="$(bash "$0" --fixture "$tmp/reparent-before.json" before)"; rc=$?
  check "BEFORE the re-parent: the criteria-less row reds on the direct rail" 1 "$rc"
  expect "BEFORE names the row" "$out" "adopted-zero-row"
  out="$(bash "$0" --fixture "$tmp/reparent-after.json" after)"; rc=$?
  check "AFTER the re-parent, un-walked: UNKNOWN, not the old SILENT" 2 "$rc"
  refute "AFTER un-walked never claims the epic is clean" "$out" "SILENT: every live row"
  out="$(BP_TASK_LS_CMD="$tmp/stub-ls" bash "$0" --fixture "$tmp/reparent-after.json" \
          --descend reparented)"; rc=$?
  check "AFTER the re-parent, WALKED: the census still reds" 1 "$rc"
  expect "the walk reaches depth 2" "$out" "read to DEPTH 2"
  expect "the adopted row is still named after moving a level down" \
    "$out" "adopted-zero-row"
  expect "the grandchild is inside the denominator" "$out" "2 rows in the population"
  expect "the walked sub-parent is counted as walked" "$out" "1 sub-parents seen, 1 walked, 0 UNWALKED"

  # 13. A descent whose per-parent read FAILS must leave that subtree UNWALKED
  #     — a read you could not make is not an empty subtree.
  cat >"$tmp/stub-ls-dead" <<'STUB'
#!/usr/bin/env bash
case "$2" in
  reparented)
    printf '%s' '{"docs":[{"doc_id":"sub-parent","lifecycle_status":"open","child_count":1,"title":"adopter","content":{"acceptance_criteria":[{"criterion":"a"}]}}]}' ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$tmp/stub-ls-dead"
  out="$(BP_TASK_LS_CMD="$tmp/stub-ls-dead" bash "$0" --fixture "$tmp/reparent-after.json" \
          --descend reparented 2>/dev/null)"; rc=$?
  check "a failed sub-parent read is UNKNOWN, not green" 2 "$rc"
  expect "the unreadable subtree is reported UNWALKED" "$out" "1 UNWALKED"

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
  ledger="$(cat "$FIXTURE")"
  # Opt-in only: a bare --fixture run stays hermetic on BOTH axes. An
  # unwalked sub-parent in the fixture then lands on the depth refusal
  # rather than on a bare SILENT, which is the point.
  if [ "$DESCEND" = "1" ]; then
    ledger="$(printf '%s' "$ledger" | descend_tree)"
  else
    ledger="$(printf '%s' "$ledger" | python3 -c "$DESCEND_PY" mark)"
  fi
  if [ "$RESOLVE" = "1" ]; then
    ledger="$(printf '%s' "$ledger" | resolve_shapes)"
  fi
  printf '%s' "$ledger" | classify "$EPIC"
  exit "${PIPESTATUS[1]}"
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

# The epic read is ONE level. Walk the sub-parents before anything is counted,
# so the denominator is the epic's roster rather than its direct rail.
if [ "$DESCEND" != "0" ]; then
  ledger="$(printf '%s' "$ledger" | descend_tree)"
else
  ledger="$(printf '%s' "$ledger" | python3 -c "$DESCEND_PY" mark)"
fi

# The epic read hands back summaries; resolve the live zero rows so ABSENT and
# EMPTY are reported as what they are rather than as one INDETERMINATE blob.
if [ "$RESOLVE" != "0" ]; then
  ledger="$(printf '%s' "$ledger" | resolve_shapes)"
fi

printf '%s' "$ledger" | classify "$EPIC"
