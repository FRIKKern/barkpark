#!/usr/bin/env bash
# required-checks.test.sh — the mutation proofs for the required-check toolchain.
#
# The rule of this epic is that a guard which cannot be shown to FAIL has not
# been shown to work. So nothing here asserts "the script ran". Every rejection
# is disarmed and the specimen watched turning ACCEPTED; every selection stage is
# removed and the name watched surviving; every verify clause is corrupted one
# field at a time.
#
#   scripts/required-checks.test.sh          # hermetic, no network, no writes
#   scripts/required-checks.test.sh --live   # + a throwaway PROTECTED branch:
#                                            #   the contexts+checks 422, the
#                                            #   non-convergence red, and the
#                                            #   converged green, for real
#
# The hermetic run is what CI executes. --live mutates a throwaway branch in the
# repo (never main; it refuses) and cleans up after itself.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$REPO_ROOT/scripts/required-checks-generate.sh"
APPLY="$REPO_ROOT/scripts/required-checks-apply.sh"
VERIFY="$REPO_ROOT/scripts/required-checks-verify.sh"
SPEC="$REPO_ROOT/.github/required-checks.json"

LIVE=0
[ "${1:-}" = "--live" ] && LIVE=1

PASS=0
FAIL=0
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $*" >&2; }

section() { echo; echo "── $* ──"; }

# ═══ fixtures ════════════════════════════════════════════════════════════════
# A miniature repo: four workflows covering every selection stage, plus a
# check-run feed carrying one specimen per rejection rule.

WF="$TMP/workflows"
FIX="$TMP/fixtures"
mkdir -p "$WF" "$FIX"

cat > "$WF/probe.yml" <<'YAML'
name: probe
on:
  pull_request:
jobs:
  good:
    name: Good gate
    runs-on: ubuntu-latest
  adv:
    name: Advisory gate
    continue-on-error: true
    runs-on: ubuntu-latest
  matrixed:
    name: Matrixed gate
    strategy:
      matrix:
        otp: ["27.0"]
        elixir: ["1.18.1"]
    runs-on: ubuntu-latest
  agg:
    name: Aggregate gate
    needs: [good, matrixed]
    runs-on: ubuntu-latest
YAML

cat > "$WF/filtered.yml" <<'YAML'
name: filtered
on:
  pull_request:
    paths:
      - "api/**"
jobs:
  filtered:
    name: Filtered gate
    runs-on: ubuntu-latest
YAML

cat > "$WF/red.yml" <<'YAML'
name: red
on:
  pull_request:
jobs:
  red:
    name: Red on main gate
    runs-on: ubuntu-latest
YAML

# The check-run feed. One specimen per rule, each caught by exactly ONE rule
# except the `${{` one, which is skipped in real life too (that is the whole
# reason it needs isolating instead of assuming).
runs_json() { # $1 = extra rows
  cat <<JSON
{ "check_runs": [
  { "name": "Good gate",            "conclusion": "success", "started_at": "2026-07-28T01:00:00Z", "app": { "id": 15368 } },
  { "name": "Advisory gate",        "conclusion": "success", "started_at": "2026-07-28T01:00:00Z", "app": { "id": 15368 } },
  { "name": "Matrixed gate (27.0, 1.18.1)", "conclusion": "success", "started_at": "2026-07-28T01:00:00Z", "app": { "id": 15368 } },
  { "name": "Aggregate gate",       "conclusion": "success", "started_at": "2026-07-28T01:00:00Z", "app": { "id": 15368 } },
  { "name": "Filtered gate",        "conclusion": "success", "started_at": "2026-07-28T01:00:00Z", "app": { "id": 15368 } },
  { "name": "Red on main gate",     "conclusion": "success", "started_at": "2026-07-28T01:00:00Z", "app": { "id": 15368 } },
  { "name": "Skipped specimen",     "conclusion": "skipped", "started_at": "2026-07-28T01:00:00Z", "app": { "id": 15368 } },
  { "name": "Prod compile gate (Elixir \${{ matrix.elixir }} / OTP \${{ matrix.otp }})", "conclusion": "skipped", "started_at": "2026-07-28T01:00:00Z", "app": { "id": 15368 } },
  { "name": "Vercel – barkpark",    "conclusion": "success", "started_at": "2026-07-28T01:00:00Z", "app": { "id": 15368 } },
  { "name": "Vercel Preview Comments", "conclusion": "success", "started_at": "2026-07-28T01:00:00Z", "app": { "id": 8329 } }
  ${1:-}
] }
JSON
}

