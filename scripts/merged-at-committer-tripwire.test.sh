#!/usr/bin/env bash
#
# THE HARNESS FOR THE TRIPWIRE — and the place the tripwire is PROVED able to
# lose. Two mutation arms carry the whole argument:
#
#   * MUTATED LITERAL. A scratch copy of the tripwire with
#     BLESSED_MERGE_COMMITTER rewritten to a foreign address is run over the
#     batch that is GREEN against the real script (5 rows, all committed by the
#     blessed identity). It must exit 1. That is the incident this exists for,
#     played forwards: the day the merge identity moves, every row lands on the
#     NULL arm, and this is what screams instead of the column quietly emptying.
#
#   * UNWIRED RECORDER. A scratch copy of .github/workflows/deploy.yml with the
#     tripwire's invocation deleted must red the wiring arm. A tripwire nothing
#     calls is a file, not a check.
#
# Hermetic: mktemp fixtures, no git, no network, no gh, no bp.
#
# exit 0  every case passed
# exit 1  at least one case FAILED
# exit 2  the harness could not measure (missing subject, zero cases run)

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
SUBJECT="${here}/merged-at-committer-tripwire.sh"
DEPLOY_YML="${here}/../.github/workflows/deploy.yml"

[ -r "$SUBJECT" ] || { echo "harness: subject ${SUBJECT} is missing — measuring nothing" >&2; exit 2; }
[ -r "$DEPLOY_YML" ] || { echo "harness: ${DEPLOY_YML} is missing — measuring nothing" >&2; exit 2; }

BLESSED="noreply@github.com"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

ok() { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; }

# expect_rc <label> <expected-rc> <script> [args...]
expect_rc() {
  label="$1"; want="$2"; shift 2
  out="$("$@" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ]; then
    ok "${label} (rc=${got})"
  else
    bad "${label}: expected rc=${want}, got rc=${got}"
    printf '        %s\n' "$out"
  fi
}

# expect_says <label> <needle> <script> [args...]
expect_says() {
  label="$1"; needle="$2"; shift 2
  out="$("$@" 2>&1)"
  case "$out" in
    *"$needle"*) ok "${label}" ;;
    *) bad "${label}: output did not contain '${needle}'"; printf '        %s\n' "$out" ;;
  esac
}

row() { printf '%s %s %s\n' "$1" "2026-09-10T10:00:00Z" "$2"; }

# ── FIXTURES ────────────────────────────────────────────────────────────────
all_blessed="${tmp}/all-blessed.txt"
: > "$all_blessed"
for n in 1 2 3 4 5; do row "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa${n}" "$BLESSED" >> "$all_blessed"; done

mixed="${tmp}/mixed.txt"
: > "$mixed"
for n in 1 2 3; do row "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb${n}" "$BLESSED" >> "$mixed"; done
for n in 4 5; do row "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb${n}" "dev@example.com" >> "$mixed"; done

all_foreign="${tmp}/all-foreign.txt"
: > "$all_foreign"
for n in 1 2 3 4 5; do row "ccccccccccccccccccccccccccccccccccccccc${n}" "merge-queue@bot.invalid" >> "$all_foreign"; done

two_foreign="${tmp}/two-foreign.txt"
: > "$two_foreign"
for n in 1 2; do row "ddddddddddddddddddddddddddddddddddddddd${n}" "dev@example.com" >> "$two_foreign"; done

no_email="${tmp}/no-email.txt"
: > "$no_email"
for n in 1 2 3 4; do printf '%s %s\n' "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee${n}" "2026-09-10T10:00:00Z" >> "$no_email"; done

empty="${tmp}/empty.txt"
: > "$empty"

echo "── A. the arm each row lands on ────────────────────────────────────────"
expect_rc "5/5 blessed committers -> green"                 0 bash "$SUBJECT" "$all_blessed"
expect_says "and it says the batch produced timestamps"     "5/5 row(s) carry a timestamp" bash "$SUBJECT" "$all_blessed"
expect_rc "3 blessed + 2 direct pushes -> green"            0 bash "$SUBJECT" "$mixed"
expect_says "and the null-rate is stated, not hidden"       "null-rate 40%" bash "$SUBJECT" "$mixed"
expect_says "and the foreign committer is NAMED"            "committed by dev@example.com" bash "$SUBJECT" "$mixed"

echo "── B. the trip ─────────────────────────────────────────────────────────"
expect_rc "5/5 foreign committers, 0 timestamps -> TRIPS"   1 bash "$SUBJECT" "$all_foreign"
expect_says "and it says the identity MOVED, loudly"        "::error::merged_at HAS STOPPED BEING PRODUCED" bash "$SUBJECT" "$all_foreign"
expect_rc "two legs, one all-foreign -> still trips"        1 bash "$SUBJECT" "$empty" "$all_foreign"
expect_rc "two legs, one blessed -> does NOT trip"          0 bash "$SUBJECT" "$all_blessed" "$all_foreign"

echo "── C. the floors that keep it from crying wolf ─────────────────────────"
expect_rc "2 direct pushes, below the 3-row floor -> green"  0 bash "$SUBJECT" "$two_foreign"
expect_says "and it says WHY it held fire"                   "below the 3-row floor" bash "$SUBJECT" "$two_foreign"
expect_rc "the floor is tunable, and 2 rows then TRIP"       1 env TRIPWIRE_MIN_ROWS=2 bash "$SUBJECT" "$two_foreign"
expect_rc "git named no committer at all -> warns, no trip"  0 bash "$SUBJECT" "$no_email"
expect_says "and that arm is not silent either"              "::warning::merged_at is NULL on all 4 row(s)" bash "$SUBJECT" "$no_email"

