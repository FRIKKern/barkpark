#!/usr/bin/env bash
# required-checks.test.sh — the mutation proofs for the required-check toolchain.
#
# The rule of this epic is that a guard which cannot be shown to FAIL has not
# been shown to work. So nothing here asserts "the script ran". Every rejection
# is disarmed and the specimen watched turning ACCEPTED; every selection stage is
# removed and the name watched surviving; every verify clause is corrupted one
# field at a time.
#
#   scripts/required-checks.test.sh --hermetic  # no network, no credentials,
#                                               #   no writes — the BLOCKING run
#   scripts/required-checks.test.sh             # + §10/§11: READ-ONLY calls to
#                                               #   the GitHub API (needs a token
#                                               #   with admin on this repo)
#   scripts/required-checks.test.sh --live      # + a throwaway PROTECTED branch:
#                                               #   the contexts+checks 422, the
#                                               #   non-convergence red, and the
#                                               #   converged green, for real
#
# THREE STAGES, AND THE DEFAULT IS NOT THE HERMETIC ONE (wave 10)
#
# The header of this file used to claim the bare run was "hermetic, no network,
# no writes". It was not, and had not been for some time: §10 makes one admin
# protection read and §11 makes three bare full-mode `verify` runs, each of which
# reads live branch protection. Measured with a `gh` shim on PATH that exits 1
# (note that `env -u GH_TOKEN -u GITHUB_TOKEN` does NOT deauthenticate gh — the
# credential lives in the keyring), the bare run is 72 passed / 3 FAILED with
# nothing wrong with the repo at all. So the claim is retired and replaced by a
# FLAG: `--hermetic` (or `RC_HERMETIC=1`) skips exactly §10 and §11's three
# API clauses and nothing else, and that is the run CI blocks on.
#
# The remaining stages are additive, never alternative: `--live` implies the API
# stage, and neither can be reached from `--hermetic`.
#
# --live mutates a throwaway branch in the repo (never main; it refuses) and
# cleans up after itself.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$REPO_ROOT/scripts/required-checks-generate.sh"
APPLY="$REPO_ROOT/scripts/required-checks-apply.sh"
VERIFY="$REPO_ROOT/scripts/required-checks-verify.sh"
SPEC="$REPO_ROOT/.github/required-checks.json"

LIVE=0
# `--hermetic` gates the API stage the way `--live` gates the branch stage: a
# named flag on a named function, never a line range. A line range rots the next
# time anyone adds a section above it, and the whole point of this file is that a
# guard which cannot be shown to fail has not been shown to work.
HERMETIC="${RC_HERMETIC:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --live)     LIVE=1; shift ;;
    --hermetic) HERMETIC=1; shift ;;
    -h|--help)  awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done
if [ "$LIVE" -eq 1 ] && [ "$HERMETIC" -eq 1 ]; then
  echo "--hermetic and --live are contradictory: --live is the API stage plus a branch write" >&2
  exit 2
fi

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
    bash "$GEN" --workflows "$WF" --fixture-dir "$FIX" --no-merge --explain "$@" 2>&1 || true
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
bash "$GEN" --workflows "$WF" --fixture-dir "$FIX" --no-merge --sha shaA --sha shaB --out "$TMP/sel-spec.json" >/dev/null 2>&1 || true
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

REAL_UNMAPPED="$(bash "$GEN" --workflows "$REPO_ROOT/.github/workflows" --fixture-dir "$FIX" --no-merge \
  --sha shaA --sha shaA --explain 2>&1 | grep -c "S0 UNMAPPED" || true)"
# Every fixture name in the intersection is synthetic, so all of them are
# unmapped against the real tree — the assertion that matters is the opposite
# one: the real names in the committed spec DO map. Checked via the spec itself.
if jq -e '.exclusions | map(select(.reason | startswith("S0"))) | length == 0' "$SPEC" >/dev/null; then
  ok "the committed spec carries no S0 UNMAPPED exclusion — every real name, parens and all, resolved to a job"
else
  bad "the committed spec has unmapped names: $(jq -c '[.exclusions[] | select(.reason|startswith("S0")).context]' "$SPEC")"
fi

section "3d. a job named after an INPUT is a catch-all — the generator refuses it instead of letting it claim every name"

# THE SPECIMEN, and it was live in this repo: .github/workflows/cp-ops.yml
# declared `jobs.run.name: ${{ inputs.operation }}`. tmpl_to_regex turns that
# into `^.+$`, job_for_name returns the FIRST match in sort order, and cp-ops
# sorts ahead of doc-gates / elixir / pr-task-gate / reland-check — so every one
# of their names was attributed to cp-ops's job and handed ITS provenance
# (coe=0, pf=0, needs=""). That erases the three fields S2/S3/S4 exclude on, and
# the run emitted SIX contexts at exit 0 including a PATHS-FILTERED name, which
# would have deadlocked main with a permanent "is expected."
#
# The harness could not see it: this fixture dir is hermetic and never reads
# .github/workflows/. So the specimen is planted HERE, and the real tree is
# asserted separately below.
cat > "$WF/poison.yml" <<'YAML'
name: poison
on:
  workflow_dispatch:
    inputs:
      operation:
        type: choice
        options:
          - alpha
jobs:
  run:
    name: ${{ inputs.operation }}
    runs-on: ubuntu-latest
YAML
# `poison.yml` sorts ahead of probe.yml and red.yml, exactly as cp-ops.yml sorted
# ahead of the workflows it hijacked — so a first-match implementation loses.
POISON_OUT="$(bash "$GEN" --workflows "$WF" --fixture-dir "$FIX" --no-merge --sha shaA --sha shaB 2>&1)" && POISON_RC=0 || POISON_RC=$?
if [ "$POISON_RC" -ne 0 ] && grep -q "CATCH-ALL JOB NAME: poison.yml job 'run'" <<<"$POISON_OUT"; then
  ok "the generator REFUSES a catch-all job name and names the file and the job (exit $POISON_RC)"
else
  bad "the catch-all was not refused (exit $POISON_RC): $(head -2 <<<"$POISON_OUT")"
fi

# MUTATION PROOF. Remove the guard's CALL — one line, and the refusal is the
# only thing that goes — and the poison must come back: the run goes green and
# the advisory specimen S2 exists to catch is silently PROMOTED, because its
# continue-on-error provenance now belongs to poison.yml's job.
NOGUARD="$TMP/gen-noguard.sh"
sed -E 's/^( *)assert_no_catchall_job_names "\$idx"/\1: # GUARD REMOVED/' "$GEN" > "$NOGUARD"
if ! grep -q 'GUARD REMOVED' "$NOGUARD"; then
  bad "the mutation did not apply — the guard call is no longer on its own line, so the proof below is vacuous"
else
  ok "the mutation applies: the guard's call site is removed from a copy of the generator"
fi
NG_OUT="$(bash "$NOGUARD" --workflows "$WF" --fixture-dir "$FIX" --no-merge --sha shaA --sha shaB --explain --out "$TMP/poison-spec.json" 2>&1)" && NG_RC=0 || NG_RC=$?
if [ "$NG_RC" -eq 0 ] && grep -q "keep     Advisory gate  (poison.yml job 'run')" <<<"$NG_OUT"; then
  ok "…and without the guard the run goes GREEN and misattributes 'Advisory gate' to poison.yml — S2 is erased, the promotion is live (mutation-proven able to fail)"
else
  bad "the unguarded run did not reproduce the poison (exit $NG_RC): $(grep -E '  (keep|exclude) ' <<<"$NG_OUT" | head -3)"
