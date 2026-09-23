#!/usr/bin/env bash
# deploy-convergence-check.test.sh — the harness for task-103b5cc5ec4a8ccd:
# "the deploy-convergence job prints converged=false and concludes success".
#
# The defect was never in the COMPARISON — `converged` has always returned rc 1
# on a real strand. It was that nothing turned that rc into a conclusion. So the
# subject here is the CONCLUSION, in the two places it now lives.
#
# PART A — `adjudicate`, the decision itself. Drives the mode end-to-end and
# asserts on the EXIT CODE of the whole program, never on scan text. Both
# directions the row demands are here: A3 is "stranded, nothing coming" (must be
# rc 1) and A4 is "stranded, a deploy is in flight" (must be rc 0). A gate that
# only proves one direction proves nothing about the boundary between them.
#
# PART D — task-a077f2e24350d3af: the in-flight suppression EXPIRES on strand
# age (2 x the deploy lock wait read from the deploy scripts). 59 min stays
# green and SAYS it is waiting; 61 min reds STALLED; a current box is the
# control; an unageable strand is CANNOT READ, rc 3; D9 proves D2 can lose.
#
# PART B — the WIRING in .github/workflows/deploy.yml. The step body is
# EXTRACTED with a YAML parser, never copied, so this harness measures the
# workflow that ships rather than a stale transcription of it. B1 is the exact
# regression: a `check` step whose last statement is an unconditional `exit 0`
# has thrown the verdict away, and this file must red on it.
#
# Nothing here reaches the network, a credential, or a box.
#
# EXIT CODES
#   0  every case passed
#   1  at least one case FAILED
#   2  the harness could not run
set -uo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
SUBJECT="$REPO_ROOT/scripts/deploy-convergence-check.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/deploy.yml"

command -v python3 >/dev/null || { echo "HARNESS-UNAVAILABLE: no python3" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "HARNESS-UNAVAILABLE: no PyYAML" >&2; exit 2; }
[ -f "$SUBJECT" ]  || { echo "HARNESS-UNAVAILABLE: $SUBJECT missing" >&2; exit 2; }
[ -f "$WORKFLOW" ] || { echo "HARNESS-UNAVAILABLE: $WORKFLOW missing" >&2; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }

