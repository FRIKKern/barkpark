#!/usr/bin/env bash
#
# landed-open-report.sh — the READER for the landing back-link. Surfaces task
# rows that carry a `landed-on-main` label AND are still lifecycle open or
# in_progress: finished work still advertising itself as available.
#
# THE DEFECT (task-2279167dd00ec347, measured 2026-09-06 by lead-deploy-10)
# ----------------------------------------------------------------------------
# The back-link the ledger was believed to lack ALREADY EXISTS. scripts/
# landed-mark.sh has been stamping two labels on every row a merged PR names —
# `landed-on-main` and `landed:pr-<n>@<sha10>` — and NOTHING READS THEM. The
# ghost sweep that DID find those rows was a 3,000-PR-body scrape only a lead
# can run by hand; this is the same question asked of the ledger, in one walk.
#
# HIGH PRECISION, LOW RECALL — SAID PLAINLY SO NOBODY OVERSELLS IT. On the day
# this was written 8,700-odd rows carry ~440 landed labels, against ~2,618 rows
# a merged PR's `Task:` trailer names. This reader therefore sees roughly a
# sixth of the landed population. It does NOT replace the trailer sweep; it is
# the part of it that is cheap, server-side, and runnable every day. The rest
# of the recall gap closes as landed-mark.sh keeps running, not by reading
# harder.
#
# WHY A REPORT AND NOT AN AUTO-CLOSER
# ----------------------------------------------------------------------------
# A landed label is evidence that a PR NAMED the row. It is not proof that
# every acceptance criterion is discharged, and two false-positive classes are
# already measured:
#
#   PARENT — an epic/goal row named by MANY PRs. One row was named by 34. A PR
#            naming a parent is a CONTRIBUTION toward it, never a discharge.
#   GATE?  — a row whose remaining criterion is a HUMAN gate. It always looks
#            finished, because the work merged and the gate is a person who has
#            not looked yet.
#
# Both are FLAGGED in the output and neither is filtered out: a reader that
# silently drops rows fails the same way as one that finds none. Nothing here
# writes to the ledger. There is no --close, and adding one would need the
# false-positive rate measured first, not assumed.
#
# THE ZERO THAT MUST NEVER BE QUIET
# ----------------------------------------------------------------------------
# A guard that cannot demonstrate it SEES is theatre, and a disconnected
# tripwire has burned this repo twice. So three distinct outcomes, three
# distinct exits, and none of them prints like another:
#
#   0  the walk succeeded. Zero LIVE rows is a legitimate, good result and
#      says so: "0 live — the population is clean".
#   2  CANNOT READ. The walk was short, a page failed, a page's `docs` length
#      disagreed with its own `page.returned`, the walk read zero rows at all,
#      or FEWER THAN --min-population rows carried the label. That last arm is
#      the positive control: labels are only ever ADDED by landed-mark.sh, so
#      the labelled population cannot shrink to zero on its own. If it reads
#      zero, the reader is broken or pointed somewhere wrong — not the ledger
#      suddenly clean.
#   3  --exit-on-findings was passed and live rows were found. For a CI arm
#      that wants to NAME them; off by default, because a lead running this by
#      hand wants the list, not a non-zero shell.
#
# USAGE
#   bash scripts/landed-open-report.sh                       # the report
#   bash scripts/landed-open-report.sh --all                 # include done rows
#   bash scripts/landed-open-report.sh --exit-on-findings     # CI arm
#   bash scripts/landed-open-report.sh --fixture DIR          # pages from disk
#   bash scripts/landed-open-report.sh --selftest             # hermetic
#
# ENV
#   LANDED_REPORT_BP        the bp binary (default `bp`)
#   LANDED_REPORT_LIMIT     page size (default 500)
#   LANDED_REPORT_MAX_PAGES safety stop (default 60)
#
# NO `printf ... | grep -q` ANYWHERE. Under pipefail grep -q exits at the first
# match, the writer takes SIGPIPE, and the pipeline reports 141 — a false NO
# that only shows up under load.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="${BASH_SOURCE[0]}"
PY="$ROOT/scripts/lib/landed_open_report.py"

BP="${LANDED_REPORT_BP:-bp}"
LIMIT="${LANDED_REPORT_LIMIT:-500}"
MAX_PAGES="${LANDED_REPORT_MAX_PAGES:-60}"
MIN_POPULATION="${LANDED_REPORT_MIN_POPULATION:-1}"

MODE="report"
FIXTURE_DIR=""
SHOW_ALL=0
EXIT_ON_FINDINGS=0