fi
if [ -f "$TMP/poison-spec.json" ] && jq -e '[.protection.required_status_checks.checks[].context] | index("Advisory gate")' "$TMP/poison-spec.json" >/dev/null 2>&1; then
  ok "…and the unguarded SPEC really pins the advisory name (the promotion reaches the file that would be PUT, not just the ledger)"
else
  bad "the unguarded spec did not carry 'Advisory gate': $(jq -c '[.protection.required_status_checks.checks[].context]' "$TMP/poison-spec.json" 2>&1)"
fi
rm -f "$WF/poison.yml" "$TMP/poison-spec.json"

# The guard must not be a blanket ban on interpolation: a PARTIAL template is
# how every matrixed job in this repo is named, and refusing those would make
# the generator unusable rather than trustworthy.
cat > "$WF/partial.yml" <<'YAML'
name: partial
on:
  pull_request:
jobs:
  part:
    name: Partial ${{ matrix.otp }} gate
    runs-on: ubuntu-latest
YAML
PART_OUT="$(bash "$GEN" --workflows "$WF" --fixture-dir "$FIX" --no-merge --sha shaA --sha shaB 2>&1)" && PART_RC=0 || PART_RC=$?
if [ "$PART_RC" -eq 0 ] && ! grep -q "CATCH-ALL" <<<"$PART_OUT"; then
  ok "a PARTIAL interpolation (\`Partial \${{ matrix.otp }} gate\`) is NOT refused — the guard bans catch-alls, not templates"
else
  bad "the guard refused a partial template (exit $PART_RC): $(grep CATCH-ALL <<<"$PART_OUT" | head -1)"
fi
rm -f "$WF/partial.yml"

# THE REAL TREE. The hermetic specimen proves the guard fires; this proves the
# repo it protects is actually clean — the assertion that would have caught
# cp-ops.yml on the day it landed.
REAL_OUT="$(bash "$GEN" --workflows "$REPO_ROOT/.github/workflows" --fixture-dir "$FIX" --no-merge \
  --sha shaA --sha shaA --allow-single-sha 2>&1)" || true
if ! grep -q "CATCH-ALL JOB NAME" <<<"$REAL_OUT"; then
  ok "no job in .github/workflows/ carries a catch-all name — the real tree the generator reads in anger is clean"
else
  bad "a real workflow carries a catch-all job name: $(grep -o "CATCH-ALL JOB NAME: [^,]*" <<<"$REAL_OUT" | head -1)"
fi