# rc CAPTURED WITHOUT A PIPE. `bash x | tail; echo $?` reports tail's status, and
# under `set -o pipefail` a `grep -q` writer answers 141 on a MATCH. Every
# assertion in this file reads a variable a plain command assignment set.
expect_rc() { # name want stdin-file args...
  local name="$1" want="$2" stdin="$3"; shift 3
  local got=0
  bash "$SUBJECT" adjudicate "$@" < "$stdin" >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then ok "$name (rc=$got)"; else bad "$name — wanted rc=$want, got rc=$got"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/none"
printf '9001 aaaaaaa queued\n'       > "$TMP/queued"
printf '9002 bbbbbbb in_progress\n'  > "$TMP/running"
printf '9003 ccccccc completed\n'    > "$TMP/terminal"
printf '9003 ccccccc completed\n9004 ddddddd queued\n' > "$TMP/mixed"

# task-a077f2e24350d3af: every in-flight suppression now needs a strand age. A
# YOUNG strand (59 min against the 60 min bound read from the real deploy
# scripts) keeps the pre-existing arms below asserting exactly what they always
# did; Part D owns the age boundary itself. --now pins the clock so no case can
# drift across the bound while the harness runs.
NOW=2026-09-22T13:00:00Z
YOUNG=(--now "$NOW" --strand-since 2026-09-22T12:01:00Z --strand-served e02e4296d
       --strand-newest 3be2babacc34c7127dcb7109c00e277b8a8ba0e8)

echo "PART A — adjudicate decides the conclusion"
expect_rc "A1 not stranded, nothing running          -> GREEN"  0 "$TMP/none"     --stranded false
expect_rc "A2 not stranded, a deploy running         -> GREEN"  0 "$TMP/queued"   --stranded false
# ── THE ROW'S TWO DIRECTIONS ────────────────────────────────────────────────
expect_rc "A3 STRANDED, nothing in flight            -> RED"    1 "$TMP/none"     --stranded true
expect_rc "A4 STRANDED, a queued deploy              -> GREEN"  0 "$TMP/queued"   --stranded true "${YOUNG[@]}"
expect_rc "A5 STRANDED, an in_progress deploy        -> GREEN"  0 "$TMP/running"  --stranded true "${YOUNG[@]}"
# A terminal run explains nothing: it already had its turn and the box is still
# behind. Folding `completed` into "in flight" is how this gate would be waived
# by its own history.
expect_rc "A6 STRANDED, only a COMPLETED run         -> RED"    1 "$TMP/terminal" --stranded true
expect_rc "A7 STRANDED, one terminal + one queued    -> GREEN"  0 "$TMP/mixed"    --stranded true "${YOUNG[@]}"
# UNCHECKED is an absence of evidence, never a finding — it must not red on its
# own, or an unreadable /health becomes an outage report.
expect_rc "A8 not stranded but a leg was UNCHECKED   -> GREEN"  0 "$TMP/none"     --stranded false --unchecked true
# "I could not look" withholds the CONCLUSION, not the finding.
expect_rc "A9 STRANDED, in-flight lookup failed      -> GREEN"  0 "$TMP/none"     --stranded true --in-flight-source unknown "${YOUNG[@]}"
# A missing or malformed verdict must REFUSE. Defaulting it to false is exactly
# the shape this row is about: a gate greening on its own breakage.
expect_rc "A10 no --stranded at all                  -> REFUSE" 2 "$TMP/none"
expect_rc "A11 --stranded 'maybe'                    -> REFUSE" 2 "$TMP/none"     --stranded maybe
expect_rc "A12 an unknown argument                   -> REFUSE" 2 "$TMP/none"     --stranded true --bogus x

echo ""
echo "PART C — task-c5955c660c7b9e55: THIS run's own instance leg"
# ── THE DEFECT, AS A FIXTURE ────────────────────────────────────────────────
# Runs 35722816309 / 35720835901 / 35718876385 (2026-09-22): the `instance` JOB
# concluded FAILURE, guerrilla kept serving e02e4296d, sibling deploy runs were
# queued, and this check concluded SUCCESS on all three. $TMP/running is exactly
# that sibling. C1 is the row's red direction and C2..C5 its green ones, and
# every one of them is asserted against the SAME in-flight fixture so the only
# thing that varies is the field under test.
#
# THE DISCRIMINATOR is the instance leg's own conclusion on THIS run, never a
# served-vs-head comparison. C3/C4/C5 are the three "never going to move it"
# shapes — skipped (the path filter found nothing for this host), cancelled
# (superseded), success (it did its job) — and none of them may red.
expect_rc "C1 instance FAILED + box STRANDED, sibling queued   -> RED" 1 "$TMP/running" \
  --stranded true --instance-result failure --instance-state stranded \
  --instance-served e02e4296d --instance-tip 3be2babacc34c7127dcb7109c00e277b8a8ba0e8 "${YOUNG[@]}"
expect_rc "C2 instance FAILED but box CONVERGED                -> GREEN" 0 "$TMP/running" \
  --stranded false --instance-result failure --instance-state converged
expect_rc "C3 instance SKIPPED (nothing for this host)         -> GREEN" 0 "$TMP/running" \
  --stranded true --instance-result skipped --instance-state stranded "${YOUNG[@]}"
expect_rc "C4 instance CANCELLED (superseded)                  -> GREEN" 0 "$TMP/running" \
  --stranded true --instance-result cancelled --instance-state stranded "${YOUNG[@]}"
expect_rc "C5 instance SUCCEEDED, box behind, deploy in flight -> GREEN" 0 "$TMP/running" \
  --stranded true --instance-result success --instance-state stranded "${YOUNG[@]}"
# ── CANNOT READ FAILS, IT DOES NOT SKIP ────────────────────────────────────
# A failed deploy plus an unreadable box is the least safe moment to assume the
# sha moved. `absent` is the same finding reached another way: the caller never
# managed to record a state at all.
expect_rc "C6 instance FAILED + box UNREADABLE (CANNOT READ)   -> RED" 1 "$TMP/running" \
  --stranded false --instance-result failure --instance-state unchecked
expect_rc "C7 instance FAILED + no state recorded at all       -> RED" 1 "$TMP/running" \
  --stranded false --instance-result failure --instance-state absent
# The in-flight lookup FAILING must not rescue a failed attempt either: the
# withheld-conclusion arm is about a box that is merely behind.
expect_rc "C8 instance FAILED + STRANDED + lookup unknown      -> RED" 1 "$TMP/none" \
  --stranded true --in-flight-source unknown --instance-result failure --instance-state stranded
# An unrecognised value is a harness fault, never "probably fine".
expect_rc "C9 --instance-result 'exploded'                     -> REFUSE" 2 "$TMP/none" \
  --stranded true --instance-result exploded
expect_rc "C10 --instance-state 'probably-ok'                  -> REFUSE" 2 "$TMP/none" \
  --stranded true --instance-state probably-ok
# Not wiring the leg at all must leave every pre-existing verdict untouched.
expect_rc "C11 unwired leg behaves exactly as before           -> GREEN" 0 "$TMP/running" --stranded true "${YOUNG[@]}"

# ── C12: THE RED NAMES BOTH SHAS ──────────────────────────────────────────
# A red that does not say what the box serves and what it owes sends the
# operator back to the log to re-derive it. Read from a captured file, never a
# pipe: `bash x | grep -q` answers 141 under pipefail.
c12="$TMP/c12.out"
c12rc=0
bash "$SUBJECT" adjudicate --stranded true --instance-result failure --instance-state stranded \
  --instance-served e02e4296d --instance-tip 3be2babacc34c7127dcb7109c00e277b8a8ba0e8 \
  < "$TMP/running" > "$c12" 2>&1 || c12rc=$?
c12body="$(cat "$c12")"
case "$c12body" in
  *e02e4296d*3be2babacc34c7127dcb7109c00e277b8a8ba0e8*|*3be2babacc34c7127dcb7109c00e277b8a8ba0e8*e02e4296d*)
    ok "C12 the red names BOTH shas (rc=$c12rc)" ;;
  *) bad "C12 the red did not name both shas" ;;
