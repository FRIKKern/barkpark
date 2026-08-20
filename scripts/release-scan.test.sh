#!/usr/bin/env bash
# release-scan.test.sh — behavioral harness for scripts/release-scan.sh, the one
# machine reader of CI state the release-curation agent trusts. Before this
# file, NOTHING in .github/workflows/** invoked release-scan.sh at all: the
# script had no syntax check, no test, no caller. It lied three ways for months
# and the fleet had no way to notice.
#
# WHY THE FIXTURES ARE PINNED TO IMMUTABLE SHAS, and why they are RECORDED
# rather than fetched live: a sibling task plans to make Sobelow green and drop
# its `continue-on-error`. A harness that re-derived the verdict from a fresh
# main sha would then read "success" for the WRONG reason, conclude the bug was
# gone, and pass vacuously forever. So every advisory-derivation case replays
# API payloads captured from two frozen shas whose CI state can never change:
#
#   A = 025c249717a40f1a9ca6741fb6eafaab83ef3a92
#       All check suites green; TWO red check runs inside them — Format (whose
#       name contains "advisory") and Sobelow (whose name does NOT). This is the
#       sha the old name regex misread: it called Sobelow blocking and flipped
#       ci.status to "failure", which stopped the curator cold. Expected now:
#       status "success", BOTH reds labelled "advisory" by the suite rollup.
#       It also carries the null-conclusion trap: 4 suites from non-Actions apps
#       (8329/34548/224032/1236702) that are queued forever and must be ignored.
#
#   B = 2c8fe0da467cd3772e250655352a25f7c5b68ee4
#       A genuinely red suite (81971901242, "Full production Paper reader
#       audit") alongside a green suite carrying an advisory Format red.
#       Expected: status "failure", the audit "blocking" (sole red in a red
#       suite — a continue-on-error job would have left that suite green), the
#       Format red still "advisory".
#
# The remaining cases are synthetic payloads for states main has not produced on
# a frozen sha: the cannot-tell residue, the three-valued cancelled
# classification, an unreadable gh, the shallow-clone guard (which builds
# real git repos, because that is the only way to make `git rev-parse
# --is-shallow-repository` actually answer true), and the argv ceiling (H),
# which builds a repo whose commit range is deliberately larger than Linux's
# MAX_ARG_STRLEN so the 2026-07-28 "dead on Linux" outage stays reproducible
# after the next release tag shrinks the real range back under it.
#
# The G fixture asserts ITSELF first (G0). A bare origin built without `-b main`
# leaves an unborn HEAD on a runner whose init.defaultBranch is `master`, and
# every G assertion then passes over an EMPTY clone at exit 0 — the fixture must
# prove it is real before its results mean anything.
#
# Set RELEASE_SCAN_TEST_LIVE=1 to ALSO replay the two pinned shas against the
# real GitHub API — the anti-rot check that the recorded payloads still match
# what GitHub serves. Off by default: CI must not depend on the network here.
#
# Templated on scripts/doctor.test.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/release-scan.sh"
SHA_GREEN_SUITES="025c249717a40f1a9ca6741fb6eafaab83ef3a92"
SHA_RED_SUITE="2c8fe0da467cd3772e250655352a25f7c5b68ee4"

fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
cleanup() { chmod -R u+w "$TMP" 2>/dev/null || true; find "$TMP" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT

# ── assertion helpers ────────────────────────────────────────────────────────
# assert_eq <name> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else
    fail "$1"; printf '    expected: %s\n    actual:   %s\n' "$2" "$3"; fi
}
# jq_of <json> <filter>
jq_of() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