# …AND THAT SILENCE HAS TO MEAN SOMETHING. The assertion above passes on the
# ABSENCE of a string, so it also passes when the generator dies before the scan
# ever reaches the real tree — an unrelated early `die`, a renamed flag, a broken
# fixture dir. That is the vacuous-green shape this epic exists to remove, so the
# same invocation over a COPY of the real tree, with one catch-all planted in it,
# must REFUSE. Clean + able-to-fail together are the claim; neither alone is.
REALCOPY="$TMP/real-workflows"
mkdir -p "$REALCOPY"
cp "$REPO_ROOT"/.github/workflows/*.yml "$REALCOPY/"
cat > "$REALCOPY/aaa-planted-poison.yml" <<'YAML'
name: planted
on:
  workflow_dispatch:
    inputs:
      operation:
        type: string
jobs:
  run:
    name: ${{ inputs.operation }}
    runs-on: ubuntu-latest
YAML
PLANT_OUT="$(bash "$GEN" --workflows "$REALCOPY" --fixture-dir "$FIX" --no-merge \
  --sha shaA --sha shaA --allow-single-sha 2>&1)" && PLANT_RC=0 || PLANT_RC=$?
if [ "$PLANT_RC" -ne 0 ] && grep -q "CATCH-ALL JOB NAME: aaa-planted-poison.yml job 'run'" <<<"$PLANT_OUT"; then
  ok "…and the identical invocation over a COPY of the real tree with one catch-all planted REFUSES — the clean verdict above is a read, not a silence"
else
  bad "the real-tree scan could not be made to fail (exit $PLANT_RC): $(head -2 <<<"$PLANT_OUT")"
fi
rm -rf "$REALCOPY"

section "3e. S5 reads the NEWEST head in the main window, not the oldest"

# THE SPECIMEN: a name that was RED on main ten commits ago and has been GREEN
# ever since — which is what every freshly-fixed aggregator looks like on the day
# somebody wants to require it. `main_conclusions()` appends one row per (sha,
# name) in the order the shas arrive and `GET /commits` returns them NEWEST
# FIRST, so the FIRST row is the latest head. S5 took `tail -1` — the OLDEST head
# in the window — while its own comment said "latest COMPLETED conclusion" and
# the string it printed said the same. The two orderings disagree on exactly this
# fixture, and the disagreement excludes the name.
#
# Every other fixture in this file supplies ONE main sha, where head and tail are
# the same row; that is why the defect survived a suite this adversarial.
S5W="$TMP/s5-workflows"
S5F="$TMP/s5-fixtures"
mkdir -p "$S5W" "$S5F"
cat > "$S5W/cloud.yml" <<'YAML'
name: cloud
on:
  pull_request:
jobs:
  gate:
    name: Cloud gate
    runs-on: ubuntu-latest
YAML
# Two PR heads (the intersection needs two path shapes), both rendering it green.
for s in s5A s5B; do
  cat > "$S5F/checkruns-$s.json" <<'JSON'
{ "check_runs": [
  { "name": "Cloud gate", "conclusion": "success", "started_at": "2026-07-28T01:00:00Z", "app": { "id": 15368 } }
] }
JSON
done
# main window, NEWEST FIRST: the tip is green, the tail of the window is the old
# failure. head -1 -> success (keep); tail -1 -> failure (S5 RED ON MAIN).
printf 's5MAINnew\ns5MAINold\n' > "$S5F/main-shas.txt"
cat > "$S5F/checkruns-s5MAINnew.json" <<'JSON'
{ "check_runs": [
  { "name": "Cloud gate", "conclusion": "success", "started_at": "2026-07-29T00:00:00Z", "app": { "id": 15368 } }
] }
JSON
cat > "$S5F/checkruns-s5MAINold.json" <<'JSON'
{ "check_runs": [
  { "name": "Cloud gate", "conclusion": "failure", "started_at": "2026-07-20T00:00:00Z", "app": { "id": 15368 } }
] }
JSON

S5_OUT="$(bash "$GEN" --workflows "$S5W" --fixture-dir "$S5F" --no-merge --sha s5A --sha s5B --explain 2>&1 || true)"
if kept_in "$S5_OUT" "Cloud gate"; then
  ok "S5 keeps a name whose NEWEST main head is green (the old failure is out of date, not disqualifying)"
else
  bad "S5 excluded a name that is green on the newest main head: $(grep -E '  (keep|exclude) ' <<<"$S5_OUT" | head -2)"
fi

# MUTATION PROOF, and it is the whole point: put the ordering back the way it
# was, on a COPY, and the identical fixtures must exclude the name. Without this
# the assertion above passes on any implementation that happens to be green.
S5REG="$TMP/gen-s5-oldest.sh"
# `{ print $2; exit }` (first match wins) -> `{ v = $2 } END { print v }` (last
# match wins). Same awk program, same fields, opposite end of the window.
sed 's/{ print \$2; exit }/{ v = $2 } END { print v }/' "$GEN" > "$S5REG"
if ! grep -q 'END { print v }' "$S5REG"; then
  bad "the S5 ordering mutation did not apply — the awk clause moved, so the proof below is vacuous"
else
  ok "the S5 ordering mutation applies: a copy of the generator reads the OLDEST row again"
fi
S5_REG_OUT="$(bash "$S5REG" --workflows "$S5W" --fixture-dir "$S5F" --no-merge --sha s5A --sha s5B --explain 2>&1 || true)"
if excluded_by "$S5_REG_OUT" "Cloud gate" "S5 RED ON MAIN"; then
  ok "…and the OLDEST-row reading excludes it as 'S5 RED ON MAIN' — the ordering is load-bearing, and it is exactly the name wave 10 wants to register"
else
  bad "the regressed ordering did not exclude 'Cloud gate' — the fixture no longer discriminates: $(grep -E '  (keep|exclude) ' <<<"$S5_REG_OUT" | head -2)"
fi

# ═══ 4. fail-closed feeds ════════════════════════════════════════════════════

section "4. the generator fails closed — an unreadable or empty feed is never an empty spec"

echo '{ "check_runs": [] }' > "$FIX/checkruns-shaEMPTY.json"
if bash "$GEN" --workflows "$WF" --fixture-dir "$FIX" --no-merge --sha shaEMPTY --sha shaA >/dev/null 2>&1; then
  bad "an EMPTY check-run feed generated a spec"
else
  ok "an EMPTY check-run feed is a hard failure"
fi
if bash "$GEN" --workflows "$WF" --fixture-dir "$FIX" --no-merge --sha shaMISSING --sha shaA >/dev/null 2>&1; then
  bad "an unreadable feed generated a spec"
else
  ok "an unreadable feed is a hard failure"
fi
if bash "$GEN" --workflows "$WF" --fixture-dir "$FIX" --no-merge --sha shaA >/dev/null 2>&1; then
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
  ok "enforce_admins:true — an admin bypass would skip the required set entirely, so false is a gate that cannot block (the fleet merges with scripts/bp-merge.sh)"
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

# THE SPECIMEN IS DISARMED EXPLICITLY, never borrowed from $SPEC (same class as
# the D77 defect in section 11). While the committed spec said `enforced:false`,
# passing $SPEC here was a safe refusal probe. The moment hgw2-s7 commits
# `enforced: true` the identical line becomes `apply --confirm` against the REAL
# spec — a live branch-protection PUT on main, executed by the test harness, on
# every CI run, and then reported as a FAILURE because it succeeded. A guard
# whose disarmed specimen is whatever the repo currently commits is not a
# specimen at all.
DISARMED="$TMP/enforced-false.json"
jq '.enforced = false' "$SPEC" > "$DISARMED"
if bash "$APPLY" --confirm --spec "$DISARMED" >/dev/null 2>&1; then
  bad "apply wrote protection from an enforced:false spec"
else
  ok "apply refuses a spec that says enforced=false, even with --confirm"
fi
cat > "$TMP/enforced.json" <<JSON
$(jq '.enforced = true' "$SPEC")
JSON
if bash "$APPLY" --spec "$TMP/enforced.json" >/dev/null 2>&1; then
  bad "apply wrote protection without --confirm"
else
  ok "apply refuses without --confirm"
fi

section "5c. apply runs the FLOOR before the PUT — a shrink never reaches the API"

# The floor script has existed since #6926 and, until this wave, was called by
# NOTHING: `grep -rn required-checks-floor .github/` returned no workflow hit and
# apply.sh never mentioned it. So the only brake on a spec that silently drops a
# required name was the `enforced=false` refusal — which a human regenerating and
# flipping the flag in one PR satisfies while the loss rides along.
#
# HERMETIC: driven through `--floor-reference`, exactly as §12 drives the floor
# itself through `--reference`, so this needs no remote ref in a depth-1 checkout.
# The DEFAULT (git) reference is asserted by reading the source, below.
APPLY_REF="$TMP/apply-floor-ref.json"
jq '{protection: {required_status_checks: {strict: false, checks: [
      {context: "Elixir gate", app_id: 15368},
      {context: "PR references an active task", app_id: 15368}]}}}' -n > "$APPLY_REF"

# (a) LOSS. `Elixir gate` dropped, protection enforced, --confirm given: every
#     pre-existing refusal is satisfied and only the floor stands in the way.
jq '.enforced = true
    | .protection.required_status_checks.checks = [{context: "PR references an active task", app_id: 15368}]' \
  "$SPEC" > "$TMP/apply-shrunk.json"
AOUT="$(bash "$APPLY" --confirm --spec "$TMP/apply-shrunk.json" --floor-reference "$APPLY_REF" 2>&1)" && ARC=0 || ARC=$?
if [ "$ARC" -ne 0 ] && grep -q "FLOOR BREACH" <<<"$AOUT" && grep -q "LOST  Elixir gate" <<<"$AOUT"; then
  ok "apply REFUSES a candidate that drops \`Elixir gate\` and names the lost context (FLOOR BREACH, exit $ARC) — with enforced=true and --confirm both satisfied"
else
  bad "apply did not refuse the shrink (exit $ARC): $(head -3 <<<"$AOUT")"
fi
# …and it refused BEFORE the PUT, not after it: the applying/verifying lines are
# the only two things printed on the write path, and neither appears.
if ! grep -qE "^(applying|verifying)" <<<"$AOUT"; then
  ok "…and it refused BEFORE the protection PUT (no 'applying …' line was reached)"
else
  bad "apply reached the PUT before the floor: $(grep -E '^(applying|verifying)' <<<"$AOUT" | head -1)"
fi

# (b) GROWTH is not a loss, but it is a decision: exit 2 must refuse UNLESS
#     acknowledged, and the acknowledgement must be the only way past it.
jq '.enforced = true
    | .protection.required_status_checks.checks += [{context: "Doc budgets + anchors", app_id: 15368}]' \
  "$SPEC" > "$TMP/apply-grown.json"
AOUT="$(bash "$APPLY" --confirm --spec "$TMP/apply-grown.json" --floor-reference "$APPLY_REF" 2>&1)" && ARC=0 || ARC=$?
if [ "$ARC" -ne 0 ] && grep -q "FLOOR GROWTH" <<<"$AOUT"; then
  ok "apply REFUSES unacknowledged GROWTH (a promoted name is a decision every future PR pays for)"
else
  bad "apply accepted unacknowledged growth (exit $ARC): $(head -3 <<<"$AOUT")"
fi

# MUTATION PROOF: remove the floor's CALL from a copy and the shrink must sail
# through to the PUT. Without this, (a) passes on any refusal at all.
NOFLOOR="$TMP/apply-nofloor.sh"
sed -E 's|^( *)floor_out="\$\(bash "\$REPO_ROOT/scripts/required-checks-floor.sh".*|\1floor_out=""; floor_rc=0 # FLOOR REMOVED|' "$APPLY" > "$NOFLOOR"
if ! grep -q "FLOOR REMOVED" "$NOFLOOR"; then
  bad "the floor mutation did not apply — the call is no longer on its own line, so the proof below is vacuous"
else
  ok "the mutation applies: the floor's call site is removed from a copy of apply"
fi
# `gh` is never reached in the guarded run; in the UNGUARDED one it is, so the
# PUT is aimed at a branch name that cannot exist. The assertion is that the run
# got PAST the floor, which the "applying …" line is the marker for.
NF_OUT="$(bash "$NOFLOOR" --confirm --spec "$TMP/apply-shrunk.json" --floor-reference "$APPLY_REF" \
          --branch "rc-floor-mutation-probe-does-not-exist" 2>&1)" || true
if grep -q "^applying 1 required context" <<<"$NF_OUT" && ! grep -q "FLOOR BREACH" <<<"$NF_OUT"; then
  ok "…and without the floor the SAME shrunk spec reaches the PUT — the wiring is load-bearing (mutation-proven able to fail)"
else
  bad "the unguarded apply did not reach the PUT: $(head -3 <<<"$NF_OUT")"
fi

# The floor's DEFAULT reference, in apply's own invocation: no `--reference` is
# passed unless the caller overrode it, so the floor falls back to
# `git show origin/main:.github/required-checks.json` — never the worktree copy
# the PR rewrites.
if grep -q 'required-checks-floor.sh" \${floor_args\[@\]+"\${floor_args\[@\]}"}' "$APPLY"; then
  ok "apply passes NO --reference by default, so the floor reads its reference out of git (the PR cannot be its own floor)"
else
  bad "apply hard-codes a floor reference — the candidate would be compared against the file the PR just rewrote"
fi

# ═══ 6. non-convergence, caught ═════════════════════════════════════════════

section "6. convergence — an out-of-band boolean the spec never asked for must red"

# THE FIXTURES ARE DERIVED FROM THE COMMITTED SPEC, NEVER TYPED (wave 10).
#
# Both this section and §7 used to hand-write `Elixir gate` and `PR references
# an active task` into their read-back and check-run heredocs. That was correct
# for exactly as long as the spec required those two names and no others. The
# moment a third context is registered, the typed read-back stops matching the
# spec, and this suite reports THREE failures — `a converged read-back did not
# verify`, `an extra rendered name was treated as drift`, `duplicate check-run
# rows broke the detector` — none of which is about the code under test, all of
# which land on the PR that registers the name. Measured: a 4-context spec sends
# the OFFLINE suite to 67 passed / 3 FAILED, unfixable by re-ordering anything.
#
# So the read-back mirrors $SPEC's own protection block and the rendered feed is
# built from $SPEC's own context list. The fixtures now widen with the spec.
SPEC_CONTEXTS() { jq -r '.protection.required_status_checks.checks[].context' "$SPEC"; }

jq '{
  required_status_checks: {
    strict: .protection.required_status_checks.strict,
    checks: .protection.required_status_checks.checks
  },
  enforce_admins:                   { enabled: .protection.enforce_admins },
  required_signatures:              { enabled: false },
  required_linear_history:          { enabled: .protection.required_linear_history },
  allow_force_pushes:               { enabled: .protection.allow_force_pushes },
  allow_deletions:                  { enabled: .protection.allow_deletions },
  block_creations:                  { enabled: .protection.block_creations },
  required_conversation_resolution: { enabled: .protection.required_conversation_resolution },
  lock_branch:                      { enabled: .protection.lock_branch },
  allow_fork_syncing:               { enabled: .protection.allow_fork_syncing }
}' "$SPEC" > "$TMP/rb.json"

# `runs.json`: one green rendered row per required context.
runs_from_spec() { # [jq filter applied to the rows array]
  jq -c --argjson f 0 '[ .protection.required_status_checks.checks[]
        | { name: .context, conclusion: "success", started_at: "2026-07-28T01:00:00Z" } ]
      | { check_runs: . }' "$SPEC"
}
runs_from_spec > "$TMP/runs.json"

# The derivation is only meaningful if the spec actually carries contexts, and a
# silent zero here would make every clause below vacuous.
if [ "$(SPEC_CONTEXTS | grep -c . || true)" -ge 1 ] \
   && [ "$(jq '.check_runs | length' "$TMP/runs.json")" = "$(jq '.protection.required_status_checks.checks | length' "$SPEC")" ]; then
  ok "the §6/§7 fixtures are DERIVED from the committed spec ($(jq '.protection.required_status_checks.checks | length' "$SPEC") context(s)) — registering a name widens them instead of reding them"
else
  bad "the derived fixtures do not match the committed spec's context list"
fi

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

# N=2 exactly, and the KEPT name is the spec's first context rather than a typed
# one — so the "the rendered context is not reported" assertion below still has a
# rendered name to point at whatever the spec grows to.
KEPT_CTX="$(SPEC_CONTEXTS | head -1)"
jq --arg keep "$KEPT_CTX" '.protection.required_status_checks.checks = [
      {"context":$keep,"app_id":15368},
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
if grep -qF "$KEPT_CTX" <<<"$OUT"; then
  bad "the detector reported a context that IS rendered ($KEPT_CTX)"
else
  ok "the rendered context is not reported — the difference is a set operation, not a message grep"
fi

# Every required context rendered, PLUS one name the spec never asked for.
jq -c '.check_runs += [
  { "name": "Some brand new advisory gate", "conclusion": "failure", "started_at": "2026-07-28T01:00:00Z" } ]' \
  "$TMP/runs.json" > "$TMP/runs-extra.json"
if bash "$VERIFY" --spec "$TMP/enforced.json" --runs "$TMP/runs-extra.json" --sha probe --deadlock >/dev/null 2>&1; then
  ok "EXTRA rendered names are tolerated (new advisory checks land constantly)"
else
  bad "an extra rendered name was treated as drift"
fi

# The first required context twice: an older FAILURE and a newer success, which
# is what a re-run leaves behind. Only the newest row is the truth.
jq -c --arg dupe "$KEPT_CTX" '.check_runs += [
  { "name": $dupe, "conclusion": "failure", "started_at": "2026-07-27T01:00:00Z" } ]' \
  "$TMP/runs.json" > "$TMP/runs-dupe.json"
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
  # The count is the selftest's OWN numbering (`1/16` … `16/16`), which this
  # label had drifted four clauses behind. It is also the reason drift.yml no
  # longer runs `--selftest` as a step of its own: §9 IS that home.
  ok "verify --selftest passes (16 mutation clauses)"
else
  bad "verify --selftest is red"
fi

section "11 (hermetic half). the section-11 mutation is DERIVED, not typed"

# hgw2-s7's own slice gate is the bare `scripts/required-checks-verify.sh`, so
# full mode has to be meaningful on both sides of the flip: green on whatever
# the spec commits, and RED on a spec that disagrees with the live world.
# Asserted by mutation, never by reading the code.
#
# THE MUTATION DIRECTION IS DERIVED, NOT TYPED (honest-gates D77). This section
# used to write `jq '.enforced = true'`. That was correct for exactly as long as
# the committed spec said `false`: the moment hgw2-s7 commits `enforced: true`,
# `= true` produces a file BYTE-IDENTICAL to $SPEC, and the section then asserts
# that one file both passes (first clause) and fails (second) — a permanent,
# self-contradictory red on the very PR that installs protection. `|= not`
# always yields a genuinely different spec.
#
# AND THE EXPECTATION IS ERA-AWARE, because inverting the flag is only a
# falsifiable mutation in one direction. `enforced: false` is a COMMITTED,
# reviewable state that full mode deliberately does not diff against live
# config, so post-flip the inverted (false) spec is legitimately GREEN.
# Asserting a red there would be a lie in the opposite direction. Post-flip the
# mutation that must red is a CONTENT one — a required context live protection
# does not carry — which is the same class of finding (spec disagrees with the
# world) reached through the field that still moves.
FULLMUT="$TMP/enforced-inverted.json"
jq '.enforced |= not' "$SPEC" > "$FULLMUT"
if [ "$(jq -c . "$FULLMUT")" = "$(jq -c . "$SPEC")" ]; then
  bad "the section-11 mutation is byte-identical to the committed spec — it would assert pass AND fail on one file"
else
  ok "the section-11 mutation is DERIVED (\`.enforced |= not\`) and differs from the committed spec in both eras"
fi


# ═══ the API stage — §10 and §11's three live clauses ════════════════════════
#
# EVERYTHING ABOVE THIS LINE IS HERMETIC. Everything below reads the live GitHub
# API, needs a token with ADMIN on this repo, and is therefore SKIPPED under
# --hermetic — which is the run CI blocks on. Measured with a failing `gh` shim
# on PATH: the four clauses in here are the ONLY ones that move.
api_stage() {
  section "10. the committed spec agrees with reality about whether protection exists"

  # This assertion follows the spec, not the calendar: while enforced is false the
  # branch MUST be unprotected; once the flip lands, the same assertion inverts and
  # an unprotected main is the failure. A test hard-coded to "main is unprotected"
  # would have to be deleted on the day it finally mattered.
  local protected=0
  gh api "repos/$(jq -r .repo "$SPEC")/branches/$(jq -r .branch "$SPEC")/protection" >/dev/null 2>&1 && protected=1
  if jq -e '.enforced == false' "$SPEC" >/dev/null; then
    if [ "$protected" -eq 0 ]; then
      ok "spec says enforced=false and main is unprotected — the flip belongs to hgw2-s7"
    else
      bad "main IS protected while the committed spec says enforced=false"
    fi
  else
    if [ "$protected" -eq 1 ]; then
      ok "spec says enforced=true and main is protected"
    else
      bad "the committed spec says enforced=true but main is NOT protected — the guard is claiming a gate that does not exist"
    fi
  fi

  section "11 (live half). full mode tracks the COMMITTED spec against reality"

  if bash "$VERIFY" >/dev/null 2>&1; then
    ok "full mode is green on the COMMITTED spec (enforced=$(jq -r .enforced "$SPEC")) — hgw2-s7's slice gate passes"
  else
    bad "full mode reds on the committed spec — hgw2-s7's slice gate cannot pass"
  fi

  if jq -e '.enforced == false' "$SPEC" >/dev/null; then
    if bash "$VERIFY" --spec "$FULLMUT" >/dev/null 2>&1; then
      bad "full mode PASSED with enforced=true against an unprotected main — it cannot fail"
    else
      ok "…and RED with enforced=true while main is unprotected (mutation-proven able to fail)"
    fi
  else
    # Post-flip. The flag inversion is green BY DESIGN (see above), so the
    # falsifying mutation is a context live protection does not publish.
    #
    # AND THE RED MUST BE THE RIGHT RED (wave 10). This clause used to assert
    # nothing but `verify exited non-zero`, which it does for a phantom context
    # AND for an unreadable protection API — so with the network down, or the
    # token lacking admin, it PASSED while proving nothing at all. It could not
    # tell its own claim from an outage. It now requires the phantom name to be
    # NAMED in the output, so a token-shaped red fails the clause instead of
    # satisfying it.
    local contentmut phantom cmout cmrc=0
    contentmut="$TMP/phantom-context.json"
    phantom="No workflow emits me"
    jq --arg p "$phantom" '.protection.required_status_checks.checks += [{"context":$p,"app_id":15368}]' \
      "$SPEC" > "$contentmut"
    cmout="$(bash "$VERIFY" --spec "$contentmut" 2>&1)" || cmrc=$?
    if [ "$cmrc" -eq 0 ]; then
      bad "full mode PASSED with a required context live protection does not carry — it cannot fail"
    elif grep -qF "MISSING from live: $phantom" <<<"$cmout"; then
      ok "…and RED *naming* the phantom context (mutation-proven able to fail post-flip, and proven to red for the RIGHT reason)"
    else
      bad "full mode red (exit $cmrc) without naming '$phantom' — that is an outage-shaped red, indistinguishable from the finding: $(grep -m2 -E 'FAIL|DRIFT' <<<"$cmout")"
    fi
    if bash "$VERIFY" --spec "$FULLMUT" >/dev/null 2>&1; then
      ok "…and the INVERTED flag (enforced=false) is green by design — a committed, reviewable state, never a swallowed one"
    else
      bad "full mode reds on enforced=false, which is a committed state the guard is documented to accept"
    fi
  fi
}

# ═══ 12. the superset floor ══════════════════════════════════════════════════

section "12. the cardinality floor refuses a SWAP that a count floor waves through"

FLOOR="$REPO_ROOT/scripts/required-checks-floor.sh"

# HERMETIC ON PURPOSE: the harness drives the floor through `--reference`
# fixtures. CI checks out at depth 1 and `git show origin/main:…` is not
# guaranteed to resolve there, and a harness that needs a remote ref is a
# harness CI eventually skips. The DEFAULT reference — the one that matters in
# anger — is asserted separately, below, by reading the script.
cat > "$TMP/floor-ref.json" <<'JSON'
{ "protection": { "required_status_checks": { "strict": false, "checks": [
  { "context": "Elixir gate", "app_id": 15368 },
  { "context": "PR references an active task", "app_id": 15368 }
] } } }
JSON

floor() { # candidate [extra args…] -> prints output, returns the floor's rc
  local cand="$1"; shift
  bash "$FLOOR" --reference "$TMP/floor-ref.json" "$@" "$cand" 2>&1
}

# (a) THE PASS CASE. Identical set, identical app_ids.
cp "$TMP/floor-ref.json" "$TMP/floor-same.json"
FOUT="$(floor "$TMP/floor-same.json")" && FRC=0 || FRC=$?
if [ "$FRC" -eq 0 ] && grep -q "FLOOR OK" <<<"$FOUT"; then
  ok "the floor PASSES a candidate identical to the reference (exit 0)"
else
  bad "the floor did not pass an identical candidate (exit $FRC): $(head -2 <<<"$FOUT")"
fi

# (b) THE REFUSE CASE, and it is the specimen a count floor cannot see: two
#     contexts in, two out, and the only blocking gate has been replaced by a
#     continue-on-error one.
cat > "$TMP/floor-swap.json" <<'JSON'
{ "protection": { "required_status_checks": { "strict": false, "checks": [
  { "context": "PR references an active task", "app_id": 15368 },
  { "context": "Boundary gate (advisory)", "app_id": 15368 }
] } } }
JSON
FOUT="$(floor "$TMP/floor-swap.json")" && FRC=0 || FRC=$?
if [ "$FRC" -eq 1 ] && grep -q "LOST  Elixir gate" <<<"$FOUT"; then
  ok "the floor REFUSES a same-COUNT swap and names the lost gate (exit 1) — a \`>= 2\` floor passes this specimen"
else
  bad "the floor did not refuse the swap specimen (exit $FRC): $(head -3 <<<"$FOUT")"
fi
# The count really is equal, so the assertion above is about the SET and not
# secretly about the length. Stated as an assertion so it cannot rot.
if [ "$(jq '.protection.required_status_checks.checks | length' "$TMP/floor-swap.json")" \
   = "$(jq '.protection.required_status_checks.checks | length' "$TMP/floor-ref.json")" ]; then
  ok "…and the swap specimen has the SAME cardinality as the reference (so a count floor is proven insufficient, not merely asserted)"
else
  bad "the swap specimen changed the count — it no longer proves what it claims"
fi

# (c) app_id weakening is a loss too: `null` means "any app with checks:write".
jq '.protection.required_status_checks.checks[0].app_id = null' "$TMP/floor-ref.json" > "$TMP/floor-nullapp.json"
FOUT="$(floor "$TMP/floor-nullapp.json")" && FRC=0 || FRC=$?
if [ "$FRC" -eq 1 ]; then
  ok "the floor REFUSES an app_id weakened to null (the name survives; the pin does not)"
else
  bad "the floor accepted app_id:null (exit $FRC)"
fi

# (d) growth is LOUD and non-zero-unless-acknowledged (D69).
jq '.protection.required_status_checks.checks += [{"context":"Doc budgets + anchors","app_id":15368}]' \
  "$TMP/floor-ref.json" > "$TMP/floor-grow.json"
FOUT="$(floor "$TMP/floor-grow.json")" && FRC=0 || FRC=$?
if [ "$FRC" -eq 2 ] && grep -q "ADDED  Doc budgets + anchors" <<<"$FOUT"; then
  ok "the floor exits 2 on GROWTH and names the added context (a promoted check is a decision, not a detail)"
else
  bad "growth did not exit 2 with the added name (exit $FRC): $(head -3 <<<"$FOUT")"
fi
FOUT="$(floor "$TMP/floor-grow.json" --acknowledge-growth)" && FRC=0 || FRC=$?
if [ "$FRC" -eq 0 ]; then
  ok "…and --acknowledge-growth is the ONLY way past it"
else
  bad "--acknowledge-growth did not clear the growth exit (exit $FRC)"
fi

# (e) an unreadable reference FAILS. This is the clause that keeps the floor
#     from degrading into "nothing to compare against, so pass".
FOUT="$(floor "$TMP/floor-same.json" --reference "$TMP/no-such-reference.json")" && FRC=0 || FRC=$?
if [ "$FRC" -ne 0 ]; then
  ok "an unreadable reference FAILS (never a vacuous pass)"
else
  bad "an unreadable reference passed"
fi

# (f) the DEFAULT reference is git, not the worktree — the whole reason the
#     floor is not vacuous on the PR that rewrites the spec.
if grep -q 'git -C "\$REPO_ROOT" show "\$REF_REV:\$SPEC_PATH"' "$FLOOR" \
   && grep -q 'REF_REV="origin/main"' "$FLOOR"; then
  ok "the floor's DEFAULT reference is \`git show origin/main:.github/required-checks.json\`, never the worktree copy the PR rewrites"
else
  bad "the floor no longer defaults to reading its reference out of git — it would compare the candidate to itself"
fi

# (g) and the floor lives OUTSIDE the generator and OUTSIDE verify, deliberately.
#     Inside the generator it would run against the harness fixture shape that
#     section 3 builds and refuse it; inside verify it has no second reference,
#     because verify treats the committed spec AS truth.
#     CODE ONLY, not prose: both files legitimately DISCUSS the floor in their
#     headers (the generator's emit path points at it as the brake on a silent
#     shrink), and a grep that counts a comment as a call site makes writing down
#     why something is not wired indistinguishable from wiring it.
floor_call_sites() { # [extra file…]
  { printf '%s\n' "$GEN" "$VERIFY" "$@"; } \
    | while IFS= read -r f; do sed 's/#.*//' "$f" | grep -Hn --label="$f" "required-checks-floor" || true; done
}
if [ -z "$(floor_call_sites)" ]; then
  ok "the floor is CALLED by neither the generator nor verify (it needs a second reference; those two have none)"