esac

# ── C13, THE MUTATION: prove C1 can actually lose ──────────────────────────
# A guard never shown failing is a guard nobody knows still works. Excise the
# new arm from a COPY of the subject and re-run C1's exact invocation: it must
# fall through to the in-flight suppression and go GREEN, which IS the defect.
# The plant is VERIFIED — arm present in the subject, absent from the mutant —
# before the verdict that rests on it is read.
# THE MUTANT LIVES BESIDE THE SUBJECT, not in $TMP: the subject sources
# scripts/lib/ relative to its OWN directory, so a copy anywhere else dies at
# load with rc=1 — indistinguishable from the red this arm is trying to prove.
# That near-miss is why C13a2 below exists.
mutsub="$REPO_ROOT/scripts/.mutant-convergence-$$.sh"
trap 'rm -rf "$TMP"; rm -f "$mutsub"' EXIT
python3 - "$SUBJECT" "$mutsub" <<'PYMUT'
import sys
src = open(sys.argv[1]).read()
start = src.index('  if [ "$inst_result" = "failure" ]; then')
end   = src.index('  if [ "$stranded" != "true" ]; then', start)
open(sys.argv[2], "w").write(src[:start] + src[end:])
PYMUT
mut_arm_before=$(grep -c 'inst_result" = "failure"' "$SUBJECT")
mut_arm_after=$(grep -c 'inst_result" = "failure"' "$mutsub")
mut_lines_gone=$(( $(wc -l < "$SUBJECT") - $(wc -l < "$mutsub") ))
if [ "$mut_arm_before" -ge 1 ] && [ "$mut_arm_after" -eq 0 ] && [ "$mut_lines_gone" -gt 20 ]; then
  ok "C13a PLANT VERIFIED: arm present in subject (${mut_arm_before}x), absent from mutant, ${mut_lines_gone} lines excised"
  # C13a2 — THE PRECONDITION, not just the plant. A mutant that fails to LOAD
  # also exits non-zero, and a non-zero from a dead script would read as "C13b
  # passed" for a green it never measured. So first make the mutant answer a
  # question whose correct answer is 0: not stranded, nothing coming.
  crc=0
  bash "$mutsub" adjudicate --stranded false < "$TMP/none" >/dev/null 2>&1 || crc=$?
  if [ "$crc" -ne 0 ]; then
    bad "C13a2 the mutant does not RUN (rc=$crc on a trivially-green input) — C13b would measure a load error, not a verdict"
  else
    ok "C13a2 the mutant loads and adjudicates normally (rc=0 on a trivially-green input)"
  fi
  mrc=0
  bash "$mutsub" adjudicate --stranded true --instance-result failure --instance-state stranded \
    --instance-served e02e4296d --instance-tip 3be2babacc34c7127dcb7109c00e277b8a8ba0e8 "${YOUNG[@]}" \
    < "$TMP/running" >/dev/null 2>&1 || mrc=$?
  if [ "$mrc" -eq 0 ]; then
    ok "C13b the mutant REPRODUCES the vacuous green (rc=0) — C1 is not vacuous"
  else
    bad "C13b the mutant still red (rc=$mrc); C1 cannot be shown to discriminate"
  fi