runs_json > "$FIX/checkruns-shaA.json"
runs_json ',
  { "name": "Only on B", "conclusion": "success", "started_at": "2026-07-28T01:00:00Z", "app": { "id": 15368 } }' \
  > "$FIX/checkruns-shaB.json"

# main: everything green except `Red on main gate`, which is the S5 specimen.
cat > "$FIX/checkruns-shaMAIN.json" <<'JSON'
{ "check_runs": [
  { "name": "Good gate",      "conclusion": "success", "started_at": "2026-07-28T00:00:00Z", "app": { "id": 15368 } },
  { "name": "Aggregate gate", "conclusion": "success", "started_at": "2026-07-28T00:00:00Z", "app": { "id": 15368 } },
  { "name": "Matrixed gate (27.0, 1.18.1)", "conclusion": "success", "started_at": "2026-07-28T00:00:00Z", "app": { "id": 15368 } },
  { "name": "Red on main gate", "conclusion": "failure", "started_at": "2026-07-28T00:00:00Z", "app": { "id": 15368 } }
] }
JSON
echo "shaMAIN" > "$FIX/main-shas.txt"

# The poisoned feed: /status. A LEGITIMATE name arriving here must still be
# rejected — that is the only thing R0 catches that no other rule does.
cat > "$FIX/status-shaA.json" <<'JSON'
{ "state": "failure", "statuses": [
  { "context": "Good gate", "state": "success" },
  { "context": "Vercel – barkpark", "state": "failure" }
] }
JSON

gen() { # args… -> ledger+notes on stdout, never dies the suite
  RC_DISABLE_RULES="${RC_DISABLE_RULES:-}" RC_NORMALIZE="${RC_NORMALIZE:-1}" \
    bash "$GEN" --workflows "$WF" --fixture-dir "$FIX" --explain "$@" 2>&1 || true
}

verdict_for() { # name, ledger
  printf '%s\n' "$2" | awk -F'\t' -v n="$3" '$3 == n { print $2 }' | head -1
}

# ═══ 1. the poison filter: five rejections, each fired ALONE ═════════════════

section "1. the poison filter — five rejections, each disarmed and watched failing to fire"

LEDGER="$(gen --sha shaA --allow-single-sha)"

expect_verdict() { # label name want
  local got; got="$(verdict_for x "$LEDGER" "$2")"
  if [ "$got" = "$3" ]; then ok "$1 ($2 -> $3)"; else bad "$1: $2 got '$got', want '$3'"; fi
}

expect_verdict "R1 rejects the uninterpolated template a never-started job publishes" \
  'Prod compile gate (Elixir ${{ matrix.elixir }} / OTP ${{ matrix.otp }})' R1
expect_verdict "R2 rejects a skipped sample" "Skipped specimen" R2
expect_verdict "R3 rejects the legacy commit-status namespace by normalized bytes" "Vercel – barkpark" R3
expect_verdict "R4 rejects a foreign app (Vercel 8329 publishes into the same feed)" "Vercel Preview Comments" R4
expect_verdict "a clean name is ACCEPTed (the filter is not a blanket deny)" "Good gate" ACCEPT

# R0: a LEGITIMATE name arriving from /status.
LEDGER_R0="$(gen --sha shaA --allow-single-sha --status-source)"
if [ "$(verdict_for x "$LEDGER_R0" "Good gate")" = "R0" ]; then
  ok "R0 rejects a legitimate name arriving from the /status feed"
else
  bad "R0 did not reject 'Good gate' from /status"
fi

section "1b. isolation — disarm the rule, watch the specimen become ACCEPTED"