die2() { echo "landed-open-report: CANNOT READ — $*" >&2; exit 2; }
usage() { sed -n "2,$(($(grep -n '^set -uo pipefail' "$SELF" | head -1 | cut -d: -f1) - 1))p" "$SELF" | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --selftest)          MODE="selftest"; shift ;;
    --all)               SHOW_ALL=1; shift ;;
    --exit-on-findings)  EXIT_ON_FINDINGS=1; shift ;;
    --fixture)           [ "$#" -ge 2 ] || die2 "--fixture needs a path"; FIXTURE_DIR="$2"; shift 2 ;;
    --fixture=*)         FIXTURE_DIR="${1#--fixture=}"; shift ;;
    --limit)             [ "$#" -ge 2 ] || die2 "--limit needs a value"; LIMIT="$2"; shift 2 ;;
    --limit=*)           LIMIT="${1#--limit=}"; shift ;;
    --min-population)    [ "$#" -ge 2 ] || die2 "--min-population needs a value"; MIN_POPULATION="$2"; shift 2 ;;
    --min-population=*)  MIN_POPULATION="${1#--min-population=}"; shift ;;
    -h|--help)           usage; exit 0 ;;
    # An unknown flag NEVER passes. A typo'd flag that exits 0 is a reader that
    # silently stopped reading, indistinguishable from a clean ledger.
    *)                   die2 "unknown option '$1'" ;;
  esac
done

case "$LIMIT" in ''|*[!0-9]*|0) die2 "--limit must be a positive integer, got '$LIMIT'" ;; esac
case "$MIN_POPULATION" in ''|*[!0-9]*) die2 "--min-population must be a non-negative integer, got '$MIN_POPULATION'" ;; esac
command -v python3 >/dev/null 2>&1 || die2 "python3 is not on PATH — the page scanner is python3."
[ -f "$PY" ] || die2 "page scanner missing at $PY"

WORK="$(mktemp -d -t landed-open-report.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# ── the walk ─────────────────────────────────────────────────────────────────
# Emits: $WORK/hits.jsonl, and sets WALKED / LABELLED / LIVE_N.
walk() {
  local cursor="" page=1 raw scan
  WALKED=0
  : > "$WORK/hits.jsonl"

  while [ "$page" -le "$MAX_PAGES" ]; do
    raw="$WORK/page.$page.json"
    if [ -n "$FIXTURE_DIR" ]; then
      [ -f "$FIXTURE_DIR/pages/$page.json" ] || break
      cat "$FIXTURE_DIR/pages/$page.json" > "$raw"
    else
      # `--cursor ""` ON PAGE ONE IS LOAD-BEARING, and this cost a run to find.
      # OMITTING --cursor is not "the same request without a cursor" — it is a
      # DIFFERENT pager. bp falls back to limit/offset mode, which returns
      # `has_more: true` and NO `next_cursor`, and caps at 1000 rows. A walker
      # that omitted it on page 1 and read next_cursor afterwards would stop
      # dead after one page. The empty string is what enters keyset mode.
      "$BP" task ls --limit "$LIMIT" --cursor "$cursor" -o json > "$raw" 2>"$WORK/page.$page.err"
      # The bp exit code, not a pipeline's. Nothing is piped here on purpose.
      if [ "$?" -ne 0 ]; then
        die2 "page $page: \`$BP task ls\` exited non-zero. stderr: $(head -c 300 "$WORK/page.$page.err")"
      fi
    fi
    # An empty file is a FAILED READ, never a zero.
    [ -s "$raw" ] || die2 "page $page: the ledger returned 0 bytes"

    # The scanner exits 3 and writes to stderr on a bad page; the substitution
    # captures only stdout, so the exit code is the whole test.
    scan="$(python3 "$PY" scan "$raw" 2>"$WORK/scan.$page.err")"
    if [ "$?" -ne 0 ]; then
      die2 "page $page: $(cat "$WORK/scan.$page.err")"
    fi

    local docs_len returned next_cursor has_more
    eval "$(python3 -c '
import json,sys
d=json.loads(sys.argv[1])
print("docs_len=%d" % d["docs_len"])
print("returned=%s" % (d["returned"] if isinstance(d["returned"],int) else -1))
print("has_more=%d" % (1 if d["has_more"] else 0))
print("next_cursor=%s" % json.dumps(d["next_cursor"]))
' "$scan")"

    # THE ASSERTION THAT CAUGHT THE ORIGINAL BUG. A pager keyed on the wrong
    # array name wrote ZERO rows for 3 of 9 pages while printing a tidy
    # "page N: 0 rows" and exiting 0. Rows-scanned must equal rows-returned.
    if [ "$returned" -ge 0 ] && [ "$docs_len" -ne "$returned" ]; then
      die2 "page $page: scanned $docs_len rows but the server said it returned $returned — the walk is dropping rows"
    fi

    python3 -c '
import json,sys
d=json.loads(sys.argv[1])
with open(sys.argv[2],"a") as fh:
    for h in d["hits"]:
        fh.write(json.dumps(h)+"\n")
' "$scan" "$WORK/hits.jsonl"

    WALKED=$((WALKED + docs_len))
    [ "$docs_len" -eq 0 ] && break
    [ "$has_more" -eq 1 ] || break
    if [ -z "$next_cursor" ] && [ -z "$FIXTURE_DIR" ]; then
      die2 "page $page: has_more is true but the server sent no next_cursor — the walk cannot continue and the result would be SHORT"
    fi
    cursor="$next_cursor"
    page=$((page + 1))
  done

  if [ "$page" -gt "$MAX_PAGES" ]; then
    die2 "walk hit LANDED_REPORT_MAX_PAGES=$MAX_PAGES with more pages pending — the result would be SHORT. Raise it deliberately."
  fi

  LABELLED="$(python3 -c 'import sys;print(sum(1 for l in open(sys.argv[1]) if l.strip()))' "$WORK/hits.jsonl")"
  LIVE_N="$(python3 -c '
import json,sys
n=0
for l in open(sys.argv[1]):
    l=l.strip()
    if l and json.loads(l)["live"]: n+=1
print(n)' "$WORK/hits.jsonl")"
}

