#!/usr/bin/env bash
#
# landed-mark.test.sh — the harness that proves scripts/landed-mark.sh's
# selftest can LOSE.
#
# A 41-assertion selftest that has never gone red is a document, not a gate. The
# one property the whole mechanism rests on is that a SECOND run over an
# already-marked sha writes nothing: without it, every workflow re-run and every
# push whose range re-includes an old commit appends another note, another
# label entry, another pr — the row accumulates duplicates until a reader stops
# trusting the field, which is the same outcome as never marking it. So that is
# the arm this harness disarms.
#
# THE MUTATION IS PROVEN TO HAVE APPLIED, not assumed. An anchor that silently
# matches zero times produces a scratch copy identical to the original, a green
# run, and a "the mutation was caught" conclusion that is exactly backwards. So:
# the anchor must match EXACTLY ONCE, and the mutated copy must differ from the
# original. Both are asserted before the mutant is ever executed.
#
# Hermetic: the selftest it drives builds mktemp git repos and mktemp fixture
# ledgers. No network, no token, no bp. It cannot rot into a skip.
#
# EXIT CODES
#   0  the armed selftest is green AND the mutant is red
#   1  the armed selftest is red, or the mutant survived
#   2  the mutation could not be applied — never reported as a catch

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$ROOT/scripts/landed-mark.sh"
TMP="$(mktemp -d -t landed-mark-harness.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

echo "landed-mark.test.sh — armed run, then two disarmed arms"
echo

# ── ARMED ────────────────────────────────────────────────────────────────────
echo "── ARMED: scripts/landed-mark.sh --selftest"
ARMED_OUT="$(bash "$SUBJECT" --selftest 2>&1)"; ARMED_RC=$?
echo "$ARMED_OUT" | tail -n 1
if [ "$ARMED_RC" -eq 0 ]; then ok "the armed selftest exits 0"; else bad "the armed selftest exits $ARMED_RC"; fi
# A green that ran ZERO assertions is the vacuous pass this refuses. The count
# is read out of the runner's own summary line, never assumed.
ARMED_N="$(sed -nE 's/^landed-mark --selftest: ([0-9]+) passed.*/\1/p' <<<"$ARMED_OUT")"
if [ "${ARMED_N:-0}" -ge 30 ]; then ok "the armed selftest ran ${ARMED_N} assertions (a green over zero is not a green)"
else bad "the armed selftest reported only '${ARMED_N:-none}' assertions"; fi
echo

# ── MUTANT: the idempotency read is disarmed ────────────────────────────────
echo "── MUTANT: MUT-IDEMPOTENT replaced by an unconditional false"
MUTANT="$TMP/landed-mark.mut.sh"
ANCHOR='    if all(w in labels for w in wanted) and commit_known:'
HITS="$(grep -cF -- "$ANCHOR" "$SUBJECT")"
if [ "$HITS" != "1" ]; then
  echo "landed-mark.test: CANNOT MUTATE — the MUT-IDEMPOTENT anchor matched ${HITS} time(s), not 1." >&2
  echo "A mutation that did not apply is not a catch. Re-anchor the harness." >&2
  exit 2
fi
ok "the MUT-IDEMPOTENT anchor matched exactly once"

# `python` false, not shell false: the anchor is inside the embedded helper.
sed 's/^    if all(w in labels for w in wanted) and commit_known:$/    if False:/' "$SUBJECT" > "$MUTANT"
if cmp -s "$SUBJECT" "$MUTANT"; then
  echo "landed-mark.test: CANNOT MUTATE — the scratch copy is byte-identical to the original." >&2
  exit 2
fi
ok "the mutated copy really differs from the original"
chmod +x "$MUTANT"

# The scratch copy lives outside scripts/, so hand it the extractor explicitly.
# Without this it loses the `Task:` grammar and reds EVERY arm — which looks
# like a spectacular catch and locates nothing.
MUT_OUT="$(LANDED_MARK_EXTRACTOR="$ROOT/scripts/pr-task-gate.sh" bash "$MUTANT" --selftest 2>&1)"; MUT_RC=$?
echo "$MUT_OUT" | tail -n 1
if [ "$MUT_RC" -ne 0 ]; then ok "the disarmed copy's selftest FAILS (rc ${MUT_RC})"
else bad "the disarmed copy's selftest still passed — the idempotency arm guards nothing"; fi

# NOT just "something went red". The reds must be the IDEMPOTENCY reds; a
# mutation that reddens an unrelated assertion proves nothing about this arm.
while IFS= read -r want; do
  if grep -qF "FAIL  $want" <<<"$MUT_OUT"; then ok "disarming reddens: ${want}"
  else bad "disarming did NOT redden: ${want}"; fi