else
  bad "the floor has been wired into the generator or verify — see the header for why that cannot work: $(floor_call_sites | head -1)"
fi
# …and the scan can see a call. Same function, one extra file — never a second
# copy of the grep, which would prove nothing about the first.
FLOOR_CANARY="$TMP/floor-canary.sh"
printf 'bash "$REPO_ROOT/scripts/required-checks-floor.sh" "$SPEC"\n' > "$FLOOR_CANARY"
if grep -q 'floor-canary' <<<"$(floor_call_sites "$FLOOR_CANARY")"; then
  ok "…and that scan FIRES on a planted floor call (mutation-proven able to fail, not a grep that only passes)"
else
  bad "the floor call-site scan did not fire on the planted canary"
fi

# ═══ 13. the prose ratchet ═══════════════════════════════════════════════════

section "13. no in-repo prose teaches \`gh pr merge --admin\` any more"

# THE POINT: `--admin` is not forbidden, and this is not a spelling rule. Under
# `enforce_admins: true` the flag simply does nothing — the server decides — so
# prose that TEACHES it as the merge protocol sends every agent in the fleet at
# a verb that now refuses. The replacement is an artifact, and the ratchet's job
# is to keep the pointer pointing: scripts/bp-merge.sh.
#
# SCOPE, and every exemption is a measured one rather than a convenience:
#   *.md only                      — prose is the thing that teaches
#   .github/workflows/elixir.yml   — DESCRIPTIVE of the deadlock refusal
#                                    ("even `gh pr merge --admin` is refused"),
#                                    which the flip makes MORE true. Not prose,
#                                    and not scanned: this rule is `*.md`.
#   scripts/bp-merge.test.sh:114+  — the existing ratchet's own implementation.
#                                    Same reason, same non-.md scope.
#   scripts/bp-vercel-quick-setup.sh — `--admin-token`, an unrelated flag.
#   tooling/grip/ledger/**         — DATED RECORDS of what was measured on a
#                                    given day. Rewriting a record to match
#                                    today's policy is falsifying it.
#   .claude/workflows/*charter.md  — the D-entries are the measurements this
#                                    epic is made of; D17 and D40 exist
#                                    precisely to say what `--admin` did.
#
# ONE scan, driven twice. The canary run below appends an extra path to the
# SAME function rather than re-typing the grep — a mutation proof against a
# second copy of the pattern proves nothing about the first.
prose_admin_hits() { # [extra path…]
  {
    ( cd "$REPO_ROOT" && git ls-files -- '*.md' )
    printf '%s\n' "$@"
  } \
    | grep -v '^$' \
    | grep -v '^tooling/grip/ledger/' \
    | grep -v '^\.claude/workflows/.*charter\.md$' \
    | ( cd "$REPO_ROOT" && tr '\n' '\0' | xargs -0 grep -nE 'gh pr merge[^`]*--admin' 2>/dev/null ) || true
}