# Resolve each landing sha to the AGE OF THE LANDING in days. Best effort: a
# sha this checkout does not carry prints `?` and sorts last. Never 0 — an
# unresolved age must not masquerade as the oldest, most damning row.
ages_map() {
  python3 -c '
import json,subprocess,sys,time
shas=set()
for l in open(sys.argv[1]):
    l=l.strip()
    if l:
        s=json.loads(l).get("sha")
        if s: shas.add(s)
out={}
now=time.time()
for s in shas:
    try:
        ts=subprocess.check_output(["git","-C",sys.argv[2],"show","-s","--format=%ct",s],
                                   stderr=subprocess.DEVNULL).decode().strip()
        out[s]=(now-int(ts))/86400.0
    except Exception:
        pass
json.dump(out,open(sys.argv[3],"w"))
' "$WORK/hits.jsonl" "$ROOT" "$WORK/ages.json" 2>/dev/null || echo '{}' > "$WORK/ages.json"
}

cmd_report() {
  walk
  ages_map

  echo "landed-open-report — task rows whose work LANDED on main but whose lifecycle is still live"
  echo "  doc_id                     lifecycle    met/tot  landing                       age   title"
  python3 "$PY" render "$WORK/hits.jsonl" "$WORK/ages.json"
  if [ "$SHOW_ALL" -eq 1 ]; then
    echo "--- terminal rows carrying the same label (context; nothing owed) ---"
    python3 -c '
import json,sys
for l in open(sys.argv[1]):
    l=l.strip()
    if not l: continue
    r=json.loads(l)
    if not r["live"]:
        print("%-26s %-12s %2d/%-2d %s" % (r["doc_id"],r["lifecycle"],r["met"],r["total"],r["fact"]))
' "$WORK/hits.jsonl"
  fi

  # THE TRAILER. It names the population walked, so a reader can tell a real
  # zero from a broken walk without trusting the exit code alone.
  echo "walked $WALKED rows, $LABELLED carry landed-on-main, $LIVE_N live"
  if [ "$WALKED" -eq 0 ]; then
    die2 "the walk read ZERO rows. That is a failed read, not an empty ledger."
  fi
  if [ "$LABELLED" -lt "$MIN_POPULATION" ]; then
    die2 "only $LABELLED rows carry '$LANDED_CLASS_NAME' but --min-population is $MIN_POPULATION. Labels are only ever ADDED, so a labelled population that reads below the floor means this reader is broken or pointed at the wrong ledger — not that the ledger went clean."
  fi
  if [ "$LIVE_N" -eq 0 ]; then
    echo "landed-open-report: 0 live — the population is clean. (Read $LABELLED labelled rows, so the query is not blind.)"
    return 0
  fi
  if [ "$EXIT_ON_FINDINGS" -eq 1 ]; then
    echo "::warning title=Landed work still open::landed-open-report: $LIVE_N rows carry landed-on-main and are still open or in_progress. They are listed above; PARENT and GATE? rows are expected false positives."
    return 3
  fi
  return 0
}
LANDED_CLASS_NAME="landed-on-main"