else
  bad "C13a the plant failed (before=$mut_arm_before after=$mut_arm_after removed=$mut_lines_gone) — C13b would measure nothing"
fi

echo ""
echo "PART D — task-a077f2e24350d3af: in-flight suppression EXPIRES on strand age"
# ── THE SHAPE, AS A FIXTURE ─────────────────────────────────────────────────
# The box is stranded, ONE sibling sits queued ('111 abc123 queued' — the row's
# own reproduction), and this run's instance leg did NOT fail. Before this row
# every such case exited 0 for as long as the queue lasted. The bound is
# 2 x the lock wait READ from the real deploy scripts (1800 s -> 60 min); D0
# pins that, so a change to the budget reds here rather than silently moving
# every boundary below.
printf '111 abc123 queued\n' > "$TMP/sibling"
SERVED=e02e4296d
NEWEST=3be2babacc34c7127dcb7109c00e277b8a8ba0e8
AT59=(--now "$NOW" --strand-since 2026-09-22T12:01:00Z --strand-served "$SERVED" --strand-newest "$NEWEST")
AT61=(--now "$NOW" --strand-since 2026-09-22T11:59:00Z --strand-served "$SERVED" --strand-newest "$NEWEST")

# run_d NAME WANT_RC STDIN NEEDLE... -- ARGS... : rc AND text, from a captured
# file (never a pipe), each needle a separate assertion.
run_d() {
  local name="$1" want="$2" stdin="$3"; shift 3
  local needles=() out="$TMP/d.out" got=0 body n
  while [ "$1" != "--" ]; do needles+=("$1"); shift; done; shift
  bash "$SUBJECT" adjudicate "$@" < "$stdin" > "$out" 2>&1 || got=$?
  body="$(cat "$out")"
  if [ "$got" -ne "$want" ]; then bad "$name — wanted rc=$want, got rc=$got"; printf '%s\n' "$body" >&2; return; fi
  for n in "${needles[@]}"; do
    case "$body" in *"$n"*) : ;; *) bad "$name — rc=$got but '$n' is absent from the output"; printf '%s\n' "$body" >&2; return ;; esac
  done
  ok "$name (rc=$got)"
  # Echo the line a reader would act on: the GREEN-BECAUSE-* word when there
  # is one (it is what tells the two greens apart), else the VERDICT line.
  local shown
  shown="$(grep -E '^GREEN-BECAUSE' "$out" | awk 'NR==1')"
  [ -n "$shown" ] || shown="$(grep -E '^VERDICT' "$out" | awk 'NR==1')"
  printf '       %s\n' "$shown"
}

