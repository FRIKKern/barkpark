#!/usr/bin/env bash
# dependabot-task-trailer.test.sh — hermetic harness for the bot path through
# the task gate (task-361f1ad90eb1b46e). No network, no ledger, no gh.
#
# FOUR SECTIONS, and §3 is the one the task row calls non-negotiable:
#   §1  the injector's own arms: append / already-stamped / human / bad ref /
#       missing env, plus end-to-end idempotence (run it on its own output).
#   §2  MUTATION PROOF of the author clause: a copy of the script with the
#       actor check gutted hands a HUMAN PR the standing trailer, and §2 reds
#       on that mutant. A guard nobody proved can fail is not a guard.
#   §3  THE POSITIVE CONTROL. The required gate `PR references an active task`
#       STILL REFUSES a human-authored PR body with no `Task:` trailer. This
#       runs the REAL scripts/pr-task-gate.sh, unmodified, through the same two
#       calls the workflow makes (--extract-task-id, then the decision), and
#       asserts a definitive FAIL. A fix that exempts everyone is worse than the
#       cost it removes; without this the change is not acceptable.
#   §4  grammar agreement: what the injector WRITES is what the gate READS.
#
# EXIT: 0 all passed · 1 at least one failed (each named) · 2 CANNOT MEASURE.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INJECTOR="$HERE/dependabot-task-trailer.sh"
GATE="$HERE/pr-task-gate.sh"
STANDING="task-3e5d6364196a7cda"

for f in "$INJECTOR" "$GATE"; do
  if [ ! -f "$f" ]; then
    echo "dependabot-task-trailer.test: CANNOT MEASURE — $f is absent, so nothing was tested (rc 2)" >&2
    exit 2
  fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n     %s\n' "$1" "${2:-}"; }

# run <script> <actor> <head_ref> <body> -> sets RC and OUT
run() {
  local script="$1" actor="$2" ref="$3" body="$4"
  OUT="$(ACTOR="$actor" HEAD_REF="$ref" PR_BODY="$body" bash "$script" 2>"$TMP/err")"
  RC=$?
  ERR="$(cat "$TMP/err")"
}

DEPBODY='Bumps [foo](https://example.invalid) from 1.0.0 to 1.0.1.
<details><summary>Release notes</summary></details>

Dependabot will resolve any conflicts.'

echo "── §1 the injector's arms ──────────────────────────────────────────────"

run "$INJECTOR" "dependabot[bot]" "dependabot/npm_and_yarn/foo-1.0.1" "$DEPBODY"
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qxF "Task: ${STANDING}"; then
  ok "dependabot actor + dependabot/ ref -> rc 0 and the standing trailer at column 0"
else
  bad "dependabot PR should be stamped" "rc=$RC out=<<$OUT>>"
fi

# THE PRESERVATION ARM: stamping must not eat the bot's own body. A trailer
# appended by deleting the release notes would pass the arm above.
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qF 'Bumps [foo]'; then
  ok "the original body survives the append (nothing is replaced)"
else
  bad "the append destroyed the original body" "out=<<$OUT>>"
fi

# IDEMPOTENCE, end to end: feed the stamped body back in.
STAMPED="$OUT"
run "$INJECTOR" "dependabot[bot]" "dependabot/npm_and_yarn/foo-1.0.1" "$STAMPED"
if [ "$RC" = 4 ] && [ -z "$OUT" ]; then
  ok "a second run on its own output -> rc 4, nothing emitted (idempotent)"
else
  bad "second run was not a no-op" "rc=$RC out=<<$OUT>>"
fi

# A DIFFERENT id already present must also stop the append: the gate REFUSES a
# body carrying two DISTINCT ids (pr-task-gate.sh --extract-task-id exit 4), so
# a second trailer would turn a green PR red.
run "$INJECTOR" "dependabot[bot]" "dependabot/hex/bar-2" "some text
Task: task-someone-elses-row"
if [ "$RC" = 4 ]; then
  ok "a body already naming a DIFFERENT task -> rc 4 (never two distinct ids)"
else
  bad "a foreign trailer did not stop the append" "rc=$RC out=<<$OUT>>"