PROSE_HITS="$(prose_admin_hits)"
if [ -z "$PROSE_HITS" ]; then
  ok "no non-exempt *.md teaches \`gh pr merge … --admin\` — the pointer is scripts/bp-merge.sh"
else
  bad "prose still teaches the abolished verb:"
  printf '%s\n' "$PROSE_HITS" | sed 's/^/       /' >&2
fi

# MUTATION PROOF: the ratchet above is a grep, and a grep that matches nothing
# is indistinguishable from a grep that is broken. So plant the folklore in a
# file the scan actually covers and watch it fire.
RATCHET_CANARY="$TMP/ratchet-canary.md"
printf 'poll checks + `gh pr merge --squash --admin` once the gate passes\n' > "$RATCHET_CANARY"
CANARY_HITS="$(prose_admin_hits "$RATCHET_CANARY")"
if grep -q 'ratchet-canary' <<<"$CANARY_HITS"; then
  ok "…and the ratchet FIRES on a planted \`gh pr merge --squash --admin\` (mutation-proven able to fail)"
else
  bad "the ratchet did not fire on the planted canary — it is a grep that can only pass"
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

# ═══ 14/15/16. wave 11: the flip's three new guards, each mutation-proven ════
#
# THESE RUN AGAINST A SAVED FIXTURE PAIR, NOT A LIVE WINDOW, and that is the
# whole design (D130). Measured on this repo inside one hour, the generator's
# emitted count over three sampling windows was 0, then 6, then 7: three of the
# newest ten main heads carry ZERO check runs, `Elixir gate` renders on two of
# them, and the newest pair intersects to nothing at all. A test that re-samples
# live would go red on a Tuesday for reasons that have nothing to do with the
# code. So the two heads are frozen on disk, exactly as GitHub reported them.

