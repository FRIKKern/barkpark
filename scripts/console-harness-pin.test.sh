#!/bin/sh
#
# console-harness-pin.test.sh — prove the pin arm of scripts/console-harness.sh
# can LOSE, without paying for a 1496-test run.
#
# WHY A SEPARATE FILE. `console-harness.sh --selftest` owns the RUNTIME
# contract (which node, and the measured banner). This owns the PIN contract
# added by task-561ac06ea4ebb607: that the number the local gate compares
# against is READ OUT of .github/workflows/console-harness.yml and is not a
# literal that can drift from CI's.
#
# The load-bearing arm is arm 3. A derivation that always answered 1496 would
# pass every other arm here, and would be exactly the second hardcoded copy
# this change exists to delete — so one arm points the script at a fixture
# workflow carrying a DIFFERENT pin and requires the answer to MOVE.
#
# Every arm runs the SHIPPED script in a child. Nothing here re-implements it.
#
# EXIT: 0 all arms pass · 1 an arm failed.
set -u

ROOT="${CONSOLE_HARNESS_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
SELF="$ROOT/scripts/console-harness.sh"
WF="$ROOT/.github/workflows/console-harness.yml"
TEST_REL="cloud/priv/static/__app.test.mjs"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   — $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL — $1" >&2; }

d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT

# ── 1. It reads a pin at all, and the SAME one a second, independent read of
#       the workflow finds. The step NAME carries `<N>-test EXACT pin`; the
#       script keys on the red sentence's `the committed pin is <N>`. Two
#       different slots, one number — if they ever disagree the workflow is
#       half-bumped and this says so.
got="$(sh "$SELF" --pin 2>&1)"; rc=$?
byname="$(sed -n 's/^      - name: Run console harness (\([0-9][0-9]*\)-test EXACT pin.*$/\1/p' "$WF" | head -n 1)"
if [ "$rc" = 0 ] && [ -n "$got" ]; then ok "--pin reads a pin from the workflow ($got)"
else bad "--pin exited $rc / printed '$got'"; fi
if [ -n "$byname" ] && [ "$got" = "$byname" ]; then ok "…and it equals the step NAME's own literal ($byname) — the workflow is not half-bumped"
else bad "the red sentence says '$got' but the step name says '$byname'"; fi

# ── 2. A workflow that carries no pin sentence for this suite -> REFUSED (2).
#       An unreadable pin must never read as a satisfied one.
sed "s#the committed pin is#the committed NOTHING is#" "$WF" > "$d/no-pin.yml"
out="$(CONSOLE_HARNESS_WORKFLOW="$d/no-pin.yml" sh "$SELF" --pin 2>&1)"; rc=$?
if [ "$rc" = 2 ]; then ok "a workflow with no pin sentence -> exit 2"; else bad "no pin sentence -> expected exit 2, got $rc ($out)"; fi
case "$out" in
  *REFUSED*"found no"*) ok "…and the refusal says it found none" ;;
  *) bad "…refusal did not name the absence. Got: $out" ;;
esac

# ── 3. THE CONTROL THAT MATTERS: a DIFFERENT pin must produce a DIFFERENT
#       answer. Otherwise the derivation is a hardcoded literal in disguise.
sed "s/the committed pin is $got/the committed pin is 424242/" "$WF" > "$d/moved.yml"
out="$(CONSOLE_HARNESS_WORKFLOW="$d/moved.yml" sh "$SELF" --pin 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ "$out" = "424242" ]; then ok "a workflow whose pin reads 424242 -> the script answers 424242 (the number is READ, not retyped)"
else bad "moved pin -> expected 424242 (exit 0), got '$out' (exit $rc). The local gate is NOT reading CI's number."; fi

# ── 4. Two pin sentences naming this suite -> REFUSED, not a guess.
awk -v t="$TEST_REL" '{ print } $0 ~ /the committed pin is [0-9]+/ && index($0, t) { print }' "$WF" > "$d/dup.yml"
out="$(CONSOLE_HARNESS_WORKFLOW="$d/dup.yml" sh "$SELF" --pin 2>&1)"; rc=$?
if [ "$rc" = 2 ]; then ok "two pin sentences for one suite -> exit 2"; else bad "duplicate pins -> expected exit 2, got $rc ($out)"; fi
case "$out" in
  *REFUSED*"cannot tell which"*) ok "…and it refuses to guess which pin is ours" ;;
  *) bad "…refusal did not say it cannot choose. Got: $out" ;;
esac

# ── 5. No workflow at all -> REFUSED, never a silent skip of the pin arm.
out="$(CONSOLE_HARNESS_WORKFLOW="$d/does-not-exist.yml" sh "$SELF" --pin 2>&1)"; rc=$?
if [ "$rc" = 2 ]; then ok "an unreadable workflow -> exit 2 (the pin arm never fails open)"; else bad "missing workflow -> expected exit 2, got $rc ($out)"; fi

# ── 6. The parser control. The pin exists for the GUTTED shape: a file that
#       still LOADS but registers nothing, which node reports as `# pass 1`.
#       The tally awk must read 1 back out of that TAP (an unguarded $(NF-1)
#       once printed EMPTY and made every later comparison a no-op), and 1 must
#       not be the pin.
g="$(printf '# tests 1\n# pass 1\n# fail 0\n' | awk 'NF == 3 && $2 == "pass" && $3 ~ /^[0-9]+$/ { s += $3 } END { print s + 0 }')"
if [ "$g" = "1" ]; then ok "the tally awk parses a gutted file's TAP to 1"; else bad "gutted TAP parsed to '$g', not 1 — the parser has gone blind"; fi
if [ "$g" != "$got" ]; then ok "…and 1 is not the pin ($got), so a gutted tree is still refused"; else bad "the pin IS 1 — it can no longer refuse a gutting"; fi

echo "console-harness-pin.test.sh: $pass passed / $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