fi

# THE HUMAN ARM — the subject of §2's mutation and of §3's control.
run "$INJECTOR" "some-human" "feature/whatever" "a human PR with no trailer"
if [ "$RC" = 3 ] && [ -z "$OUT" ]; then
  ok "human actor -> rc 3, body untouched"
else
  bad "a human PR was touched" "rc=$RC out=<<$OUT>>"
fi

# BOTH halves of the author clause are load-bearing, so each is tested alone.
run "$INJECTOR" "some-human" "dependabot/npm_and_yarn/foo-1.0.1" "x"
if [ "$RC" = 3 ]; then
  ok "human actor on a dependabot/-NAMED branch -> rc 3 (branch name is not authority)"
else
  bad "a human could self-serve the trailer by naming their branch dependabot/" "rc=$RC"
fi

run "$INJECTOR" "dependabot[bot]" "feature/not-a-bump" "x"
if [ "$RC" = 3 ]; then
  ok "dependabot actor on a non-dependabot/ ref -> rc 3"
else
  bad "the head-ref half of the author clause did not hold" "rc=$RC"
fi

# CANNOT MEASURE beats a quiet no-op: an empty ACTOR must not read as "a human".
OUT="$(ACTOR="" HEAD_REF="dependabot/x" PR_BODY="x" bash "$INJECTOR" 2>"$TMP/err")"; RC=$?
if [ "$RC" = 2 ] && grep -qF 'CANNOT MEASURE' "$TMP/err"; then
  ok "empty ACTOR -> rc 2 CANNOT MEASURE (never a silent no-op)"
else
  bad "an unreadable actor did not fail loudly" "rc=$RC err=$(cat "$TMP/err")"
fi

OUT="$(ACTOR="dependabot[bot]" HEAD_REF="" PR_BODY="x" bash "$INJECTOR" 2>"$TMP/err")"; RC=$?
if [ "$RC" = 2 ] && grep -qF 'CANNOT MEASURE' "$TMP/err"; then
  ok "empty HEAD_REF -> rc 2 CANNOT MEASURE"
else
  bad "an unreadable head ref did not fail loudly" "rc=$RC err=$(cat "$TMP/err")"
fi

echo "── §2 MUTATION: gut the author clause, the human arm must red ──────────"

MUT="$TMP/mutant.sh"
sed 's/^if \[ "\$ACTOR" != "dependabot\[bot\]" \]; then$/if false; then/' "$INJECTOR" > "$MUT"
if ! grep -qF 'if false; then' "$MUT"; then
  bad "MUTATION DID NOT APPLY" "the actor clause was not found in $INJECTOR — this section measured NOTHING"
else
  # ASSERT THE MUTANT REACHED THE STATE THE MUTATION IS SUPPOSED TO BREAK: it
  # must still stamp a genuine dependabot PR. A mutant that is broken outright
  # would "pass" the detector below for the wrong reason (a vacuous green).
  run "$MUT" "dependabot[bot]" "dependabot/hex/x-1" "$DEPBODY"
  if [ "$RC" = 0 ]; then
    ok "the mutant is alive (it still stamps a real dependabot PR)"
  else
    bad "the mutant is broken, so §2 measured nothing" "rc=$RC err=$ERR"
  fi
  # THE DETECTOR. Same human fixture as §1: on the mutant it MUST be stamped.
  run "$MUT" "some-human" "dependabot/hex/x-1" "a human PR with no trailer"
  if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -qxF "Task: ${STANDING}"; then
    ok "DETECTOR FIRES: without the actor clause a human PR is handed the trailer"
  else
    bad "the actor clause is UNPROVEN — removing it changed nothing" "rc=$RC out=<<$OUT>>"
  fi
  # And the restore: the real script leaves that same fixture alone.
  run "$INJECTOR" "some-human" "dependabot/hex/x-1" "a human PR with no trailer"
  if [ "$RC" = 3 ]; then
    ok "RESTORE: the shipped script refuses the same fixture (rc 3)"
  else
    bad "restore arm did not hold" "rc=$RC"
  fi
fi

echo "── §3 POSITIVE CONTROL: the gate still REFUSES a human PR with no trailer ──"