FIXP="$REPO_ROOT/scripts/fixtures/registration-flip"
# `--merge-base "$SPEC"` is the committed spec ON PURPOSE: these two guards are
# statements ABOUT the committed spec, so a name removed from it should change
# what they assert.
FIXARGS=(--workflows "$REPO_ROOT/.github/workflows" --fixture-dir "$FIXP"
         --merge-base "$SPEC" --sha e34031104 --sha f69cfb1f6)
ACK=(--expect-unrendered "Elixir gate" --expect-unrendered "PR references an active task")

section "14. S1 LOSS — a committed name the sample did not render is refused BY NAME, before the merge can hide it"

if jq -e '[.protection.required_status_checks.checks[].context]
          | index("Elixir gate") and index("PR references an active task")' "$SPEC" >/dev/null; then
  ok "the fixture premise holds: the committed spec requires both names the fixture pair fails to render"
else
  bad "the committed spec no longer requires both fixture names — section 14 is asserting about a spec that moved"
fi

L14_OUT="$(bash "$GEN" "${FIXARGS[@]}" 2>&1)" && L14_RC=0 || L14_RC=$?
if [ "$L14_RC" -eq 1 ] \
   && grep -q "^S1 LOSS" <<<"$L14_OUT" \
   && grep -q "LOST  Elixir gate" <<<"$L14_OUT" \
   && grep -q "LOST  PR references an active task" <<<"$L14_OUT"; then
  ok "the unacknowledged run REFUSES (exit 1) and names BOTH lost contexts"