# ── the fake `gh` ────────────────────────────────────────────────────────────
# Emulates `gh api <path> [--jq FILTER]` by replaying recorded payloads from
# $GH_FIXTURE_DIR and applying the script's OWN jq filter to them — so the
# filters under test are the ones that actually run, not a paraphrase. A
# missing fixture exits non-zero, which is exactly how a real gh failure looks.
BIN="$TMP/bin"
mkdir -p "$BIN"
cat >"$BIN/gh" <<'FAKEGH'
#!/usr/bin/env bash
set -uo pipefail
[ "${1:-}" = "api" ] || { echo "fake gh: only \`gh api\` is emulated: $*" >&2; exit 1; }
path="$2"; shift 2
filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) filter="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
file=""
case "$path" in
  */check-runs*)             file="check-runs.json" ;;
  */check-suites*)           file="check-suites.json" ;;
  */actions/runs\?head_sha=*) file="runs-head-sha.json" ;;
  */actions/runs\?branch=*)  file="runs-branch.json" ;;
  */actions/runs/*/jobs*)
    rid="${path#*/actions/runs/}"; rid="${rid%%/jobs*}"
    file="jobs-${rid}.json" ;;
  *) echo "fake gh: unrouted path: $path" >&2; exit 1 ;;
esac
src="${GH_FIXTURE_DIR:-}/$file"
[ -f "$src" ] || { echo "fake gh: no fixture $src" >&2; exit 1; }
if [ -n "$filter" ]; then jq "$filter" <"$src"; else cat "$src"; fi
FAKEGH
chmod +x "$BIN/gh"
PATH="$BIN:$PATH"
export PATH

# run_scan <fixture_dir> <ref> — the scan with fixtures wired in.
# RELEASE_SCAN_ALLOW_SHALLOW=1 because the checkout under test may be shallow
# (worktrees often are) and these cases assert only the `ci` object, never
# commits[]. The guard itself is proven separately, both directions, below.
run_scan() {
  GH_FIXTURE_DIR="$1" RELEASE_SCAN_ALLOW_SHALLOW=1 bash "$SCAN" "$2" 2>/dev/null
}

# ── fixture A: 025c2497 — green suites, two advisory reds, null-suite trap ────
FA="$TMP/fixture-green-suites"; mkdir -p "$FA"
cat >"$FA/check-runs.json" <<'JSON'
{"total_count":11,"check_runs":[
 {"name":"Prod compile gate (Elixir 1.18.1 / OTP 27.0)","status":"completed","conclusion":"success","check_suite":{"id":82031225733}},
 {"name":"Test (Elixir 1.18.1 / OTP 27.0)","status":"completed","conclusion":"success","check_suite":{"id":82031225733}},
 {"name":"Format (mix format --check-formatted, advisory) (27.0, 1.18.1)","status":"completed","conclusion":"failure","check_suite":{"id":82031225733}},
 {"name":"Validation perf bench (median-of-5, alarm >100ms) (27.0, 1.18.1)","status":"completed","conclusion":"success","check_suite":{"id":82031225733}},
 {"name":"control-plane","status":"completed","conclusion":"skipped","check_suite":{"id":82031229824}},
 {"name":"instance","status":"completed","conclusion":"success","check_suite":{"id":82031229824}},
 {"name":"changes","status":"completed","conclusion":"success","check_suite":{"id":82031229824}},
 {"name":"Dependency CVE audit (mix_audit over mix.lock, blocking) (27.0, 1.18.1)","status":"completed","conclusion":"success","check_suite":{"id":82031229971}},
 {"name":"Sobelow static analysis (regression gate, baseline .sobelow-skips) (27.0, 1.18.1)","status":"completed","conclusion":"failure","check_suite":{"id":82031229971}},
 {"name":"Doc budgets + anchors","status":"completed","conclusion":"success","check_suite":{"id":82031225484}},
 {"name":"build","status":"completed","conclusion":"success","check_suite":{"id":82031225481}}
]}
JSON
cat >"$FA/check-suites.json" <<'JSON'
{"total_count":9,"check_suites":[
 {"id":82031220457,"status":"queued","conclusion":null,"app":{"id":8329}},
 {"id":82031220840,"status":"queued","conclusion":null,"app":{"id":34548}},
 {"id":82031221093,"status":"queued","conclusion":null,"app":{"id":224032}},
 {"id":82031221389,"status":"queued","conclusion":null,"app":{"id":1236702}},
 {"id":82031225481,"status":"completed","conclusion":"success","app":{"id":15368}},
 {"id":82031225484,"status":"completed","conclusion":"success","app":{"id":15368}},
 {"id":82031225733,"status":"completed","conclusion":"success","app":{"id":15368}},
 {"id":82031229824,"status":"completed","conclusion":"success","app":{"id":15368}},
 {"id":82031229971,"status":"completed","conclusion":"success","app":{"id":15368}}
]}
JSON