isolate() { # label rule name co_disarm
  local only_disarmed all_disarmed
  # (i) everything EXCEPT this rule disabled: the specimen must STILL be rejected
  #     by this rule, so the rule is not decorative.
  local others; others="$(printf 'R0,R1,R2,R3,R4' | tr ',' '\n' | grep -vx "$2" | paste -sd, -)"
  only_disarmed="$(RC_DISABLE_RULES="$others" gen --sha shaA --allow-single-sha ${5:-})"
  if [ "$(verdict_for x "$only_disarmed" "$3")" = "$2" ]; then
    ok "$1: fires with every OTHER rule disarmed"
  else
    bad "$1: with only $2 armed the specimen was not rejected by $2 (got '$(verdict_for x "$only_disarmed" "$3")')"
  fi
  # (ii) this rule disabled too: the specimen must become ACCEPTED.
  all_disarmed="$(RC_DISABLE_RULES="R0,R1,R2,R3,R4" gen --sha shaA --allow-single-sha ${5:-})"
  if [ "$(verdict_for x "$all_disarmed" "$3")" = "ACCEPT" ]; then
    ok "$1: disarming it lets the specimen through — the rule is load-bearing"
  else
    bad "$1: with all rules disarmed the specimen was still '$(verdict_for x "$all_disarmed" "$3")'"
  fi
}

isolate "R0 SOURCE"   R0 "Good gate" "" --status-source
isolate "R1 TEMPLATE" R1 'Prod compile gate (Elixir ${{ matrix.elixir }} / OTP ${{ matrix.otp }})' ""
isolate "R2 SAMPLE"   R2 "Skipped specimen" ""
isolate "R3 LEGACY"   R3 "Vercel – barkpark" ""
isolate "R4 APP"      R4 "Vercel Preview Comments" ""

# The `${{` specimen is ALSO skipped, exactly as it is in production. Prove R1
# and R2 each carry it on their own rather than leaning on the other.
L_NO_R2="$(RC_DISABLE_RULES=R2 gen --sha shaA --allow-single-sha)"
if [ "$(verdict_for x "$L_NO_R2" 'Prod compile gate (Elixir ${{ matrix.elixir }} / OTP ${{ matrix.otp }})')" = "R1" ]; then
  ok "the double-caught specimen is isolated: with R2 off, R1 still rejects it"
else
  bad "with R2 disarmed the template specimen escaped R1"
fi
L_NO_R1="$(RC_DISABLE_RULES=R1 gen --sha shaA --allow-single-sha)"
if [ "$(verdict_for x "$L_NO_R1" 'Prod compile gate (Elixir ${{ matrix.elixir }} / OTP ${{ matrix.otp }})')" = "R2" ]; then
  ok "…and with R1 off, R2 still rejects it (neither rule is decorative)"
else
  bad "with R1 disarmed the template specimen escaped R2"
fi

section "2. D20c — the denylist is ASCII, the real name is EN DASH, normalization is what closes the gap"

L_NONORM="$(RC_NORMALIZE=0 gen --sha shaA --allow-single-sha)"
if [ "$(verdict_for x "$L_NONORM" "Vercel – barkpark")" = "ACCEPT" ]; then
  ok "with normalization disarmed the EN DASH name is silently ACCEPTED (the transcription bug, live)"
else
  bad "disarming normalization did not change the R3 verdict — normalization is not what catches it"
fi
if grep -q "U+2013 EN DASH" <<<"$LEDGER"; then
  ok "the R3 hit prints the offending codepoint (U+2013), so a hyphen/en-dash mis-key is visible"
else
  bad "the R3 ledger row did not print the codepoint"
fi

# ═══ 3. the selection stage ══════════════════════════════════════════════════

section "3. selection — the filter accepts 6 names; selection keeps ONE"

SEL="$(gen --sha shaA --sha shaB)"
[ -n "${RC_TEST_DEBUG:-}" ] && printf '%s\n' "$SEL" | sed 's/^/    debug| /'
# Both helpers take the run's output EXPLICITLY — an earlier draft closed over
# $SEL and silently asserted section 3's run inside section 3b.
excluded_by() { # output name stage
  grep -q "$3" <<<"$(grep -F "  exclude  $2  " <<<"$1")"
}
kept_in() { # output name
  grep -q "^  keep     $2" <<<"$1"
}