else
  bad "the loss was not refused (exit $L14_RC): $(grep -E 'LOST|S1 LOSS' <<<"$L14_OUT" | head -3)"
fi
# The two losses are not the same KIND of loss, and the refusal must say so —
# otherwise the operator's only move is to acknowledge both and hope.
if grep -q "PULL_REQUEST-ONLY" <<<"$L14_OUT" && grep -q "this window is the anomaly" <<<"$L14_OUT"; then
  ok "…and it distinguishes 'no window can ever render this' from 'THIS window is the anomaly, re-sample'"
else
  bad "the refusal did not distinguish the two causes of absence"
fi

bash "$GEN" "${FIXARGS[@]}" "${ACK[@]}" --out "$TMP/ack-spec.json" >/dev/null 2>&1 || true
if jq -e '[.protection.required_status_checks.checks[].context]
          == ["Cloud gate","Console gate","Elixir gate","PR references an active task"]' \
     "$TMP/ack-spec.json" >/dev/null 2>&1; then
  ok "…and per-NAME acknowledgement lets it through, emitting exactly the four contexts"
else
  bad "the acknowledged emit is $(jq -c '[.protection.required_status_checks.checks[].context]' "$TMP/ack-spec.json" 2>&1)"
fi

# MUTATION (i): the REFUSAL is load-bearing. Neuter its condition — one line —
# and the identical unacknowledged run must go through silently.
NOLOSS="$TMP/gen-noloss.sh"
sed 's/^    if \[ -n "\$lost_names" \]; then$/    if false; then # LOSS REFUSAL REMOVED/' "$GEN" > "$NOLOSS"
if grep -q 'LOSS REFUSAL REMOVED' "$NOLOSS"; then
  ok "the loss-refusal mutation applies: a copy of the generator no longer refuses"
else
  bad "the loss-refusal mutation did not apply — its condition moved, so the proof below is vacuous"
fi
NL_OUT="$(bash "$NOLOSS" "${FIXARGS[@]}" 2>&1)" && NL_RC=0 || NL_RC=$?
if [ "$NL_RC" -eq 0 ] && ! grep -q "^S1 LOSS" <<<"$NL_OUT"; then
  ok "…and without it the SAME sample is accepted in silence (mutation-proven able to fail)"
else
  bad "the unguarded run still refused (exit $NL_RC)"
fi

# MUTATION (ii): the MERGE is the other half, and it is separately load-bearing.
# `--no-merge` IS the pre-wave-11 emit path — `jq -n` into a pure overwrite — and
# on this very fixture pair it emits a spec that has DROPPED both committed
# names. That is the de-registration this slice exists to make impossible.
bash "$GEN" --workflows "$REPO_ROOT/.github/workflows" --fixture-dir "$FIXP" --no-merge \
  --sha e34031104 --sha f69cfb1f6 --out "$TMP/overwrite-spec.json" >/dev/null 2>&1 || true
if jq -e '[.protection.required_status_checks.checks[].context]
          | (index("Elixir gate") | not) and (index("PR references an active task") | not)' \
     "$TMP/overwrite-spec.json" >/dev/null 2>&1; then
  ok "the OVERWRITE path emits a spec MISSING both committed names — the merge, not the refusal, is what carries them"
else
  bad "the overwrite specimen did not drop the committed names: $(jq -c '[.protection.required_status_checks.checks[].context]' "$TMP/overwrite-spec.json" 2>&1)"
fi

section "15. S6 LEAF DEMOTION — an excluded aggregator takes its \`needs\` upstreams DOWN with it, never up"

S6_OUT="$(bash "$GEN" "${FIXARGS[@]}" "${ACK[@]}" --explain 2>&1 || true)"
if grep -q "exclude  Security gate  — S5 RED ON MAIN" <<<"$S6_OUT"; then
  ok "the aggregator itself is excluded S5 RED ON MAIN (the precondition the demotion hangs off)"
else
  bad "'Security gate' was not excluded as S5 RED ON MAIN — section 15's premise is gone"
fi
for leaf in "Dispatch (security paths)" "Security gate shape ratchet" \
            "Sobelow baseline does not swallow its own inline waivers (blocking)"; do
  if grep -qF "exclude  $leaf  — S6 LEAF OF AN EXCLUDED AGGREGATOR (Security gate)" <<<"$S6_OUT"; then
    ok "S6 demotes '$leaf', naming the aggregator that took it down"
  else
    bad "S6 did not demote '$leaf': $(grep -F "$leaf" <<<"$S6_OUT" | head -1)"
  fi
done

# MUTATION: remove the demotion pass and the SAME fixture must promote all three
# — S3 subsumption is computed against survivors, so with the aggregator gone its
# leaves are subsumed by nothing and sail straight into the spec.
NOS6="$TMP/gen-nos6.sh"
sed 's/^  if \[ -n "\$demoted" \]; then$/  if false; then # S6 REMOVED/' "$GEN" > "$NOS6"
if grep -q 'S6 REMOVED' "$NOS6"; then
  ok "the S6 mutation applies: a copy of the generator skips the demotion pass"
else
  bad "the S6 mutation did not apply — the pass's guard moved, so the proof below is vacuous"
fi
bash "$NOS6" "${FIXARGS[@]}" "${ACK[@]}" --out "$TMP/nos6-spec.json" >/dev/null 2>&1 || true
if jq -e '[.protection.required_status_checks.checks[].context] as $c
          | ($c | index("Dispatch (security paths)"))
            and ($c | index("Security gate shape ratchet"))
            and ($c | index("Sobelow baseline does not swallow its own inline waivers (blocking)"))' \
     "$TMP/nos6-spec.json" >/dev/null 2>&1; then
  ok "…and without S6 the identical fixture PROMOTES all three security leaves into the spec (mutation-proven able to fail)"
else
  bad "the un-demoted spec did not promote the leaves: $(jq -c '[.protection.required_status_checks.checks[].context]' "$TMP/nos6-spec.json" 2>&1)"
fi