lw_all="$(bash "$SUBJECT" filters 2>&1 || true)"
lw_line="$(grep '^deploy lock wait:' <<<"$lw_all" || true)"
case "$lw_line" in
  "deploy lock wait: 1800s ("*"stall bound 3600s") ok "D0 the bound is READ from the deploy scripts: $lw_line" ;;
  *) bad "D0 the lock wait did not read as 1800s — every boundary below is off: '${lw_line:-<none>}'" ;;
esac

for r in skipped cancelled success; do
  run_d "D1 ${r}: 59 min stranded + queued sibling -> GREEN-BECAUSE-WAITING" 0 "$TMP/sibling" \
    "GREEN-BECAUSE-WAITING" "stranded 59 min of a 60 min bound" "$SERVED" "$NEWEST" -- \
    --stranded true --in-flight-source ok --instance-state stranded --instance-result "$r" "${AT59[@]}"
  run_d "D2 ${r}: 61 min stranded + queued sibling -> STALLED" 1 "$TMP/sibling" \
    "VERDICT: STALLED" "for 61 min" "$SERVED" "$NEWEST" "60 min = 2 x the 1800s deploy lock wait" -- \
    --stranded true --in-flight-source ok --instance-state stranded --instance-result "$r" "${AT61[@]}"
done

# D3 THE CONTROL: a CURRENT box with the same queued sibling stays green, and
# says it is green because it SHIPPED — never the waiting word.
run_d "D3 CONTROL: box CURRENT + queued sibling -> GREEN-BECAUSE-SHIPPED" 0 "$TMP/sibling" \
  "GREEN-BECAUSE-SHIPPED" -- \
  --stranded false --in-flight-source ok --instance-state converged --instance-result success "${AT61[@]}"
d3="$(bash "$SUBJECT" adjudicate --stranded false --instance-state converged --instance-result success \
       "${AT61[@]}" < "$TMP/sibling" 2>&1 || true)"
case "$d3" in
  *GREEN-BECAUSE-WAITING*) bad "D3b a CURRENT box printed GREEN-BECAUSE-WAITING — the two greens are indistinguishable again" ;;
  *) ok "D3b a CURRENT box never prints GREEN-BECAUSE-WAITING" ;;
esac

# D4 THE #19859 ARM, UNCHANGED: a failed instance leg on a stranded box reds by
# its own verdict at ANY strand age — young, old, or not supplied at all.
run_d "D4a instance FAILED, 59 min -> RED by the failed-attempt arm" 1 "$TMP/sibling" \
  "TRIED AND THE SHA DID NOT MOVE" -- \
  --stranded true --instance-state stranded --instance-result failure "${AT59[@]}"
run_d "D4b instance FAILED, no strand age at all -> RED by the failed-attempt arm" 1 "$TMP/sibling" \
  "TRIED AND THE SHA DID NOT MOVE" -- \
  --stranded true --instance-state stranded --instance-result failure

# D5 CANNOT READ — fails CLOSED with its own exit code (3), never "age 0".
run_d "D5a no --strand-since, sibling queued -> CANNOT READ" 3 "$TMP/sibling" "VERDICT: CANNOT READ" -- \
  --stranded true --instance-state stranded --instance-result skipped --now "$NOW"
# "yesterday" is the GNU-date trap: `date -d yesterday` PARSES, so without a
# shape check it would become a plausible age on the CI runner.
for junk in yesterday not-a-date 2026-09-22; do
  run_d "D5b unparseable --strand-since '$junk' -> CANNOT READ" 3 "$TMP/sibling" "VERDICT: CANNOT READ" -- \
    --stranded true --instance-state stranded --instance-result skipped --now "$NOW" --strand-since "$junk"
