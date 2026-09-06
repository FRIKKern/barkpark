#!/usr/bin/env bash
# shell-harnesses-dispatch.test.sh — the partition guard and fixture matrix for
# the `changes` dispatcher in .github/workflows/shell-harnesses.yml.
#
# THE DEFECT IT GUARDS. That workflow's `paths:` list is an OR over the inputs
# of ~30 unrelated harness jobs. Measured on PR #15631 (three files, all under
# cloud/lib/): 55 check runs, 28 from this one workflow, 27 of them measuring
# nothing. The dispatcher partitions the list per job so a PR runs only the
# harnesses whose inputs it touched. A partition is two lists that must agree —
# the workflow-level list and the roster — and nothing else makes them, so:
#
#   A  SUBSET   every roster row names a verbatim on.pull_request.paths entry
#   B  UNION    every on.pull_request.paths entry has a roster row (the
#               workflow file itself is in every set implicitly and is exempt)
#   C  GATING   every job under jobs: except `changes` carries
#               `needs: [changes]` and `if: needs.changes.outputs.<id> == 'true'`
#   D  OUTPUTS  every gated job has ≥1 roster row AND an entry in the changes
#               job's `outputs:` map — a gate on an undeclared output is a
#               silent false (the expression is empty, never 'true')
#   E  FIXTURES the dispatcher's `run:` body is EXTRACTED (yaml-parsed, GitHub
#               expressions substituted, leftovers refused) and run over mktemp
#               git repos: push → all true; empty diff → all true; the measured
#               router.ex change → cloud-static-gz ONLY; a cloud/lib file no set
#               names → all false; a new workflow file → exactly the three
#               corpus readers; the workflow file itself → all true; an
#               unresolvable base → exit 1 with the named refusal
#   F  MUTATION the `# MUT: unresolvable-base` line is deleted from a scratch
#               copy (anchor matched EXACTLY ONCE, diff non-empty) and the named
#               refusal must DISAPPEAR — a mutation the harness cannot see is
#               not a catch
#
# bash 3.2 compatible (macOS runs it too): no associative arrays, no mapfile.
# python3 + PyYAML are the only unstubbed dependencies; their absence is exit 2
# HARNESS-UNAVAILABLE, never a pass.
#
# EXIT CODES: 0 all assertions pass · 1 at least one failed · 2 cannot measure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="${SHELL_HARNESSES_WORKFLOW:-$REPO_ROOT/.github/workflows/shell-harnesses.yml}"
SELF_ENTRY=".github/workflows/shell-harnesses.yml"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "ok   - $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $*"; }
unavailable() { echo "HARNESS-UNAVAILABLE: $*" >&2; exit 2; }

command -v python3 >/dev/null 2>&1 || unavailable "python3 is required (the workflow is yaml-parsed)"
python3 -c 'import yaml' 2>/dev/null || unavailable "PyYAML is required (pip3 install pyyaml)"
[ -f "$WORKFLOW" ] || unavailable "workflow not found: $WORKFLOW"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/shd.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── extraction (one python pass, several plain-text products) ───────────────
# Products: paths.txt (on.pull_request.paths, one per line), jobs.txt (job id,
# then needs-ok/if-ok flags), outputs.txt (keys of jobs.changes.outputs),
# body.sh (the dispatcher step with expressions substituted).
if ! python3 - "$WORKFLOW" "$TMP" <<'PY'
import sys, yaml
wf, out = sys.argv[1], sys.argv[2]
with open(wf) as fh:
    doc = yaml.safe_load(fh)
on = doc.get(True) or doc.get("on")  # PyYAML reads a bare `on:` key as True
paths = on["pull_request"]["paths"]
if not paths:
    sys.stderr.write("on.pull_request.paths is empty\n"); sys.exit(2)
with open(out + "/paths.txt", "w") as fh:
    fh.write("\n".join(paths) + "\n")
jobs = doc["jobs"]
if "changes" not in jobs:
    sys.stderr.write("no jobs.changes\n"); sys.exit(2)