echo "── A. sha 025c2497: advisory derived from the suite rollup (was: name regex) ──"
out_a="$(run_scan "$FA" "$SHA_GREEN_SUITES")"
assert_eq "A1 ci.status is success (the old regex said failure here)" \
  "success" "$(jq_of "$out_a" '.ci.status')"
assert_eq "A2 Sobelow — no 'advisory' in its name — is labelled advisory" \
  "advisory" "$(jq_of "$out_a" '.ci.failures[] | select(.name | startswith("Sobelow")) | .advisory')"
assert_eq "A3 Format is labelled advisory too, by the rollup and not by its name" \
  "advisory" "$(jq_of "$out_a" '.ci.failures[] | select(.name | startswith("Format")) | .advisory')"
assert_eq "A4 both reds are still REPORTED, not swallowed" \
  "2" "$(jq_of "$out_a" '.ci.failures | length')"
assert_eq "A5 certainty is 'known' — every red sits in a green suite" \
  "known" "$(jq_of "$out_a" '.ci.advisory_certainty')"
# The trap: 4 non-Actions suites are queued with a null conclusion FOREVER.
assert_eq "A6 unreferenced null-conclusion suites are excluded (5 of 9 counted)" \
  "5" "$(jq_of "$out_a" '.ci.suites_total')"
assert_eq "A7 …so the rollup is NOT pinned at 'pending' by them" \
  "true" "$([ "$(jq_of "$out_a" '.ci.status')" != "pending" ] && echo true || echo false)"

# ── fixture B: 2c8fe0da — a genuinely red suite next to an advisory red ───────
FB="$TMP/fixture-red-suite"; mkdir -p "$FB"
cat >"$FB/check-runs.json" <<'JSON'
{"total_count":12,"check_runs":[
 {"name":"Finder unit specs (dep-free, no browser)","status":"completed","conclusion":"skipped","check_suite":{"id":81987920284}},
 {"name":"Journey smoke — self-test (fixtures, no network)","status":"completed","conclusion":"skipped","check_suite":{"id":81987920284}},
 {"name":"Journey smoke — live demo (report mode, never gates)","status":"completed","conclusion":"success","check_suite":{"id":81987920284}},
 {"name":"Calibrate scoring (release cadence)","status":"completed","conclusion":"skipped","check_suite":{"id":81984148132}},
 {"name":"Drift guard (weekly)","status":"completed","conclusion":"success","check_suite":{"id":81984148132}},
 {"name":"Full production Paper reader audit","status":"completed","conclusion":"failure","check_suite":{"id":81971901242}},
 {"name":"Prod compile gate (Elixir 1.18.1 / OTP 27.0)","status":"completed","conclusion":"success","check_suite":{"id":81922407683}},
 {"name":"Format (mix format --check-formatted, advisory) (27.0, 1.18.1)","status":"completed","conclusion":"failure","check_suite":{"id":81922407683}},
 {"name":"Test (Elixir 1.18.1 / OTP 27.0)","status":"completed","conclusion":"success","check_suite":{"id":81922407683}},
 {"name":"Validation perf bench (median-of-5, alarm >100ms) (27.0, 1.18.1)","status":"completed","conclusion":"success","check_suite":{"id":81922407683}},
 {"name":"Typecheck + lint + jest","status":"completed","conclusion":"success","check_suite":{"id":81922407774}},
 {"name":"Doc budgets + anchors","status":"completed","conclusion":"success","check_suite":{"id":81922407716}}
]}
JSON
cat >"$FB/check-suites.json" <<'JSON'
{"total_count":10,"check_suites":[
 {"id":81922406205,"status":"queued","conclusion":null,"app":{"id":8329}},
 {"id":81922406301,"status":"queued","conclusion":null,"app":{"id":34548}},
 {"id":81922406391,"status":"queued","conclusion":null,"app":{"id":224032}},
 {"id":81922406481,"status":"queued","conclusion":null,"app":{"id":1236702}},
 {"id":81922407683,"status":"completed","conclusion":"success","app":{"id":15368}},
 {"id":81922407716,"status":"completed","conclusion":"success","app":{"id":15368}},
 {"id":81922407774,"status":"completed","conclusion":"success","app":{"id":15368}},
 {"id":81971901242,"status":"completed","conclusion":"failure","app":{"id":15368}},
 {"id":81984148132,"status":"completed","conclusion":"success","app":{"id":15368}},
 {"id":81987920284,"status":"completed","conclusion":"success","app":{"id":15368}}
]}
JSON