done
run_d "D5c strand start in the FUTURE -> CANNOT READ" 3 "$TMP/sibling" "VERDICT: CANNOT READ" -- \
  --stranded true --instance-state stranded --instance-result skipped --now "$NOW" --strand-since 2026-09-22T14:00:00Z
run_d "D5d unparseable --now -> CANNOT READ" 3 "$TMP/sibling" "VERDICT: CANNOT READ" -- \
  --stranded true --instance-state stranded --instance-result skipped --now never --strand-since 2026-09-22T12:01:00Z
run_d "D5e lookup failed AND no strand age -> CANNOT READ" 3 "$TMP/none" "VERDICT: CANNOT READ" -- \
  --stranded true --in-flight-source unknown --now "$NOW"

# The lock wait itself unreadable: fixture trees shaped like the repo
# (.github/workflows/deploy.yml + deploy/<x>-deploy.sh).
fx() { # dir yml-scp-line script-body
  mkdir -p "$1/.github/workflows" "$1/deploy"
  printf 'jobs:\n  instance:\n    steps:\n      - run: |\n          %s\n' "$2" > "$1/.github/workflows/deploy.yml"
  [ -z "$3" ] || printf '%s\n' "$3" > "$1/deploy/x-deploy.sh"
}
fx "$TMP/fx-noscp" 'echo nothing shipped' ''
fx "$TMP/fx-nocall" '$SCP deploy/x-deploy.sh root@h:/tmp/x.sh' 'flock -w 1800 9'
fx "$TMP/fx-var" '$SCP deploy/x-deploy.sh root@h:/tmp/x.sh' "$(printf 'budget="$(cat /etc/budget)"\nqueue_for_deploy_lock "$budget"')"
fx "$TMP/fx-missing" '$SCP deploy/gone-deploy.sh root@h:/tmp/x.sh' ''
fx "$TMP/fx-900" '$SCP deploy/x-deploy.sh root@h:/tmp/x.sh' "$(printf 'b="${LOCK_SECS:-900}"\nqueue_for_deploy_lock "$b"')"
for f in noscp nocall var missing; do
  run_d "D5f lock wait unreadable ($f) -> CANNOT READ" 3 "$TMP/sibling" "VERDICT: CANNOT READ" -- \
    --stranded true --instance-state stranded --instance-result skipped "${AT59[@]}" \
    --deploy-yml "$TMP/fx-$f/.github/workflows/deploy.yml"
done

# D6 THE BOUND IS NOT A CONSTANT: a repo whose lock budget is 900 s stalls at
# 30 min, so the same 59-min strand that is green above reds here.
run_d "D6 lock budget 900s -> bound 30 min -> 59 min is STALLED" 1 "$TMP/sibling" \
  "VERDICT: STALLED" "30 min = 2 x the 900s deploy lock wait" -- \
  --stranded true --instance-state stranded --instance-result skipped "${AT59[@]}" \
  --deploy-yml "$TMP/fx-900/.github/workflows/deploy.yml"

# D7 the withheld-conclusion arm expires on the same bound.
run_d "D7a lookup failed, 59 min -> withheld (GREEN-BECAUSE-WAITING)" 0 "$TMP/none" "GREEN-BECAUSE-WAITING" -- \
  --stranded true --in-flight-source unknown "${AT59[@]}"
run_d "D7b lookup failed, 61 min -> STALLED" 1 "$TMP/none" "VERDICT: STALLED" -- \
  --stranded true --in-flight-source unknown "${AT61[@]}"

# D8 nothing in flight needs no age: the red it always was.
run_d "D8 stranded, nothing in flight, no strand age -> RED as before" 1 "$TMP/none" \
  "STRANDED AND NOTHING IS COMING" -- --stranded true