echo "── D. inputs it refuses rather than guesses ────────────────────────────"
expect_rc "no rows anywhere -> green, said out loud"         0 bash "$SUBJECT" "$empty"
expect_rc "a leg that never deployed (missing file) -> green" 0 bash "$SUBJECT" "${tmp}/absent.txt"
expect_rc "no arguments -> refusal"                          2 bash "$SUBJECT"
expect_rc "a non-numeric floor -> refusal, never a guess"     2 env TRIPWIRE_MIN_ROWS=lots bash "$SUBJECT" "$all_foreign"
unreadable="${tmp}/unreadable.txt"
row "fffffffffffffffffffffffffffffffffffffff1" "$BLESSED" > "$unreadable"
chmod 000 "$unreadable"
if [ -r "$unreadable" ]; then
  echo "  SKIP  unreadable-file refusal (running as a user chmod 000 cannot stop)"
else
  expect_rc "an unreadable range file -> refusal, not a null-rate" 2 bash "$SUBJECT" "$unreadable"
fi
chmod 644 "$unreadable"

echo "── E. the single definition ────────────────────────────────────────────"
expect_rc "--print-committer exits 0"                        0 bash "$SUBJECT" --print-committer
printed="$(bash "$SUBJECT" --print-committer)"
if [ "$printed" = "$BLESSED" ]; then
  ok "--print-committer prints exactly '${BLESSED}'"
else
  bad "--print-committer printed '${printed}', expected '${BLESSED}'"
fi
expect_rc "--print-committer with extra args -> refusal"     2 bash "$SUBJECT" --print-committer "$all_blessed"

echo "── F. THE MUTATION: move the literal, the check must RED ───────────────"
mutant="${tmp}/mutant.sh"
sed 's|^BLESSED_MERGE_COMMITTER=.*|BLESSED_MERGE_COMMITTER="merge-bot@elsewhere.invalid"|' "$SUBJECT" > "$mutant"
if grep -q 'BLESSED_MERGE_COMMITTER="merge-bot@elsewhere.invalid"' "$mutant"; then
  ok "the mutant was actually produced (the sed matched)"
else
  bad "the mutation did not apply — every arm below would be vacuous"
  echo "harness cannot measure its own mutation arm" >&2
  exit 2
fi
# The batch that is GREEN against the real script must be RED against a script
# whose blessed identity has moved. This is the incident, played forwards.
expect_rc "mutated literal + today's real committer -> TRIPS" 1 bash "$mutant" "$all_blessed"
expect_says "and it names the literal it is now keyed on"     "merge-bot@elsewhere.invalid" bash "$mutant" "$all_blessed"
expect_says "the mutant's --print-committer moves with it"    "merge-bot@elsewhere.invalid" bash "$mutant" --print-committer
# The other direction, so the arm above is not just "any change reds": the
# mutant is GREEN on the batch its new literal actually matches.
mutant_native="${tmp}/mutant-native.txt"
: > "$mutant_native"
for n in 1 2 3 4 5; do row "9999999999999999999999999999999999999${n}aa" "merge-bot@elsewhere.invalid" >> "$mutant_native"; done
expect_rc "and the mutant is GREEN on ITS committer (control)" 0 bash "$mutant" "$mutant_native"

echo "── G. the recorder actually calls it ───────────────────────────────────"
wiring_check() { # <workflow file> -> 0 wired, 1 not
  wf="$1"
  grep -q 'merged-at-committer-tripwire.sh" --print-committer' "$wf" || return 1
  grep -q 'merged-at-committer-tripwire.sh" /tmp/pd-range' "$wf" || return 1
  # And the literal must exist in exactly ONE place: an assignment in deploy.yml
  # that does not read from the script is the two-definitions bug returning.
  if grep -Eq '^[[:space:]]*GITHUB_MERGE_COMMITTER="[^$]' "$wf"; then return 1; fi
  return 0
}
if wiring_check "$DEPLOY_YML"; then
  ok "deploy.yml sources the literal from the script AND runs the tripwire on its own ranges"
else
  bad "deploy.yml does not both source the literal and run the tripwire"
  grep -n 'MERGE_COMMITTER\|merged-at-committer-tripwire' "$DEPLOY_YML" | sed 's/^/        /'
fi
# CONTROL for the arm above: delete the call, the arm must red.
unwired="${tmp}/deploy-unwired.yml"
grep -v 'merged-at-committer-tripwire.sh" /tmp/pd-range' "$DEPLOY_YML" > "$unwired"
if wiring_check "$unwired"; then
  bad "the wiring arm passed a deploy.yml with the tripwire call REMOVED — it measures nothing"
else
  ok "the wiring arm reds when the tripwire call is removed (control)"
fi
# And the second control: a hardcoded literal back in deploy.yml.
relittered="${tmp}/deploy-relittered.yml"
{ cat "$DEPLOY_YML"; printf '          GITHUB_MERGE_COMMITTER="noreply@github.com"\n'; } > "$relittered"
if wiring_check "$relittered"; then
  bad "the wiring arm passed a deploy.yml that re-hardcodes the literal — it measures nothing"
else
  ok "the wiring arm reds when the literal is hardcoded back into deploy.yml (control)"
fi

echo
total=$((pass + fail))
if [ "$total" -eq 0 ]; then
  echo "harness ran ZERO cases — that is a refusal, not a pass" >&2
  exit 2
fi
echo "merged-at-committer-tripwire: ${pass} passed, ${fail} FAILED, ${total} cases"
[ "$fail" -eq 0 ] || exit 1
exit 0