with open(out + "/jobs.txt", "w") as fh:
    for jid, job in jobs.items():
        if jid == "changes":
            continue
        needs = job.get("needs")
        if isinstance(needs, str):
            needs = [needs]
        needs_ok = "1" if needs and "changes" in needs else "0"
        want_if = "needs.changes.outputs.%s == 'true'" % jid
        if_ok = "1" if str(job.get("if", "")).strip() == want_if else "0"
        fh.write("%s %s %s\n" % (jid, needs_ok, if_ok))
outputs = jobs["changes"].get("outputs") or {}
with open(out + "/outputs.txt", "w") as fh:
    for k, v in outputs.items():
        fh.write("%s %s\n" % (k, v))
steps = jobs["changes"]["steps"]
hit = [s for s in steps if s.get("id") == "sets"]
if len(hit) != 1:
    sys.stderr.write("expected exactly one step with id sets, got %d\n" % len(hit)); sys.exit(2)
body = hit[0]["run"]
body = body.replace("${{ github.event_name }}", "${EVENT_NAME}")
body = body.replace("${{ github.event.pull_request.base.sha }}", "${BASE_SHA}")
with open(out + "/body.sh", "w") as fh:
    fh.write(body)
PY
then
  unavailable "could not extract the dispatcher from $WORKFLOW (unparseable, or the shape moved)"
fi

BODY="$TMP/body.sh"
if grep -q '\${{' "$BODY"; then
  echo "unsubstituted GitHub expression(s) in the extracted body:" >&2
  grep -n '\${{' "$BODY" >&2
  unavailable "add them to the replace() list in this harness before trusting any result"
fi

# The roster: rows between roster=' and the closing quote, as the dispatcher
# reads them. Extracted from the SAME body the fixtures run.
awk '/^roster=\x27$/ { on = 1; next } on && /^\x27$/ { exit } on && NF { print $1, $2 }' "$BODY" >"$TMP/roster.txt"
ROWS=$(wc -l <"$TMP/roster.txt" | tr -d ' ')
[ "$ROWS" -gt 0 ] || unavailable "the roster came out empty — the extraction anchors no longer match"
awk '{ print $1 }' "$TMP/roster.txt" | awk '!seen[$0]++' >"$TMP/roster-jobs.txt"

N_PATHS=$(wc -l <"$TMP/paths.txt" | tr -d ' ')
N_JOBS=$(wc -l <"$TMP/jobs.txt" | tr -d ' ')
echo "── shell-harnesses dispatcher: $N_PATHS workflow paths, $ROWS roster rows, $N_JOBS gated jobs ──"

# ── A: SUBSET ────────────────────────────────────────────────────────────────
missing_up=""
while read -r job pat; do
  grep -qxF -- "$pat" "$TMP/paths.txt" || missing_up="$missing_up $job:$pat"
done <"$TMP/roster.txt"
if [ -z "$missing_up" ]; then ok "A subset: every roster row is a verbatim on.pull_request.paths entry"
else bad "A subset: roster rows naming paths the workflow never triggers on:$missing_up"; fi

if grep -q "^[^ ]* $SELF_ENTRY\$" "$TMP/roster.txt"; then
  bad "A: the workflow file is implicit in every set and must not be a roster row"
else ok "A: the workflow file is not a roster row (it is implicit in every set)"; fi

# ── B: UNION ─────────────────────────────────────────────────────────────────
missing_down=""
while IFS= read -r p; do
  [ "$p" = "$SELF_ENTRY" ] && continue
  awk '{ print $2 }' "$TMP/roster.txt" | grep -qxF -- "$p" || missing_down="$missing_down $p"
done <"$TMP/paths.txt"
if [ -z "$missing_down" ]; then ok "B union: every on.pull_request.paths entry has a roster row"
else bad "B union: workflow paths with NO roster row (a harness that would never fire):$missing_down"; fi

# ── C: GATING ────────────────────────────────────────────────────────────────
ungated=""
while read -r jid needs_ok if_ok; do
  [ "$needs_ok" = 1 ] && [ "$if_ok" = 1 ] || ungated="$ungated $jid(needs=$needs_ok,if=$if_ok)"