# ── D9, THE MUTATION: prove D2 can actually lose ───────────────────────────
# Excise the expiry block from a copy beside the subject and re-run D2's exact
# invocation: it must fall back to the unbounded suppression and go GREEN —
# which IS the defect this row filed. Plant verified before the verdict is read.
mut2="$REPO_ROOT/scripts/.mutant-strand-age-$$.sh"
trap 'rm -rf "$TMP"; rm -f "$mutsub" "$mut2"' EXIT
python3 - "$SUBJECT" "$mut2" <<'PYMUT2'
import sys
src = open(sys.argv[1]).read()
start = src.index('  # ── SUPPRESSION NEEDS AN EXPIRY')
end   = src.index('  if [ "$source" = "unknown" ]; then\n    say ""\n    say "VERDICT: STRANDED, and the in-flight', start)
open(sys.argv[2], "w").write(src[:start] + '  local mins="" bound_mins="" lock_secs=""\n' + src[end:])
PYMUT2
if grep -q 'VERDICT: STALLED' "$SUBJECT" && ! grep -q 'VERDICT: STALLED' "$mut2"; then
  ok "D9a PLANT VERIFIED: the STALLED arm is in the subject and absent from the mutant"
  m0=0; bash "$mut2" adjudicate --stranded false < "$TMP/none" >/dev/null 2>&1 || m0=$?
  if [ "$m0" -eq 0 ]; then ok "D9b the mutant loads and adjudicates (rc=0 on a trivially-green input)"
  else bad "D9b the mutant does not RUN (rc=$m0) — D9c would measure a load error"; fi
  m1=0; bash "$mut2" adjudicate --stranded true --in-flight-source ok --instance-state stranded \
    --instance-result skipped "${AT61[@]}" < "$TMP/sibling" >/dev/null 2>&1 || m1=$?
  if [ "$m1" -eq 0 ]; then ok "D9c the mutant REPRODUCES the unbounded green at 61 min (rc=0) — D2 is not vacuous"
  else bad "D9c the mutant still reds at 61 min (rc=$m1); D2 cannot be shown to discriminate"; fi
else
  bad "D9a the plant failed — D9c would measure nothing"
fi

echo ""
echo "PART B — the workflow actually wires the conclusion to the job status"

BODY="$TMP/check-step.sh"
python3 - "$WORKFLOW" "$BODY" <<'PY' || { echo "HARNESS-UNAVAILABLE: could not extract the check step" >&2; exit 2; }
import sys, yaml
wf, out = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(wf))
job = d["jobs"]["convergence"]
step = [s for s in job["steps"] if s.get("id") == "check"]
if len(step) != 1:
    sys.exit("expected exactly one step with id 'check', found %d" % len(step))
open(out, "w").write(step[0]["run"])
PY

body="$(cat "$BODY")"

b_has() { # name needle
  case "$body" in *"$2"*) ok "$1" ;; *) bad "$1 — '$2' is absent from the check step" ;; esac
}
b_has "B1 the step calls the adjudicator"            "deploy-convergence-check.sh adjudicate"
b_has "B2 it passes the strand verdict"              "--stranded"
b_has "B3 it passes the in-flight source"            "--in-flight-source"
b_has "B4 it captures rc rather than dropping it"    "verdict_rc"
b_has "B5 it still emits converged= for the reporter" "converged=\${converged}"
# ── B9..B12, task-c5955c660c7b9e55 ─────────────────────────────────────────
# The adjudicator can only tell a failed ATTEMPT from a run that was never going
# to move the box if the WORKFLOW hands it those facts. A green Part C over a
# step that passes neither flag is a green with no subject.
b_has "B9 it passes this run's instance leg result"  "--instance-result"
b_has "B10 it passes the instance leg's read state"  "--instance-state"
b_has "B11 it names both shas for the red"           "--instance-served"
b_has "B12 it records the leg's read state as a fact" "inst_state="
# ── B14..B17, task-a077f2e24350d3af ────────────────────────────────────────
# Part D is only a verdict on production if the workflow PRODUCES the strand
# start and hands it over; a D-green over a step that passes no --strand-since
# is CANNOT READ on every strand, not a fix.
b_has "B14 each converged leg emits its strand record" "--emit-strand"
b_has "B15 it passes the strand start to the adjudicator" "--strand-since"
b_has "B16 it names served + newest for the STALLED red"  "--strand-newest"
b_has "B17 it names CANNOT READ (rc 3) as its own error"  '"$verdict_rc" -eq 3'