echo "── B. sha 2c8fe0da: a real blocking red still reds the verdict ──"
out_b="$(run_scan "$FB" "$SHA_RED_SUITE")"
assert_eq "B1 ci.status is failure — the honest derivation still catches real reds" \
  "failure" "$(jq_of "$out_b" '.ci.status')"
assert_eq "B2 the sole red in the red suite is proven BLOCKING" \
  "blocking" "$(jq_of "$out_b" '.ci.failures[] | select(.name == "Full production Paper reader audit") | .advisory')"
assert_eq "B3 the Format red in the GREEN suite is still advisory" \
  "advisory" "$(jq_of "$out_b" '.ci.failures[] | select(.name | startswith("Format")) | .advisory')"
assert_eq "B4 certainty stays 'known' — every red here is decidable" \
  "known" "$(jq_of "$out_b" '.ci.advisory_certainty')"

# ── C. the honest blind spot: two reds in one red suite ──────────────────────
# GitHub does not say which of them was continue-on-error, and neither may we.
FC="$TMP/fixture-cannot-tell"; mkdir -p "$FC"
cat >"$FC/check-runs.json" <<'JSON'
{"total_count":3,"check_runs":[
 {"name":"Test","status":"completed","conclusion":"failure","check_suite":{"id":900001}},
 {"name":"Format","status":"completed","conclusion":"failure","check_suite":{"id":900001}},
 {"name":"Compile","status":"completed","conclusion":"success","check_suite":{"id":900001}}
]}
JSON
cat >"$FC/check-suites.json" <<'JSON'
{"total_count":1,"check_suites":[
 {"id":900001,"status":"completed","conclusion":"failure","app":{"id":15368}}
]}
JSON
echo "── C. under a red suite with several reds, the reader ADMITS it cannot tell ──"
out_c="$(run_scan "$FC" "$SHA_RED_SUITE")"
assert_eq "C1 ci.status is failure" "failure" "$(jq_of "$out_c" '.ci.status')"
assert_eq "C2 advisory_certainty is the explicit third value, not a boolean" \
  "cannot_tell" "$(jq_of "$out_c" '.ci.advisory_certainty')"
assert_eq "C3 every red in the ambiguous suite is cannot_tell (never guessed)" \
  "2" "$(jq_of "$out_c" '[.ci.failures[] | select(.advisory == "cannot_tell")] | length')"
assert_eq "C4 no failure entry is ever a bare true/false" \
  "0" "$(jq_of "$out_c" '[.ci.failures[] | select(.advisory | type != "string")] | length')"

