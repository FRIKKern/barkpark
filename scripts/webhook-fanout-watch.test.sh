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

# A flag with no value used to HANG: `shift 2` on a one-element argv fails, does
# not shift, and the parse loop spins forever. A watch that never returns tells
# nobody anything — strictly worse than a red. Run it under a hard alarm so the
# regression re-appears as a FAILURE here rather than as a wedged CI job.
for flag in --rows-file --prefix --expect-min; do
  OUT="$(perl -e 'alarm 10; exec("bash", @ARGV)' "$WATCH" "$flag" 2>&1)"; RC=$?
  expect_rc 3 "$flag with no value → fault (and TERMINATES: 142 would mean it hung)"
done

# A non-numeric floor must not sail past the anti-vacuity check. `[ 0 -lt "" ]`
# makes `test` exit 2 with an error, and a bare `if` reads that as "floor met" —
# a green derived from a broken comparison.
OUT="$(env WEBHOOK_FANOUT_EXPECT_MIN=abc bash "$WATCH" --rows-file "$TMP/five-typed.json" 2>&1)"; RC=$?
expect_rc 3 "a non-numeric floor is a FAULT, never a silently-met floor"
OUT="$(bash "$WATCH" --expect-min "" --rows-file "$TMP/five-typed.json" 2>&1)"; RC=$?
expect_rc 3 "an EMPTY --expect-min is a FAULT too (the shape [ 5 -lt \"\" ] would have greened)"
# An empty ENV var is the one case that legitimately reads as "unset" (`:-`), so
# it falls back to the documented default of 1 instead of faulting. Pinned so the
# two paths cannot silently swap behaviours.
OUT="$(env WEBHOOK_FANOUT_EXPECT_MIN= bash "$WATCH" --rows-file "$TMP/five-typed.json" 2>&1)"; RC=$?
expect_rc 0 "an empty WEBHOOK_FANOUT_EXPECT_MIN means UNSET → the documented default floor of 1"
grep -q "floor 1 met" <<<"$OUT" && ok "…and the met floor is printed, so a near-vacuous green stays legible" || bad "the met floor is not printed"

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

# THE GROUP KEY MUST ACTUALLY SEPARATE. The meter groups on
# `.dataset + <sep> + .doc_type`, so a separator that is not there at RUNTIME
# silently merges distinct pairs whose concatenations collide — and prints the
# merged count under the FIRST member's labels, i.e. a wrong dataset and a wrong
# doc_type on a wrong number. The separator was written as a literal NUL byte
# inside the jq program, and bash DROPS a NUL while building an argv (a NUL
# cannot survive exec): jq received `.dataset + "" + .doc_type`, so there was no
# separator at all. This fixture is the shape that tells the two forms apart —
# ("ab","c") and ("a","bc") both concatenate to "abc" — and it goes RED on the
# raw-NUL form while the \u0000 escape keeps them two groups of one.
{
  printf '{"webhooks":['
  printf '%s,' "$(row site-autodeploy-collide-1 ab '["c"]')"
  printf '%s'  "$(row site-autodeploy-collide-2 a  '["bc"]')"
  printf ']}\n'
} >"$TMP/key-collision.json"

run "$TMP/key-collision.json" WEBHOOK_FANOUT_EXPECT_MIN=2
if grep -q "dataset=ab doc_type=c rows=1" <<<"$OUT" && grep -q "dataset=a doc_type=bc rows=1" <<<"$OUT"; then
  ok "the meter group key SEPARATES: (ab,c) and (a,bc) stay two rows of 1"
else
  bad "the meter merged two distinct dataset/doc_type pairs — the group-key separator never reached jq"
  printf '%s\n' "$OUT" | sed 's/^/       | /' >&2
fi

# ═══ 5. THE GUARD CANNOT BE LAUNDERED ════════════════════════════════════════
section "the reporting can lose"

# Comment lines are STRIPPED before the search: both files discuss
# continue-on-error at length as the thing they refuse to do, and an assertion
# that cannot tell a prohibition from a use would force the reason to go
# unwritten — which is how the next author reintroduces it.
#
# The stripped text is MATERIALISED before it is searched — honest-gates D37, as
# written at cloud-path-escape-check.test.sh:39. D37 exempts a match made
# straight against a FILE, and that exemption is what let this file keep the bug:
# `uncommented FILE | grep -q PAT` LOOKS like a file match but is a pipeline, and
# its producer is exactly the writer D37 says must not exist.
#
# The obvious spelling, `uncommented FILE | grep -q PAT`, is a race: `grep -q`
# exits at its FIRST match, closing the pipe while the stripping `grep -v` still
# has bytes to write, so the producer takes SIGPIPE (141) or EPIPE (2). Under the
# `set -o pipefail` at the top of this file the PIPELINE then reports that
# non-zero — so a SUCCESSFUL match is read by the caller as a failure. Whether
# the producer finishes first is pure scheduling, which is why it presented as a
# flake on a loaded runner (`grep: write error: Broken pipe`, then a bogus FAIL).
# The direction that flake took was the loud one. The same race in the two
# "there is no continue-on-error here" assertions below flips the other way: a
# file that really does carry one gets reported CLEAN, which is the exact false
# green this whole section exists to prevent. Command substitution has no reader
# to close early, and the status read below is then grep's own, not a pipeline's.
#
# `-a` is the second half of the fix and is NOT cosmetic. webhook-fanout-watch.sh
# USED TO carry a literal NUL byte — the `^@` separator inside the jq group_by
# near its meter — so grep classified it as BINARY and, instead of the ~6.4 kB of
# stripped text, emitted the one line `Binary file … matches`. Without -a the
# script-side assertion below therefore searched 38 bytes that can never contain
# the pattern: it was not flaky, it was UNCONDITIONALLY blind, and it printed its
# ok over a copy of the script with continue-on-error planted in it three times.
# The separator is a \u0000 escape today and the no-NUL invariant is asserted
# below, so `-a` is now a BELT, not the load-bearing half — it is kept because a
# predicate that only works while a file happens to be plain text is one byte
# away from going blind again.
uncommented() { grep -a -vE '^[[:space:]]*#' "$1"; }