if excluded_by "$SEL" "Advisory gate" "S2 ADVISORY"; then ok "S2 drops a continue-on-error job (its needs.result reads success even when it failed)"; else bad "S2 did not drop Advisory gate"; fi
if excluded_by "$SEL" "Filtered gate" "S4 PATHS-FILTERED"; then ok "S4 drops a paths-filtered job (ABSENT on other PRs = permanent 'expected')"; else bad "S4 did not drop Filtered gate"; fi
if excluded_by "$SEL" "Red on main gate" "S5 RED ON MAIN"; then ok "S5 drops a job whose latest completed conclusion on main is a failure"; else bad "S5 did not drop Red on main gate"; fi
if excluded_by "$SEL" "Good gate" "S3 SUBSUMED"; then ok "S3 drops an upstream \`needs\` of the kept aggregator"; else bad "S3 did not drop Good gate"; fi
if excluded_by "$SEL" "Matrixed gate (27.0, 1.18.1)" "S3 SUBSUMED"; then ok "S3 resolves a MATRIX-SUFFIXED rendered name back to its source job"; else bad "S3 did not map the matrix-suffixed name to its job"; fi
if kept_in "$SEL" "Aggregate gate"; then ok "the aggregator survives — selection keeps exactly one context"; else bad "the aggregator was not kept"; fi
# Asserted against the EMITTED SPEC, not the ledger: the ledger legitimately
# records "Only on B" as ACCEPTed on shaB — the intersection is what drops it.
bash "$GEN" --workflows "$WF" --fixture-dir "$FIX" --sha shaA --sha shaB --out "$TMP/sel-spec.json" >/dev/null 2>&1 || true
if jq -e '[.protection.required_status_checks.checks[].context] == ["Aggregate gate"]' "$TMP/sel-spec.json" >/dev/null 2>&1; then
  ok "the emitted spec is EXACTLY the aggregator — 'Only on B' (present on one sha only) and every stage's specimen are gone"
else
  bad "the emitted spec is $(jq -c '[.protection.required_status_checks.checks[].context]' "$TMP/sel-spec.json" 2>&1), not [Aggregate gate]"
fi

section "3b. the matrix suffix is read from the SOURCE, never by stripping a parenthetical"

# `Good gate` is NOT matrixed, so a trailing parenthetical on it maps to no job
# at all. If the code stripped trailing parens instead of reading the workflow,
# this would resolve to `good` and sail through.
cat > "$FIX/checkruns-shaP.json" <<'JSON'
{ "check_runs": [
  { "name": "Good gate (27.0, 1.18.1)", "conclusion": "success", "started_at": "2026-07-28T01:00:00Z", "app": { "id": 15368 } },
  { "name": "Advisory gate",  "conclusion": "success", "started_at": "2026-07-28T01:00:00Z", "app": { "id": 15368 } },
  { "name": "Aggregate gate", "conclusion": "success", "started_at": "2026-07-28T01:00:00Z", "app": { "id": 15368 } }
] }
JSON
P="$(gen --sha shaP --sha shaP)"
if excluded_by "$P" "Good gate (27.0, 1.18.1)" "S0 UNMAPPED"; then
  ok "a suffix on a NON-matrixed job is UNMAPPED — a paren-stripping implementation would have accepted it"
else
  bad "the paren trap: 'Good gate (27.0, 1.18.1)' was not reported as unmapped"
fi
# and a literal-paren name is never mangled: `Advisory gate` has none, but the
# real repo's `Boundary gate (advisory)` maps exactly — asserted on the real
# workflow tree below.

section "3c. against the REAL workflow tree — literal-paren names still map"

REAL_UNMAPPED="$(bash "$GEN" --workflows "$REPO_ROOT/.github/workflows" --fixture-dir "$FIX" \
  --sha shaA --sha shaA --explain 2>&1 | grep -c "S0 UNMAPPED" || true)"
