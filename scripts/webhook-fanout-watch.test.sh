#!/usr/bin/env bash
# webhook-fanout-watch.test.sh — the mutation proofs for the live-row guard.
#
# Nothing here asserts "the script ran". Every case MUTATES the world into a
# shape that must produce a specific one of the four verdicts, and the verdict is
# read from the EXIT CODE — the thing CI actually consumes — not from a string in
# the log. The fixtures are the shapes `bp cloud webhook list … -o json` really
# emits, plus the failure bodies a refused or blipped read really emits.
#
# Fully hermetic: no network, no `bp`, no writes outside a temp dir.
#
#   scripts/webhook-fanout-watch.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WATCH="$REPO_ROOT/scripts/webhook-fanout-watch.sh"
WF="$REPO_ROOT/.github/workflows/shell-harnesses.yml"
ESCAPE="$REPO_ROOT/scripts/cloud-path-escape-check.sh"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*" >&2; }
section() { echo; echo "── $* ──"; }

# run <fixture-file> [env-assignments…] → sets RC and OUT
run() {
  local f="$1"; shift
  OUT="$(env "$@" bash "$WATCH" --rows-file "$f" 2>&1)"
  RC=$?
}

expect_rc() { # want, label
  local want="$1" label="$2"
  if [ "$RC" = "$want" ]; then
    ok "$label → exit $RC"
  else
    bad "$label → expected exit $want, got $RC"
    printf '%s\n' "$OUT" | sed 's/^/       | /' >&2
  fi
}

row() { # name, dataset, types-json
  printf '{"name":"%s","dataset":"%s","url":"https://x/y","types":%s}' "$1" "$2" "$3"
}

# ═══ FIXTURES ════════════════════════════════════════════════════════════════
# The green world: five site-autodeploy rows on one dataset, every one filtered
# to {paper} — i.e. the state the 2026-08-07 03:43Z repair actually left behind.
{
  printf '{"webhooks":['
  printf '%s,' "$(row site-autodeploy-alpha production '["paper"]')"
  printf '%s,' "$(row site-autodeploy-bravo production '["paper"]')"
  printf '%s,' "$(row site-autodeploy-charlie production '["paper"]')"
  printf '%s,' "$(row site-autodeploy-delta production '["paper"]')"
  printf '%s'  "$(row site-autodeploy-echo production '["paper"]')"
  printf ']}'
} > "$TMP/five-typed.json"

# One row re-armed to match everything (types: []) — the exact regression.
sed 's/"name":"site-autodeploy-charlie","dataset":"production","url":"https:\/\/x\/y","types":\["paper"\]/"name":"site-autodeploy-charlie","dataset":"production","url":"https:\/\/x\/y","types":[]/' \
  "$TMP/five-typed.json" > "$TMP/one-open.json"

# Same regression via the OTHER fail-open door: the key is absent entirely.
{
  printf '{"webhooks":['
  printf '%s,' "$(row site-autodeploy-alpha production '["paper"]')"
  printf '{"name":"site-autodeploy-bravo","dataset":"production","url":"https://x/y"}'
  printf ']}'
} > "$TMP/missing-key.json"

# No site-autodeploy rows at all (other webhooks exist, one of them wide open —
# it must NOT be judged: this guard owns site-autodeploy-* and nothing else).
{
  printf '{"webhooks":['
  printf '%s,' "$(row customer-hook production '[]')"
  printf '%s'  "$(row analytics-hook staging '["post"]')"
  printf ']}'
} > "$TMP/empty-population.json"

# Two well-typed rows — green at the default floor, RED at the pinned floor 5.
{
  printf '{"webhooks":['
  printf '%s,' "$(row site-autodeploy-alpha production '["paper"]')"
  printf '%s'  "$(row site-autodeploy-bravo production '["paper"]')"
  printf ']}'
} > "$TMP/two-typed.json"

# A refused read: the body `bp` hands back when the session is gone.
printf 'HTTP 403: Resource not accessible — not logged in (run `bp login`)\n' > "$TMP/refused.json"
# A transport blip: clears on its own, must be UNKNOWN and never green.
printf 'error: HTTP 502 Bad Gateway from control plane\n' > "$TMP/blip.json"
# Unparseable: half a payload (a truncated pipe, a proxy error page).
printf '{"webhooks":[{"name":"site-autodeploy-alpha",\n' > "$TMP/garbage.json"
# Parses, but is not a webhook payload at all.
printf '{"instances":[{"id":"guerrilla"}]}\n' > "$TMP/wrong-shape.json"

# ═══ 1. THE SIX REQUIRED MUTATION CASES ══════════════════════════════════════
section "the six required mutation cases"

run "$TMP/five-typed.json" WEBHOOK_FANOUT_EXPECT_MIN=5
expect_rc 0 "five rows, all {paper}, floor 5"

run "$TMP/one-open.json" WEBHOOK_FANOUT_EXPECT_MIN=5
expect_rc 1 "one row mutated to types:[] (matches everything)"