# Call 1, exactly as .github/workflows/pr-task-gate.yml does it: extract the id.
HUMAN_BODY='Refactors the widget cache. See the discussion for context.
Nothing here is a Task: trailer because it is not at column 0 — see Task: nope.'
ID="$(PR_BODY="$HUMAN_BODY" bash "$GATE" --extract-task-id 2>"$TMP/err")"; RC=$?
if [ "$RC" = 0 ] && [ -z "$ID" ]; then
  ok "control step 1: a human body with no column-0 trailer yields NO task id"
else
  bad "control step 1: the extractor found an id where there is none" "rc=$RC id='$ID'"
fi

# Call 2: the decision the workflow then makes with that empty id. A DEFINITIVE
# FAIL (exit 1) is required — not exit 2 (ledger unreachable), which would mean
# the refusal came from an outage rather than from the rule.
OUT="$(TASK_ID="$ID" PR_OPENED_AT="2026-09-09T00:00:00Z" LEDGER_BASE="http://127.0.0.1:9" bash "$GATE" 2>&1)"; RC=$?
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -qF 'no task reference found on the PR'; then
  ok "control step 2: the gate REFUSES it, definitively (exit 1, 'no task reference found')"
else
  bad "THE GATE NO LONGER REFUSES A HUMAN PR WITH NO TRAILER" "rc=$RC out=<<$OUT>>"
fi

# THE OTHER HALF OF THE CONTROL, so the arm above cannot pass vacuously: the
# same gate, same offline ledger, WITH a trailer must NOT return that verdict.
# It cannot reach the ledger here, so it exits 2 (UNCHECKED) — which is still
# not a pass, and is a DIFFERENT refusal from the one above. If both arms
# produced the same verdict, neither would be discriminating.
OUT="$(TASK_ID="$STANDING" PR_OPENED_AT="2026-09-09T00:00:00Z" PR_TASK_GATE_RETRIES=1 PR_TASK_GATE_RETRY_DELAY=0 LEDGER_BASE="http://127.0.0.1:9" bash "$GATE" 2>&1)"; RC=$?
if [ "$RC" != 1 ] && ! printf '%s' "$OUT" | grep -qF 'no task reference found on the PR'; then
  ok "control is discriminating: a body WITH a trailer does not produce the no-reference refusal (rc $RC)"
else
  bad "the no-reference refusal fires regardless of the body — it discriminates nothing" "rc=$RC out=<<$OUT>>"
fi

echo "── §4 the injector writes what the gate reads ──────────────────────────"

ID="$(PR_BODY="$STAMPED" bash "$GATE" --extract-task-id 2>"$TMP/err")"; RC=$?
if [ "$RC" = 0 ] && [ "$ID" = "$STANDING" ]; then
  ok "the gate's own extractor reads the injected trailer as '$STANDING'"
else
  bad "GRAMMAR DISAGREEMENT: the gate cannot read what the injector writes" "rc=$RC id='$ID'"
fi

# The workflow's job-level `if:` must agree with the script's clause, or the
# cheap filter and the guard disagree about who is a bot.
WF="$HERE/../.github/workflows/dependabot-task-trailer.yml"
if [ -f "$WF" ]; then
  if grep -qF "github.actor == 'dependabot[bot]'" "$WF" \
     && grep -qF "startsWith(github.event.pull_request.head.ref, 'dependabot/')" "$WF"; then
    ok "the workflow's job-level if: carries both halves of the author clause"
  else
    bad "the workflow's if: does not match the script's author clause" "$WF"
  fi
  if grep -qE '^\s*ref:' "$WF"; then
    bad "the workflow checks out an explicit ref under pull_request_target" "a ref: override here executes PR code with a write token — remove it"
  else
    ok "no ref: override — pull_request_target checks out the base, never PR code"
  fi
else
  bad "the workflow is absent" "$WF"
fi

echo
echo "dependabot-task-trailer.test: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" = 0 ] || exit 1
[ "$PASS" -gt 0 ] || { echo "CANNOT MEASURE: zero assertions ran (rc 2)" >&2; exit 2; }
exit 0