# B13: the job must NOT gate itself on a leg having SUCCEEDED. That precondition
# skipped the whole check when both deploy legs failed — a false green traded
# for a silent one, which the row names as a wrong fix. It must still exclude the
# SUPERSEDED shape (both legs skipped), which is deploy-supersede-exit.test.sh's
# B7 and is asserted there; this arm only guards the direction that row owns.
cguard="$(python3 - "$WORKFLOW" <<'PYC'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print(" ".join(str(d["jobs"]["convergence"]["if"]).split()))
PYC
)"
case "$cguard" in
  *"needs.control-plane.result == 'success'"*|*"needs.instance.result == 'success'"*)
    bad "B13 convergence still skips itself unless a leg succeeded: $cguard" ;;
  *"always()"*) ok "B13 convergence no longer requires a leg to have SUCCEEDED: $cguard" ;;
  *) bad "B13 convergence's if: no longer starts from always(): $cguard" ;;
esac

# ── B6, THE REGRESSION ITSELF ──────────────────────────────────────────────
# The pre-fix step ended `exit 0` on its own line, unconditionally. If that ever
# comes back, every assertion above still passes — the adjudicator would run and
# its rc would be thrown away one line later. So assert on the LAST executable
# statement, which is the only thing that decides a job's conclusion.
last="$(printf '%s\n' "$body" | sed 's/#.*$//' | grep -v '^[[:space:]]*$' | tail -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
case "$last" in
  'exit "$verdict_rc"') ok "B6 the step's last statement exits the adjudicated rc ($last)" ;;
  'exit 0')             bad "B6 the step ends in an unconditional 'exit 0' — the verdict is discarded again" ;;
  *)                    bad "B6 the step's last statement is '$last', which does not exit the adjudicated rc" ;;
esac

# The mutation this harness is built to catch, run for real: replace the exit
# with the pre-fix `exit 0` and prove B6 turns red. A guard that is never shown
# losing is a guard nobody knows still works.
mut="$TMP/mutant.sh"
sed 's/^\([[:space:]]*\)exit "\$verdict_rc"$/\1exit 0/' "$BODY" > "$mut"
if ! cmp -s "$BODY" "$mut"; then
  mlast="$(sed 's/#.*$//' "$mut" | grep -v '^[[:space:]]*$' | tail -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ "$mlast" = "exit 0" ]; then
    ok "B7 the pre-fix mutant ('exit 0') is what B6 rejects — B6 is not vacuous"
  else
    bad "B7 the mutant's last statement read '$mlast'; B6 cannot be shown to discriminate"
  fi
else
  bad "B7 the mutation changed nothing — B6 is anchored on text the step no longer contains"
fi

# report-convergence-failure must still fire on a RED convergence job, not only
# on the output. Otherwise the new exit code would REPLACE the issue instead of
# joining it, and a strand would go from silent-green to red-with-no-record.
guard="$(python3 - "$WORKFLOW" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print(" ".join(str(d["jobs"]["report-convergence-failure"]["if"]).split()))
PY
)"
case "$guard" in
  *"needs.convergence.result == 'failure'"*) ok "B8 the reporter still fires when convergence FAILS" ;;
  *) bad "B8 the reporter's if: no longer covers a failed convergence job: $guard" ;;
esac

echo ""
printf 'deploy-convergence-check.test.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$PASS" -eq 0 ]; then
  echo "HARNESS-UNAVAILABLE: zero cases ran — a green over an empty matrix is not a verdict" >&2
  exit 2
fi
[ "$FAIL" -eq 0 ] || exit 1
