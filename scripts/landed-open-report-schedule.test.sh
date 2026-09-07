#!/usr/bin/env bash
#
# landed-open-report-schedule.test.sh — the harness for the SCHEDULED consumer,
# scripts/landed-open-report-schedule.sh.
#
# It runs the exact step body the workflow runs, with a STUB `bp` on
# LANDED_REPORT_BP, so every arm is provable with no token and no network:
#
#   1. good pages          -> exit 0, the report reaches $GITHUB_STEP_SUMMARY
#   2. a PARENT/GATE? row  -> the FLAGS survive into the summary file
#   3. bp exits non-zero (a 401) -> exit NON-ZERO and the reader's own
#                                   `CANNOT READ` line is in the output
#   4. no BARKPARK_TOKEN   -> exit non-zero, ::error, never a silent skip
#   5. a labelled population under the floor -> exit non-zero (the positive
#                                   control: labels are only ever ADDED)
#   6. findings            -> exit 0 (a report is not a defect) but a
#                                   ::warning names the count
#
# And then it MUTATES the consumer to prove those assertions are load-bearing:
# a harness that stays green when the failure propagation is deleted is
# theatre. Each mutation asserts it APPLIED (anchor present exactly once, diff
# non-empty) before it asserts the run goes red — a mutation that did not build
# is not a catch.
#
#   bash scripts/landed-open-report-schedule.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEP="$ROOT/scripts/landed-open-report-schedule.sh"
SH="$ROOT/scripts/landed-open-report.sh"
PY="$ROOT/scripts/lib/landed_open_report.py"

WORK="$(mktemp -d -t landed-open-schedule-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
FAIL=0
PASS=0

ok()   { PASS=$((PASS + 1)); }
bad()  { echo "FAIL [$1]: $2"; FAIL=$((FAIL + 1)); }

# ── a stub bp ────────────────────────────────────────────────────────────────
# $1 dir · $2 mode: good | flagged | thin | deny
make_stub() {
  local d="$1" mode="$2"
  mkdir -p "$d"
  cat > "$d/bp" <<STUB
#!/usr/bin/env bash
# stub bp — answers exactly one shape: \`task ls --limit N --cursor C -o json\`
case "\$*" in
  *"task ls"*) ;;
  *) echo "stub bp: unexpected argv: \$*" >&2; exit 64 ;;
esac
MODE="$mode"
if [ "\$MODE" = "deny" ]; then
  echo '{"ok":false,"error":{"code":"unauthorized","message":"401 invalid token"}}'
  exit 1
fi
STUB
  cat >> "$d/bp" <<'STUB'
if [ "$MODE" = "thin" ]; then
  cat <<'JSON'
{"ok":true,"docs":[{"doc_id":"task-plain-1","title":"nothing labelled","lifecycle_status":"open","content":{"labels":["p1"]}}],"page":{"returned":1,"has_more":false}}
JSON
  exit 0
fi
cat <<'JSON'
{"ok":true,"docs":[
 {"doc_id":"task-live-1","title":"a live landed row","lifecycle_status":"open","child_count":0,
  "content":{"labels":["landed-on-main","landed:pr-15090@abcdef1234"],
             "acceptance_criteria":[{"criterion":"a thing","met":true},{"criterion":"another","met":false}]}},
 {"doc_id":"task-parent-1","title":"an epic named by many PRs","lifecycle_status":"open","child_count":7,
  "content":{"labels":["landed-on-main","landed:pr-15092@cccccc3333"],
             "acceptance_criteria":[{"criterion":"kids ship","met":false}]}},
 {"doc_id":"task-gate-1","title":"waiting on a person","lifecycle_status":"in_progress",
  "content":{"labels":["landed-on-main","landed:pr-15093@dddddd4444"],
             "acceptance_criteria":[{"criterion":"a lead signs off on the rollout","met":false}]}},
 {"doc_id":"task-done-1","title":"already sealed","lifecycle_status":"done",
  "content":{"labels":["landed-on-main","landed:pr-15091@bbbbbb2222"],"acceptance_criteria":[]}}
],"page":{"returned":4,"has_more":false}}
JSON
STUB
  chmod +x "$d/bp"
}