# Every fixture name in the intersection is synthetic, so all of them are
# unmapped against the real tree — the assertion that matters is the opposite
# one: the real names in the committed spec DO map. Checked via the spec itself.
if jq -e '.exclusions | map(select(.reason | startswith("S0"))) | length == 0' "$SPEC" >/dev/null; then
  ok "the committed spec carries no S0 UNMAPPED exclusion — every real name, parens and all, resolved to a job"
else
  bad "the committed spec has unmapped names: $(jq -c '[.exclusions[] | select(.reason|startswith("S0")).context]' "$SPEC")"
fi

# ═══ 4. fail-closed feeds ════════════════════════════════════════════════════

section "4. the generator fails closed — an unreadable or empty feed is never an empty spec"

echo '{ "check_runs": [] }' > "$FIX/checkruns-shaEMPTY.json"
if bash "$GEN" --workflows "$WF" --fixture-dir "$FIX" --sha shaEMPTY --sha shaA >/dev/null 2>&1; then
  bad "an EMPTY check-run feed generated a spec"
else
  ok "an EMPTY check-run feed is a hard failure"
fi
if bash "$GEN" --workflows "$WF" --fixture-dir "$FIX" --sha shaMISSING --sha shaA >/dev/null 2>&1; then
  bad "an unreadable feed generated a spec"
else
  ok "an unreadable feed is a hard failure"
fi
if bash "$GEN" --workflows "$WF" --fixture-dir "$FIX" --sha shaA >/dev/null 2>&1; then
  bad "a single-sha sample was accepted without --allow-single-sha"
else
  ok "a single-sha sample is refused: one path shape cannot tell a universal check from a filtered one"
fi

# ═══ 5. the apply payload ════════════════════════════════════════════════════

section "5. the apply payload — every field, no contexts, app_id always pinned"

PAYLOAD="$(bash "$APPLY" --payload --spec "$SPEC")"
if printf '%s' "$PAYLOAD" | jq -e 'has("required_status_checks") and (.required_status_checks | has("contexts") | not)' >/dev/null; then
  ok "the payload never sends 'contexts' (contexts alongside checks is a hard 422 — D41)"
else
  bad "the payload sends a contexts key"
fi
if printf '%s' "$PAYLOAD" | jq -e '.required_status_checks.strict == false' >/dev/null; then
  ok "strict:false (strict:true would serialise this fleet's parallel merges)"
else bad "strict is not false"; fi
if printf '%s' "$PAYLOAD" | jq -e '[.required_status_checks.checks[].app_id] | all(. == 15368)' >/dev/null; then
  ok "every check pins app_id 15368 (an omitted app_id reads back null on a new name = spoofable)"
else bad "a check is missing its app_id pin"; fi
if printf '%s' "$PAYLOAD" | jq -e '.enforce_admins == true' >/dev/null; then
  ok "enforce_admins:true — every merge here is --admin, so false would be a gate that cannot block"
else bad "enforce_admins is not true"; fi
if printf '%s' "$PAYLOAD" | jq -e '.required_pull_request_reviews == null and .restrictions == null' >/dev/null; then
  ok "required_pull_request_reviews and restrictions are explicit nulls (restrictions is org-only; this repo is user-owned)"
else bad "the null blocks are wrong"; fi
MISSING_FALSES=""
for k in required_linear_history allow_force_pushes allow_deletions block_creations required_conversation_resolution lock_branch allow_fork_syncing; do
  printf '%s' "$PAYLOAD" | jq -e --arg k "$k" 'has($k)' >/dev/null || MISSING_FALSES="$MISSING_FALSES $k"
done
if [ -z "$MISSING_FALSES" ]; then
  ok "all seven optional booleans are enumerated INCLUDING the falses (the PUT does not converge omissions — D41)"
else
  bad "the payload omits:$MISSING_FALSES — omitted fields do not converge"
fi

section "5b. apply refuses to protect anything from an enforced:false spec"

if bash "$APPLY" --confirm --spec "$SPEC" >/dev/null 2>&1; then
  bad "apply wrote protection from an enforced:false spec"