section "16. the deadlock sweep's predicate is TWO-SIDED — a PR that is already stuck is not a casualty of the flip"

SWEEP="$REPO_ROOT/scripts/registration-deadlock-sweep.sh"
SWF="$TMP/sweep-fixtures"
mkdir -p "$SWF"
# A candidate that adds ONE synthetic name over origin/main's spec. Synthetic on
# purpose: the baseline is read from git, and no real registration can ever make
# this name stop being new, so the section cannot rot the way a real name would.
# Built from the BASELINE, not the worktree spec: the sweep's "newly proposed"
# set is candidate minus origin/main, so a candidate derived from the worktree
# would also carry whatever contexts THIS PR is adding, and the section would
# assert about those instead of about its own probe.
git -C "$REPO_ROOT" show "origin/main:.github/required-checks.json" \
  | jq '.protection.required_status_checks.checks += [{context: "Probe gate", app_id: 15368}]' \
  > "$TMP/sweep-candidate.json"
cat > "$SWF/checkruns-sweepRENDERS.json" <<'JSON'
{ "check_runs": [ { "name": "Probe gate", "conclusion": "success", "status": "completed", "started_at": "2026-07-30T01:00:00Z" } ] }
JSON
for s in sweepCLEANMISS sweepDIRTY sweepBLOCKED; do
  cat > "$SWF/checkruns-$s.json" <<'JSON'
{ "check_runs": [ { "name": "Some other check", "conclusion": "success", "status": "completed", "started_at": "2026-07-30T01:00:00Z" } ] }
JSON
done
# #3 and #4 are the FALSE ALARMS a one-sided test produces: this repo carries
# three of them today (#6086, #6057, #2907 — CONFLICTING/DIRTY, stale merge refs,
# already deadlocked on the `Elixir gate` that has been required since 2026-07-28).
cat > "$TMP/sweep-prs-safe.json" <<'JSON'
[
 {"number":1,"headRefOid":"sweepRENDERS","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","isDraft":false,"title":"renders it"},
 {"number":3,"headRefOid":"sweepDIRTY","mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","isDraft":false,"title":"already conflicting"},
 {"number":4,"headRefOid":"sweepBLOCKED","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","isDraft":false,"title":"already blocked"}
]
JSON
cat > "$TMP/sweep-prs-casualty.json" <<'JSON'
[
 {"number":1,"headRefOid":"sweepRENDERS","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","isDraft":false,"title":"renders it"},
 {"number":2,"headRefOid":"sweepCLEANMISS","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","isDraft":false,"title":"mergeable and does NOT render it"},
 {"number":3,"headRefOid":"sweepDIRTY","mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","isDraft":false,"title":"already conflicting"}
]
JSON

sweep() { bash "$SWEEP" --spec "$TMP/sweep-candidate.json" --fixture-dir "$SWF" --prs "$1" 2>&1; }

SW_SAFE="$(sweep "$TMP/sweep-prs-safe.json")" && SW_SAFE_RC=0 || SW_SAFE_RC=$?
if [ "$SW_SAFE_RC" -eq 0 ] && grep -q "NO CASUALTY" <<<"$SW_SAFE"; then
  ok "a CONFLICTING PR and an already-BLOCKED PR that do not render the new context are NOT casualties (exit 0)"
else
  bad "the sweep refused on PRs that are already stuck (exit $SW_SAFE_RC): $(grep REFUSE <<<"$SW_SAFE" | head -2)"
fi
if grep -q "^#3 .*skip" <<<"$SW_SAFE" && grep -q "^#4 .*skip" <<<"$SW_SAFE"; then
  ok "…and it says so per PR, rather than omitting them from the table"
else
  bad "the classification table did not carry #3/#4 as skips"
fi

SW_CAS="$(sweep "$TMP/sweep-prs-casualty.json")" && SW_CAS_RC=0 || SW_CAS_RC=$?
if [ "$SW_CAS_RC" -eq 1 ] && grep -q "^#2 .*REFUSE" <<<"$SW_CAS" && ! grep -q "^#3 .*REFUSE" <<<"$SW_CAS"; then
  ok "a MERGEABLE+CLEAN PR that does NOT render the new context IS a casualty (exit 1), and only it"
else
  bad "the casualty was not caught cleanly (exit $SW_CAS_RC): $(grep -E '^#' <<<"$SW_CAS" | head -4)"
fi

# UNKNOWN IS NOT A SKIP. Measured, not imagined: the first live run of this
# script came back `mergeable: UNKNOWN` on nine of nine open PRs — GitHub had
# just invalidated every answer because a PR landed — and an earlier draft
# classified all nine as `skip` and exited 0 having evaluated nothing.
cat > "$TMP/sweep-prs-unknown.json" <<'JSON'
[
 {"number":1,"headRefOid":"sweepRENDERS","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","isDraft":false,"title":"renders it"},
 {"number":9,"headRefOid":"sweepCLEANMISS","mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","isDraft":false,"title":"not computed yet"}
]
JSON
SW_UNK="$(sweep "$TMP/sweep-prs-unknown.json")" && SW_UNK_RC=0 || SW_UNK_RC=$?
if [ "$SW_UNK_RC" -eq 2 ] && grep -q "mergeability is UNKNOWN for PR(s) 9" <<<"$SW_UNK"; then
  ok "a PR whose mergeability GitHub has not computed yet exits 2 and names it — never a silent skip that greens the sweep"
else
  bad "the UNKNOWN specimen did not fail closed (exit $SW_UNK_RC): $(tail -2 <<<"$SW_UNK")"
fi

# MUTATION: drop side (A) and the sweep becomes the one-sided test — it must now
# refuse on the specimens it correctly ignored, which is what would veto the flip
# forever.
ONESIDED="$TMP/sweep-onesided.sh"
sed 's/^    if \[ "\$unblocked" -eq 0 \]; then$/    if false; then # SIDE A REMOVED/' "$SWEEP" > "$ONESIDED"
if grep -q 'SIDE A REMOVED' "$ONESIDED"; then
  ok "the two-sidedness mutation applies: a copy of the sweep no longer asks whether the PR is mergeable"
else
  bad "the two-sidedness mutation did not apply — the guard moved, so the proof below is vacuous"
fi
OS_OUT="$(RC_REPO_ROOT="$REPO_ROOT" bash "$ONESIDED" --spec "$TMP/sweep-candidate.json" \
           --fixture-dir "$SWF" --prs "$TMP/sweep-prs-safe.json" 2>&1)" && OS_RC=0 || OS_RC=$?
if [ "$OS_RC" -eq 1 ] && grep -q "^#3 .*REFUSE" <<<"$OS_OUT" && grep -q "^#4 .*REFUSE" <<<"$OS_OUT"; then
  ok "…and the one-sided version REFUSES on both already-stuck PRs — the second side is load-bearing (mutation-proven able to fail)"
else
  bad "the one-sided version did not produce the false alarms (exit $OS_RC): $(grep -E '^#' <<<"$OS_OUT" | head -4)"
fi


if [ "$HERMETIC" -eq 1 ]; then
  section "SKIPPED under --hermetic: §10 and §11's live half (4 clauses, all of them GitHub API reads)"
  echo "  Run without --hermetic, with a token carrying admin on this repo, to exercise them."
else
  api_stage
fi

[ "$LIVE" -eq 1 ] && live_stage

echo
echo "════════════════════════════════════════════════════════════"
echo "required-checks: $PASS passed, $FAIL failed$([ "$HERMETIC" -eq 1 ] && echo " (hermetic — the API stage was skipped)")"
[ "$FAIL" -eq 0 ] || exit 1