# ── D. cancelled ≠ failure, classified three-valued (D28) ────────────────────
FD="$TMP/fixture-cancelled"; mkdir -p "$FD"
cat >"$FD/check-runs.json" <<'JSON'
{"total_count":2,"check_runs":[
 {"name":"elixir","status":"completed","conclusion":"cancelled","check_suite":{"id":910001}},
 {"name":"Doc budgets + anchors","status":"completed","conclusion":"success","check_suite":{"id":910002}}
]}
JSON
cat >"$FD/check-suites.json" <<'JSON'
{"total_count":2,"check_suites":[
 {"id":910001,"status":"completed","conclusion":"cancelled","app":{"id":15368}},
 {"id":910002,"status":"completed","conclusion":"success","app":{"id":15368}}
]}
JSON
# Three cancelled runs on the same sha, one per classification.
cat >"$FD/runs-head-sha.json" <<'JSON'
{"total_count":3,"workflow_runs":[
 {"id":30290179083,"name":"elixir","workflow_id":266694577,"head_branch":"main","conclusion":"cancelled","created_at":"2026-07-27T17:38:57Z","updated_at":"2026-07-27T17:39:06Z"},
 {"id":30271023563,"name":"doc-gates","workflow_id":292491212,"head_branch":"main","conclusion":"cancelled","created_at":"2026-07-27T13:35:51Z","updated_at":"2026-07-27T13:47:47Z"},
 {"id":30269324442,"name":"security","workflow_id":111111111,"head_branch":"main","conclusion":"cancelled","created_at":"2026-07-27T13:14:08Z","updated_at":"2026-07-27T13:14:15Z"}
]}
JSON
# The successor correlation, measured 5/5 on main: the collapse victim's
# updated_at equals the NEXT run's created_at within 0–1s. Only run 30290179083
# has such a successor here; 30269324442 deliberately has none.
cat >"$FD/runs-branch.json" <<'JSON'
{"total_count":3,"workflow_runs":[
 {"id":30290189839,"workflow_id":266694577,"created_at":"2026-07-27T17:39:06Z"},
 {"id":30271099999,"workflow_id":292491212,"created_at":"2026-07-27T14:30:00Z"},
 {"id":30269399999,"workflow_id":111111111,"created_at":"2026-07-27T15:00:00Z"}
]}
JSON
echo '{"total_count":0,"jobs":[]}' >"$FD/jobs-30290179083.json"
echo '{"total_count":3,"jobs":[{"name":"a","conclusion":"cancelled"}]}' >"$FD/jobs-30271023563.json"
echo '{"total_count":0,"jobs":[]}' >"$FD/jobs-30269324442.json"

echo "── D. cancelled: superseded / cancelled / unknown, and never 'failure' ──"
out_d="$(run_scan "$FD" "$SHA_RED_SUITE")"
assert_eq "D1 a cancelled suite does NOT read as failure" \
  "true" "$([ "$(jq_of "$out_d" '.ci.status')" != "failure" ] && echo true || echo false)"
assert_eq "D2 …it reads unknown — this sha simply never finished" \
  "unknown" "$(jq_of "$out_d" '.ci.status')"
assert_eq "D3 never-dispatched + successor within 1s ⇒ superseded" \
  "superseded" "$(jq_of "$out_d" '.ci.cancelled_runs[] | select(.run_id == 30290179083) | .classification')"
assert_eq "D4 jobs dispatched then killed ⇒ cancelled (duration is NOT the discriminator)" \
  "cancelled" "$(jq_of "$out_d" '.ci.cancelled_runs[] | select(.run_id == 30271023563) | .classification')"
assert_eq "D5 never-dispatched with no successor ⇒ unknown, the honest residue" \
  "unknown" "$(jq_of "$out_d" '.ci.cancelled_runs[] | select(.run_id == 30269324442) | .classification')"
assert_eq "D6 every cancelled run carries a stated basis" \
  "3" "$(jq_of "$out_d" '[.ci.cancelled_runs[] | select(.basis | length > 0)] | length')"