done <<'WANTED'
a re-run over the same shas reports already-marked
the re-run tally is 0 marked
a re-run wrote NOTHING NEW (still 2)
WANTED

# And the arms that do NOT depend on it must stay green — a mutation that
# reddens everything is a broken script, not a located guarantee.
while IFS= read -r want; do
  if grep -qF "PASS  $want" <<<"$MUT_OUT"; then ok "unrelated arm stays green: ${want}"
  else bad "disarming smeared onto an unrelated arm: ${want}"; fi
done <<'UNRELATED'
a 401 from the ledger exits 1
an OPEN row named by a landed trailer is listed
two distinct ids are refused, not picked
UNRELATED

# ── MUTANT 2: the PR-body fallback is gutted ────────────────────────────────
# The second property this file guards, added 2026-09-10. This repo squashes
# with COMMIT_MESSAGES, so the commit on main carries the BRANCH's messages and
# not the PR body — where the `Task:` trailer actually lives. Measured over
# origin/main 2026-09-09 16:00Z..23:00Z: 30 squash commits with a `(#N)`
# subject carried no column-0 `Task:` line, all 30 resolved to a task row
# through their PR body, and none of those rows carried the mark for its sha.
# Gut the fallback and the script goes back to silence — which is
# indistinguishable from "this commit really names no task", which is why the
# defect went unnoticed for a whole campaign.
echo
echo "── MUTANT 2: MUT-PR-FALLBACK replaced by an unconditional empty id"
MUTANT2="$TMP/landed-mark.mut2.sh"
# shellcheck disable=SC2016  # the anchor is the SUBJECT's literal text: $sha must NOT expand here.
ANCHOR2='      trailer_from_pr_body "$sha"; rc=$?'
HITS2="$(grep -cF -- "$ANCHOR2" "$SUBJECT")"
if [ "$HITS2" != "1" ]; then
  echo "landed-mark.test: CANNOT MUTATE — the MUT-PR-FALLBACK anchor matched ${HITS2} time(s), not 1." >&2
  echo "A mutation that did not apply is not a catch. Re-anchor the harness." >&2
  exit 2
fi
ok "the MUT-PR-FALLBACK anchor matched exactly once"

# The fallback is not merely SKIPPED here — it is made to answer "no id, no
# error", which is precisely the pre-fix behaviour. A mutation to `rc=1` would
# take the CANNOT-READ arm instead and prove something else.
# shellcheck disable=SC2016  # a sed script over the SUBJECT's literal text; expansion would break it.
sed 's/^      trailer_from_pr_body "\$sha"; rc=\$?$/      FALLBACK_ID=""; rc=0/' "$SUBJECT" > "$MUTANT2"
if cmp -s "$SUBJECT" "$MUTANT2"; then
  echo "landed-mark.test: CANNOT MUTATE — the mutant-2 scratch copy is byte-identical to the original." >&2
  exit 2
fi
ok "the mutant-2 copy really differs from the original"
chmod +x "$MUTANT2"

MUT2_OUT="$(LANDED_MARK_EXTRACTOR="$ROOT/scripts/pr-task-gate.sh" bash "$MUTANT2" --selftest 2>&1)"; MUT2_RC=$?
echo "$MUT2_OUT" | tail -n 1
if [ "$MUT2_RC" -ne 0 ]; then ok "the gutted-fallback copy's selftest FAILS (rc ${MUT2_RC})"
else bad "the gutted-fallback copy's selftest still passed — §14 guards nothing"; fi

while IFS= read -r want; do
  if grep -qF "FAIL  $want" <<<"$MUT2_OUT"; then ok "gutting the fallback reddens: ${want}"
  else bad "gutting the fallback did NOT redden: ${want}"; fi
done <<'WANTED2'
MUT-PR-FALLBACK: the fallback says WHERE the id came from
MUT-PR-FALLBACK: a trailer that lives only in the PR body still marks the row
MUT-PR-FALLBACK: the fallback really wrote (1 label POST)
MUT-PR-FALLBACK positive control: the row carries the class label
WANTED2

# The NEGATIVE arms of §14 must SURVIVE. They assert that nothing is written,
# and a gutted fallback writes nothing either — so if one of them reddens here,
# it was never measuring the fallback at all.
while IFS= read -r want; do
  if grep -qF "PASS  $want" <<<"$MUT2_OUT"; then ok "unrelated arm stays green: ${want}"
  else bad "gutting the fallback smeared onto an unrelated arm: ${want}"; fi
done <<'UNRELATED2'
the fallback finding NO PR writes NOTHING
a PR body with no COLUMN-0 trailer writes NOTHING
a commit-message trailer is used and the PR body is never consulted
a 401 from the ledger exits 1
an OPEN row named by a landed trailer is listed
UNRELATED2

echo
echo "landed-mark.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
