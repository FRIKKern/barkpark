#!/usr/bin/env bash
#
# registry-impact-check.test.sh — the harness for scripts/registry-impact-check.sh.
#
# THE FIRST GREEN OF A NEW CHECK IS THE LEAST TRUSTWORTHY GREEN THERE IS, so the
# arms that carry this harness are the ones that MUST FIND SOMETHING: two real
# historical main-reddenings, replayed by path set, each asserting the exact
# registry and the exact artifact the real follow-up commit had to edit.
#
#   CASE 1  #18213 (7d56df653) changed scripts/pds-pull-proof.sh, a pinned ROW in
#           .github/run-level-readers.allow. main reddened; #18258 (90d63a4dd)
#           was a one-line follow-up editing ONLY that allow file.
#   CASE 2  branch deploy/assets-survive-gap adds 147 lines of checks to
#           deploy/instance-deploy_test.sh, whose published count lives in
#           deploy/README.md (guard landed by #18191 / 5ca440b3d). The branch
#           DOES touch deploy/README.md — and never moves the number. The arm
#           asserts the output refuses to call that discharged.
#
# Both replays need git history a shallow CI checkout may not have. They SKIP
# when it is absent — LOUDLY, and counted, because a silent skip is the vacuous
# green this repo keeps finding. The hermetic arms below need no history at all
# and carry the three exit codes on their own.
#
# EXIT: 0 all arms passed · 1 an arm failed · 2 the harness could not run.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/registry-impact-check.sh"
TESTS=0; FAILS=0; SKIPS=0

ok()   { TESTS=$((TESTS+1)); echo "PASS: $1"; }
bad()  { TESTS=$((TESTS+1)); FAILS=$((FAILS+1)); echo "FAIL: $1"; }
skip() { SKIPS=$((SKIPS+1)); echo "SKIP: $1"; }