# uncommented_has PATTERN FILE [extra grep flags…] → 0 iff the stripped file matches.
uncommented_has() {
  local pat="$1" file="$2"; shift 2
  local stripped; stripped="$(uncommented "$file")"
  grep -q -a "$@" -e "$pat" <<<"$stripped"
}

uncommented_has "continue-on-error" "$WATCH" -i \
  && bad "continue-on-error used as a mechanism in the script" \
  || ok "no continue-on-error in the script (only the written-down reason it is refused)"

if [ -f "$WF" ]; then
  if uncommented_has "continue-on-error" "$WF"; then
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
  if uncommented_has "continue-on-error" "$TMP/laundered.yml"; then
    ok "the detector FIRES on a planted continue-on-error (it can still lose)"
  else
    bad "the detector missed a planted continue-on-error — comment-stripping blinded it"
  fi

  # The SAME mutation, but padded past the pipe buffer. This is the shape that
  # made the arm above a coin flip: with `… | grep -q …` the stripping grep takes
  # SIGPIPE partway through the padding and pipefail reports the match as a
  # failure. The padding is what makes the race certain instead of scheduling-
  # dependent, so this case pins the fix rather than re-rolling the dice.
  { cat "$TMP/laundered.yml"; yes "        key: padding past the pipe buffer" | head -n 3000; } \
    > "$TMP/laundered-padded.yml"
  if uncommented_has "continue-on-error" "$TMP/laundered-padded.yml"; then
    ok "the detector still FIRES when the stripped text overruns the pipe buffer"
  else
    bad "the detector lost a planted continue-on-error to a SIGPIPE race (pipefail read the producer's 141 as 'no match')"
  fi

  # MUTATION-PROVE THE OTHER DIRECTION, which is the dangerous one. The two
  # assertions above that report "no continue-on-error here" would, if blinded,
  # print ok on a file that carries one — a false green indistinguishable from a
  # real pass. Plant one in a copy of the SCRIPT and require the same predicate
  # those assertions use to say so.
  # The fixture is built with cat, NOT with awk/sed, so it is a BYTE copy of
  # $WATCH plus the plant: whatever makes the real file hard to read is
  # reproduced here rather than filtered out on the way in.
  { cat "$WATCH"; printf '        continue-on-error: true\n'; } > "$TMP/laundered-watch.sh"
  if [ "$(grep -c -a "continue-on-error" "$TMP/laundered-watch.sh")" -gt \
       "$(grep -c -a "continue-on-error" "$WATCH")" ]; then
    ok "the script-side mutation fixture really carries the plant (the arm is not vacuous)"
  else
    bad "the script-side plant did not land in $TMP/laundered-watch.sh"
  fi
  # $WATCH MUST STAY PLAIN TEXT. It used to carry a raw NUL — the group_by
  # separator near the meter — and one NUL byte makes every line-printing grep
  # over scripts/ call the file BINARY and emit nothing but "Binary file …
  # matches". That is not hypothetical: it blinded the two assertions above, and
  # it is how a census of scripts/ concluded this script had no `set` line and no
  # harness when line 123 is `set -uo pipefail` and this file is the harness. The
  # separator is a \u0000 ESCAPE now (which is also the only form that reaches
  # jq — bash drops a literal NUL from an argv), so the invariant is checkable:
  # ZERO NUL bytes, forever. This arm replaces a preservation check that went
  # vacuous the moment the NUL left — 0 == 0 is an ok that proves nothing.
  if [ "$(tr -dc '\000' < "$WATCH" | wc -c | tr -d ' ')" = "0" ]; then
    ok "\$WATCH carries no NUL byte — every line-printing grep over it can still read it"
  else
    bad "\$WATCH carries a NUL byte — grep will call it BINARY and the assertions above go blind"
  fi
  if uncommented_has "continue-on-error" "$TMP/laundered-watch.sh" -i; then
    ok "the script-side predicate FIRES on a planted continue-on-error (the no-continue assertion can still lose)"
  else
    bad "the script-side predicate missed a planted continue-on-error — the 'no continue-on-error in the script' ok is a false green"
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