# ── selftest: hermetic, fixture-driven, and it must FAIL if it stops seeing ──
cmd_selftest() {
  local fail=0 fx="$WORK/fx" out rc
  mkdir -p "$fx/pages"

  # Page 1 carries: a LIVE landed row (must appear), a DONE landed row (must
  # NOT appear in the live list), an unlabelled row (never appears), a PARENT
  # row and a GATE? row (must appear, FLAGGED).
  cat > "$fx/pages/1.json" <<'JSON'
{"ok":true,"docs":[
 {"doc_id":"task-live-1","title":"live landed row","lifecycle_status":"open","child_count":0,
  "content":{"labels":["landed-on-main","landed:pr-15090@abcdef1234"],
             "acceptance_criteria":[{"criterion":"a thing","met":true},{"criterion":"another","met":false}]}},
 {"doc_id":"task-done-1","title":"done landed row","lifecycle_status":"done",
  "content":{"labels":["landed-on-main","landed:pr-15091@bbbbbb2222"],"acceptance_criteria":[]}},
 {"doc_id":"task-plain-1","title":"no label","lifecycle_status":"open","content":{"labels":["p1"]}},
 {"doc_id":"task-parent-1","title":"an epic","lifecycle_status":"open","child_count":7,
  "content":{"labels":[{"tag":"landed-on-main"},{"tag":"landed:pr-15092@cccccc3333"}],
             "acceptance_criteria":[{"criterion":"kids ship","met":false}]}},
 {"doc_id":"task-gate-1","title":"human gate","lifecycle_status":"in_progress",
  "content":{"labels":["landed-on-main","landed:pr-15093@dddddd4444"],
             "acceptance_criteria":[{"criterion":"a lead signs off on the rollout","met":false}]}}
],"page":{"returned":5,"has_more":false,"limit":500,"offset":0}}
JSON

  out="$(bash "$SELF" --fixture "$fx" 2>&1)"; rc=$?
  # POSITIVE CONTROL — it must SEE.
  case "$out" in *task-live-1*) ;; *) echo "FAIL: live landed row task-live-1 absent from the report"; fail=1 ;; esac
  # The met TALLY, not just the row. task-live-1 carries met:true and met:false,
  # so the only correct rendering is 1/2. Without this the criteria counter
  # could read `met` truthily (counting a met:false as met) and nothing here
  # would notice — the reader would then advertise finished-looking rows.
  case "$out" in *"task-live-1"*" 1/2 "*) ;;
    *) echo "FAIL: task-live-1 rendered the wrong met tally (want 1/2)"; fail=1 ;; esac
  case "$out" in *task-parent-1*) ;; *) echo "FAIL: PARENT row absent — it must be listed, flagged, not filtered"; fail=1 ;; esac
  case "$out" in *"[PARENT]"*) ;; *) echo "FAIL: PARENT flag missing"; fail=1 ;; esac
  case "$out" in *"[GATE?]"*) ;; *) echo "FAIL: GATE? flag missing"; fail=1 ;; esac
  # NEGATIVE CONTROL — a done row and an unlabelled row must NOT be in the list.
  case "$out" in *task-plain-1*) echo "FAIL: unlabelled row leaked into the report"; fail=1 ;; esac
  case "$(bash "$SELF" --fixture "$fx" 2>&1 | sed -n '/^walked /q;p')" in
    *task-done-1*) echo "FAIL: a DONE row leaked into the live list"; fail=1 ;;
  esac
  case "$out" in *"walked 5 rows, 4 carry landed-on-main, 3 live"*) ;;
    *) echo "FAIL: trailer wrong. got: $(printf '%s' "$out" | tail -2)"; fail=1 ;; esac
  [ "$rc" -eq 0 ] || { echo "FAIL: a clean fixture read exited $rc, want 0"; fail=1; }

  # --exit-on-findings must turn the same finding into a 3.
  bash "$SELF" --fixture "$fx" --exit-on-findings >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 3 ] || { echo "FAIL: --exit-on-findings exited $rc, want 3"; fail=1; }

  # A ZERO MUST NOT PRINT LIKE A FAILURE, AND A FAILURE MUST NOT PRINT LIKE A
  # ZERO. Empty page = zero labelled rows = below the floor = CANNOT READ + 2.
  local fz="$WORK/fz"; mkdir -p "$fz/pages"
  echo '{"ok":true,"docs":[{"doc_id":"t","title":"x","lifecycle_status":"open","content":{"labels":[]}}],"page":{"returned":1,"has_more":false}}' > "$fz/pages/1.json"
  out="$(bash "$SELF" --fixture "$fz" 2>&1)"; rc=$?
  [ "$rc" -eq 2 ] || { echo "FAIL: an empty labelled population exited $rc, want 2"; fail=1; }
  case "$out" in *"CANNOT READ"*) ;; *) echo "FAIL: empty population printed no CANNOT READ line"; fail=1 ;; esac
  # ...and the SAME fixture with the floor lowered is a legitimate clean zero.
  out="$(bash "$SELF" --fixture "$fz" --min-population 0 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: floor 0 on an honestly-empty ledger exited $rc, want 0"; fail=1; }
  case "$out" in *"the population is clean"*) ;; *) echo "FAIL: a true zero did not say so"; fail=1 ;; esac

  # A MALFORMED SOURCE IS A FAILED READ, NOT A ZERO.
  local fb="$WORK/fb"; mkdir -p "$fb/pages"
  echo 'not json at all' > "$fb/pages/1.json"
  out="$(bash "$SELF" --fixture "$fb" 2>&1)"; rc=$?
  [ "$rc" -eq 2 ] || { echo "FAIL: a malformed page exited $rc, want 2"; fail=1; }
  case "$out" in *"CANNOT READ"*) ;; *) echo "FAIL: malformed page printed no CANNOT READ"; fail=1 ;; esac

  # THE WRONG ARRAY NAME — the exact trap that produced a tidy, wrong zero.
  local fw="$WORK/fw"; mkdir -p "$fw/pages"
  echo '{"ok":true,"tasks":[{"doc_id":"t","content":{"labels":["landed-on-main"]}}],"page":{"returned":1}}' > "$fw/pages/1.json"
  out="$(bash "$SELF" --fixture "$fw" 2>&1)"; rc=$?
  [ "$rc" -eq 2 ] || { echo "FAIL: a page keyed \`tasks\` instead of \`docs\` exited $rc, want 2"; fail=1; }
  # And it must be REFUSED BY NAME, not by tripping over a TypeError further
  # down. A crash also exits 2, so the exit code alone cannot tell the two
  # apart — and only the named refusal survives someone hardening the loop.
  case "$out" in *'no `docs` array'*) ;;
    *) echo "FAIL: the missing-\`docs\` refusal did not name the array. got: $out"; fail=1 ;; esac

  # A SHORT PAGE — docs shorter than the server's own `returned`.
  local fs="$WORK/fs"; mkdir -p "$fs/pages"
  echo '{"ok":true,"docs":[{"doc_id":"t","content":{"labels":["landed-on-main"]}}],"page":{"returned":9,"has_more":false}}' > "$fs/pages/1.json"
  out="$(bash "$SELF" --fixture "$fs" 2>&1)"; rc=$?
  [ "$rc" -eq 2 ] || { echo "FAIL: a short page exited $rc, want 2"; fail=1; }
  case "$out" in *"dropping rows"*) ;; *) echo "FAIL: a short page did not name the drop"; fail=1 ;; esac

  # bp WARNING LINES BEFORE THE JSON must not kill a good page.
  local fp="$WORK/fp"; mkdir -p "$fp/pages"
  { echo "bp: result page filled your --limit exactly; more may be available"
    echo '{"ok":true,"docs":[{"doc_id":"task-warn-1","title":"after a warning","lifecycle_status":"open","content":{"labels":["landed-on-main","landed:pr-1@aaaaaaa"],"acceptance_criteria":[]}}],"page":{"returned":1,"has_more":false}}'
  } > "$fp/pages/1.json"
  out="$(bash "$SELF" --fixture "$fp" 2>&1)"; rc=$?
  case "$out" in *task-warn-1*) ;; *) echo "FAIL: a warning line before the JSON hid a real row"; fail=1 ;; esac

  # LABELS AS OBJECTS, not strings — the mixed shape that aborts a join().
  # Already exercised by task-parent-1 above; assert its landing fact rendered.
  out="$(bash "$SELF" --fixture "$fx" 2>&1)"
  case "$out" in *"landed:pr-15092@cccccc3333"*) ;;
    *) echo "FAIL: an object-shaped label array lost its landing fact"; fail=1 ;; esac

  # UNKNOWN FLAG NEVER PASSES.
  bash "$SELF" --fixture "$fx" --nope >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || { echo "FAIL: an unknown flag exited $rc, want 2"; fail=1; }

  if [ "$fail" -eq 0 ]; then
    echo "landed-open-report --selftest: PASSED"
    return 0
  fi
  echo "landed-open-report --selftest: FAILED"
  return 1
}

case "$MODE" in
  selftest) cmd_selftest; exit $? ;;
  report)   cmd_report;   exit $? ;;
esac