done <"$TMP/jobs.txt"
if [ -z "$ungated" ]; then ok "C gating: all $N_JOBS jobs carry needs: [changes] + if: needs.changes.outputs.<id> == 'true'"
else bad "C gating: jobs missing the gate:$ungated"; fi

# ── D: OUTPUTS ───────────────────────────────────────────────────────────────
no_row=""; no_out=""; bad_out=""
while read -r jid _ _; do
  grep -qx -- "$jid" "$TMP/roster-jobs.txt" || no_row="$no_row $jid"
  if line=$(grep "^$jid " "$TMP/outputs.txt"); then
    case "$line" in
      "$jid \${{ steps.sets.outputs.$jid }}") ;;
      *) bad_out="$bad_out $jid" ;;
    esac
  else
    no_out="$no_out $jid"
  fi
done <"$TMP/jobs.txt"
if [ -z "$no_row" ]; then ok "D: every gated job has at least one roster row"
else bad "D: gated jobs with NO roster row (their output would be empty — a silent false):$no_row"; fi
if [ -z "$no_out$bad_out" ]; then ok "D: every gated job has a matching outputs: entry on the changes job"
else bad "D: outputs missing:$no_out  outputs mis-wired:$bad_out"; fi
extra_out=""
while read -r k _; do
  grep -q "^$k " "$TMP/jobs.txt" || extra_out="$extra_out $k"
done <"$TMP/outputs.txt"
if [ -z "$extra_out" ]; then ok "D: no outputs: entry without a job"
else bad "D: outputs: entries naming no job:$extra_out"; fi
extra_rows=""
while read -r j; do
  grep -q "^$j " "$TMP/jobs.txt" || extra_rows="$extra_rows $j"
done <"$TMP/roster-jobs.txt"
if [ -z "$extra_rows" ]; then ok "D: no roster row names a job that does not exist"
else bad "D: roster rows for jobs that do not exist:$extra_rows"; fi

# ── E: FIXTURES ──────────────────────────────────────────────────────────────
# A throwaway repo: base commit A holds one file from every relevant area; each
# case branches from A, changes one path, and the dispatcher runs at that head.
FIX="$TMP/repo"
mkdir -p "$FIX"
G() { git -C "$FIX" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }
G init -q >/dev/null 2>&1 || unavailable "git init failed"
seed() { mkdir -p "$FIX/$(dirname "$1")"; printf '%s\n' "$2" >"$FIX/$1"; }
seed cloud/lib/barkpark_cloud/web/router.ex "a"
seed cloud/lib/barkpark_cloud/other.ex "a"
seed scripts/doctor.sh "a"
seed .github/workflows/shell-harnesses.yml "a"
seed .github/workflows/elixir.yml "a"
seed README.md "a"
G add -A >/dev/null && G commit -qm A >/dev/null || unavailable "seed commit failed"
BASE_A="$(G rev-parse HEAD)"

# run_dispatcher <event> <base> <outfile> ; prints rc
run_dispatcher() {
  : >"$3"
  ( cd "$FIX" && EVENT_NAME="$1" BASE_SHA="$2" GITHUB_OUTPUT="$3" bash "$BODY" >"$3.log" 2>&1 )
  echo $?
}
# make_case <name> <path> <content> → checks out a branch from A with one change
make_case() {
  G checkout -q "$BASE_A" 2>/dev/null
  G checkout -qB "case-$1" 2>/dev/null
  seed "$2" "$3"
  G add -A >/dev/null && G commit -qm "$1" >/dev/null
}
count_true()  { grep -c '=true$'  "$1" | tr -d ' '; }
count_false() { grep -c '=false$' "$1" | tr -d ' '; }
true_set()    { grep '=true$' "$1" | sed 's/=true$//' | sort | tr '\n' ' ' | sed 's/ $//'; }

# E1 push → all true, exactly N_JOBS outputs
G checkout -q "$BASE_A" 2>/dev/null
rc=$(run_dispatcher push "" "$TMP/e1.out")
if [ "$rc" -eq 0 ] && [ "$(count_true "$TMP/e1.out")" -eq "$N_JOBS" ] && [ "$(count_false "$TMP/e1.out")" -eq 0 ]; then
  ok "E1 push: rc=0, all $N_JOBS harnesses true"