[ -f "$CHECK" ] || { echo "registry-impact-check.test: REFUSING — no $CHECK" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ric-test.XXXXXX")" || { echo "REFUSING — no tempdir" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

have_rev() { git -C "$ROOT" rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1; }

# ---------------------------------------------------------------- CASE 1 replay
if have_rev 7d56df653; then
  git -C "$ROOT" show --name-only --format= 7d56df653 > "$TMP/c1.paths" 2>/dev/null
  out="$(bash "$CHECK" --paths-from "$TMP/c1.paths" 2>&1)"; rc=$?
  [ "$rc" = 1 ] && ok "case 1: exits 1 (implicated)" || bad "case 1: expected rc=1, got $rc"
  grep -q 'REGISTRY  scripts/run-level-reader-census.sh' <<< "$out" \
    && ok "case 1: names scripts/run-level-reader-census.sh" \
    || bad "case 1: did NOT name run-level-reader-census.sh — the registry that actually reddened main"
  grep -q 'DECLARE in \.github/run-level-readers\.allow' <<< "$out" \
    && ok "case 1: names .github/run-level-readers.allow — what 90d63a4dd actually edited" \
    || bad "case 1: did NOT name the allow file"
  # CONTROL, the other direction: the REAL FIX's own path set must be clean of
  # this obligation, because it IS the declaration. A checker that fires on the
  # remedy as loudly as on the defect has not measured anything.
  if have_rev 90d63a4dd; then
    git -C "$ROOT" show --name-only --format= 90d63a4dd > "$TMP/c1fix.paths" 2>/dev/null
    outf="$(bash "$CHECK" --paths-from "$TMP/c1fix.paths" 2>&1)"
    grep -q 'TOUCHES it' <<< "$outf" \
      && ok "case 1 control: the fix's own diff reports the allow file as TOUCHED" \
      || bad "case 1 control: the fix's diff did not register as touching its artifact"
  else
    skip "case 1 control: 90d63a4dd not in this checkout"
  fi
else
  skip "case 1: commit 7d56df653 not in this checkout (shallow clone?) — this arm measured NOTHING"
fi

# ---------------------------------------------------------------- CASE 2 replay
if git -C "$ROOT" rev-parse --verify --quiet origin/deploy/assets-survive-gap >/dev/null 2>&1; then
  git -C "$ROOT" diff --name-only origin/main...origin/deploy/assets-survive-gap > "$TMP/c2.paths" 2>/dev/null
  out2="$(bash "$CHECK" --paths-from "$TMP/c2.paths" 2>&1)"; rc2=$?
  [ "$rc2" = 1 ] && ok "case 2: exits 1 (implicated)" || bad "case 2: expected rc=1, got $rc2"
  grep -q 'REGISTRY  deploy/instance-deploy_test\.sh' <<< "$out2" \
    && ok "case 2: names deploy/instance-deploy_test.sh" \
    || bad "case 2: did NOT name deploy/instance-deploy_test.sh"
  # THE LOAD-BEARING ARM. The branch touches deploy/README.md. A checker that
  # treats a touch as a discharge greens here and misses the real red.
  grep -q 'DECLARE in deploy/README\.md.*TOUCHES it — a touch is NOT a bump' <<< "$out2" \
    && ok "case 2: refuses to treat touching deploy/README.md as discharging the count" \
    || bad "case 2: treated a touched artifact as satisfied — this is the exact false green"
else
  skip "case 2: origin/deploy/assets-survive-gap not in this checkout — this arm measured NOTHING"
fi

# ------------------------------------------- CASE 3 replay: CONTENT membership
# d3af39283 ("fix(ci-boundary): add a --from-ci read mode") reddened
# run-level-reader-census.sh on main and every commit since. It touched three
# paths, none of which appears in ANY registry's rows or globs: the census's
# corpus is a CONTENT grep, and tooling/concept-map/ci-boundary.test.mjs BECAME a
# member by gaining run-level reads (0 source hits at d3af39283^, 2 at
# d3af39283). Every path-keyed door is structurally blind to that transition.
#
# THE CONTROL IS THE POINT AND IT RUNS THE SAME PATHS. Only --content-at differs
# between the two arms, so a D4 that simply always fires fails the control, and a
# D4 that reads the wrong tree fails the subject. Both directions, one mechanism.
if have_rev d3af39283; then
  git -C "$ROOT" show --name-only --format= d3af39283 > "$TMP/c3.paths" 2>/dev/null
  out3="$(bash "$CHECK" --paths-from "$TMP/c3.paths" --content-at d3af39283 2>&1)"; rc3=$?
  [ "$rc3" = 1 ] && ok "case 3: exits 1 (implicated) on the content-membership case" \
    || bad "case 3: expected rc=1, got $rc3 — the live main red is invisible to this check"
  grep -q 'REGISTRY  scripts/run-level-reader-census\.sh' <<< "$out3" \
    && ok "case 3: names scripts/run-level-reader-census.sh" \
    || bad "case 3: did NOT name run-level-reader-census.sh — the registry that is RED on main"
  grep -q 'via D4-CONTENT  *tooling/concept-map/ci-boundary\.test\.mjs' <<< "$out3" \
    && ok "case 3: reaches it through the CONTENT door, naming the file that became a member" \
    || bad "case 3: did not attribute the hit to D4-CONTENT on ci-boundary.test.mjs"
  grep -q 'DECLARE in \.github/run-level-readers\.allow' <<< "$out3" \
    && ok "case 3: names the allow file the adjudication row belongs in" \
    || bad "case 3: did not name .github/run-level-readers.allow"
  # Self-match guard. This file's header quotes the census's own grep invocation
  # as documentation; joining continuations before stripping comments made the
  # extractor read `-e 'gh run list'` out of its own prose and become a content
  # member of everything. An instrument must not match its own description.
  grep -q 'REGISTRY  scripts/registry-impact-check\.sh' <<< "$out3" \
    && bad "case 3: the check reported ITSELF as a content member — it is matching its own documentation" \
    || ok "case 3: the check does not match its own prose about another instrument"
  # THE CONTROL: identical paths, content one commit earlier, when the file was
  # not yet a member.
  out3c="$(bash "$CHECK" --paths-from "$TMP/c3.paths" --content-at 'd3af39283^' 2>&1)"; rc3c=$?
  [ "$rc3c" = 0 ] && ok "case 3 control: the SAME paths at d3af39283^ are CLEAN (rc=0)" \
    || bad "case 3 control: expected rc=0 before the content landed, got $rc3c — D4 fires on the path, not the transition"
  grep -q 'REGISTRY  scripts/run-level-reader-census\.sh' <<< "$out3c" \
    && bad "case 3 control: named the census at d3af39283^, where the file had ZERO run-level reads" \
    || ok "case 3 control: does not name the census before the reads were added"
else
  skip "case 3: commit d3af39283 not in this checkout — the content-membership arms measured NOTHING"
fi

# --------------------------------------------- D2 GLOB DOOR (the new-file class)
# The door that no allowlist can carry: a file that does not exist yet is in no
# registry's rows by construction. Only the corpus glob can reach it.
outg="$(bash "$CHECK" --path 'scripts/zzz-nonexistent-probe.test.sh' 2>&1)"; rcg=$?
[ "$rcg" = 1 ] && ok "glob door: a brand-new scripts/*.test.sh is implicated (rc=1)" \
  || bad "glob door: a brand-new scripts/*.test.sh produced rc=$rcg — the NEW-FILE class is not reachable"
grep -q 'selftest-wiring-census' <<< "$outg" \
  && ok "glob door: names selftest-wiring-census.sh for a new .test.sh" \
  || bad "glob door: did not name selftest-wiring-census.sh — the registry that reds on an unwired harness"

# ------------------------------------------------------------- NEGATIVE CONTROL
# A change set that legitimately touches no registry. This must be EMPTY, and the
# emptiness must be distinguishable from a scan that never ran.
outn="$(bash "$CHECK" --path web/README.md --path api/lib/barkpark/plugins/quiz.ex 2>&1)"; rcn=$?
[ "$rcn" = 0 ] && ok "negative control: exits 0" || bad "negative control: expected rc=0, got $rcn"
grep -q '^CLEAN' <<< "$outn" \
  && ok "negative control: prints CLEAN" || bad "negative control: did not print CLEAN"
grep -qE 'TALLY: 0 obligation\(s\).*[0-9]+ registries scanned' <<< "$outn" \
  && ok "negative control: the clean states its sample size (a green with no denominator is not evidence)" \
  || bad "negative control: printed a clean with no sample size"

# ------------------------------------------------ CANNOT READ is its own state
outr="$(REGISTRY_IMPACT_ROOT=/ bash "$CHECK" --path x 2>&1)"; rcr=$?
[ "$rcr" = 2 ] && ok "cannot-read (no repo): exits 2, not 0" || bad "cannot-read: expected rc=2, got $rcr"
grep -q 'CANNOT READ' <<< "$outr" \
  && ok "cannot-read: says so" || bad "cannot-read: did not say CANNOT READ"
grep -q 'TALLY' <<< "$outr" \
  && bad "cannot-read: printed a TALLY — a failed read must not look like a measured one" \
  || ok "cannot-read: prints NO tally, so it cannot be mistaken for a clean run"

# The floor: a derivation that collapses must refuse, not report a confident zero.
outf2="$(REGISTRY_IMPACT_FLOOR=999999 bash "$CHECK" --path web/README.md 2>&1)"; rcf=$?
[ "$rcf" = 2 ] && ok "floor: an unsatisfiable floor refuses with rc=2" || bad "floor: expected rc=2, got $rcf"
grep -q 'below the floor' <<< "$outf2" \
  && ok "floor: names the floor it failed" || bad "floor: did not name the floor"

# ------------------------------------------------------------------------ tally
echo ""
if [ "$TESTS" -eq 0 ]; then
  echo "registry-impact-check.test: CANNOT READ — this tally measures nothing (0 arms ran)"
  exit 2
fi
echo "registry-impact-check.test: $((TESTS - FAILS))/$TESTS checks passed, $SKIPS skipped"
if [ "$SKIPS" -gt 0 ]; then
  echo "  NOTE: $SKIPS arm(s) were skipped for missing git history. Those arms measured NOTHING;"
  echo "  this result is a statement about the arms that ran, not about the ones that did not."
fi
[ "$FAILS" -eq 0 ] || exit 1
exit 0