# Run the step script (or a scratch copy of it) under a stub.
# $1 label-dir · $2 step path · $3 stub mode · $4 floor · $5 token ("" = unset)
# Sets: RUN_OUT, RUN_RC, RUN_SUMMARY (path)
run_step() {
  local tag="$1" step="$2" mode="$3" floor="$4" token="$5"
  local d="$WORK/$tag"
  mkdir -p "$d"
  make_stub "$d" "$mode"
  RUN_SUMMARY="$d/summary.md"
  : > "$RUN_SUMMARY"
  if [ -z "$token" ]; then
    RUN_OUT="$(env -u BARKPARK_TOKEN \
      GITHUB_STEP_SUMMARY="$RUN_SUMMARY" \
      LANDED_REPORT_BP="$d/bp" \
      LANDED_SCHEDULE_MIN_POPULATION="$floor" \
      bash "$step" 2>&1)"
  else
    RUN_OUT="$(env BARKPARK_TOKEN="$token" \
      GITHUB_STEP_SUMMARY="$RUN_SUMMARY" \
      LANDED_REPORT_BP="$d/bp" \
      LANDED_SCHEDULE_MIN_POPULATION="$floor" \
      bash "$step" 2>&1)"
  fi
  RUN_RC=$?
}

# ── 1. the happy path ────────────────────────────────────────────────────────
run_step good "$STEP" good 1 "tok"
[ "$RUN_RC" -eq 0 ] || bad "good/exit" "a successful read exited $RUN_RC, want 0"
[ "$RUN_RC" -eq 0 ] && ok
case "$RUN_OUT" in *"walked 4 rows, 4 carry landed-on-main, 3 live"*) ok ;;
  *) bad "good/trailer" "the population trailer is missing. got: $(printf '%s' "$RUN_OUT" | tail -3)" ;; esac
case "$(cat "$RUN_SUMMARY")" in *task-live-1*) ok ;;
  *) bad "good/summary" "the report did not reach GITHUB_STEP_SUMMARY" ;; esac

# ── 2. THE FLAGS SURVIVE. The row this whole task exists to protect: a clean-
# looking list is the failure mode, so [PARENT] and [GATE?] must be in the
# published summary, not merely in some intermediate buffer.
case "$(cat "$RUN_SUMMARY")" in *"[PARENT]"*) ok ;;
  *) bad "flags/parent" "[PARENT] did not survive into the step summary" ;; esac
case "$(cat "$RUN_SUMMARY")" in *"[GATE?]"*) ok ;;
  *) bad "flags/gate" "[GATE?] did not survive into the step summary" ;; esac
case "$(cat "$RUN_SUMMARY")" in *task-done-1*)
    bad "flags/done" "a terminal row leaked into the live list" ;; *) ok ;; esac

# ── 6. findings are a REPORT, not a red — but they are announced ─────────────
case "$RUN_OUT" in *"::warning title=Landed work still open::3 task rows"*) ok ;;
  *) bad "good/warning" "3 live rows raised no ::warning naming the count" ;; esac

# ── 3. a refused read is a RED, and it carries the reader's own line ─────────
run_step deny "$STEP" deny 1 "tok"
[ "$RUN_RC" -ne 0 ] || bad "deny/exit" "a 401 from bp exited 0 — a failed read rendered as nothing to do"
[ "$RUN_RC" -ne 0 ] && ok
case "$RUN_OUT" in *"CANNOT READ"*) ok ;;
  *) bad "deny/line" "the reader's own CANNOT READ line is absent from the job output" ;; esac
case "$RUN_OUT" in *"::error title=landed-open-report CANNOT READ"*) ok ;;
  *) bad "deny/annotation" "a failed read raised no ::error annotation" ;; esac
case "$(cat "$RUN_SUMMARY")" in *"CANNOT READ"*) ok ;;
  *) bad "deny/summary" "the CANNOT READ line did not reach the step summary" ;; esac

# ── 4. an unset token is a failure, never a skip ─────────────────────────────
run_step notoken "$STEP" good 1 ""
[ "$RUN_RC" -ne 0 ] || bad "notoken/exit" "an unset BARKPARK_TOKEN exited 0 — a permanent silent no-op"
[ "$RUN_RC" -ne 0 ] && ok
case "$RUN_OUT" in *"::error title=landed-open-report cannot read"*) ok ;;
  *) bad "notoken/annotation" "an unset token raised no ::error" ;; esac

# ── 5. the floor is the positive control ─────────────────────────────────────
run_step floor "$STEP" thin 400 "tok"
[ "$RUN_RC" -ne 0 ] || bad "floor/exit" "a labelled population of 0 against a floor of 400 exited 0"
[ "$RUN_RC" -ne 0 ] && ok
case "$RUN_OUT" in *"min-population"*) ok ;;
  *) bad "floor/line" "the floor refusal did not name --min-population" ;; esac