else bad "E1 push: rc=$rc true=$(count_true "$TMP/e1.out") false=$(count_false "$TMP/e1.out") (want $N_JOBS/0)"; fi

# E2 empty diff (head == base) → all true, with the warning
rc=$(run_dispatcher pull_request "$BASE_A" "$TMP/e2.out")
if [ "$rc" -eq 0 ] && [ "$(count_true "$TMP/e2.out")" -eq "$N_JOBS" ] && grep -q '::warning::.*EMPTY' "$TMP/e2.out.log"; then
  ok "E2 empty diff: rc=0, all $N_JOBS true, warning annotated"
else bad "E2 empty diff: rc=$rc true=$(count_true "$TMP/e2.out") warning=$(grep -c '::warning::' "$TMP/e2.out.log")"; fi

# E3 THE MEASURED CASE: router.ex alone → cloud-static-gz only
make_case router cloud/lib/barkpark_cloud/web/router.ex "b"
rc=$(run_dispatcher pull_request "$BASE_A" "$TMP/e3.out")
if [ "$rc" -eq 0 ] && [ "$(true_set "$TMP/e3.out")" = "cloud-static-gz" ] && [ "$(count_false "$TMP/e3.out")" -eq $((N_JOBS - 1)) ]; then
  ok "E3 router.ex only: cloud-static-gz true, the other $((N_JOBS - 1)) false (PR #15631's shape)"
else bad "E3 router.ex only: rc=$rc true={$(true_set "$TMP/e3.out")} false=$(count_false "$TMP/e3.out")"; fi

# E4 a cloud/lib file no set names → all false, all outputs still emitted
make_case other cloud/lib/barkpark_cloud/other.ex "b"
rc=$(run_dispatcher pull_request "$BASE_A" "$TMP/e4.out")
if [ "$rc" -eq 0 ] && [ "$(count_true "$TMP/e4.out")" -eq 0 ] && [ "$(count_false "$TMP/e4.out")" -eq "$N_JOBS" ]; then
  ok "E4 unlisted cloud/lib file: rc=0, all $N_JOBS false (every output still emitted)"
else bad "E4 unlisted file: rc=$rc true=$(count_true "$TMP/e4.out") false=$(count_false "$TMP/e4.out")"; fi

# E5 a single-set literal → exactly that job
make_case doctor scripts/doctor.sh "b"
rc=$(run_dispatcher pull_request "$BASE_A" "$TMP/e5.out")
if [ "$rc" -eq 0 ] && [ "$(true_set "$TMP/e5.out")" = "doctor-matrix" ]; then
  ok "E5 scripts/doctor.sh: doctor-matrix only"
else bad "E5 scripts/doctor.sh: rc=$rc true={$(true_set "$TMP/e5.out")}"; fi

# E6 a new workflow file → the FOUR corpus readers via the *.yml glob (selftest-wiring-census
#    joined in task-8780f3b465edea5b: it resolves execution FROM the workflow corpus, so a new
#    workflow can change which self-tests count as run)
make_case newwf .github/workflows/brand-new.yml "a"
rc=$(run_dispatcher pull_request "$BASE_A" "$TMP/e6.out")
if [ "$rc" -eq 0 ] && [ "$(true_set "$TMP/e6.out")" = "deploy-concurrency selftest-wiring-census workflow-portability workflow-trigger-coverage" ]; then
  ok "E6 new workflow file: exactly the four .github/workflows/*.yml readers"
else bad "E6 new workflow file: rc=$rc true={$(true_set "$TMP/e6.out")}"; fi

# E7 this workflow file itself → all true
make_case self .github/workflows/shell-harnesses.yml "b"
rc=$(run_dispatcher pull_request "$BASE_A" "$TMP/e7.out")
if [ "$rc" -eq 0 ] && [ "$(count_true "$TMP/e7.out")" -eq "$N_JOBS" ]; then
  ok "E7 the workflow file itself: all $N_JOBS true"