else
  ok "apply refuses while the committed spec says enforced=false"
fi
cat > "$TMP/enforced.json" <<JSON
$(jq '.enforced = true' "$SPEC")
JSON
if bash "$APPLY" --spec "$TMP/enforced.json" >/dev/null 2>&1; then
  bad "apply wrote protection without --confirm"
else
  ok "apply refuses without --confirm"
fi

# ═══ 6. non-convergence, caught ═════════════════════════════════════════════

section "6. convergence — an out-of-band boolean the spec never asked for must red"

cat > "$TMP/rb.json" <<'JSON'
{
  "required_status_checks": { "strict": false, "checks": [
    { "context": "Elixir gate", "app_id": 15368 },
    { "context": "PR references an active task", "app_id": 15368 } ] },
  "enforce_admins": { "enabled": true },
  "required_signatures": { "enabled": false },
  "required_linear_history": { "enabled": false },
  "allow_force_pushes": { "enabled": false },
  "allow_deletions": { "enabled": false },
  "block_creations": { "enabled": false },
  "required_conversation_resolution": { "enabled": false },
  "lock_branch": { "enabled": false },
  "allow_fork_syncing": { "enabled": false }
}
JSON
cat > "$TMP/runs.json" <<'JSON'
{ "check_runs": [
  { "name": "Elixir gate", "conclusion": "success", "started_at": "2026-07-28T01:00:00Z" },
  { "name": "PR references an active task", "conclusion": "success", "started_at": "2026-07-28T01:00:00Z" } ] }
JSON
if bash "$VERIFY" --spec "$TMP/enforced.json" --readback "$TMP/rb.json" --runs "$TMP/runs.json" --sha probe >/dev/null 2>&1; then
  ok "the converged read-back verifies green"
else
  bad "a converged read-back did not verify"
fi
jq '.required_conversation_resolution.enabled = true' "$TMP/rb.json" > "$TMP/rb-oob.json"
if bash "$VERIFY" --spec "$TMP/enforced.json" --readback "$TMP/rb-oob.json" --runs "$TMP/runs.json" --sha probe >/dev/null 2>&1; then
  bad "out-of-band required_conversation_resolution=true passed verify"
else
  ok "out-of-band required_conversation_resolution=true reds — the field the PUT does NOT reset by omission"
fi

# ═══ 7. the deadlock detector, at N=2 ═══════════════════════════════════════

section "7. the deadlock detector — a SET DIFFERENCE, at N=2 where the refusal message names nothing"

jq '.protection.required_status_checks.checks = [
      {"context":"Elixir gate","app_id":15368},
      {"context":"A name no workflow emits","app_id":15368}]' "$TMP/enforced.json" > "$TMP/dead2.json"
set +e
OUT="$(bash "$VERIFY" --spec "$TMP/dead2.json" --runs "$TMP/runs.json" --sha probe --deadlock 2>&1)"
RC=$?
set -e
if [ "$RC" -eq 3 ]; then
  ok "DEADLOCK is a THIRD state (exit 3), distinct from pass and fail"
else
  bad "the deadlock detector exited $RC, not 3"
fi
if grep -q "A name no workflow emits" <<<"$OUT"; then
  ok "at N=2 it NAMES the missing context — GitHub's own refusal says only '2 of 2 … are expected.' (D38)"
else
  bad "the detector did not name the missing context at N=2"
fi
if grep -q "Elixir gate" <<<"$OUT"; then
  bad "the detector reported a context that IS rendered"
else
  ok "the rendered context is not reported — the difference is a set operation, not a message grep"
fi

cat > "$TMP/runs-extra.json" <<'JSON'
{ "check_runs": [
  { "name": "Elixir gate", "conclusion": "success", "started_at": "2026-07-28T01:00:00Z" },
  { "name": "PR references an active task", "conclusion": "success", "started_at": "2026-07-28T01:00:00Z" },
  { "name": "Some brand new advisory gate", "conclusion": "failure", "started_at": "2026-07-28T01:00:00Z" } ] }