# ── E. gh unreadable degrades to unknown, never to a verdict ─────────────────
FE="$TMP/fixture-empty"; mkdir -p "$FE"
echo "── E. an unreadable gh degrades to unknown, and the script still exits 0 ──"
out_e="$(run_scan "$FE" "$SHA_GREEN_SUITES")"; rc_e=$?
assert_eq "E1 exit 0 — CI lookup is best-effort by contract" "0" "$rc_e"
assert_eq "E2 ci.status unknown" "unknown" "$(jq_of "$out_e" '.ci.status')"
assert_eq "E3 certainty is cannot_tell, not a fabricated 'known'" \
  "cannot_tell" "$(jq_of "$out_e" '.ci.advisory_certainty')"

# ── F. the name regex is GONE, not widened ──────────────────────────────────
echo "── F. no name-based advisory classification survives in the script ──"
# Comment lines are stripped first: the header DOCUMENTS the deleted regex on
# purpose, and a guard that cannot tell prose from code is its own false red.
scan_code="$(grep -vE '^[[:space:]]*#' "$SCAN")"
if grep -qiE 'test\("advisory\|lighthouse"\)|ascii_downcase\) *\| *test\(' <<<"$scan_code"; then
  fail "F1 a name-regex advisory classifier is still present in release-scan.sh"
else
  pass "F1 no name-regex advisory classifier in release-scan.sh"
fi
if grep -qn 'conclusion == "cancelled"' "$SCAN" && grep -q 'status: (' "$SCAN" &&
   grep -qE 'if .*\$red_suites \| length' "$SCAN"; then
  pass "F2 ci.status is derived from suite conclusions, cancelled handled apart"
else
  fail "F2 ci.status derivation no longer reads as suite-rollup + separate cancelled"
fi

# ── G. the shallow-clone guard, proven BY MUTATION in real git repos ─────────
# release-scan.sh always scans ITS OWN checkout, so the only way to exercise the
# guard is to stand up real repos and copy the script into them.
#
# THE FIXTURE ITSELF IS ASSERTED FIRST (G0). The original of this block built
# its origin with `git init -q --bare` and no `-b main`, so on a runner whose
# `init.defaultBranch` is `master` the bare repo kept an UNBORN HEAD pointing at
# refs/heads/master. `git push origin main` does not move an unborn bare HEAD,
# and `git clone --depth 1` implies `--single-branch` and clones HEAD — so the
# clone landed EMPTY: exit 0, `is-shallow-repository` FALSE, no origin/main.
# Every behavioural G assertion below then tested nothing on Linux while passing
# on macOS. Note what does NOT catch this: un-muting the clone's exit status,
# which is 0. Only a POSITIVE assertion on the refs can, and it has to run
# before the behavioural ones so a broken fixture reads as "fixture broken"
# instead of as a broken script. Construction stderr goes to a log, not
# /dev/null, so a fixture that fails to build says why.
echo "── G. shallow clone: loud failure, not an empty commits[] at exit 0 ──"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e
GITLOG="$TMP/git-fixture.log"
: >"$GITLOG"
ORIGIN="$TMP/origin"
git init -q --bare -b main "$ORIGIN" >>"$GITLOG" 2>&1
SEED="$TMP/seed"
git init -q -b main "$SEED" >>"$GITLOG" 2>&1
(
  cd "$SEED" || exit 1
  for i in 1 2 3; do
    echo "$i" >"f$i"; git add "f$i"
    git commit -qm "feat: commit $i"
    [ "$i" = "1" ] && git tag v0.1.0
  done
  git remote add origin "$ORIGIN"
  git push -q origin main --tags
) >>"$GITLOG" 2>&1

DEEP="$TMP/deep"
git clone -q "$ORIGIN" "$DEEP" >>"$GITLOG" 2>&1
mkdir -p "$DEEP/scripts"; cp "$SCAN" "$DEEP/scripts/release-scan.sh"

SHALLOW="$TMP/shallow"
git clone -q --depth 1 "file://$ORIGIN" "$SHALLOW" >>"$GITLOG" 2>&1
mkdir -p "$SHALLOW/scripts"; cp "$SCAN" "$SHALLOW/scripts/release-scan.sh"