else bad "E7 the workflow file: rc=$rc true=$(count_true "$TMP/e7.out")"; fi

# E8 unresolvable base → exit 1, named refusal, NO outputs
G checkout -q "case-router" 2>/dev/null
BOGUS="dddddddddddddddddddddddddddddddddddddddd"
rc=$(run_dispatcher pull_request "$BOGUS" "$TMP/e8.out")
if [ "$rc" -eq 1 ] && grep -q 'is not resolvable in this checkout' "$TMP/e8.out.log" && [ ! -s "$TMP/e8.out" ]; then
  ok "E8 unresolvable base: rc=1, named refusal, zero outputs emitted"
else bad "E8 unresolvable base: rc=$rc refusal=$(grep -c 'is not resolvable' "$TMP/e8.out.log") outputs=$(wc -l <"$TMP/e8.out" | tr -d ' ')"; fi

# E9 missing base sha on a pull_request → exit 1
rc=$(run_dispatcher pull_request "" "$TMP/e9.out")
if [ "$rc" -eq 1 ] && grep -q 'no base sha' "$TMP/e9.out.log" && [ ! -s "$TMP/e9.out" ]; then
  ok "E9 empty base sha: rc=1, refused, zero outputs"
else bad "E9 empty base sha: rc=$rc"; fi

# E10 no common ancestor → exit 1, named refusal
ORPH="$TMP/orphan"; mkdir -p "$ORPH"
git -C "$ORPH" -c init.defaultBranch=main init -q >/dev/null 2>&1
printf 'x\n' >"$ORPH/x"
git -C "$ORPH" -c user.name=t -c user.email=t@t -c commit.gpgsign=false add -A >/dev/null
git -C "$ORPH" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm orphan >/dev/null
ORPH_SHA="$(git -C "$ORPH" rev-parse HEAD)"
G fetch -q "$ORPH" "$ORPH_SHA" 2>/dev/null || unavailable "could not fetch the orphan commit into the fixture"
rc=$(run_dispatcher pull_request "$ORPH_SHA" "$TMP/e10.out")
if [ "$rc" -eq 1 ] && grep -q 'NO common ancestor' "$TMP/e10.out.log" && [ ! -s "$TMP/e10.out" ]; then
  ok "E10 no common ancestor: rc=1, named refusal, zero outputs"
else bad "E10 no common ancestor: rc=$rc refusal=$(grep -c 'common ancestor' "$TMP/e10.out.log")"; fi

# ── F: MUTATION — the unresolvable-base refusal is load-bearing ──────────────
MUT="$TMP/body-mut.sh"
ANCHOR='# MUT: unresolvable-base'
n_anchor=$(grep -cF -- "$ANCHOR" "$BODY" | tr -d ' ')
if [ "$n_anchor" -eq 1 ]; then
  ok "F: mutation anchor '$ANCHOR' matched exactly once"
else
  bad "F: mutation anchor matched $n_anchor times (want 1) — the mutation below cannot be trusted"
fi
grep -vF -- "$ANCHOR" "$BODY" >"$MUT"
if ! cmp -s "$BODY" "$MUT"; then ok "F: the mutant differs from the original (mutation applied)"
else bad "F: the mutant is byte-identical to the original — nothing was mutated"; fi
G checkout -q "case-router" 2>/dev/null
: >"$TMP/f.out"
( cd "$FIX" && EVENT_NAME=pull_request BASE_SHA="$BOGUS" GITHUB_OUTPUT="$TMP/f.out" bash "$MUT" >"$TMP/f.log" 2>&1 )
mrc=$?
if ! grep -q 'is not resolvable in this checkout' "$TMP/f.log"; then
  ok "F: with the guard deleted the named refusal DISAPPEARS (mutant rc=$mrc) — the guard is load-bearing"
else
  bad "F: the mutant still printed the unresolvable-base refusal — the anchor no longer covers the guard"
fi

echo ""
echo "shell-harnesses-dispatch: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
[ "$PASS" -ge 20 ] || { echo "only $PASS assertions ran — the harness shrank" >&2; exit 2; }
exit 0