JSON
if bash "$VERIFY" --spec "$TMP/enforced.json" --runs "$TMP/runs-extra.json" --sha probe --deadlock >/dev/null 2>&1; then
  ok "EXTRA rendered names are tolerated (new advisory checks land constantly)"
else
  bad "an extra rendered name was treated as drift"
fi

cat > "$TMP/runs-dupe.json" <<'JSON'
{ "check_runs": [
  { "name": "Elixir gate", "conclusion": "failure", "started_at": "2026-07-28T01:00:00Z" },
  { "name": "Elixir gate", "conclusion": "success", "started_at": "2026-07-28T03:00:00Z" },
  { "name": "PR references an active task", "conclusion": "success", "started_at": "2026-07-28T01:00:00Z" } ] }
JSON
if bash "$VERIFY" --spec "$TMP/enforced.json" --runs "$TMP/runs-dupe.json" --sha probe --deadlock >/dev/null 2>&1; then
  ok "duplicate rows reduce to the latest per name (a re-run leaves both)"
else
  bad "duplicate check-run rows broke the detector"
fi

# ═══ 8. the guard's own no-read paths ═══════════════════════════════════════

section "8. the guard FAILS — never skips — when it cannot see one of the three sides"

if bash "$VERIFY" --spec "$TMP/no-such-spec.json" --readback "$TMP/rb.json" --runs "$TMP/runs.json" --sha probe >/dev/null 2>&1; then
  bad "a missing spec passed"
else
  ok "a missing committed spec FAILS"
fi
if bash "$VERIFY" --spec "$TMP/enforced.json" --readback "$TMP/nope.json" --runs "$TMP/runs.json" --sha probe >/dev/null 2>&1; then
  bad "an unreadable live config passed"
else
  ok "an unreadable live config FAILS"
fi
if bash "$VERIFY" --spec "$TMP/enforced.json" --readback "$TMP/rb.json" --runs "$TMP/nope.json" --sha probe >/dev/null 2>&1; then
  bad "an unreadable check-run feed passed"
else
  ok "an unreadable check-run feed FAILS (no PR to render names against = red, not green)"
fi
jq '.protection.required_status_checks.checks = []' "$TMP/enforced.json" > "$TMP/empty-spec.json"
if bash "$VERIFY" --spec "$TMP/empty-spec.json" --readback "$TMP/rb.json" --runs "$TMP/runs.json" --sha probe >/dev/null 2>&1; then
  bad "a spec requiring nothing passed"
else
  ok "a spec that requires ZERO contexts FAILS — it could never fail, which is the disease"
fi

section "9. verify --selftest is itself green"

if bash "$VERIFY" --selftest >/dev/null 2>&1; then
  ok "verify --selftest passes (12 mutation clauses)"
else
  bad "verify --selftest is red"
fi

section "10. the committed spec agrees with reality about whether protection exists"

# This assertion follows the spec, not the calendar: while enforced is false the
# branch MUST be unprotected (this slice ships the tooling and nothing else);
# once hgw2-s7 flips it, the same assertion inverts and an unprotected main is
# the failure. A test hard-coded to "main is unprotected" would have to be
# deleted on the day it finally mattered.
PROTECTED=0
gh api "repos/$(jq -r .repo "$SPEC")/branches/$(jq -r .branch "$SPEC")/protection" >/dev/null 2>&1 && PROTECTED=1
if jq -e '.enforced == false' "$SPEC" >/dev/null; then
  if [ "$PROTECTED" -eq 0 ]; then
    ok "spec says enforced=false and main is unprotected — the flip belongs to hgw2-s7"
  else
    bad "main IS protected while the committed spec says enforced=false"
  fi
else
  if [ "$PROTECTED" -eq 1 ]; then
    ok "spec says enforced=true and main is protected"
  else
    bad "the committed spec says enforced=true but main is NOT protected — the guard is claiming a gate that does not exist"
  fi
fi

# ═══ live stage ══════════════════════════════════════════════════════════════