# ── G0. is the fixture even real? ────────────────────────────────────────────
g0_fails_before=$fails
assert_eq "G0a the bare origin HEAD is main, not the runner's init.defaultBranch" \
  "refs/heads/main" "$(git --git-dir="$ORIGIN" symbolic-ref HEAD 2>/dev/null)"
assert_eq "G0b the seed actually pushed its 3 commits to the origin" \
  "3" "$(git --git-dir="$ORIGIN" rev-list --count refs/heads/main 2>/dev/null)"
assert_eq "G0c …and its tag v0.1.0 (without it the range under test is empty)" \
  "yes" "$(git --git-dir="$ORIGIN" rev-parse -q --verify refs/tags/v0.1.0 >/dev/null 2>&1 && echo yes || echo no)"
assert_eq "G0d the deep clone resolved origin/main" \
  "yes" "$(git -C "$DEEP" rev-parse -q --verify origin/main >/dev/null 2>&1 && echo yes || echo no)"
assert_eq "G0e the shallow clone is ACTUALLY shallow (an empty clone is not)" \
  "true" "$(git -C "$SHALLOW" rev-parse --is-shallow-repository 2>/dev/null)"
assert_eq "G0f …and carries origin/main, so the guard has something to refuse" \
  "yes" "$(git -C "$SHALLOW" rev-parse -q --verify origin/main >/dev/null 2>&1 && echo yes || echo no)"
if [ "$fails" -ne "$g0_fails_before" ]; then
  echo "  !! G FIXTURE IS BROKEN — read every G1-G7 result below as 'fixture broken',"
  echo "     not as a release-scan.sh defect. git construction log:"
  sed 's/^/       /' "$GITLOG"
fi

out_g="$(GH_FIXTURE_DIR="$FE" bash "$DEEP/scripts/release-scan.sh" origin/main 2>/dev/null)"; rc_g=$?
assert_eq "G1 a full clone scans clean (exit 0)" "0" "$rc_g"
assert_eq "G2 …and declares shallow:false" "false" "$(jq_of "$out_g" '.shallow')"
assert_eq "G3 …and actually sees the history (2 commits since v0.1.0)" \
  "2" "$(jq_of "$out_g" '.commit_count')"

err_g="$(GH_FIXTURE_DIR="$FE" bash "$SHALLOW/scripts/release-scan.sh" origin/main 2>&1 >/dev/null)"; rc_s=$?
assert_eq "G4 a shallow clone FAILS loudly instead of shrugging in green" \
  "3" "$rc_s"
if grep -qF "FATAL shallow repository" <<<"$err_g"; then
  pass "G5 the failure names the cause on stderr"
else
  fail "G5 the failure does not name the cause"; printf '    stderr: %s\n' "$err_g"
fi
out_s="$(GH_FIXTURE_DIR="$FE" RELEASE_SCAN_ALLOW_SHALLOW=1 bash "$SHALLOW/scripts/release-scan.sh" origin/main 2>/dev/null)"; rc_o=$?
assert_eq "G6 the documented override proceeds (exit 0)" "0" "$rc_o"
assert_eq "G7 …but the output DECLARES its own degradation: shallow:true" \
  "true" "$(jq_of "$out_s" '.shallow')"