# ── MUTATIONS — the assertions above must be load-bearing ────────────────────
# Every mutation below DELETES one guard and requires the consumer to stop
# refusing: pristine refuses (asserted above), mutant does not. A harness that
# stays green when the failure propagation is removed is theatre.
#
# `apply_mutation` proves the edit LANDED before anything is concluded from the
# run — anchor present exactly once, resulting file not byte-identical. A
# mutation that did not build is not a catch.
# $1 label · $2 anchor · $3 replacement  ->  echoes the mutated script's path
apply_mutation() {
  local label="$1" anchor="$2" repl="$3"
  # A SCRATCH TREE, not a loose file. The consumer resolves its reader as
  # `$(dirname $0)/../scripts/landed-open-report.sh`, so a mutant dropped
  # anywhere else takes the "reader missing" exit — a red for the wrong reason
  # that would let a dead mutation pass for a catch.
  local d="$WORK/mut-$label/scripts"
  mkdir -p "$d/lib"
  cp "$SH" "$d/landed-open-report.sh"
  cp "$PY" "$d/lib/landed_open_report.py"
  cp "$STEP" "$d/step.sh"
  local hits
  hits="$(python3 -c 'import sys;print(open(sys.argv[1]).read().count(sys.argv[2]))' "$d/step.sh" "$anchor")"
  if [ "$hits" != "1" ]; then
    echo "HARNESS FAIL [$label]: anchor matched $hits times, want exactly 1" >&2
    return 1
  fi
  python3 -c '
import sys
p,a,r=sys.argv[1],sys.argv[2],sys.argv[3]
s=open(p).read()
open(p,"w").write(s.replace(a,r,1))
' "$d/step.sh" "$anchor" "$repl"
  if cmp -s "$d/step.sh" "$STEP"; then
    echo "HARNESS FAIL [$label]: the mutation left the file byte-identical" >&2
    return 1
  fi
  printf '%s' "$d/step.sh"
}

# $1 label · $2 anchor · $3 repl · $4 stub mode · $5 floor · $6 token
# The pristine consumer REFUSES on this input; the mutant must stop refusing.
mutation_kills_the_red() {
  local label="$1" mutant
  mutant="$(apply_mutation "$1" "$2" "$3")" || { FAIL=$((FAIL + 1)); return; }
  run_step "mutrun-$label" "$mutant" "$4" "$5" "$6"
  if [ "$RUN_RC" -ne 0 ]; then
    echo "FAIL [$label]: the mutation removed the only refusal on this input and the run STILL exited $RUN_RC — the assertion is not testing what it claims"
    FAIL=$((FAIL + 1))
  else
    PASS=$((PASS + 1))
  fi
}

# THE FAILURE PROPAGATION ITSELF. Delete it and a refused ledger read becomes a
# green job — the exact defect this row was filed against.
mutation_kills_the_red "reader-2-not-red" \
  '    exit 1
    ;;
  *)' \
  '    exit 0
    ;;
  *)' \
  deny 1 "tok"

# THE MISSING-CREDENTIAL ARM. Without it an unset secret is a permanent silent
# no-op wearing a green tick.
mutation_kills_the_red "notoken-not-red" \
  '  } | tee -a "$SUMMARY"
  exit 1
fi' \
  '  } | tee -a "$SUMMARY"
  exit 0
fi' \
  good 1 ""

# THE FLAG PUBLICATION. Stop writing the report into the summary and the
# [PARENT] / [GATE?] assertions above must go dark — otherwise they were
# reading something the job never published.
flagmut="$(apply_mutation "flags-not-published" \
  '  echo '"'"'```'"'"'
  printf '"'"'%s\n'"'"' "$out"
  echo '"'"'```'"'"'' \
  '  echo "(report withheld)"')" || FAIL=$((FAIL + 1))
if [ -n "${flagmut:-}" ]; then
  run_step mutrun-flags "$flagmut" good 1 "tok"
  case "$(cat "$RUN_SUMMARY")" in
    *"[PARENT]"*) echo "FAIL [flags-not-published]: [PARENT] reached the summary even with the report withheld — the flag assertion reads something else"; FAIL=$((FAIL + 1)) ;;
    *) PASS=$((PASS + 1)) ;;
  esac
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "landed-open-report-schedule.test.sh: PASSED ($PASS assertions)"
  exit 0
fi
echo "landed-open-report-schedule.test.sh: FAILED ($FAIL failed, $PASS passed)"
exit 1