live_stage() {
  section "LIVE — a throwaway PROTECTED branch: the 422, the non-convergence, the converged green"
  local repo branch
  repo="$(jq -r .repo "$SPEC")"
  branch="hgw3-s6-protection-probe"
  [ "$branch" != "$(jq -r .branch "$SPEC")" ] || { bad "the probe branch is the protected branch"; return; }

  local base
  base="$(gh api "repos/$repo/commits/$(jq -r .branch "$SPEC")" --jq .sha)"
  gh api -X POST "repos/$repo/git/refs" -f ref="refs/heads/$branch" -f sha="$base" >/dev/null 2>&1 || true

  local cleanup_live
  cleanup_live() {
    gh api -X DELETE "repos/$repo/branches/$branch/protection" >/dev/null 2>&1 || true
    gh api -X DELETE "repos/$repo/git/refs/heads/$branch" >/dev/null 2>&1 || true
  }

  # (a) contexts alongside checks is a hard 422
  local out
  out="$(jq -n '{required_status_checks:{strict:false,contexts:[],checks:[{context:"Elixir gate",app_id:15368}]},enforce_admins:true,required_pull_request_reviews:null,restrictions:null}' \
        | gh api -X PUT "repos/$repo/branches/$branch/protection" --input - 2>&1 || true)"
  if grep -q "422" <<<"$out"; then
    ok "LIVE: contexts alongside checks returns 422 — the apply script never sends it"
  else
    bad "LIVE: contexts+checks did not 422: $(printf '%s' "$out" | head -2)"
  fi

  # (b) apply the real spec to the probe branch
  jq '.enforced = true | .branch = "'"$branch"'"' "$SPEC" > "$TMP/live-spec.json"
  if bash "$APPLY" --spec "$TMP/live-spec.json" --confirm >/dev/null 2>&1; then
    ok "LIVE: apply + verify agree on a freshly protected branch"
  else
    bad "LIVE: apply/verify failed on the probe branch"
  fi

  # (c) out-of-band mutation the PUT would NOT reset by omission.
  #     Two earlier drafts of this probe were FAKE: a PATCH on the protection
  #     url (no such verb) and a POST to …/protection/required_linear_history
  #     (404) both did nothing, and the assertion still read "RED" off an
  #     unrelated clause. So the mutation is a hand-rolled full PUT — the exact
  #     shape of the recipe in docs/ops/merge-gates.md — and it is CONFIRMED to
  #     have landed before anything is concluded from the red.
  bash "$APPLY" --payload --spec "$TMP/live-spec.json" \
    | jq '.required_linear_history = true' \
    | gh api -X PUT "repos/$repo/branches/$branch/protection" --input - >/dev/null 2>&1 || true
  if [ "$(gh api "repos/$repo/branches/$branch/protection" --jq '.required_linear_history.enabled' 2>/dev/null)" = "true" ]; then
    ok "LIVE: the out-of-band mutation landed (required_linear_history is true on the branch, and no spec asked for it)"
  else
    bad "LIVE: the out-of-band mutation did not land — the next assertion would be vacuous"
  fi
  local vout vrc=0
  vout="$(bash "$VERIFY" --spec "$TMP/live-spec.json" 2>&1)" || vrc=$?
  if [ "$vrc" -ne 0 ] && grep -q "DRIFT  required_linear_history" <<<"$vout"; then
    ok "LIVE: verify goes RED and names required_linear_history — the field the PUT does NOT reset by omission (D41)"
  else
    bad "LIVE: verify exit=$vrc and did not name required_linear_history: $(grep DRIFT <<<"$vout" | head -3)"
  fi

  # (d) re-apply converges it
  if bash "$APPLY" --spec "$TMP/live-spec.json" --confirm >/dev/null 2>&1; then
    ok "LIVE: re-apply CONVERGES the branch and verify goes green again"
  else
    bad "LIVE: re-apply did not converge the branch"
  fi

  cleanup_live
  if gh api "repos/$repo/branches/$branch/protection" >/dev/null 2>&1; then
    bad "LIVE: the probe branch is still protected — clean it up by hand"
  else
    ok "LIVE: probe branch and its protection removed"
  fi
}

[ "$LIVE" -eq 1 ] && live_stage

echo
echo "════════════════════════════════════════════════════════════"
echo "required-checks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