# ── H. the argv ceiling, in a repo the harness OWNS (honest-gates D44) ───────
# The 2026-07-28 outage — release-scan.sh exiting 126 with empty stdout on every
# Linux runner — was invisible to every case above, because A–G scan ranges of
# 0–3 commits. It only became reproducible because v0.2.25 was 1900 commits
# stale. THAT IS A DISAPPEARING TEST: the next release tag shrinks the real
# range back under the ceiling and the regression stops being observable.
#
# So this case owns its own repo and manufactures the ceiling deterministically:
# COMMITS commits whose subjects are SUBJECT_LEN bytes each, folded to > 131072
# bytes of JSON — Linux's MAX_ARG_STRLEN, the per-argument cap that ARG_MAX does
# not describe and that macOS does not have at all. H1 asserts the payload is
# ACTUALLY over the ceiling, so this case can never pass vacuously by quietly
# shrinking; H4 asserts commits[] is a FLAT array of objects, which is the
# `--slurpfile` contract trap ($commits vs $commits[0]) that the real-repo run
# cannot distinguish from correct output.
echo "── H. a commit range over Linux MAX_ARG_STRLEN still scans (argv ceiling) ──"
MAX_ARG_STRLEN=131072
COMMITS=100
SUBJECT_LEN=4000
BIG="$TMP/bigrange"
git init -q -b main "$BIG" >>"$GITLOG" 2>&1
(
  cd "$BIG" || exit 1
  pad="$(head -c "$SUBJECT_LEN" /dev/zero | tr '\0' 'x')"
  git commit -q --allow-empty -m "chore: base"
  git tag v0.1.0
  for i in $(seq 1 "$COMMITS"); do
    git commit -q --allow-empty -m "feat: commit $i $pad"
  done
) >>"$GITLOG" 2>&1
mkdir -p "$BIG/scripts"; cp "$SCAN" "$BIG/scripts/release-scan.sh"

# The exact bytes the pre-fix script handed to execve as ONE argv word.
argv_bytes="$(git -C "$BIG" log --format='%H%x09%s' v0.1.0..main 2>/dev/null \
  | jq -R -s 'split("\n") | map(select(length > 0))
      | map(split("\t") | {sha: (.[0][0:12]), subject: (.[1] // ""), pr: null})' \
  | wc -c | tr -d ' ')"
assert_eq "H1 the fixture range really exceeds MAX_ARG_STRLEN (${argv_bytes}B > ${MAX_ARG_STRLEN}B)" \
  "true" "$([ "${argv_bytes:-0}" -gt "$MAX_ARG_STRLEN" ] && echo true || echo false)"
out_h="$(GH_FIXTURE_DIR="$FE" bash "$BIG/scripts/release-scan.sh" main 2>/dev/null)"; rc_h=$?
assert_eq "H2 the scan survives it (exit 0 — was 126, execve E2BIG, on Linux)" \
  "0" "$rc_h"
assert_eq "H3 …and reports every commit in the range" \
  "$COMMITS" "$(jq_of "$out_h" '.commit_count')"
assert_eq "H4 …with commits[] a FLAT array of objects (--slurpfile needs \$commits[0])" \
  "object" "$(jq_of "$out_h" '.commits[0] | type')"
assert_eq "H5 …and commits[] length matches commit_count (no silent truncation)" \
  "$COMMITS" "$(jq_of "$out_h" '.commits | length')"

# ── I. optional live re-record check (anti-rot for the recorded payloads) ────
if [ "${RELEASE_SCAN_TEST_LIVE:-0}" = "1" ]; then
  echo "── I. live replay of the two pinned shas against the real GitHub API ──"
  live_a="$(PATH="${PATH#"$BIN":}" RELEASE_SCAN_ALLOW_SHALLOW=1 bash "$SCAN" "$SHA_GREEN_SUITES" 2>/dev/null)"
  live_b="$(PATH="${PATH#"$BIN":}" RELEASE_SCAN_ALLOW_SHALLOW=1 bash "$SCAN" "$SHA_RED_SUITE" 2>/dev/null)"
  assert_eq "I1 live 025c2497 still success" "success" "$(jq_of "$live_a" '.ci.status')"
  assert_eq "I2 live 2c8fe0da still failure" "failure" "$(jq_of "$live_b" '.ci.status')"
else
  echo "── I. live replay SKIPPED (set RELEASE_SCAN_TEST_LIVE=1 to re-verify the recordings) ──"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "release-scan.test.sh: ALL PASS"
  exit 0
fi
echo "release-scan.test.sh: $fails FAILING"
exit 1
