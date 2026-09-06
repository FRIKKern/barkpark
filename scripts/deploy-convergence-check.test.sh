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

echo "PART A — adjudicate decides the conclusion"
expect_rc "A1 not stranded, nothing running          -> GREEN"  0 "$TMP/none"     --stranded false
expect_rc "A2 not stranded, a deploy running         -> GREEN"  0 "$TMP/queued"   --stranded false
# ── THE ROW'S TWO DIRECTIONS ────────────────────────────────────────────────
expect_rc "A3 STRANDED, nothing in flight            -> RED"    1 "$TMP/none"     --stranded true
expect_rc "A4 STRANDED, a queued deploy              -> GREEN"  0 "$TMP/queued"   --stranded true
expect_rc "A5 STRANDED, an in_progress deploy        -> GREEN"  0 "$TMP/running"  --stranded true
# A terminal run explains nothing: it already had its turn and the box is still
# behind. Folding `completed` into "in flight" is how this gate would be waived
# by its own history.
expect_rc "A6 STRANDED, only a COMPLETED run         -> RED"    1 "$TMP/terminal" --stranded true
expect_rc "A7 STRANDED, one terminal + one queued    -> GREEN"  0 "$TMP/mixed"    --stranded true
# UNCHECKED is an absence of evidence, never a finding — it must not red on its
# own, or an unreadable /health becomes an outage report.
expect_rc "A8 not stranded but a leg was UNCHECKED   -> GREEN"  0 "$TMP/none"     --stranded false --unchecked true
# "I could not look" withholds the CONCLUSION, not the finding.
expect_rc "A9 STRANDED, in-flight lookup failed      -> GREEN"  0 "$TMP/none"     --stranded true --in-flight-source unknown
# A missing or malformed verdict must REFUSE. Defaulting it to false is exactly
# the shape this row is about: a gate greening on its own breakage.
expect_rc "A10 no --stranded at all                  -> REFUSE" 2 "$TMP/none"
expect_rc "A11 --stranded 'maybe'                    -> REFUSE" 2 "$TMP/none"     --stranded maybe
expect_rc "A12 an unknown argument                   -> REFUSE" 2 "$TMP/none"     --stranded true --bogus x

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