run "$TMP/empty-population.json" WEBHOOK_FANOUT_EXPECT_MIN=1
expect_rc 1 "empty population (vacuous green refused)"

run "$TMP/refused.json" WEBHOOK_FANOUT_EXPECT_MIN=5
expect_rc 3 "refused read (401/403) is a CONFIGURATION FAULT, not a blip"

run "$TMP/garbage.json" WEBHOOK_FANOUT_EXPECT_MIN=5
expect_rc 3 "unparseable input"

run "$TMP/two-typed.json" WEBHOOK_FANOUT_EXPECT_MIN=5
expect_rc 1 "pinned floor 5 against 2 well-typed rows"

# ═══ 2. THE VERDICT IS THE MUTATION'S, NOT THE FIXTURE'S ═════════════════════
# Proves case 2 and case 6 red for DIFFERENT reasons, and that each fixture is
# green under the condition it does satisfy — otherwise "red" could be an
# artefact of the fixture rather than of the mutation.
section "each red names its own cause"

run "$TMP/two-typed.json" WEBHOOK_FANOUT_EXPECT_MIN=2
expect_rc 0 "the same 2 rows are GREEN at floor 2 — the floor is what reds them"

grep -q "BELOW the pinned floor" <<<"$OUT" && bad "floor message leaked into a green run" || ok "green run carries no floor complaint"

run "$TMP/one-open.json" WEBHOOK_FANOUT_EXPECT_MIN=1
expect_rc 1 "the offender reds even at floor 1 — the offender is what reds it"
grep -q "site-autodeploy-charlie" <<<"$OUT" && ok "the offending row is NAMED in the output" || bad "offender not named"

run "$TMP/missing-key.json" WEBHOOK_FANOUT_EXPECT_MIN=2
expect_rc 1 "an ABSENT types key is the same fail-open as an empty one"
grep -q "site-autodeploy-bravo" <<<"$OUT" && ok "the absent-key row is named" || bad "absent-key row not named"

run "$TMP/empty-population.json" WEBHOOK_FANOUT_EXPECT_MIN=0
expect_rc 0 "a wide-open NON-site-autodeploy row is not judged (scope stays boolean and narrow)"

# ═══ 3. THE FOUR-VALUED EXIT CONTRACT ════════════════════════════════════════
section "four-valued exit contract"

run "$TMP/blip.json" WEBHOOK_FANOUT_EXPECT_MIN=5
expect_rc 2 "a 502 is UNKNOWN (2), never green and never a hard red"
grep -q "NOT a green" <<<"$OUT" && ok "the UNKNOWN says out loud that it is not a pass" || bad "UNKNOWN reads like a pass"

run "$TMP/wrong-shape.json" WEBHOOK_FANOUT_EXPECT_MIN=5
expect_rc 3 "valid JSON of an unknown shape is a FAULT, not an empty population"

OUT="$(bash "$WATCH" --rows-file "$TMP/does-not-exist.json" 2>&1)"; RC=$?
expect_rc 3 "a missing rows file has read nothing → fault"

OUT="$(bash "$WATCH" 2>&1)"; RC=$?
expect_rc 3 "no --rows-file at all → fault (never a green default)"

OUT="$(bash "$WATCH" --nonsense 2>&1)"; RC=$?
expect_rc 3 "an unknown argument → fault"

OUT="$(printf '%s' "$(cat "$TMP/five-typed.json")" | env WEBHOOK_FANOUT_EXPECT_MIN=5 bash "$WATCH" --rows-file - 2>&1)"; RC=$?
expect_rc 0 "stdin (--rows-file -) is the runbook's one-pipe form"

# Every observed code must be one of the four. An undefined code is red by the
# dispatcher at the foot of the script; assert that dispatcher exists rather than
# only trusting it.
grep -q "undefined exit code" "$WATCH" \
  && ok "an undefined exit code is explicitly mapped to RED" \
  || bad "no undefined-exit-code guard in the script"

# ═══ 4. THE METER IS PRINTED, AND JUDGES NOTHING ═════════════════════════════
section "fan-out is metered, never judged"

run "$TMP/five-typed.json" WEBHOOK_FANOUT_EXPECT_MIN=5
grep -q "FAN-OUT (metered, not judged): dataset=production doc_type=paper rows=5" <<<"$OUT" \
  && ok "the meter line is printed with the real dataset/doc_type/rows" \
  || { bad "meter line missing or malformed"; printf '%s\n' "$OUT" | sed 's/^/       | /' >&2; }

# THE LOAD-BEARING ONE: rows=5 on one dataset is EXACTLY the shape a
# 'count > 1' verdict would red, and it is green. D206 rules that population the
# current state; D228(f) rules that cutting it needs a fresh argument. A guard
# that reds on ground truth gets disabled in a week.
[ "$RC" = "0" ] && ok "rows=5 on ONE dataset is GREEN — no verdict is derived from the meter" || bad "the meter judged: rows>1 turned the verdict red"

run "$TMP/one-open.json" WEBHOOK_FANOUT_EXPECT_MIN=5
grep -q "MATCHES EVERYTHING" <<<"$OUT" \
  && ok "a wide-open row is visible in the meter as well as the verdict" \
  || bad "the meter hid the wide-open row"

run "$TMP/empty-population.json" WEBHOOK_FANOUT_EXPECT_MIN=1
grep -q "rows=0" <<<"$OUT" && ok "the meter still prints on a red (rows=0)" || bad "meter silent on the empty-population red"

# ═══ 5. THE GUARD CANNOT BE LAUNDERED ════════════════════════════════════════
section "the reporting can lose"

# Comment lines are STRIPPED before the search: both files discuss
# continue-on-error at length as the thing they refuse to do, and an assertion
# that cannot tell a prohibition from a use would force the reason to go
# unwritten — which is how the next author reintroduces it.
uncommented() { grep -vE '^[[:space:]]*#' "$1"; }

uncommented "$WATCH" | grep -qi "continue-on-error" \
  && bad "continue-on-error used as a mechanism in the script" \
  || ok "no continue-on-error in the script (only the written-down reason it is refused)"

if [ -f "$WF" ]; then
  if uncommented "$WF" | grep -q "continue-on-error"; then
    bad "shell-harnesses.yml carries a continue-on-error (a red would launder to a green job)"
  else
    ok "shell-harnesses.yml carries no continue-on-error"
  fi
  grep -q "scripts/webhook-fanout-watch.sh" "$WF" \
    && ok "the workflow lists webhook-fanout-watch.sh by EXPLICIT path (D26: an unlisted edit never triggers)" \
    || bad "webhook-fanout-watch.sh is not an explicit path entry in shell-harnesses.yml"
  grep -q "scripts/webhook-fanout-watch.test.sh" "$WF" \
    && ok "the workflow lists webhook-fanout-watch.test.sh by explicit path" \
    || bad "webhook-fanout-watch.test.sh is not an explicit path entry in shell-harnesses.yml"
  grep -q "bash scripts/webhook-fanout-watch.test.sh" "$WF" \
    && ok "the workflow actually RUNS this harness (a listed path with no run: is a green that never ran)" \
    || bad "shell-harnesses.yml never executes this harness"

  # MUTATION-PROVE THE LAUNDERING DETECTOR ITSELF. A comment-stripping check that
  # can no longer SEE a real continue-on-error is the same false green it exists
  # to prevent, so plant one in a copy and watch the detector fire.
  awk '{print} /run: bash scripts\/webhook-fanout-watch.test.sh/ {print "        continue-on-error: true"}' \
    "$WF" > "$TMP/laundered.yml"
  if uncommented "$TMP/laundered.yml" | grep -q "continue-on-error"; then
    ok "the detector FIRES on a planted continue-on-error (it can still lose)"
  else
    bad "the detector missed a planted continue-on-error — comment-stripping blinded it"
  fi
else
  bad "shell-harnesses.yml not found at $WF"
fi

# D329(b): this must not be a Cloud-suite tenant. Declaring it in CLOUD_PATHS
# would hand every edit the full Postgres-backed Cloud suite — and the
# internal/cli/** precedent (cloud-path-escape-check.sh:115-127) exists precisely
# so a guard cannot publish a GREEN required context on a PR where it never ran.
if [ -f "$ESCAPE" ]; then
  grep -q "webhook-fanout-watch" "$ESCAPE" \
    && bad "webhook-fanout-watch is declared in cloud-path-escape-check.sh (it must not be a Cloud tenant)" \
    || ok "not declared in CLOUD_PATHS — this is a shell-harnesses tenant, not a Cloud-suite one"
fi

# ═══ 6. THE HUMAN-MOVED FLOOR AND THE NAMED GATE ARE WRITTEN DOWN ════════════
section "the human-moved floor and the open human gate"

grep -q "WEBHOOK_FANOUT_EXPECT_MIN" "$WATCH" && ok "the floor is named in the script" || bad "floor not named"
grep -qi "human-moved" "$WATCH" && ok "the script states the floor is human-moved" || bad "script does not state the floor is human-moved"
grep -qi "no site-list verb" "$WATCH" && ok "the script states WHY it cannot derive the floor" || bad "script does not state why the floor cannot be derived"
grep -q "make cli-install" "$WATCH" && ok "the runbook opens with make cli-install" || bad "runbook does not open with make cli-install"
grep -qi "OPEN HUMAN GATE" "$WATCH" && ok "the missing control-plane credential is a NAMED open human gate" || bad "no named human gate"
grep -qi "regression watch" "$WATCH" && ok "the name-prefix residual is stated, not hidden" || bad "residual not stated"

# ═══ RESULT ══════════════════════════════════════════════════════════════════
echo
echo "══ $PASS passed, $FAIL failed ══"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
