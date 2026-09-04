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
#
# THE EXIT-CODE TABLE — AND WHY 4 EXISTS
#
#   0   every assertion passed, and the tally line was reached
#   1   ASSERTION DRIFT: the suite read every input it needed and something it
#       asserts about the toolchain is no longer true. A verdict AGAINST the
#       repo — someone must fix the repo.
#   2   you invoked me wrong (unknown flag, contradictory flags, a non-bash or
#       POSIX-mode interpreter)
#   3   no git object database / no shared check-runs lib — a PRECONDITION of
#       the run is absent, refused before the first assertion
#   4   INPUT UNREADABLE / PRODUCER REFUSED: the suite could not obtain an input
#       it needed to make an assertion — the generator refused and wrote no
#       spec, a fixture could not be read. NOT a verdict about the repo's
#       required set; the suite never got far enough to have one. A caller
#       should HOLD, not report drift.
#   70  the run ended before its tally line while reporting success (a crash is
#       not a pass; see the EXIT trap below)
#
# 4 IS THE MACHINE HALF OF #14371. That fix made the generator's refusal
# READABLE ("the generator REFUSED (exit N), wrote no <file>, and said: …")
# after `Required-check spec gate` sat red for the 2026-08-24T21:59Z ->
# 2026-08-31 bracket and the whole fleet learned to ignore the red. The human
# half alone leaves a machine reading `exit 1` unable to tell "your PR drifted
# the spec" from "our generator is down", which is how a red gets ignored in
# the first place. 4 separates them.
#
# PRECEDENCE, AND IT IS DELIBERATE: 4 outranks 1. A run that could not read an
# input cannot be trusted to have completed the assertions that WOULD have
# found drift, so a run with both a blocked site and a failed one reports the
# blocked one — "I could not tell you" beats a partial verdict. The tally line
# still prints, and it prints the blocked count separately from the failed
# count so neither is hidden inside the other. No assertion drift ever maps to
# 4: only `blocked()` raises it, and only `fail_emit` routes to `blocked()`,
# and only when the producer's own refusal is on record in GEN_EMIT_ERR.
# Section 25 pins both directions.
#
# THE INTERPRETER GUARD, AND THE VACUOUS GREEN IT DELETES (wave 53)
#
# The shebang above only decides who runs this file when it is EXECUTED. An
# agent or a human who types `sh scripts/required-checks.test.sh` overrides it,
# and until wave 53 that invocation produced the exact defect this epic exists
# to delete — a green nothing earned, inside the epic's own instrument:
#
#   sh scripts/required-checks.test.sh >/tmp/out 2>&1; echo "exit=$?"  ->  exit=0
#   grep -c '^  ok' /tmp/out                                           ->  68
#
# 68 of 170 assertions, §18 never reached, and a SUCCESS exit code. bash reads a
# script incrementally, so it ran a third of the file before parsing the first
# `done < <(...)` process substitution, which bash in POSIX mode cannot parse;
# the syntax error killed the shell mid-run and the exit status of the last
# completed command — a passing assertion — was what the caller saw.
#
# CI WAS NEVER EXPOSED: both jobs that invoke this suite from
# .github/workflows/required-checks-drift.yml call it with `bash`. This was an agent- and human-facing trap, not a
# CI hole, and it is recorded here as one.
#
# So the file now refuses a non-bash or POSIX-mode interpreter BEFORE the first
# assertion, rather than trusting a shebang the caller may have bypassed. The
# guard below must stay POSIX-parseable and must stay FIRST — anything it is
# placed after is code a POSIX-mode shell has already run.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "required-checks.test.sh: needs bash (this suite uses process substitution); run: bash scripts/required-checks.test.sh${1:+ $1}" >&2
  exit 2
fi
case ":${SHELLOPTS:-}:" in
  *:posix:*)
    echo "required-checks.test.sh: bash is in POSIX mode (invoked as \`sh\`?), which cannot parse this suite's process substitution; run: bash scripts/required-checks.test.sh${1:+ $1}" >&2
    exit 2
    ;;
esac

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$REPO_ROOT/scripts/required-checks-generate.sh"
APPLY="$REPO_ROOT/scripts/required-checks-apply.sh"
VERIFY="$REPO_ROOT/scripts/required-checks-verify.sh"
SPEC="$REPO_ROOT/.github/required-checks.json"

# THE MUTANTS RUN FROM A TEMP DIRECTORY, AND THE SHARED READER LIVES IN THE REPO.
# Both instruments now source scripts/lib/check-runs.sh instead of each keeping a
# private copy of the check-run pipeline (cch-adopt-check-runs-lib-in-required-checks),
# and both resolve it through $0-derived REPO_ROOT. Every `sed`-mutated copy in
# this file is written to $TMP, whose REPO_ROOT is the temp directory's parent —
# so without this handle each mutant would die on a missing lib instead of on the
# clause it is meant to prove. It is the same accommodation the mutants already
# make with an explicit --workflows and --prose, and it points at the REAL lib,
# so nothing is stubbed. §4 below re-runs the generator with it UNSET, which is
# what keeps the default resolution from rotting behind this export.
export BARKPARK_CHECK_RUNS_LIB="$REPO_ROOT/scripts/lib/check-runs.sh"
[ -f "$BARKPARK_CHECK_RUNS_LIB" ] || {
  echo "required-checks.test.sh: no shared check-runs reader at $BARKPARK_CHECK_RUNS_LIB — both instruments source it, so every clause below would red on the lib rather than on itself" >&2
  exit 3
}

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

# ── the object database is a PRECONDITION, not an assumption ─────────────────
#
# FOURTH SIGHTING of the same trap (charter D423, D547, and the third-sighting
# paragraph). At origin/main in a REAL worktree this suite is 170 passed, 0
# failed, exit 0. Unpack the IDENTICAL tree with `git archive origin/main | tar
# -x` — no `.git`, so no object database — and it becomes 168 passed, 2 failed,
# exit 1, with `fatal: not a git repository` printed above each red.
#
# Two reads need the object database:
#   §13 `git ls-files -- '*.md'`  — the corpus of the `gh pr merge --admin`
#                                   prose ratchet (1291 files real, ZERO here)
#   §18 `git grep --untracked -lE` — the protection-claim census, which then
#                                   reports all 14 pins STALE
#
# §18 fails CLOSED (it reds). §13 fails OPEN: its primary assertion printed
#
#   ok   no non-exempt *.md teaches `gh pr merge … --admin` …
#
# one line under the fatal — a green earned over a corpus of zero files, which
# is the exact defect this suite exists to catch, living inside the suite. A
# degraded run is worse than no run, so refuse BEFORE any section: name the
# cause, name the fix, and exit 3 (distinct from the 2 that means "you invoked
# me wrong" and from the 1 that means "an assertion failed").
#
# Both probes matter. `rev-parse --git-dir` catches the extract; a non-empty
# tracked *.md corpus catches the subtler shape — a directory that IS inside a
# repository but whose tree git does not track — where §13 would again scan
# nothing and call it ok.
if ! ( cd "$REPO_ROOT" && git rev-parse --git-dir >/dev/null 2>&1 ); then
  echo "required-checks.test.sh: no git object database at $REPO_ROOT (a \`git archive\` extract or a copied tree?); sections 13 and 18 read the tracked corpus with \`git ls-files\`/\`git grep\`, and without it section 13 prints ok over ZERO files; run: bash scripts/required-checks.test.sh from a real checkout or worktree" >&2
  exit 3
fi
RC_TRACKED_MD="$( ( cd "$REPO_ROOT" && git ls-files -- '*.md' 2>/dev/null ) | grep -c . || true )"
if [ "$RC_TRACKED_MD" -eq 0 ]; then
  echo "required-checks.test.sh: git tracks no *.md under $REPO_ROOT, so section 13's prose ratchet would scan an EMPTY corpus and print ok over nothing; run: bash scripts/required-checks.test.sh from a real checkout or worktree" >&2
  exit 3
fi

PASS=0
FAIL=0
# BLOCKED is the third tally, and it is NOT a kind of FAIL. A `bad` is a verdict
# about the repo; a `blocked` is the suite reporting that it could not obtain an
# input and therefore has no verdict to give. They are counted apart so the
# tally line cannot hide one inside the other, and `rc_exit_code` maps them to
# distinct exit codes (see the table in the header).
BLOCKED=0
TMP="$(mktemp -d)"
# A CRASH IS NOT A PASS, AND THIS FILE USED TO REPORT IT AS ONE.
# `cleanup() { rm -rf "$TMP"; }` ends in a command that succeeds, and an EXIT
# trap's final status REPLACES the script's — so any death before the tally line
# exited 0. Measured, not theorised: while §22 was being written an unbound
# variable under `set -u` killed the run at §22 and `echo "RC=$?"` printed 0,
# with 107 assertions run out of ~190 and no tally line at all. In CI that is
# `Required-check spec gate` GREEN over a fraction of its suite — the exact
# shape every clause in this file exists to refuse, in the file itself.
#
# Two clauses, because preserving the status alone is not enough: a `set -e`
# death whose failing command exits 0 is possible, and "the run stopped early"
# must be a failure on its own terms. RC_TALLY_REACHED is set on the last line
# of the run; if the trap fires without it and the status is somehow 0, that is
# a hard 70. The `exit 3` preconditions above run BEFORE this trap is installed,
# so they are unaffected.
RC_TALLY_REACHED=0
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  if [ "$RC_TALLY_REACHED" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "required-checks.test.sh: the run ended BEFORE its tally line while reporting success — it crashed, and a crash is not a pass. Scroll up for the last assertion that printed." >&2
    exit 70
  fi
  exit "$rc"
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $*" >&2; }
# A site that could not READ its input says so in its own word. `BLOCKED` never
# increments FAIL: the exit code, not the failed count, is what tells the two
# apart, and a caller that greps `0 failed` must still see the blocked count on
# the same tally line.
blocked() { BLOCKED=$((BLOCKED + 1)); echo "  BLOCKED $*" >&2; }

# The exit-code table as a FUNCTION, so the tally line and section 25 read the
# same rule rather than two copies of it. <failed> <blocked> -> code.
rc_exit_code() {
  if   [ "${2:-0}" -gt 0 ]; then printf '4'
  elif [ "${1:-0}" -gt 0 ]; then printf '1'
  else                           printf '0'
  fi
}

section() { echo; echo "── $* ──"; }

# ── AN EMIT THAT REFUSES MUST SAY SO IN ITS OWN WORDS ────────────────────────
#
# THE TWO-DAY BLACKOUT THIS EXISTS TO PREVENT (#14073, main red from 253a83184a
# 2026-08-24T21:59Z to 2026-08-31T20:14Z — 6d22h elapsed, spanning EIGHT calendar
# dates, and still red on main head 8cf6af2b0e at 19:55Z on the day this was
# written; quote the bracket, not a rounded day count, because the two framings
# disagree by one and the bracket is checkable). Every section that wants the generator to EMIT a
# spec used to run it as
#
#     bash "$GEN" … --out "$TMP/foo.json" >/dev/null 2>&1 || true
#     if jq -e '…' "$TMP/foo.json" >/dev/null 2>&1; then ok …; else bad "… $(jq -c '…' "$TMP/foo.json" 2>&1)"; fi
#
# and that line drops the generator's exit status TWICE over: `|| true` discards
# the code and `2>&1 >/dev/null` discards the refusal text. When the generator
# refused it wrote no file, and the assertion below then jq'd a path that does
# not exist — so the headline every reader saw was
#
#     FAIL the acknowledged emit is jq: error: Could not open file …: No such file or directory
#
# eight times over. That names the SYMPTOM (a missing file) and buries the CAUSE
# (`EXCLUSION LOSS — … LOST Sobelow baseline rows still hash to their own
# fingerprint (blocking)`), which is precisely why a one-line acknowledgement fix
# went undiagnosed for that whole bracket while every open PR carried the red.
#
# THE RULE, and it is general: a sub-script's exit status must be checked BEFORE
# its output file is consumed, and its own stderr must survive to the failure
# text. `emit_spec` does both — it captures the combined output, checks the
# status AND that a non-empty file actually appeared, prints the refusal inline
# where it happened, and parks a headline in GEN_EMIT_ERR. `why_emit` then makes
# the assertion prefer that headline over whatever jq has to say about a file
# that was never written. Assertion COUNT is unchanged, so a refusal still reds
# exactly one assertion per site — it just reds it with the true cause.
GEN_EMIT_ERR=""
emit_spec() {
  local out="$1"; shift
  local rc=0 log
  rm -f "$out"
  log="$("$@" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] || [ ! -s "$out" ]; then
    local why banner
    # The headline must NAME THE ROW, not just the refusal class. The generator
    # puts the class on line 1 and the offending name on an indented `LOST  …` /
    # `STALE  …` line several lines down, so take the class line plus every
    # diagnostic line — a plain `head -n` truncates exactly the half that
    # identifies what to fix.
    banner="$(printf '%s\n' "$log" | grep -v '^[[:space:]]*$' | head -1)"
    why="$(printf '%s\n' "$log" | grep -E '^ *(LOST|STALE|UNMAPPED|POISONED) ' | head -6 | tr '\n' '⏎')"
    [ -n "$why" ] || why="$(printf '%s\n' "$log" | grep -v '^[[:space:]]*$' | head -4 | tr '\n' '⏎')"
    GEN_EMIT_ERR="the generator REFUSED (exit $rc), wrote no $(basename "$out"), and said: ${banner:-<no output>} ⇢ ${why:-<no diagnostic lines>}"
    echo "  ---- $(basename "$out"): generator refused (exit $rc); its own output follows ----" >&2
    printf '%s\n' "$log" >&2
    echo "  ---- end generator output ----" >&2
    return 1
  fi
  GEN_EMIT_ERR=""
  return 0
}
# Prefer the generator's own refusal over the caller's jq-derived text.
why_emit() { if [ -n "$GEN_EMIT_ERR" ]; then printf '%s' "$GEN_EMIT_ERR"; else printf '%s' "$1"; fi; }
# …and the MACHINE half of the same distinction. `why_emit` fixes the TEXT a
# human reads; `fail_emit` fixes the EXIT CODE a caller reads. The condition is
# identical and deliberately so — the producer's own refusal is on record in
# GEN_EMIT_ERR or it is not, and nothing else may promote a red to a hold. Every
# site that consumes a file `emit_spec` was supposed to write goes through this;
# section 25 reds if one of them goes back to a bare `bad`.
fail_emit() { if [ -n "$GEN_EMIT_ERR" ]; then blocked "$1"; else bad "$1"; fi; }

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
emit_spec "$TMP/sel-spec.json" bash "$GEN" --workflows "$WF" --fixture-dir "$FIX" --no-merge --sha shaA --sha shaB --out "$TMP/sel-spec.json" || true
if jq -e '[.protection.required_status_checks.checks[].context] == ["Aggregate gate"]' "$TMP/sel-spec.json" >/dev/null 2>&1; then
  ok "the emitted spec is EXACTLY the aggregator — 'Only on B' (present on one sha only) and every stage's specimen are gone"
else
  fail_emit "$(why_emit "the emitted spec is $(jq -c '[.protection.required_status_checks.checks[].context]' "$TMP/sel-spec.json" 2>&1), not [Aggregate gate]")"
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

section "3c. against the REAL workflow tree — every required context still resolves to a job that publishes it"

# WHAT THIS SECTION USED TO BE, AND WHY IT COULD NOT LOSE (wave 29).
#
# The real-tree read below was already here. Its answer went into `REAL_UNMAPPED`
# — a variable that occurred EXACTLY ONCE in this file, as an assignment. The
# only assertion in the section jq'd `$SPEC`, i.e. the committed, static
# `.github/required-checks.json`: a file that no edit to `.github/workflows/`
# can move. So the one signal in the section that responds to the real tree was
# computed and dropped, and the assertion that ran was green by construction.
# Measured on origin/main, by isolated reproduction:
#
#   tree given to the generator            REAL_UNMAPPED   generator rc   3c said
#   clean                                  0               0              ok
#   `Console gate`'s job `name:` renamed   2               0              ok
#   a catch-all planted in the real tree   0               1              ok
#
# READING THE OLD VARIABLE WOULD NOT HAVE BEEN ENOUGH EITHER, which is why this
# is a rebuild and not a one-line fix. The old read fed the generator the
# HERMETIC fixture feed, whose names are all synthetic, so EVERY name in the
# intersection is unmapped against the real tree and the count is noise that
# happens to be 0 only because the intersection is small. A real-tree read needs
# a feed carrying the names the real tree is supposed to publish — and those are
# DERIVED from the committed spec's required contexts rather than typed here,
# because a hand-written probe can always be written so as not to contain the
# defect it is supposed to find.
#
# TWO ARMS, BECAUSE ONE OF THEM CANNOT SEE HALF THE FAILURES. `REAL_UNMAPPED`
# alone is blind to a generator that DIES before it ever classifies a name: a
# real-tree catch-all exits 1 with the count still at 0 (row three above), and
# an `|| true` would swallow it exactly the way the emit sites did before
# `emit_spec` existed. So the exit status is CAPTURED and asserted on its own,
# and both arms get their own mutation twin below.
#
# THE VERDICT COMES FROM THE GENERATOR; THE DIAGNOSIS COMES FROM A LOCAL READ.
# `rc3c_inventory` is a small awk pass over `jobs:` → `name:` used ONLY to say
# which job most likely used to publish a name that no longer maps. It never
# decides anything: if it ever drifts from the generator's own parser the
# failure text gets vaguer and no verdict moves. A rename that keeps the old
# name as a substring (a suffix, a qualifier — the common shape) is named
# exactly; a rename beyond recognition degrades to "the string still appears
# in <file>".
#
# WHERE THIS RUNS AND WHAT ITS RED DOES: `.github/workflows/required-checks-drift.yml`
# job `spec-gate`, rendered as `Required-check spec gate`. That name is held out
# of the required set under S7 and the job is in no required aggregator's
# `needs:`, so it cannot stop a merge — its red is a signal a human must read.
# Registering it is a branch-protection change and a lead call; see that
# workflow's own header, which states the same thing.

RC3C_FIX="$TMP/rc3c-fixtures"
mkdir -p "$RC3C_FIX"

# The probe feed: one green Actions check run per COMMITTED REQUIRED CONTEXT,
# read out of $SPEC. Nothing here is typed.
rc3c_feed() {
  jq -r '.protection.required_status_checks.checks[].context' "$SPEC" \
    | jq -R . \
    | jq -s '{check_runs: map({name: ., conclusion: "success", started_at: "2026-07-28T01:00:00Z", app: {id: 15368}})}'
}
rc3c_feed > "$RC3C_FIX/checkruns-rc3cA.json"
cp "$RC3C_FIX/checkruns-rc3cA.json" "$RC3C_FIX/checkruns-rc3cB.json"
# main is all-green so S5 can never fire on a probe name: this section's subject
# is S0 and the exit code, and nothing else may decide its verdict.
cp "$RC3C_FIX/checkruns-rc3cA.json" "$RC3C_FIX/checkruns-rc3cMAIN.json"
echo "rc3cMAIN" > "$RC3C_FIX/main-shas.txt"

RC3C_REQUIRED_N="$(jq -r '.protection.required_status_checks.checks[].context' "$SPEC" | awk 'NF {n++} END {print n+0}')"
RC3C_SPEC_SORTED="$(jq -c '[.protection.required_status_checks.checks[].context] | sort' "$SPEC")"
RC3C_FEED_SORTED="$(jq -c '[.check_runs[].name] | sort' "$RC3C_FIX/checkruns-rc3cA.json")"
if [ "$RC3C_REQUIRED_N" -ge 1 ] && [ "$RC3C_FEED_SORTED" = "$RC3C_SPEC_SORTED" ]; then
  ok "the probe feed IS the committed required set — $RC3C_REQUIRED_N name(s) read out of .github/required-checks.json, never typed here, so the fixture cannot be written so as to miss the defect"
else
  bad "the probe feed is not derived from the spec: feed $RC3C_FEED_SORTED vs spec $RC3C_SPEC_SORTED ($RC3C_REQUIRED_N required)"
fi

# ONE invocation, driven three times (the real tree, a COPY with a required
# aggregator's job renamed, a COPY with a catch-all planted). The exit status is
# captured into RC3C_RC — never `|| true`d, never piped into anything whose own
# status would replace it.
RC3C_OUT=""
RC3C_RC=0
rc3c_run() { # <workflows dir>
  RC3C_RC=0
  RC3C_OUT="$(bash "$GEN" --workflows "$1" --fixture-dir "$RC3C_FIX" --no-merge \
    --sha rc3cA --sha rc3cB --explain 2>&1)" || RC3C_RC=$?
}
# The ledger lines are `  exclude  <name>  — <reason>` and
# `  keep     <name>  (<file> job '<job>')`; both prefixes are 11 characters and
# the name is terminated by the next DOUBLE space. awk rather than
# `grep | sed`, because `grep -c` prints a count AND exits non-zero on zero
# matches, and a `grep -q` that closes the pipe early takes its upstream out
# with SIGPIPE under `set -o pipefail` — either one turns "clean" into a suite
# abort or a false number.
rc3c_unmapped() { # <ledger text> -> one required context per line that NO job publishes
  printf '%s\n' "$1" | awk '
    /^  exclude  / && index($0, "S0 UNMAPPED") {
      s = substr($0, 12); i = index(s, "  "); if (i) s = substr(s, 1, i - 1)
      print s
    }'
}
rc3c_count() { # <ledger text> -> the integer REAL_UNMAPPED
  rc3c_unmapped "$1" | awk 'NF {n++} END {print n+0}'
}
rc3c_mapped() { # <ledger text> -> "<context> <- <file> job '<job>'; …"
  printf '%s\n' "$1" | awk '
    /^  keep     / {
      s = substr($0, 12); i = index(s, "  ("); if (!i) next
      ctx = substr(s, 1, i - 1); prov = substr(s, i + 3); sub(/\)$/, "", prov)
      printf "%s <- %s; ", ctx, prov
    }'
}
rc3c_inventory() { # <workflows dir> -> file<TAB>job key<TAB>job name template
  local f
  for f in "$1"/*.yml; do
    [ -f "$f" ] || continue
    awk -v file="$(basename "$f")" '
      /^jobs:[[:space:]]*$/                 { injobs = 1; next }
      injobs && /^[^[:space:]#]/            { injobs = 0 }
      injobs && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { job = $1; sub(/:$/, "", job); next }
      injobs && job != "" && /^    name:[[:space:]]/ {
        nm = $0; sub(/^    name:[[:space:]]*/, "", nm)
        gsub(/^["\047]|["\047]$/, "", nm)
        printf "%s\t%s\t%s\n", file, job, nm
      }
    ' "$f"
  done
}
rc3c_diagnose() { # <workflows dir> <context>
  local near files
  near="$(rc3c_inventory "$1" | awk -F'\t' -v c="$2" '
    $3 != "" && (index($3, c) || index(c, $3)) { printf "%s job \047%s\047 now publishes \047%s\047; ", $1, $2, $3 }')"
  if [ -n "$near" ]; then
    printf 'the job that used to feed it is %s' "$near"
    return 0
  fi
  files="$( { ( cd "$1" && grep -lF -- "$2" ./*.yml 2>/dev/null ) || true; } | sed 's|^\./||' | tr '\n' ' ' )"
  if [ -n "$files" ]; then
    printf 'no job publishes it and no job name resembles it; the string still appears in: %s(renamed beyond recognition, or deleted?)' "$files"
  else
    printf 'no job publishes it and no workflow file mentions it at all (deleted?)'
  fi
}
rc3c_report() { # <workflows dir> <ledger text> <generator rc>
  local ctx
  printf 'the REAL workflow tree does not publish every required context (generator exit %s). ' "$3"
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    printf 'UNMAPPED required context "%s" — %s. ' "$ctx" "$(rc3c_diagnose "$1" "$ctx")"
  done <<EOF
$(rc3c_unmapped "$2")
EOF
  printf 'still resolving: %s' "$(rc3c_mapped "$2")"
}

# ── the clean read, on the tree this repo actually ships ─────────────────────
rc3c_run "$REPO_ROOT/.github/workflows"
RC3C_CLEAN_OUT="$RC3C_OUT"
RC3C_CLEAN_RC="$RC3C_RC"
REAL_UNMAPPED="$(rc3c_count "$RC3C_CLEAN_OUT")"
RC3C_MAPPED_N="$(rc3c_mapped "$RC3C_CLEAN_OUT" | tr ';' '\n' | awk 'NF {n++} END {print n+0}')"

if [ "$RC3C_CLEAN_RC" -eq 0 ]; then
  ok "the real-tree run EXITS 0, and that status is asserted separately from the count — a refusal leaves REAL_UNMAPPED at 0, so a count-only clause reads clean on a generator that died"
else
  bad "the generator REFUSED over .github/workflows/ (exit $RC3C_CLEAN_RC): $(printf '%s\n' "$RC3C_CLEAN_OUT" | grep -v '^[[:space:]]*$' | head -2 | tr '\n' '⏎')"
fi

# ZERO UNMAPPED IS NOT THE CLAIM — "$RC3C_REQUIRED_N of $RC3C_REQUIRED_N RESOLVED" is.
# A generator that refuses at index-build time classifies NOTHING, so it returns
# zero unmapped names as well: measured with a catch-all planted in the real
# tree, a bare `REAL_UNMAPPED -eq 0` printed "all 4 resolve" over an empty
# ledger. The mapped side is counted too, and both must agree with the spec.
if [ "$RC3C_CLEAN_RC" -eq 0 ] && [ "$REAL_UNMAPPED" -eq 0 ] && [ "$RC3C_MAPPED_N" -eq "$RC3C_REQUIRED_N" ]; then
  ok "REAL_UNMAPPED is 0 and it is READ: all $RC3C_REQUIRED_N committed required context(s) resolve to a NAMED job in .github/workflows/ — $(rc3c_mapped "$RC3C_CLEAN_OUT")"
else
  bad "$(rc3c_report "$REPO_ROOT/.github/workflows" "$RC3C_CLEAN_OUT" "$RC3C_CLEAN_RC") [$RC3C_MAPPED_N of $RC3C_REQUIRED_N required context(s) resolved to a job]"
fi

# ── MUTATION TWIN 1: the count arm. Rename a required aggregator's job. ──────
#
# Both assertions above pass on a NUMBER BEING ZERO and a STATUS BEING ZERO, so
# both also pass when the read never happened. The victim is DERIVED from the
# clean run's own keep ledger — the first required context the real tree
# resolves — so this twin cannot be aimed at a name chosen to make it work.
RC3C_COPY="$TMP/rc3c-renamed"
mkdir -p "$RC3C_COPY"
cp "$REPO_ROOT"/.github/workflows/*.yml "$RC3C_COPY/"
# FIRST MATCH WINS WITHOUT `exit`, AND THAT IS NOT A STYLE CHOICE. This line
# used to end `{ print substr($0, 12); exit }`. Under `set -o pipefail` an awk
# that exits early closes the pipe while `printf` is still writing the
# generator's multi-kilobyte log, printf takes SIGPIPE and returns 141, pipefail
# hands 141 to the command substitution and `set -e` kills the whole suite —
# MEASURED here twice in a row on this file's own §3c, `line 746: printf: write
# error: Broken pipe`, with the run dying mid-section and no tally line. It is
# payload-size- and load-dependent, which is why CI has not shown it. Draining
# the input costs nothing and the flag preserves first-match-wins exactly.
RC3C_KEEP1="$(printf '%s\n' "$RC3C_CLEAN_OUT" | awk '/^  keep     / && !seen { print substr($0, 12); seen = 1 }')"
RC3C_CTX="${RC3C_KEEP1%%  (*}"
RC3C_PROV="${RC3C_KEEP1#*  (}"; RC3C_PROV="${RC3C_PROV%)}"
RC3C_FILE="${RC3C_PROV%% job *}"
RC3C_JOB="${RC3C_PROV#* job }"; RC3C_JOB="${RC3C_JOB//\'/}"

RC3C_RENAME_RC=0
awk -v ctx="$RC3C_CTX" '
  {
    line = $0; t = line; ind = ""
    if (match(line, /^[[:space:]]+/)) ind = substr(line, 1, RLENGTH)
    sub(/^[[:space:]]+/, "", t)
    if (t == "name: " ctx) { line = ind "name: " ctx " RENAMED BY THE 3C MUTATION"; n++ }
    print line
  }
  END { exit (n == 1 ? 0 : 1) }
' "$RC3C_COPY/$RC3C_FILE" > "$TMP/rc3c-rename.tmp" || RC3C_RENAME_RC=$?
if [ "$RC3C_RENAME_RC" -eq 0 ] && [ -s "$TMP/rc3c-rename.tmp" ]; then
  mv "$TMP/rc3c-rename.tmp" "$RC3C_COPY/$RC3C_FILE"
  ok "the mutation APPLIES: EXACTLY ONE \`name: $RC3C_CTX\` line — $RC3C_FILE job '$RC3C_JOB' — is rewritten in a COPY of the real tree, so the twin below is not asserting over an unchanged file"
else
  bad "the rename did not rewrite exactly one \`name:\` line (awk exit $RC3C_RENAME_RC) for the victim derived from the clean ledger — file '$RC3C_FILE', job '$RC3C_JOB', context '$RC3C_CTX' (an EMPTY triple means the clean run classified nothing, i.e. the generator refused) — everything below it would be vacuous"
fi

rc3c_run "$RC3C_COPY"
RC3C_R_UNMAPPED="$(rc3c_count "$RC3C_OUT")"
RC3C_R_REPORT="$(rc3c_report "$RC3C_COPY" "$RC3C_OUT" "$RC3C_RC")"
# `grep -qF ""` matches ANYTHING, so every clause below is guarded on the
# derived victim being non-empty first: a twin aimed at nothing must red, never
# pass by matching the empty string.
if [ -n "$RC3C_CTX" ] && [ "$RC3C_R_UNMAPPED" -gt "$REAL_UNMAPPED" ] && grep -qxF "$RC3C_CTX" <<<"$(rc3c_unmapped "$RC3C_OUT")"; then
  ok "…and renaming that one job in the COPY takes REAL_UNMAPPED from $REAL_UNMAPPED to $RC3C_R_UNMAPPED and names '$RC3C_CTX' — the clean verdict above is a READ of the workflow tree, not a silence (main's clause could not move at all: it asserted on the static spec file)"
else
  bad "the real-tree read could not be made to move: renamed $RC3C_FILE job '$RC3C_JOB' out from under required context '$RC3C_CTX' and REAL_UNMAPPED is still $RC3C_R_UNMAPPED"
fi
if [ -n "$RC3C_FILE" ] && [ -n "$RC3C_JOB" ] && [ -n "$RC3C_CTX" ] \
   && grep -qF "$RC3C_FILE" <<<"$RC3C_R_REPORT" && grep -qF "$RC3C_JOB" <<<"$RC3C_R_REPORT" \
   && grep -qF "$RC3C_CTX" <<<"$RC3C_R_REPORT"; then
  ok "…and the text it reds WITH names the workflow ($RC3C_FILE), the job ('$RC3C_JOB') and the required context it feeds ('$RC3C_CTX') — the operator is told what to fix, not merely that something is wrong"
else
  bad "the red names less than workflow+job+context: $RC3C_R_REPORT"
fi
rm -rf "$RC3C_COPY"

# ── MUTATION TWIN 2: the exit-code arm, which the count arm cannot see. ──────
#
# A catch-all job name in the real tree makes the generator `die` at INDEX-BUILD
# time — before a single name is classified — so it exits 1 with REAL_UNMAPPED
# still 0. This is the row-three case from the table at the top of the section,
# and it is the whole reason the status is asserted on its own line.
RC3C_CA="$TMP/rc3c-catchall"
mkdir -p "$RC3C_CA"
cp "$REPO_ROOT"/.github/workflows/*.yml "$RC3C_CA/"
cat > "$RC3C_CA/aaa-rc3c-catchall.yml" <<'YAML'
name: rc3c catch-all specimen
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
rc3c_run "$RC3C_CA"
RC3C_CA_UNMAPPED="$(rc3c_count "$RC3C_OUT")"
if [ "$RC3C_RC" -ne 0 ] && [ "$RC3C_CA_UNMAPPED" -eq 0 ]; then
  ok "…and a catch-all planted in a COPY of the real tree REFUSES (exit $RC3C_RC) while REAL_UNMAPPED stays 0 — the exit-code arm is load-bearing, and a clause that asserted only the count would have called this clean"
else
  bad "the catch-all case did not reproduce (exit $RC3C_RC, REAL_UNMAPPED $RC3C_CA_UNMAPPED) — the exit-code assertion above may be idle"
fi
rm -rf "$RC3C_CA"

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
  bad "the unguarded spec did not carry 'Advisory gate' (generator exit $NG_RC): $(if [ "$NG_RC" -ne 0 ]; then printf 'it REFUSED and wrote no poison-spec.json — its own output: %s' "$(printf '%s\n' "$NG_OUT" | grep -v '^[[:space:]]*$' | head -3 | tr '\n' '⏎')"; else jq -c '[.protection.required_status_checks.checks[].context]' "$TMP/poison-spec.json" 2>&1; fi)"
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

# ── THE EMPTY-FEED REFUSAL BELONGS TO THIS CALLER, AND A REFUSAL NOBODY CAN
#    DELETE IS A REFUSAL NOBODY HAS PROVEN ──────────────────────────────────
#
# `fetch_check_runs` no longer owns the read: it calls check_runs_rows_ext from
# scripts/lib/check-runs.sh, which returns an EMPTY feed as zero rows and exit 0
# ON PURPOSE (for the registration sampler a head with no runs is the cadence
# datum, so a primitive that died there could not be shared). The refusal above
# therefore has to live at the CALL SITE — and an adoption that silently
# inherited the lib's permissiveness would turn this fail-closed guard into a
# fail-open one with no test noticing. So: name the message, then delete it from
# a copy and watch the same fixture stop naming it.
RC4_EMPTY_OUT="$(bash "$GEN" --workflows "$WF" --fixture-dir "$FIX" --no-merge --sha shaEMPTY --sha shaA 2>&1)" && RC4_EMPTY_RC=0 || RC4_EMPTY_RC=$?
if [ "$RC4_EMPTY_RC" -ne 0 ] && grep -q "refusing to generate a spec from nothing" <<<"$RC4_EMPTY_OUT"; then
  ok "…and it reds BY NAME — the generator's own refusal, not something the shared reader happened to raise"
else
  bad "the empty feed did not red with the generator's own refusal (exit $RC4_EMPTY_RC): $(head -2 <<<"$RC4_EMPTY_OUT")"
fi
RC4_NOEMPTY="$TMP/gen-no-empty-refusal.sh"
sed 's%^.*refusing to generate a spec from nothing.*$%    || : # EMPTY REFUSAL REMOVED%' "$GEN" > "$RC4_NOEMPTY"
RC4_MUTN="$(grep -c 'EMPTY REFUSAL REMOVED' "$RC4_NOEMPTY" || true)"
if [ "$RC4_MUTN" -ne 1 ]; then
  bad "the empty-refusal mutation applied $RC4_MUTN times, not 1 — the die moved, so the proof below is vacuous"
else
  ok "the mutation applies: the generator's empty-feed die is removed from a copy"
  RC4_MUT_OUT="$(bash "$RC4_NOEMPTY" --workflows "$WF" --fixture-dir "$FIX" --no-merge --sha shaEMPTY --sha shaA 2>&1)" || true
  # The mutant still reds — `selection produced ZERO contexts` is a downstream
  # backstop — but it reds for the WRONG REASON, naming the selection rather
  # than the empty feed that caused it. That difference is the whole point: the
  # call-site die is what turns "the sample was unusable" into a diagnosis.
  if grep -q "refusing to generate a spec from nothing" <<<"$RC4_MUT_OUT"; then
    bad "the mutant STILL refuses by name — the mutation did not reach the clause under test, so the proof above is vacuous"
  elif grep -q "selection produced ZERO contexts" <<<"$RC4_MUT_OUT"; then
    ok "…and WITHOUT it the identical empty feed falls through to the downstream backstop, which blames the SELECTION instead of the feed"
  else
    bad "the mutant neither refused by name nor hit the backstop — the fixture no longer discriminates: $(head -2 <<<"$RC4_MUT_OUT")"
  fi
fi
# NON-VACUITY OF THE EXPORT ABOVE. Every clause in this file runs with
# BARKPARK_CHECK_RUNS_LIB set, so the DEFAULT resolution — the one every real
# invocation and every other harness uses — would rot behind it unnoticed. Run
# the healthy sample once with the handle unset.
if env -u BARKPARK_CHECK_RUNS_LIB bash "$GEN" --workflows "$WF" --fixture-dir "$FIX" --no-merge --sha shaA --sha shaB >/dev/null 2>&1; then
  ok "the generator finds the shared reader on its own with BARKPARK_CHECK_RUNS_LIB UNSET — the handle is a mutant accommodation, not the production path"
else
  bad "the generator cannot resolve scripts/lib/check-runs.sh without the harness's handle — every other caller (bp-merge, the drift workflow, CI) would be broken"
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

# hgw5-bl-deadlock-pending-informational: a required context that RENDERED but
# has not SETTLED (conclusion null) used to return exit 0 with output
# byte-shaped like green. It must now print an INFORMATIONAL PENDING line —
# naming the context, its status and its started_at — and STILL exit 0
# (charter D76: never a fifth failing state; bp-merge pre-flights this once,
# so a failing PENDING would refuse every freshly pushed PR).
# (a) in_progress with a null conclusion key
jq -c --arg keep "$KEPT_CTX" '(.check_runs[] | select(.name == $keep)) |= (.conclusion = null | .status = "in_progress")' \
  "$TMP/runs.json" > "$TMP/runs-pending-ip.json"
set +e
OUT="$(bash "$VERIFY" --spec "$TMP/enforced.json" --runs "$TMP/runs-pending-ip.json" --sha probe --deadlock 2>&1)"
RC=$?
set -e
if [ "$RC" -eq 0 ]; then
  ok "an in_progress required context still exits 0 (informational, not a fifth failing state)"
else
  bad "an in_progress required context exited $RC, not 0 — PENDING must never refuse (D76)"
fi
if grep -q "PENDING: $KEPT_CTX has not settled (status=in_progress, started_at=2026-07-28T01:00:00Z)" <<<"$OUT"; then
  ok "the PENDING line names the context, its status and its started_at (in_progress)"
else
  bad "no PENDING line for an in_progress required context — rendered-but-unsettled reads as green"
fi

# (b) queued with NO conclusion key at all (the API omits it before a run starts)
jq -c --arg keep "$KEPT_CTX" '(.check_runs[] | select(.name == $keep)) |= (del(.conclusion) | .status = "queued")' \
  "$TMP/runs.json" > "$TMP/runs-pending-q.json"
set +e
OUT="$(bash "$VERIFY" --spec "$TMP/enforced.json" --runs "$TMP/runs-pending-q.json" --sha probe --deadlock 2>&1)"
RC=$?
set -e
if [ "$RC" -eq 0 ] && grep -q "PENDING: $KEPT_CTX has not settled (status=queued" <<<"$OUT"; then
  ok "queued-with-no-conclusion also prints the PENDING line and exits 0"
else
  bad "queued-with-no-conclusion did not print PENDING/exit 0 (exit $RC)"
fi

# (c) pending + MISSING still exits 3 — the failing states keep winning
jq -c --arg keep "$KEPT_CTX" '(.check_runs[] | select(.name == $keep)) |= (.conclusion = null | .status = "in_progress")' \
  "$TMP/runs.json" > "$TMP/runs-pending-dead.json"
set +e
bash "$VERIFY" --spec "$TMP/dead2.json" --runs "$TMP/runs-pending-dead.json" --sha probe --deadlock >/dev/null 2>&1
RC=$?
set -e
if [ "$RC" -eq 3 ]; then
  ok "pending + missing still exits 3 — PENDING never outranks DEADLOCK"
else
  bad "pending + missing exited $RC, not 3"
fi

# (d) pending + CANCELLED still exits 4
OTHER_CTX="$(SPEC_CONTEXTS | sed -n 2p)"
if [ -n "$OTHER_CTX" ]; then
  jq -c --arg keep "$KEPT_CTX" --arg oth "$OTHER_CTX" \
    '(.check_runs[] | select(.name == $keep)) |= (.conclusion = null | .status = "in_progress")
     | (.check_runs[] | select(.name == $oth)  | .conclusion) = "cancelled"' \
    "$TMP/runs.json" > "$TMP/runs-pending-cancel.json"
  set +e
  bash "$VERIFY" --spec "$TMP/enforced.json" --runs "$TMP/runs-pending-cancel.json" --sha probe --deadlock >/dev/null 2>&1
  RC=$?
  set -e
  if [ "$RC" -eq 4 ]; then
    ok "pending + cancelled still exits 4 — PENDING never outranks RE-RUN"
  else
    bad "pending + cancelled exited $RC, not 4"
  fi
else
  bad "spec has fewer than 2 contexts — the pending+cancelled probe has nothing to drive"
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

# ── AN EMPTY FEED IS NOT A DEADLOCK, AND THE REFUSAL THAT SAYS SO IS THIS
#    CALLER'S ────────────────────────────────────────────────────────────────
#
# `rendered_names` now reads through scripts/lib/check-runs.sh, which returns an
# empty feed as zero rows and exit 0 on purpose (the sampler needs that; see §4).
# Drop the call-site refusal and the guard does not go quietly green — it goes
# LOUDLY WRONG: zero rendered names makes every required context read as missing,
# so an unusable feed is reported as exit 3 DEADLOCK, a formal accusation that
# the committed spec names contexts the workflows never emit. scripts/bp-merge.sh
# routes on that 3. Wrong state, right-looking red.
RC8_EMPTY_RUNS="$TMP/runs-empty.json"
echo '{ "check_runs": [] }' > "$RC8_EMPTY_RUNS"
RC8_E_OUT="$(bash "$VERIFY" --spec "$TMP/enforced.json" --readback "$TMP/rb.json" --runs "$RC8_EMPTY_RUNS" --sha probe 2>&1)" && RC8_E_RC=0 || RC8_E_RC=$?
if [ "$RC8_E_RC" -eq 1 ] && grep -q "refusing to declare agreement against an empty feed" <<<"$RC8_E_OUT"; then
  ok "an EMPTY check-run feed FAILS BY NAME (exit 1) — never a green, and never a deadlock verdict against the spec"
else
  bad "an empty check-run feed did not red with the guard's own refusal (exit $RC8_E_RC): $(grep -m2 -e FAIL -e DEADLOCK <<<"$RC8_E_OUT")"
fi
RC8_NOEMPTY="$TMP/verify-no-empty-refusal.sh"
sed 's%^.*refusing to declare agreement against an empty feed.*$%    || : # EMPTY REFUSAL REMOVED%' "$VERIFY" > "$RC8_NOEMPTY"
RC8_MUTN="$(grep -c 'EMPTY REFUSAL REMOVED' "$RC8_NOEMPTY" || true)"
if [ "$RC8_MUTN" -ne 1 ]; then
  bad "the empty-refusal mutation applied $RC8_MUTN times, not 1 — the fail moved, so the proof below is vacuous"
else
  ok "the mutation applies: the verifier's empty-feed fail is removed from a copy"
  # --workflows/--prose for the reason §8b(d) writes down: the mutant lives in
  # $TMP, so its own REPO_ROOT is the temp directory.
  RC8_NEUTRAL="$TMP/rc8-prose-neutral"
  mkdir -p "$RC8_NEUTRAL"
  printf '%s\n' "Neutral corpus, naming no required context." > "$RC8_NEUTRAL/neutral.md"
  RC8_M_OUT="$(bash "$RC8_NOEMPTY" --spec "$TMP/enforced.json" --readback "$TMP/rb.json" --runs "$RC8_EMPTY_RUNS" --sha probe --workflows "$REPO_ROOT/.github/workflows" --prose "$RC8_NEUTRAL" 2>&1)" && RC8_M_RC=0 || RC8_M_RC=$?
  if [ "$RC8_M_RC" -eq 3 ] && grep -q "DEADLOCK: the committed spec requires context(s) that head" <<<"$RC8_M_OUT"; then
    ok "…and WITHOUT it the identical empty feed becomes a FALSE DEADLOCK (exit 3) blaming the spec — the fail-open the shared reader would have handed us"
  else
    bad "the unguarded verify did not reproduce the false deadlock (exit $RC8_M_RC) — the clause above may be reding for an unrelated reason: $(grep -m2 -e FAIL -e DEADLOCK <<<"$RC8_M_OUT")"
  fi
fi
jq '.protection.required_status_checks.checks = []' "$TMP/enforced.json" > "$TMP/empty-spec.json"
if bash "$VERIFY" --spec "$TMP/empty-spec.json" --readback "$TMP/rb.json" --runs "$TMP/runs.json" --sha probe >/dev/null 2>&1; then
  bad "a spec requiring nothing passed"
else
  ok "a spec that requires ZERO contexts FAILS — it could never fail, which is the disease"
fi

section "8b. enforced=false is CHECKED against the live branch, not taken on the spec's word"

# THE DEFECT THIS SECTION PINS (cch-w51-s6). `run_full`'s `enforced != true`
# branch used to `return 0` before `live_protection` was ever called — the first
# live read sat on the line AFTER that return. So the guard could not see one of
# the two drift directions at all: SPEC SAYS THE GATE IS OFF WHILE THE GATE IS
# ON. Measured on the primary checkout, 652 commits behind, against a live
# branch carrying four required contexts under `enforce_admins: true`: exit 0,
# "protection is not applied yet". Not a stale-checkout chore — a code property,
# reachable from `scripts/bp-merge.sh:77`, which resolves the verifier out of
# whatever checkout the merger happens to be sitting in.
#
# HERMETIC, and the "unprotected" fixture is GitHub's OWN 404 body rather than a
# sentinel invented here: `{"message":"Branch not protected"}` is what the API
# returns, is what the live code path greps for, and is already quoted as
# expected output in five other files in this repo. A fixture that agreed with
# the code only because both were made up would prove nothing.

RCS6_UNAPPLIED="$TMP/s6-unapplied.json"          # the committed spec, flag flipped off
jq '.enforced = false' "$SPEC" > "$RCS6_UNAPPLIED"
RCS6_UNPROTECTED="$TMP/s6-rb-unprotected.json"
printf '%s\n' '{"message":"Branch not protected","documentation_url":"https://docs.github.com/rest/branches/branch-protection"}' > "$RCS6_UNPROTECTED"

# (a) THE DRIFT DIRECTION. enforced=false spec, live branch PROTECTED -> red,
#     and red NAMING what it found: a bare non-zero would be satisfied by an
#     outage, a bad fixture path, or any other refusal in the file.
RCS6_OUT="$(bash "$VERIFY" --spec "$RCS6_UNAPPLIED" --readback "$TMP/rb.json" --runs "$TMP/runs.json" --sha probe 2>&1)" && RCS6_RC=0 || RCS6_RC=$?
RCS6_MISSING=""
while IFS= read -r c; do
  grep -qF "$c" <<<"$RCS6_OUT" || RCS6_MISSING="$RCS6_MISSING $c"
done < <(SPEC_CONTEXTS)
if [ "$RCS6_RC" -ne 0 ] && grep -q "IS PROTECTED right now" <<<"$RCS6_OUT" && [ -z "$RCS6_MISSING" ]; then
  ok "an enforced=false spec against a PROTECTED branch REDS (exit $RCS6_RC) and names all $(SPEC_CONTEXTS | grep -c .) live context(s)"
else
  bad "the enforced=false/protected drift was not caught as a named red (exit $RCS6_RC, unnamed:${RCS6_MISSING:- none}): $(grep -m2 FAIL <<<"$RCS6_OUT")"
fi
# …and it must not ALSO claim agreement in the same breath.
if grep -q "protection is not applied yet" <<<"$RCS6_OUT"; then
  bad "the drift red still printed the all-agree line — a red that also says OK is read as OK"
else
  ok "…and the run does NOT print the \`protection is not applied yet\` line it used to exit 0 on"
fi

# (b) THE LEGITIMATE CASE, unchanged. Same spec, genuinely unprotected branch.
#     Without this the fix would be indistinguishable from "always red here",
#     which is how a guard gets disabled two waves later.
RCS6_OK_OUT="$(bash "$VERIFY" --spec "$RCS6_UNAPPLIED" --readback "$RCS6_UNPROTECTED" --runs "$TMP/runs.json" --sha probe 2>&1)" && RCS6_OK_RC=0 || RCS6_OK_RC=$?
if [ "$RCS6_OK_RC" -eq 0 ] && grep -q "genuinely unprotected" <<<"$RCS6_OK_OUT"; then
  ok "…while a genuinely unapplied spec against a genuinely unprotected branch still exits 0"
else
  bad "the pre-flip case broke (exit $RCS6_OK_RC): $(tail -2 <<<"$RCS6_OK_OUT")"
fi

# (c) COULD-NOT-LOOK IS NOT AGREEMENT. An unreadable read-back on this branch
#     must red, and must say so in those terms — the whole finding is a guard
#     that greened because it declined to look.
RCS6_BLIND_OUT="$(bash "$VERIFY" --spec "$RCS6_UNAPPLIED" --readback "$TMP/nope.json" --runs "$TMP/runs.json" --sha probe 2>&1)" && RCS6_BLIND_RC=0 || RCS6_BLIND_RC=$?
if [ "$RCS6_BLIND_RC" -ne 0 ] && grep -q "could not look at live protection" <<<"$RCS6_BLIND_OUT" \
   && ! grep -q "protection is not applied yet" <<<"$RCS6_BLIND_OUT"; then
  ok "…and an unreadable live protection on the enforced=false path REDS as \"could not look\", never as agreement"
else
  bad "the no-read path did not degrade honestly (exit $RCS6_BLIND_RC): $(tail -2 <<<"$RCS6_BLIND_OUT")"
fi

# (d) MUTATION PROOF. Remove the new clause's CALL from a copy of verify and
#     (a)'s exact fixture must sail through green again. Without this, (a)
#     passes on any refusal the file happens to raise for another reason —
#     and the BEFORE half of this slice's claim is unproven.
RCS6_NOCHECK="$TMP/verify-no-s6-clause.sh"
sed -E 's%^( *)unapplied_spec_matches_reality \|\| return 1%\1: # S6 CLAUSE REMOVED%' "$VERIFY" > "$RCS6_NOCHECK"
if ! grep -q "S6 CLAUSE REMOVED" "$RCS6_NOCHECK"; then
  bad "the s6 mutation did not apply — the clause's call is no longer on its own line, so the proof below is vacuous"
else
  ok "the mutation applies: the enforced=false live-probe call is removed from a copy of verify"
  # `--workflows` explicitly: the mutant lives in $TMP, so its own REPO_ROOT
  # points at the temp dir and the advisory-prose clause would red for a reason
  # that has nothing to do with what is being proven here. `--prose` for the
  # same reason and the same directory: the merge-truth clause (cch-w34) scans
  # `git ls-files` in REPO_ROOT, which in $TMP is not a checkout at all, so the
  # mutant would refuse before ever reaching the clause this proof is about.
  RCS6_NEUTRAL="$TMP/s6-prose-neutral"
  mkdir -p "$RCS6_NEUTRAL"
  printf '%s\n' "Neutral corpus, naming no required context." > "$RCS6_NEUTRAL/neutral.md"
  RCS6_MUT_OUT="$(bash "$RCS6_NOCHECK" --spec "$RCS6_UNAPPLIED" --readback "$TMP/rb.json" --runs "$TMP/runs.json" --sha probe --workflows "$REPO_ROOT/.github/workflows" --prose "$RCS6_NEUTRAL" 2>&1)" && RCS6_MUT_RC=0 || RCS6_MUT_RC=$?
  if [ "$RCS6_MUT_RC" -eq 0 ] && grep -q "protection is not applied yet" <<<"$RCS6_MUT_OUT"; then
    ok "…and WITHOUT it the SAME protected read-back exits 0 saying \`protection is not applied yet\` — the old blindness, reproduced on demand"
  else
    bad "the unguarded verify did not reproduce the blindness (exit $RCS6_MUT_RC) — clause (a) may be reding for an unrelated reason: $(tail -2 <<<"$RCS6_MUT_OUT")"
  fi
fi

section "9. verify --selftest is itself green"

RC9_OUT="$(bash "$VERIFY" --selftest 2>&1)" && RC9_RC=0 || RC9_RC=$?
# The count is READ OFF the selftest's own numbering (`1/29` … `29/29`) rather
# than typed here. It was typed here, it said 16 against a suite of 23, and a
# label four clauses behind is the same instrument fault this file exists to
# hunt: a number nobody re-earns. §9 is also the only home `--selftest` has —
# drift.yml no longer runs it as a step of its own.
RC9_N="$(sed -n 's/^  ok   [0-9]*\/\([0-9]*\) .*/\1/p' <<<"$RC9_OUT" | tail -1)"
if [ "$RC9_RC" -eq 0 ] && [ -n "$RC9_N" ]; then
  ok "verify --selftest passes ($RC9_N mutation clauses, counted from its own numbering)"
elif [ "$RC9_RC" -eq 0 ]; then
  bad "verify --selftest exited 0 but printed no numbered clause — a suite that runs nothing exits 0 too"
else
  bad "verify --selftest is red (exit $RC9_RC): $(grep -m2 'SELFTEST FAIL' <<<"$RC9_OUT")"
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
# falsifiable mutation in one direction. `enforced: false` used to be treated as
# a COMMITTED, reviewable state that full mode deliberately did not diff against
# live config — so post-flip the inverted (false) spec was asserted GREEN. That
# was the blindness, not a design (cch-w51-s6): full mode now reads live
# protection on that path too, so post-flip the inverted spec REDS and names
# what it found. The CONTENT mutation below — a required context live protection
# does not carry — stays as the second, independent falsifier, reached through
# the field that moves in both eras.
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
    # THE INVERTED FLAG USED TO BE ASSERTED GREEN HERE, and that assertion was
    # the blindness written down as a requirement (cch-w51-s6). Post-flip the
    # branch IS protected, so a spec claiming `enforced=false` is not "a
    # committed, reviewable state" — it is a spec contradicting the live gate,
    # in the one direction the guard used to return 0 without reading. It must
    # red, and it must NAME the live contexts, or the red is outage-shaped.
    local imout imrc=0
    imout="$(bash "$VERIFY" --spec "$FULLMUT" 2>&1)" || imrc=$?
    if [ "$imrc" -eq 0 ]; then
      bad "full mode PASSED with enforced=false while the branch IS protected — the guard declined to look (cch-w51-s6)"
    elif grep -q "IS PROTECTED right now" <<<"$imout"; then
      ok "…and the INVERTED flag (enforced=false) REDS against a protected branch, naming the live contexts (the direction the guard used to skip)"
    else
      bad "full mode red on the inverted flag (exit $imrc) without naming the live protection — outage-shaped: $(grep -m2 FAIL <<<"$imout")"
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

# ── 12b. the floor holds `_readme` and `enforced` too ────────────────────────
#
# THE BLINDNESS THIS DELETES, measured before it was written:
# `grep -c '_readme\|enforced' scripts/required-checks-floor.sh` returned 0, and
# a candidate identical to the committed spec except `_readme: ["gone"]` and
# `enforced: false` printed `FLOOR OK … identical on context AND app_id`, exit 0.
#
# Every specimen below keeps the CONTEXT SET EXACTLY EQUAL to the reference, so
# none of them can be caught by the superset comparison §12 already asserts —
# that equality is itself an assertion, not a comment, so it cannot rot into a
# test that secretly re-proves the old clause.
#
# HERMETIC, and driven through `--reference` for the same reason §12 is: a
# harness that needs `origin/main` to resolve is a harness a depth-1 CI checkout
# eventually skips.
cat > "$TMP/floor-ref-doc.json" <<'JSON'
{ "enforced": true,
  "_readme": [
    "GENERATED by a fixture — never hand-edit a context string.",
    "THE FLOOR IS A SEPARATE ARTIFACT, and regenerating this file without it is how the required set silently shrinks.",
    "EXCLUSIONS ARE WHAT THE SAMPLE SAW, never a complete census.",
    "MERGE PROTOCOL: scripts/bp-merge.sh, argument-free, from the PR branch's own worktree."
  ],
  "protection": { "required_status_checks": { "strict": false, "checks": [
    { "context": "Elixir gate", "app_id": 15368 },
    { "context": "PR references an active task", "app_id": 15368 }
  ] } } }
JSON

floor_doc() { # candidate [extra args…] -> prints output, returns the floor's rc
  local cand="$1"; shift
  bash "$FLOOR" --reference "$TMP/floor-ref-doc.json" "$@" "$cand" 2>&1
}

# (h) THE PASS CASE, and the PASS LINE MUST NAME WHAT IT CHECKED. A summary that
#     says "identical on context AND app_id" while not looking at `_readme` is
#     how this script read as more thorough than it was for its whole life.
cp "$TMP/floor-ref-doc.json" "$TMP/floor-same-doc.json"
FOUT="$(floor_doc "$TMP/floor-same-doc.json")" && FRC=0 || FRC=$?
if [ "$FRC" -eq 0 ] && grep -q "FLOOR OK" <<<"$FOUT" \
   && grep -q "4 committed _readme" <<<"$FOUT" && grep -q "enforced still true" <<<"$FOUT"; then
  ok "the floor PASSES an identical candidate and its PASS line NAMES the _readme and enforced axes it checked"
else
  bad "the pass line did not account for _readme/enforced (exit $FRC): $(head -2 <<<"$FOUT")"
fi

# (i) THE CLOBBER. `_readme` replaced wholesale, contexts untouched, enforced
#     untouched. This is the specimen that was FLOOR OK before this clause.
jq '._readme = ["regenerated: one stub paragraph"]' "$TMP/floor-ref-doc.json" > "$TMP/floor-readme-clobber.json"
if [ "$(jq -cS '.protection' "$TMP/floor-readme-clobber.json")" = "$(jq -cS '.protection' "$TMP/floor-ref-doc.json")" ]; then
  ok "…and the clobber specimen's protection block is BYTE-IDENTICAL to the reference (so the superset comparison provably cannot catch it)"
else
  bad "the clobber specimen changed the contexts — it no longer proves the _readme clause is what caught it"
fi
FOUT="$(floor_doc "$TMP/floor-readme-clobber.json")" && FRC=0 || FRC=$?
if [ "$FRC" -eq 1 ] && grep -q "README LOST" <<<"$FOUT" && grep -q "LOST README  THE FLOOR IS A SEPARATE ARTIFACT" <<<"$FOUT"; then
  ok "the floor REFUSES a candidate that drops committed _readme entries (exit 1) and NAMES the dropped paragraph"
else
  bad "the floor did not refuse the _readme clobber (exit $FRC): $(head -3 <<<"$FOUT")"
fi

# …and a single dropped paragraph is caught too, not only a wholesale replace:
# the generator's realistic shape is a MERGE that loses one entry, not four.
jq '._readme = [._readme[0], ._readme[2], ._readme[3]]' "$TMP/floor-ref-doc.json" > "$TMP/floor-readme-one.json"
FOUT="$(floor_doc "$TMP/floor-readme-one.json")" && FRC=0 || FRC=$?
if [ "$FRC" -eq 1 ] && grep -q "LOST README  THE FLOOR IS A SEPARATE ARTIFACT" <<<"$FOUT"; then
  ok "…and ONE dropped paragraph out of four is enough (the realistic merge-shape loss, not just the wholesale replace)"
else
  bad "the floor waved through a single dropped _readme entry (exit $FRC): $(head -3 <<<"$FOUT")"
fi

# MUTATION PROOF for the _readme refusal: blank the clause on a COPY and the
# SAME clobber specimen must sail through to FLOOR OK. Without this, the two
# assertions above pass on any refusal at all.
FLOOR_NOREADME="$TMP/floor-noreadme.sh"
sed -E 's|^.*# README-LOSS CLAUSE$|  readme_lost="" # README-LOSS CLAUSE REMOVED|' "$FLOOR" > "$FLOOR_NOREADME"
if [ "$(grep -c 'README-LOSS CLAUSE REMOVED' "$FLOOR_NOREADME")" -eq 1 ]; then
  ok "the _readme mutation applies EXACTLY ONCE (an anchor that matched zero or many lines proves nothing)"
else
  bad "the _readme mutation applied $(grep -c 'README-LOSS CLAUSE REMOVED' "$FLOOR_NOREADME") time(s) — the proof below would be vacuous"
fi
MOUT="$(bash "$FLOOR_NOREADME" --reference "$TMP/floor-ref-doc.json" "$TMP/floor-readme-clobber.json" 2>&1)" && MRC=0 || MRC=$?
if [ "$MRC" -eq 0 ] && grep -q "FLOOR OK" <<<"$MOUT"; then
  ok "…and WITHOUT it the same clobber is FLOOR OK again (mutation-proven able to fail — this is the pre-fix behaviour, reproduced)"
else
  bad "the un-clauses floor still refused the clobber (exit $MRC) — something else is catching it: $(head -2 <<<"$MOUT")"
fi

# (j) `enforced` true → false. Contexts and `_readme` both untouched.
jq '.enforced = false' "$TMP/floor-ref-doc.json" > "$TMP/floor-unenforced.json"
FOUT="$(floor_doc "$TMP/floor-unenforced.json")" && FRC=0 || FRC=$?
if [ "$FRC" -eq 1 ] && grep -q "ENFORCED REGRESSED" <<<"$FOUT"; then
  ok "the floor REFUSES enforced true→false (exit 1) — the flip that makes verify's live-protection diff skip itself"
else
  bad "the floor accepted an enforced downgrade (exit $FRC): $(head -3 <<<"$FOUT")"
fi
# DELETING the field is the same downgrade wearing a different hat, and a guard
# that only compares `false` lets the deletion through.
jq 'del(.enforced)' "$TMP/floor-ref-doc.json" > "$TMP/floor-noenforced.json"
FOUT="$(floor_doc "$TMP/floor-noenforced.json")" && FRC=0 || FRC=$?
if [ "$FRC" -eq 1 ] && grep -q "the candidate says absent" <<<"$FOUT"; then
  ok "…and DELETING enforced is refused too, and named as absent rather than reported as false"
else
  bad "a candidate with no enforced field passed the enforcement floor (exit $FRC): $(head -3 <<<"$FOUT")"
fi

# MUTATION PROOF for the enforcement refusal.
FLOOR_NOENF="$TMP/floor-noenf.sh"
sed -E 's|^.*# ENFORCED-REGRESSION CLAUSE$|  enforced_regressed=0 # ENFORCED-REGRESSION CLAUSE REMOVED|' "$FLOOR" > "$FLOOR_NOENF"
if [ "$(grep -c 'ENFORCED-REGRESSION CLAUSE REMOVED' "$FLOOR_NOENF")" -eq 1 ]; then
  ok "the enforced mutation applies EXACTLY ONCE"
else
  bad "the enforced mutation applied $(grep -c 'ENFORCED-REGRESSION CLAUSE REMOVED' "$FLOOR_NOENF") time(s) — the proof below would be vacuous"
fi
MOUT="$(bash "$FLOOR_NOENF" --reference "$TMP/floor-ref-doc.json" "$TMP/floor-unenforced.json" 2>&1)" && MRC=0 || MRC=$?
if [ "$MRC" -eq 0 ] && grep -q "FLOOR OK" <<<"$MOUT"; then
  ok "…and WITHOUT it the enforced:false candidate is FLOOR OK again (mutation-proven able to fail)"
else
  bad "the un-clauses floor still refused enforced:false (exit $MRC): $(head -2 <<<"$MOUT")"
fi

# (k) NEITHER CLAUSE MAY RED THE IMPROVING DIRECTION. A guard that refuses every
#     edit is a guard nobody keeps: ADDING a paragraph and turning enforcement ON
#     are the two shapes that must stay silent, and a floor that reddened them
#     would be quietly reverted the first time someone documented something.
jq '._readme += ["a NEW paragraph a human wrote this wave"]' "$TMP/floor-ref-doc.json" > "$TMP/floor-readme-grown.json"
FOUT="$(floor_doc "$TMP/floor-readme-grown.json")" && FRC=0 || FRC=$?
if [ "$FRC" -eq 0 ] && grep -q "FLOOR OK" <<<"$FOUT"; then
  ok "ADDING an _readme paragraph is not growth and not a breach — more explanation is never a downgrade (exit 0)"
else
  bad "the floor reddened an ADDED _readme paragraph (exit $FRC): $(head -3 <<<"$FOUT")"
fi
jq '.enforced = false' "$TMP/floor-ref-doc.json" > "$TMP/floor-ref-off.json"
FOUT="$(bash "$FLOOR" --reference "$TMP/floor-ref-off.json" "$TMP/floor-ref-doc.json" 2>&1)" && FRC=0 || FRC=$?
if [ "$FRC" -eq 0 ]; then
  ok "…and enforced false→true PASSES: the floor holds the direction that is a loss, not every change"
else
  bad "the floor refused an enforcement UPGRADE (exit $FRC): $(head -3 <<<"$FOUT")"
fi

# (l) A reference that carries neither field floors neither — and SAYS so. This
#     is what keeps §12's own fixtures (which have no `_readme` and no
#     `enforced`) from turning into a vacuous pass that reads like a real one.
FOUT="$(floor "$TMP/floor-same.json")" && FRC=0 || FRC=$?
if [ "$FRC" -eq 0 ] && grep -q "the reference carries no _readme, so none is floored" <<<"$FOUT" \
   && grep -q "the reference does not say enforced=true" <<<"$FOUT"; then
  ok "a reference with no _readme and no enforced floors neither, and the PASS line SAYS which axes it did not check"
else
  bad "the floor implied it checked _readme/enforced against a reference that carries neither: $(head -2 <<<"$FOUT")"
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
    | ( cd "$REPO_ROOT" && tr '\n' '\0' | xargs -0 grep -nHE 'gh pr merge[^`]*--admin' 2>/dev/null ) || true
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
#
# The scan above carries `-H` for THIS assertion's sake, matching §18's `-nHE`.
# grep omits the filename prefix when it is handed exactly ONE file, so without
# `-H` the canary line comes back as `1:poll checks + …` with no path and the
# `grep -q 'ratchet-canary'` below MISSES — the match was found, the assertion
# reported it broken. That made this mutation proof silently dependent on the
# tracked corpus being >= 2 files: it defeats itself on a one-file corpus and
# on any tree where git tracks nothing (see the object-database refusal above).
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
# THE EXCLUSION HALF OF THE SAME ACKNOWLEDGEMENT (wave 57). `--expect-unrendered`
# now answers for the `.exclusions` ledger as well as the check list, and this
# frozen pair cannot render ten committed exclusion rows: six elixir.yml names
# that simply did not run on these two heads, two whose jobs are
# pull_request-only and therefore unrenderable on ANY branch head (`gofmt drift
# ceiling (blocking)` and `PR task gate self-test`), and two whose jobs DID NOT
# EXIST at either frozen head — `Sobelow baseline rows still hash to their own
# fingerprint (blocking)` and `Dispatch (compose-smoke paths)`, whose whole
# workflow landed on 2026-08-09, nine days after both frozen heads. They are
# listed here ONE NAME AT
# A TIME, exactly as an operator would type them, so a row that stops being
# unrenderable reds this file instead of quietly widening a blanket waiver. §14b
# below asserts the refusal that makes this list necessary; every section that
# wants a successful EMIT passes "$ACK".
#
# THE THIRD CAUSE OF ABSENCE, and it is the one that broke this gate for a week
# (#14073, red from 253a83184a). The generator's refusal names two causes — a name
# no window can EVER render, and a window that is merely anomalous ("re-sample").
# A job ADDED AFTER the fixture pair was frozen is neither: re-sampling is exactly
# what D130 forbids here, so the frozen pair can never grow the name, and the row
# is permanently unrenderable ON THIS WINDOW while being perfectly renderable on a
# live head. Acknowledgement is therefore the only sanctioned move, and it is the
# SIXTH place a new blocking job has to pay — #14073's own message enumerated the
# other five (the job, the aggregator's `needs`, its decide binding, every `env -i`
# simulator of that step body, and the spec-authority marker) and stopped there.
# ADDING A BLOCKING JOB TO security.yml? Add its rendered name below.
ACK_EX=(--expect-unrendered "Dispatch (changed-path sets)"
        --expect-unrendered "Dispatch (compose-smoke paths)"
        --expect-unrendered "Elixir path-escape ratchet"
        --expect-unrendered "Format (mix format --check-formatted, advisory) (27.0, 1.18.1)"
        --expect-unrendered "gofmt drift ceiling (blocking)"
        --expect-unrendered "PR task gate self-test"
        --expect-unrendered "Prod compile gate (Elixir 1.18.1 / OTP 27.0)"
        --expect-unrendered "Sobelow baseline rows still hash to their own fingerprint (blocking)"
        --expect-unrendered "Test (Elixir 1.18.1 / OTP 27.0)"
        --expect-unrendered "Validation perf bench (median-of-5, alarm >100ms) (27.0, 1.18.1)")
ACK=(--expect-unrendered "Elixir gate" --expect-unrendered "PR references an active task"
     "${ACK_EX[@]}")

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

emit_spec "$TMP/ack-spec.json" bash "$GEN" "${FIXARGS[@]}" "${ACK[@]}" --out "$TMP/ack-spec.json" || true
if jq -e '[.protection.required_status_checks.checks[].context]
          == ["Cloud gate","Console gate","Elixir gate","PR references an active task"]' \
     "$TMP/ack-spec.json" >/dev/null 2>&1; then
  ok "…and per-NAME acknowledgement lets it through, emitting exactly the four contexts"
else
  fail_emit "$(why_emit "the acknowledged emit is $(jq -c '[.protection.required_status_checks.checks[].context]' "$TMP/ack-spec.json" 2>&1)")"
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
# "${ACK_EX[@]}" and NOT "${ACK[@]}": the exclusion arm is acknowledged so this
# mutation stays SINGLE-VARIABLE — the two check names are left unacknowledged on
# purpose, because they are the whole subject of the proof.
NL_OUT="$(bash "$NOLOSS" "${FIXARGS[@]}" "${ACK_EX[@]}" 2>&1)" && NL_RC=0 || NL_RC=$?
if [ "$NL_RC" -eq 0 ] && ! grep -q "^S1 LOSS" <<<"$NL_OUT"; then
  ok "…and without it the SAME sample is accepted in silence (mutation-proven able to fail)"
else
  bad "the unguarded run still refused (exit $NL_RC): $(grep -E '^(S1 LOSS|EXCLUSION LOSS)|^ *(LOST|STALE) ' <<<"$NL_OUT" | head -3 | tr '\n' '⏎')"
fi

# MUTATION (ii): the MERGE is the other half, and it is separately load-bearing.
# `--no-merge` IS the pre-wave-11 emit path — `jq -n` into a pure overwrite — and
# on this very fixture pair it emits a spec that has DROPPED both committed
# names. That is the de-registration this slice exists to make impossible.
emit_spec "$TMP/overwrite-spec.json" \
  bash "$GEN" --workflows "$REPO_ROOT/.github/workflows" --fixture-dir "$FIXP" --no-merge \
  --sha e34031104 --sha f69cfb1f6 --out "$TMP/overwrite-spec.json" || true
if jq -e '[.protection.required_status_checks.checks[].context]
          | (index("Elixir gate") | not) and (index("PR references an active task") | not)' \
     "$TMP/overwrite-spec.json" >/dev/null 2>&1; then
  ok "the OVERWRITE path emits a spec MISSING both committed names — the merge, not the refusal, is what carries them"
else
  fail_emit "$(why_emit "the overwrite specimen did not drop the committed names: $(jq -c '[.protection.required_status_checks.checks[].context]' "$TMP/overwrite-spec.json" 2>&1)")"
fi

section "14b. EXCLUSION LOSS — the DECISION LEDGER gets the same pair: the merge CARRIES the row, the refusal NOTICES it"

# WHY THIS SECTION EXISTS (wave 57), and it is not hypothetical. Until this wave
# the emit read `exclusions: $exclusions` with no base at all — eleven lines
# below the check list's base-first union — so this very fixture pair took 25
# exclusion rows IN and wrote 18 OUT, EXIT 0, ZERO BYTES ON STDERR. The rows that
# vanished included `gofmt drift ceiling (blocking)`, whose reason carries the
# longest load-bearing prose in the file, and the loss is IRRECOVERABLE by
# re-running: stage 2 iterates the INTERSECTION, so a name that did not render
# can never re-enter the derived array.
#
# AND THE SUITE COULD NOT SEE ANY OF IT. On origin/main this file reported
# `166 passed, 0 failed` on the broken tree AND on a tree carrying the fix — a
# byte-identical verdict — which means the repair would have landed as
# revertible as the loss it repairs. That is what this section deletes.
#
# THE SEED IS SYNTHETIC ON PURPOSE. §14 keys on the committed spec because it is
# a statement ABOUT it; this one seeds its own base row, so the proof survives
# any future edit to `.exclusions` and cannot go vacuous when a real row's
# renderability changes. The row names a job no workflow publishes, which is the
# strongest form of "cannot render": no sampling window anywhere can restore it.
SEEDX="$TMP/seeded-base.json"
SEEDNAME="Ghost ceiling (blocking) — no workflow publishes this name"
# THE SECOND SEED IS SYNTHETIC FOR THE SAME REASON (hg: §14b was half-synthetic).
# The PULL_REQUEST-ONLY half of the distinction used to be keyed to a REAL
# workflow trigger shape (go-format.yml was the repo's only pull_request-only
# specimen carrying an excluded context), so the CORRECT act of adding a push
# arm to that workflow would red this section with a message naming neither the
# workflow nor the reason. The seed row below pairs with a synthetic
# pull_request-only WORKFLOW in a copied workflows dir, so the proof survives
# any trigger edit to any real workflow — exactly the principle already stated
# for the ghost seed.
PRSEEDNAME="Seeded PR-only ceiling (blocking) — published against merge refs only"
jq --arg c "$SEEDNAME" --arg pr "$PRSEEDNAME" \
   '.exclusions += [
      {context: $c,  reason: "SEEDED BY THE TEST SUITE: a hand-added decision row whose name no workflow publishes, so no sample can ever re-derive it"},
      {context: $pr, reason: "SEEDED BY THE TEST SUITE: a decision row whose job exists only in a synthetic pull_request-only workflow, so it can never render on a branch head"}
    ]' \
   "$SPEC" > "$SEEDX"
# The synthetic workflows dir: every real workflow, plus ONE pull_request-only
# workflow publishing the PR-only seed name. Used by §14b alone.
mkdir -p "$TMP/workflows-14b"
cp "$REPO_ROOT/.github/workflows"/*.yml "$TMP/workflows-14b/" 2>/dev/null || true
cat >"$TMP/workflows-14b/zz-seeded-pr-only.yml" <<EOF
name: zz-seeded-pr-only
on:
  pull_request:
    paths:
      - "zz-seeded-nonexistent-path/**"
jobs:
  seeded:
    name: "$PRSEEDNAME"
    runs-on: ubuntu-latest
    steps:
      - run: "true"
EOF
SEEDARGS=(--workflows "$TMP/workflows-14b" --fixture-dir "$FIXP"
          --merge-base "$SEEDX" --sha e34031104 --sha f69cfb1f6)

X14_OUT="$(bash "$GEN" "${SEEDARGS[@]}" --expect-unrendered "Elixir gate" \
             --expect-unrendered "PR references an active task" 2>&1)" && X14_RC=0 || X14_RC=$?
if [ "$X14_RC" -eq 1 ] \
   && grep -q "^EXCLUSION LOSS" <<<"$X14_OUT" \
   && grep -qF "LOST  $SEEDNAME" <<<"$X14_OUT" \
   && grep -qF "LOST  gofmt drift ceiling (blocking)" <<<"$X14_OUT"; then
  ok "an unreproduced exclusion row is REFUSED (exit 1) and named — the seeded one and the real gofmt one alike"
else
  bad "the exclusion loss was not refused (exit $X14_RC): $(grep -E 'EXCLUSION LOSS|LOST' <<<"$X14_OUT" | head -3)"
fi
# The DISTINCTION, each half keyed to ITS OWN synthetic seed row's line — never
# to a real workflow's trigger shape, which a correct edit is allowed to change.
if grep -F "LOST  $SEEDNAME" <<<"$X14_OUT" | grep -qF "no job in"; then
  ok "…the deleted-job absence is named ON the ghost row itself (no job in …)"
else
  bad "the ghost row did not carry the deleted-job hint: $(grep -F "LOST  $SEEDNAME" <<<"$X14_OUT")"
fi
if grep -F "LOST  $PRSEEDNAME" <<<"$X14_OUT" | grep -qF "PULL_REQUEST-ONLY"; then
  ok "…and the pull_request-only absence is named ON the seeded PR-only row — keyed to the synthetic workflow, so adding a push arm to any REAL workflow cannot red this"
else
  bad "the seeded PR-only row did not carry the PULL_REQUEST-ONLY hint: $(grep -F "LOST  $PRSEEDNAME" <<<"$X14_OUT")"
fi

emit_spec "$TMP/seeded-spec.json" \
  bash "$GEN" "${SEEDARGS[@]}" "${ACK[@]}" --expect-unrendered "$SEEDNAME" \
  --expect-unrendered "$PRSEEDNAME" \
  --out "$TMP/seeded-spec.json" || true
if jq -e --arg c "$SEEDNAME" '[.exclusions[].context] | index($c)' "$TMP/seeded-spec.json" >/dev/null 2>&1; then
  ok "…and once acknowledged the seeded row SURVIVES the regeneration (the merge carries what the sample cannot see)"
else
  fail_emit "$(why_emit "the seeded exclusion did not survive: $(jq -c '[.exclusions[].context]' "$TMP/seeded-spec.json" 2>&1)")"
fi
# Set inclusion, never a count: a count is satisfied by any 26 rows at all.
if jq -e --slurpfile base "$SEEDX" \
     '[.exclusions[].context] as $out
      | ($base[0].exclusions | map(.context) | map(. as $c | $out | index($c) != null) | all)' \
     "$TMP/seeded-spec.json" >/dev/null 2>&1; then
  ok "…and EVERY committed exclusion context survives, 'gofmt drift ceiling (blocking)' included (set inclusion over the whole seeded base)"
else
  fail_emit "$(why_emit "rows were dropped: $(jq -c --slurpfile b "$SEEDX" '[$b[0].exclusions[].context] - [.exclusions[].context]' "$TMP/seeded-spec.json" 2>&1)")"
fi
# The union must not FREEZE a row's grounds: where this run restated a reason,
# the DERIVED one wins. `Security gate` is committed as an S7 decision and the
# frozen pair reads it red on main, so the emitted reason must be the S5 one.
if jq -e '[.exclusions[] | select(.context == "Security gate") | .reason]
          | any(startswith("S5 RED ON MAIN"))' "$TMP/seeded-spec.json" >/dev/null 2>&1 \
   && jq -e '[.exclusions[] | select(.context == "Security gate") | .reason]
             | any(startswith("S7 EXCLUDED BY DECISION"))' "$SEEDX" >/dev/null 2>&1; then
  ok "…and where BOTH sides carry a row the DERIVED reason wins ('Security gate': S7 committed → S5 emitted)"
else
  fail_emit "$(why_emit "the base reason survived the derivation: $(jq -c '[.exclusions[] | select(.context == "Security gate") | .reason[0:40]]' "$TMP/seeded-spec.json" 2>&1)")"
fi

# MUTATION (i): the UNION is load-bearing. Drop the base out of it — the exact
# `exclusions: $exclusions` origin/main shipped — and the acknowledged run must
# silently write a spec that has LOST the seeded row.
NOUNION="$TMP/gen-nounion.sh"
sed 's|\$b\.exclusions // \[\]|[]|' "$GEN" > "$NOUNION"
if ! grep -q '\$b\.exclusions' "$NOUNION"; then
  ok "the exclusion-union mutation applies: a copy of the generator merges no base into .exclusions"
else
  bad "the exclusion-union mutation did not apply — the expression moved, so the proof below is vacuous"
fi
emit_spec "$TMP/nounion-spec.json" \
  bash "$NOUNION" "${SEEDARGS[@]}" "${ACK[@]}" --expect-unrendered "$SEEDNAME" \
  --expect-unrendered "$PRSEEDNAME" \
  --out "$TMP/nounion-spec.json" || true
if jq -e --arg c "$SEEDNAME" \
     '([.exclusions[].context] | index($c) | not) and (.exclusions | length < 20)' \
     "$TMP/nounion-spec.json" >/dev/null 2>&1; then
  ok "…and without it the IDENTICAL run drops the seeded row and emits 18 of 26 (mutation-proven able to fail)"
else
  fail_emit "$(why_emit "the un-merged spec did not lose the row: $(jq -c '.exclusions | length' "$TMP/nounion-spec.json" 2>&1)")"
fi

# MUTATION (ii): the REFUSAL is separately load-bearing. The union alone buys
# IMMORTALITY as well as survival — a row for a job nobody publishes any more
# rides through forever — so neuter the refusal and watch the unacknowledged run
# carry the ghost in silence.
NOXREF="$TMP/gen-noxref.sh"
sed 's/^    if \[ -n "\$lost_ex" \]; then$/    if false; then # EXCLUSION REFUSAL REMOVED/' "$GEN" > "$NOXREF"
if grep -q 'EXCLUSION REFUSAL REMOVED' "$NOXREF"; then
  ok "the exclusion-refusal mutation applies: a copy of the generator no longer refuses"
else
  bad "the exclusion-refusal mutation did not apply — its condition moved, so the proof below is vacuous"
fi
NX_OUT="$(bash "$NOXREF" "${SEEDARGS[@]}" --expect-unrendered "Elixir gate" \
            --expect-unrendered "PR references an active task" \
            --out "$TMP/noxref-spec.json" 2>&1)" && NX_RC=0 || NX_RC=$?
if [ "$NX_RC" -eq 0 ] && ! grep -q "^EXCLUSION LOSS" <<<"$NX_OUT" \
   && jq -e --arg c "$SEEDNAME" '[.exclusions[].context] | index($c)' "$TMP/noxref-spec.json" >/dev/null 2>&1; then
  ok "…and without it the ghost row is carried in SILENCE, unacknowledged and unmentioned (mutation-proven able to fail)"
else
  bad "the unguarded run did not go silent (exit $NX_RC): $(grep -E 'EXCLUSION LOSS|LOST' <<<"$NX_OUT" | head -2)"
fi

# THE CONTRADICTION IS NOT ACKNOWLEDGEABLE. A committed exclusion whose context
# this run SELECTED as required is not an absence — the emit would carry one name
# on both lists — so `--expect-unrendered` must not silence it.
STALEX="$TMP/stale-base.json"
jq '.exclusions += [{context: "Cloud gate", reason: "SEEDED BY THE TEST SUITE: a row this sample selects as REQUIRED"}]' \
  "$SPEC" > "$STALEX"
SX_OUT="$(bash "$GEN" --workflows "$REPO_ROOT/.github/workflows" --fixture-dir "$FIXP" \
            --merge-base "$STALEX" --sha e34031104 --sha f69cfb1f6 \
            "${ACK[@]}" --expect-unrendered "Cloud gate" 2>&1)" && SX_RC=0 || SX_RC=$?
if [ "$SX_RC" -eq 1 ] && grep -q "STALE Cloud gate" <<<"$SX_OUT"; then
  ok "a committed exclusion this run REQUIRES is refused as STALE, and the acknowledgement flag does not silence it"
else
  bad "the required/excluded contradiction was not refused (exit $SX_RC): $(grep -E 'STALE|EXCLUSION LOSS' <<<"$SX_OUT" | head -2)"
fi
# Its own acknowledgement DROPS the row rather than carrying it — an operator
# saying "the derivation is right, the held-out decision is spent". A carry here
# would be the incoherence the refusal exists to prevent, just typed by hand.
emit_spec "$TMP/promoted-spec.json" \
  bash "$GEN" --workflows "$REPO_ROOT/.github/workflows" --fixture-dir "$FIXP" \
  --merge-base "$STALEX" --sha e34031104 --sha f69cfb1f6 \
  "${ACK[@]}" --expect-promoted "Cloud gate" --out "$TMP/promoted-spec.json" || true
if jq -e '([.exclusions[].context] | index("Cloud gate") | not)
          and ([.protection.required_status_checks.checks[].context] | index("Cloud gate"))' \
     "$TMP/promoted-spec.json" >/dev/null 2>&1; then
  ok "…and --expect-promoted DROPS that row instead of carrying it, so no context is emitted as both required and excluded"
else
  fail_emit "$(why_emit "the promoted acknowledgement left the spec self-contradictory: $(jq -c '[.exclusions[].context] | index("Cloud gate")' "$TMP/promoted-spec.json" 2>&1)")"
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
# `--expect-promoted` on the three leaves: without S6 this mutant SELECTS names
# the committed spec holds out, which the exclusion arm (§14b) correctly refuses
# as a contradiction. Acknowledging it is what lets the assertion below read the
# emit — and it is also the shape of the accident: the flags name exactly the
# three contexts a missing demotion pass would have registered.
emit_spec "$TMP/nos6-spec.json" \
  bash "$NOS6" "${FIXARGS[@]}" "${ACK[@]}" \
  --expect-promoted "Dispatch (security paths)" \
  --expect-promoted "Security gate shape ratchet" \
  --expect-promoted "Sobelow baseline does not swallow its own inline waivers (blocking)" \
  --out "$TMP/nos6-spec.json" || true
if jq -e '[.protection.required_status_checks.checks[].context] as $c
          | ($c | index("Dispatch (security paths)"))
            and ($c | index("Security gate shape ratchet"))
            and ($c | index("Sobelow baseline does not swallow its own inline waivers (blocking)"))' \
     "$TMP/nos6-spec.json" >/dev/null 2>&1; then
  ok "…and without S6 the identical fixture PROMOTES all three security leaves into the spec (mutation-proven able to fail)"
else
  fail_emit "$(why_emit "the un-demoted spec did not promote the leaves: $(jq -c '[.protection.required_status_checks.checks[].context]' "$TMP/nos6-spec.json" 2>&1)")"
fi

section "16. the deadlock sweep's predicate is TWO-SIDED — a PR that is already stuck is not a casualty of the flip"

SWEEP="$REPO_ROOT/scripts/registration-deadlock-sweep.sh"
SWF="$TMP/sweep-fixtures"
mkdir -p "$SWF"
# HERMETIC BASELINE, for the reason §12 already wrote down two hundred lines
# above and this section originally ignored: CI checks out at depth 1 and the
# remote-tracking ref `origin/main` OFTEN DOES NOT EXIST on a runner at all —
# actions/checkout fetches the PR ref. The first draft of this section did
# `git show origin/main:…` and died with `fatal: invalid object name
# 'origin/main'` on every PR, reding a job that is green on main. So the
# baseline is a literal fixture and reaches the sweep through --ref-file, the
# same harness seam the floor exposes as --reference.
#
# The candidate adds ONE SYNTHETIC name over that baseline. Synthetic on
# purpose: no real registration can ever make this name stop being new, so the
# section cannot rot the way a real name would. Built from the BASELINE, not
# the worktree spec — the sweep's "newly proposed" set is candidate minus
# baseline, so a candidate derived from the worktree would also carry whatever
# contexts THIS PR is adding and the section would assert about those instead
# of about its own probe.
cat > "$TMP/sweep-ref.json" <<'JSON'
{ "protection": { "required_status_checks": { "strict": false, "checks": [
  { "context": "Elixir gate", "app_id": 15368 },
  { "context": "PR references an active task", "app_id": 15368 }
] } } }
JSON
jq '.protection.required_status_checks.checks += [{context: "Probe gate", app_id: 15368}]' \
  "$TMP/sweep-ref.json" > "$TMP/sweep-candidate.json"
# …and the DEFAULT reference — the one that matters in anger — is asserted by
# reading the script, so --ref-file cannot quietly become the norm. Mirrors the
# floor's own default assertion in §12.
if grep -q 'REF_REV="origin/main"' "$SWEEP" \
   && grep -q 'git -C "$REPO_ROOT" show "$REF_REV:$SPEC_PATH"' "$SWEEP"; then
  ok "the sweep's DEFAULT baseline is still \`git show origin/main:\`, never the worktree copy the PR rewrites"
else
  bad "the sweep's default baseline moved — --ref-file must stay a harness seam, not the norm"
fi
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

sweep() { bash "$SWEEP" --spec "$TMP/sweep-candidate.json" --ref-file "$TMP/sweep-ref.json" \
            --fixture-dir "$SWF" --prs "$1" 2>&1; }

# An unreadable baseline must FAIL, never sweep against an empty set: with a
# zero-context baseline EVERY proposed context looks new and the sweep would
# refuse the world — an exit-1 that means "I could not see", the same shape the
# builder already fixed for mergeable=UNKNOWN.
echo '{ "protection": { "required_status_checks": { "checks": [] } } }' > "$TMP/sweep-ref-empty.json"
EMPTY_OUT="$(bash "$SWEEP" --spec "$TMP/sweep-candidate.json" --ref-file "$TMP/sweep-ref-empty.json" \
  --fixture-dir "$SWF" --prs "$TMP/sweep-prs-safe.json" 2>&1)" && EMPTY_RC=0 || EMPTY_RC=$?
if [ "$EMPTY_RC" -eq 2 ] && grep -q "baseline requires ZERO contexts" <<<"$EMPTY_OUT"; then
  ok "a baseline requiring ZERO contexts is an INFRA FAULT (exit 2), never an empty diff"
else
  bad "the sweep accepted an empty baseline (exit $EMPTY_RC): $(head -2 <<<"$EMPTY_OUT")"
fi

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

# ═══ AN ALL-SKIPPED SWEEP IS EVIDENCE OF NOTHING (wave 37, D422) ═════════════
#
# NOT HYPOTHETICAL, AND NOT THE UNKNOWN CASE ABOVE. Measured against this repo
# on 2026-08-06 — twice, six minutes apart, byte-identical — with a candidate
# adding `Required-check spec gate`: thirteen open PRs, THIRTEEN `skip` rows,
# `casualties: 0`, `NO CASUALTY`, exit 0. Every mergeability was COMPUTED (so the
# UNKNOWN refusal never fires) and side (B) was still never asked about a single
# head: eight were MERGEABLE/BLOCKED, four CONFLICTING/DIRTY, one a DRAFT. That
# green would have authorized registering a fifth required context on `main`
# under `enforce_admins: true`, on zero evaluated PRs.
#
# THE FIXTURE IS ALL-SKIP BY THREE DIFFERENT ROUTES on purpose, because the
# refusal must not be reachable only through the one state a lazy fixture picks.
cat > "$SWF/checkruns-sweepDRAFT.json" <<'JSON'
{ "check_runs": [ { "name": "Some other check", "conclusion": "success", "status": "completed", "started_at": "2026-07-30T01:00:00Z" } ] }
JSON
cat > "$TMP/sweep-prs-allskip.json" <<'JSON'
[
 {"number":11,"headRefOid":"sweepDRAFT","mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE","isDraft":true,"title":"a draft — a STABLE exclusion"},
 {"number":12,"headRefOid":"sweepBLOCKED","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","isDraft":false,"title":"a required check still in flight — TRANSIENT"},
 {"number":13,"headRefOid":"sweepDIRTY","mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","isDraft":false,"title":"already conflicting"}
]
JSON
SW_ALL="$(sweep "$TMP/sweep-prs-allskip.json")" && SW_ALL_RC=0 || SW_ALL_RC=$?
if [ "$SW_ALL_RC" -eq 2 ] && grep -q "evaluated 0 of 3 open PR(s)" <<<"$SW_ALL"; then
  ok "a sweep that skipped EVERY open PR exits 2 and names the empty evaluated set — 'casualties: 0' on zero evidence is not a finding"
else
  bad "the all-skip sweep did not fail closed (exit $SW_ALL_RC): $(tail -2 <<<"$SW_ALL")"
fi
# COVERAGE IS REPORTED ON EVERY RUN, not only on the refusal — that line is what
# stops a PARTIAL sweep (exit 0, and it must stay exit 0 or the guard becomes
# unpassable and gets bypassed) from being quoted as a full one.
if grep -q "evaluated 1, skipped 2" <<<"$SW_SAFE" && grep -q "PARTIAL COVERAGE: 2 PR(s) were skipped" <<<"$SW_SAFE"; then
  ok "…and a sweep that evaluated 1 of 3 says PARTIAL COVERAGE out loud rather than reporting a bare NO CASUALTY"
else
  bad "the partial-coverage sweep did not report its coverage: $(tail -3 <<<"$SW_SAFE")"
fi
# THE TWO SKIP REASONS ARE NOT ONE REASON. A DRAFT is a stable exclusion; a PR
# BLOCKED by a run still in flight is a measurement taken early. Before wave 37
# both printed the identical "not currently mergeable-and-unblocked", which is
# how thirteen rows of nothing read as thirteen rows of clearance.
if grep -q "^#11 .*skip:draft" <<<"$SW_ALL" && grep -q "^#12 .*skip:blocked" <<<"$SW_ALL" \
   && grep -q "^#13 .*skip:conflicting" <<<"$SW_ALL" \
   && grep -q "TRANSIENT" <<<"$SW_ALL" && grep -q "STABLE exclusion" <<<"$SW_ALL"; then
  ok "a DRAFT, a transiently-BLOCKED PR and a CONFLICTING PR are three DIFFERENT skip rows, not one sentence three times"
else
  bad "the skip reasons are still reported identically: $(grep -E '^#1[123]' <<<"$SW_ALL")"
fi
# MUTATION: remove the coverage refusal and the same fixture goes GREEN on zero
# evidence — the exact byte-identical failure measured on main. This is the guard
# shown able to lose.
NOCOV="$TMP/sweep-nocoverage.sh"
sed 's/^  if \[ "\$evaluated" -eq 0 \]; then$/  if false; then # COVERAGE REFUSAL REMOVED/' "$SWEEP" > "$NOCOV"
if grep -q 'COVERAGE REFUSAL REMOVED' "$NOCOV"; then
  ok "the coverage mutation applies: a copy of the sweep no longer refuses an empty evaluated set"
else
  bad "the coverage mutation did not apply — the refusal moved, so the proof below is vacuous"
fi
NC_OUT="$(RC_REPO_ROOT="$REPO_ROOT" bash "$NOCOV" --spec "$TMP/sweep-candidate.json" \
           --ref-file "$TMP/sweep-ref.json" \
           --fixture-dir "$SWF" --prs "$TMP/sweep-prs-allskip.json" 2>&1)" && NC_RC=0 || NC_RC=$?
if [ "$NC_RC" -eq 0 ] && grep -q "NO CASUALTY" <<<"$NC_OUT"; then
  ok "…and without it the all-skip fixture exits 0 with NO CASUALTY on zero evaluated PRs (fail-before proven, not asserted)"
else
  bad "the unguarded copy did not reproduce the vacuous green (exit $NC_RC): $(tail -2 <<<"$NC_OUT")"
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
           --ref-file "$TMP/sweep-ref.json" \
           --fixture-dir "$SWF" --prs "$TMP/sweep-prs-safe.json" 2>&1)" && OS_RC=0 || OS_RC=$?
if [ "$OS_RC" -eq 1 ] && grep -q "^#3 .*REFUSE" <<<"$OS_OUT" && grep -q "^#4 .*REFUSE" <<<"$OS_OUT"; then
  ok "…and the one-sided version REFUSES on both already-stuck PRs — the second side is load-bearing (mutation-proven able to fail)"
else
  bad "the one-sided version did not produce the false alarms (exit $OS_RC): $(grep -E '^#' <<<"$OS_OUT" | head -4)"
fi

# ═══ AND A CANDIDATE THAT PROPOSES NOTHING NEW EXAMINES NOTHING (wave 39) ════
#
# THE SIBLING OF THE ALL-SKIP CASE ABOVE, and until this block nothing in this
# file pinned it. Measured on 2026-08-07 against merge base 9e39c60c: running
# the sweep with a candidate equal to `main`'s COMMITTED spec exits 0 after TWO
# lines, having made zero `gh` calls — `grep -c 'PARTIAL COVERAGE\|evaluated'`
# on that output was 0, because the identity short-circuit fires BEFORE the
# counters exist. That is the run a human produces by executing the flip
# packet's steps out of order: sweeping AFTER the spec PR merged, when candidate
# and baseline are the same file. The exit code cannot tell it apart from a full
# sweep that found no casualty.
#
# THE FIXTURE IS THE BASELINE ITSELF, passed as the candidate — the identity
# case in its purest form, and it needs no PR feed precisely because the script
# never reaches one.
ID_OUT="$(bash "$SWEEP" --spec "$TMP/sweep-ref.json" --ref-file "$TMP/sweep-ref.json" \
           --fixture-dir "$SWF" --prs "$TMP/sweep-prs-safe.json" 2>&1)" && ID_RC=0 || ID_RC=$?
if [ "$ID_RC" -eq 0 ] && grep -q "^NO COVERAGE: this run listed no pull request" <<<"$ID_OUT"; then
  ok "a candidate that proposes no new context still exits 0 — a bare sweep on a spec-untouching branch stays passable — but now NAMES what it did not examine"
else
  bad "the identity candidate printed no NO COVERAGE line (exit $ID_RC): $(tail -2 <<<"$ID_OUT")"
fi
# THE COPY FENCE (D386/D438): the line STATES the absence and stops. Advice
# bolted onto a diagnosis nobody asked for is what gets skimmed past, so the
# assertion is that no imperative follows.
ID_LINE="$(grep '^NO COVERAGE:' <<<"$ID_OUT")"
if ! grep -Eqi '(re-?run|re-?order|pass +--|sweep the|you should|make sure|instead,)' <<<"$ID_LINE"; then
  ok "…and that line carries no instruction about what to do next — it reports the absence, it does not coach"
else
  bad "the NO COVERAGE line appended advice (D386/D438): $ID_LINE"
fi
# AND THE FLAG THE FLIP-AUTHORIZING CALLER PASSES TURNS IT INTO A REFUSAL,
# through the same fail() the UNKNOWN and all-skip cases already use.
IDF_OUT="$(bash "$SWEEP" --spec "$TMP/sweep-ref.json" --ref-file "$TMP/sweep-ref.json" \
            --require-new-context --fixture-dir "$SWF" --prs "$TMP/sweep-prs-safe.json" 2>&1)" && IDF_RC=0 || IDF_RC=$?
if [ "$IDF_RC" -eq 2 ] && grep -q "Under --require-new-context that is exit 2" <<<"$IDF_OUT"; then
  ok "…and under --require-new-context the same candidate REFUSES (exit 2) — sweeping a spec that already merged is not evidence for the flip it was meant to authorize"
else
  bad "--require-new-context did not refuse the identity candidate (exit $IDF_RC): $(tail -2 <<<"$IDF_OUT")"
fi
# MUTATION: remove the identity refusal and the flagged run goes green on the
# same fixture — the assertion above is shown able to lose, not merely asserted.
NOID="$TMP/sweep-noidentity.sh"
sed 's/^    if \[ "\$REQUIRE_NEW_CONTEXT" -eq 1 \]; then$/    if false; then # IDENTITY REFUSAL REMOVED/' "$SWEEP" > "$NOID"
NI_OUT="$(RC_REPO_ROOT="$REPO_ROOT" bash "$NOID" --spec "$TMP/sweep-ref.json" \
           --ref-file "$TMP/sweep-ref.json" --require-new-context \
           --fixture-dir "$SWF" --prs "$TMP/sweep-prs-safe.json" 2>&1)" && NI_RC=0 || NI_RC=$?
if grep -q 'IDENTITY REFUSAL REMOVED' "$NOID" && [ "$NI_RC" -eq 0 ]; then
  ok "…and a copy with that refusal removed exits 0 on the identical fixture (fail-before proven, not asserted)"
else
  bad "the identity mutation did not reproduce the vacuous green (applied=$(grep -c 'IDENTITY REFUSAL REMOVED' "$NOID"), exit $NI_RC): $(tail -2 <<<"$NI_OUT")"
fi

section "17. S7 holds \`Security gate\` OUT once it goes GREEN — the stage that held it is gone, the hold is not"

# WHY THIS SECTION EXISTS, and it is not hypothetical (wave 11 REVIEW).
# `Security gate` was held out of the flip by S5 RED ON MAIN. Between the build
# and the review, 95ace3150 landed a req bump from OUTSIDE this epic and the
# name went green on main — so the mechanical ground evaporated and re-running
# the generator against the post-bump window KEPT it, i.e. the next person to
# follow the file's own instruction ("regenerate immediately before any flip")
# would have silently registered it. That is forbidden: its sole blocking
# upstream is mix-audit, which reads a LIVE advisory database, so a CVE
# published tomorrow reds it on every open PR with no change to this repo.
#
# The fixture is DERIVED, not committed: the frozen pair with `Security gate`'s
# conclusion flipped to success everywhere. Deriving it means it cannot drift
# out of agreement with the pair §15 asserts over, and it states the premise
# (green on main) as data rather than as prose.
S7F="$TMP/postbump-fixtures"
mkdir -p "$S7F"
cp "$FIXP/main-shas.txt" "$S7F/"
for f in "$FIXP"/checkruns-*.json; do
  jq '.check_runs |= map(if .name == "Security gate" then .conclusion = "success" else . end)' \
    "$f" > "$S7F/$(basename "$f")"
done
S7ARGS=(--workflows "$REPO_ROOT/.github/workflows" --fixture-dir "$S7F"
        --merge-base "$SPEC" --sha e34031104 --sha f69cfb1f6)

S7_OUT="$(bash "$GEN" "${S7ARGS[@]}" "${ACK[@]}" --explain 2>&1 || true)"
if ! grep -q "exclude  Security gate  — S5 RED ON MAIN" <<<"$S7_OUT"; then
  ok "the derived fixture really is post-bump: S5 no longer fires on 'Security gate'"
else
  bad "the derived fixture still reads RED on main — the flip did not apply, so this section is vacuous"
fi
if grep -q "exclude  Security gate  — S7 EXCLUDED BY DECISION" <<<"$S7_OUT"; then
  ok "…and S7 holds it out anyway, on a stated forward-looking ground"
else
  bad "'Security gate' was not held by S7 on a green fixture: $(grep -F 'Security gate  —' <<<"$S7_OUT" | head -1)"
fi
# S6 must key on the EXCLUSION, not on the stage that produced it: with the hold
# moved from S5 to S7 the three leaves must still go down, not up.
for leaf in "Dispatch (security paths)" "Security gate shape ratchet" \
            "Sobelow baseline does not swallow its own inline waivers (blocking)"; do
  if grep -qF "exclude  $leaf  — S6 LEAF OF AN EXCLUDED AGGREGATOR (Security gate)" <<<"$S7_OUT"; then
    ok "S6 still demotes '$leaf' under an S7 hold — the demotion keys on the exclusion, not on S5"
  else
    bad "S6 did not demote '$leaf' under S7: $(grep -F "$leaf" <<<"$S7_OUT" | head -1)"
  fi
done

# MUTATION: drop the S7 entry and the SAME green fixture must PROMOTE the name
# into required protection — which is precisely what a live regeneration did
# before this hold existed.
NOS7="$TMP/gen-nos7.sh"
sed 's/^  "Security gate"$//' "$GEN" > "$NOS7"
if ! grep -q '^  "Security gate"$' "$NOS7"; then
  ok "the S7 mutation applies: a copy of the generator no longer names 'Security gate' in its decision list"
else
  bad "the S7 mutation did not apply — the entry moved, so the proof below is vacuous"
fi
# `--expect-promoted "Security gate"` for the same reason as §15's three leaves:
# the mutant registers a name the committed spec holds OUT, and §14b refuses that
# contradiction rather than emitting one context on both lists.
emit_spec "$TMP/nos7-spec.json" \
  bash "$NOS7" "${S7ARGS[@]}" "${ACK[@]}" --expect-promoted "Security gate" \
  --out "$TMP/nos7-spec.json" || true
if jq -e '[.protection.required_status_checks.checks[].context] | index("Security gate")' \
     "$TMP/nos7-spec.json" >/dev/null 2>&1; then
  ok "…and without it the identical green fixture REGISTERS 'Security gate' (mutation-proven able to fail)"
else
  fail_emit "$(why_emit "the un-held spec did not promote it: $(jq -c '[.protection.required_status_checks.checks[].context]' "$TMP/nos7-spec.json" 2>&1)")"
fi

# The committed file must not still be teaching the evaporated ground.
if ! jq -e '[.exclusions[] | select(.context == "Security gate") | .reason]
            | any(startswith("S5 RED ON MAIN"))' "$SPEC" >/dev/null 2>&1; then
  ok "the committed spec no longer grounds the 'Security gate' hold in S5 RED ON MAIN"
else
  bad "the committed spec still says 'Security gate' is red on main — it is green on main head 6e53d2782"
fi

# ═══ 18. the protection-claim census ═════════════════════════════════════════

section "18. no UNPINNED in-repo text still claims this repo's \`main\` is unprotected"

# THE POINT. `main` IS protected — since 2026-07-28T22:42:10Z, with exactly four
# required contexts (Elixir gate, PR references an active task, Cloud gate,
# Console gate) and `enforce_admins: true`. Tracked text that still tells an
# agent the opposite does not just misinform: it retires the merge protocol the
# rest of this toolchain exists to enforce, and the fleet reads prose long
# before it reads an API.
#
# WHY THIS IS A NEW SIBLING CLAUSE AND NOT A WIDENING OF `advisory_prose_check`
# (required-checks-verify.sh:374). That clause is anchored on SPEC'D CONTEXT
# NAMES: it walks the four required names and looks for a disclaimer within 200
# chars AFTER one of them. A blanket claim about protection AS A WHOLE names no
# context, so it is not merely unmatched — it is structurally unreachable.
# Measured: `.github/workflows/bp-graph-drift.yml` already sits INSIDE that
# clause's scanned directory and carried such a claim while passing. Widening
# WORKFLOWS_DIR buys nothing; adding a phrasing to PROSE_DISCLAIMERS buys
# nothing. Hence: its own scan, its own corpus, its own census.
#
# THE REGEX SHIPS NARROW, and each dropped term was dropped on a live reading:
#   `no rulesets`          — TRUE today. `gh api repos/FRIKKern/barkpark/rulesets`
#                            → `[]`. Protection here is CLASSIC branch protection,
#                            not a ruleset. docs/ops/merge-gates.md:241 already
#                            documents this as "a TRUE reading that produces the
#                            WRONG conclusion" — matching it would red a truth.
#   `Branch not protected` — GitHub's OWN 404 body, quoted as EXPECTED OUTPUT in
#                            breakglass.sh:153, breakglass.test.sh:81 and :255,
#                            breakglass-watch.sh:111 and :139, and
#                            required-checks-verify.sh:109. Matching it reds the
#                            break-glass toolchain's own fixtures.
#   bare `unprotected` /   — in this corpus it means an unprotected export path,
#   `not protected`          unprotected DB columns, an unprotected PR base, and a
#                            deliberately-unprotected test fixture. Four senses,
#                            none of them this one.
# Measured here on 2026-08-06, over the scan set below: restoring those loose
# terms takes the census to 89 hits; the claim-shape regex that ships returns 35
# (32 after the three live offenders were fixed in this same commit). The
# narrowing is not a convenience — it makes the API-LITERAL class STRUCTURALLY
# EMPTY rather than allowlisted, and an exemption that does not exist cannot be
# quietly widened later.
#
# `git grep --untracked`, NOT `git grep`. Measured on this repo: a plain
# `git grep` scores 0 on a NEW untracked file and 1 with the flag. Without it,
# every future "I proved this guard can fail" mutation planted in a new file is
# a vacuous green — inside the very guard written to attack vacuous greens.
# KNOWN PRICE, and it is the right way round: an UNCOMMITTED scratch note in a
# scanned directory reds the LOCAL run even though CI (which checks out clean)
# is green. Delete the scratch file or finish the note — do not drop the flag.
#
# WHEN THIS SECTION REDS ON A LINE THAT IS FINE (a new dated ledger, a new
# retraction): read the line, decide its class, and PIN it — the hash is already
# printed in the UNPINNED row, so paste `<hash>  <class>  <path>:<line>  <why>`
# into the list below. Never delete a line from the list to silence a STALE row
# without also confirming the member it pinned was genuinely fixed.
#
# WHAT WAVE 36 DID TO THIS SECTION, so the next reader does not re-derive it.
# Charter PR #9751 merged and this section went RED on main head 070c7584b: 11
# UNPINNED + 2 STALE, and NINE of the eleven were wave 35's OWN grip ledgers,
# flagged for quoting this census's search pattern inside the corpus it scans.
# It blocked nothing — the spec gate is not one of `main`'s four required
# contexts — and that is the exhibit, not the excuse: #9751's own spec gate
# concluded `failure` at 11:50:12Z and the PR merged 23 seconds later.
#
# The remedy was NOT to paste eleven pins. Eight of the eleven were pattern
# quoting, so the QUOTED-PATTERN FENCE below retires them as a CLASS (41 raw
# rows -> 33 AS MEASURED AT WAVE 36's COMMIT — it is 42 -> 33 today, and the
# fence's own comment carries the re-derivation; UNPINNED 11 -> 4), taking the
# pinned charter row `965d722b53f6`
# with it — which is why THREE stale pins were dropped in that commit
# (`ce745c039e38`, `562eb5d348c9`, `965d722b53f6`) and not the two this comment
# used to predict. The four survivors were READ and classified by hand: two
# class-B dated retractions in this epic's own charter, two class-C dated
# records in wave 35's census ledger. Their pin notes carry the reading.
#
# THE STANDING COST IS NOW MUCH SMALLER, BUT IT IS NOT ZERO, so nobody
# discovers it as a surprise and silences the section: `tooling/grip/ledger/**`
# is append-only, and a ledger that STATES a claim (rather than quoting a search
# for it) still arrives UNPINNED. That is the design — a dated record gets one
# human reading before it is exempt. The fallback this comment used to offer,
# exempting the ledger directory BY SUBJECT the way §13 does, is now REFUSED on
# a measurement: see the fence's own comment and mutation 4 below.
#
# THE LIMIT THIS GUARD CANNOT CLOSE, stated here rather than discovered later:
# THIS IS A PINNED CENSUS, NOT A SEMANTIC DETECTOR. It pins today's members by
# CONTENT HASH and reds on any NEW instance of the enumerated phrasings — a
# fresh paraphrase walks straight through it. Measured escape, exit 0:
# "Nothing in CI mechanically blocks a merge here; the gates are discipline."
# Nor can literal matching classify: this file's own charter row D106 matches
# only because it contains the SEARCH PATTERN `grep -c "no branch protection"`,
# which is not a claim at all. That is exactly why members are PINNED and
# re-reviewed on edit rather than auto-classified — an edited line loses its pin
# and comes back for a human reading.
#
# THE PIN LIST BELOW IS CLASSIFIED, and the classes are the review contract:
#   B  a CORRECT dated retraction or correction — the line says the claim is now
#      false, and quotes it in order to retire it. Green because it is TRUE.
#   C  a DATED RECORD — a grip ledger recipe or a foreign epic's charter D-row,
#      true on the day it was measured. Rewriting a record to match today is
#      falsifying it (same ground as §13's ledger and charter exemptions).
#   D  NOT A CLAIM ABOUT THIS REPO — a search pattern quoted as a pattern, or a
#      statement about ANOTHER repo. jarl-gates-live-status:45 is about
#      FRIKKern/jarl-website and is STILL TRUE of it: that repo's
#      branches/main/protection returns 404 today. Exempt by SUBJECT, not by pin.
#   (Class A — a LIVE claim about THIS repo — is not pinnable. The three found
#   at wave 35 were FIXED in the same commit that added this clause:
#   .github/workflows/bp-graph-drift.yml:15, scripts/check-bp-graph-drift.sh:27,
#   and .claude/workflows/bp-search-template-charter.md:103 — the D72 row that
#   DECIDED both comments, so fixing only the two would leave the rationale
#   alive to be re-copied. Pinning your own live falsehood is the
#   "exempted by phrase = disarmed" failure this clause exists to attack.)
#
# ONE EXCLUSION, and it is the same one §13 makes for its own ratchet: THIS
# FILE. It necessarily contains the pattern, the planted canary text and the
# failure messages, so scanning itself would pin the guard to its own wording
# and red on every edit to this section. Nothing else in `scripts/` is exempt.
PROTECTION_CLAIM_RE='(no|No|NO|zero|Zero) branch protection|main is NOT PROTECTED|no CI check in this repo can block a merge'
PROTECTION_SCAN=(.claude/workflows .github docs scripts tooling/grip/ledger CLAUDE.md
                 ':!scripts/required-checks.test.sh')

# ═══ THE QUOTED-PATTERN FENCE (wave 36) ══════════════════════════════════════
#
# WHAT IT EXEMPTS, AND NOTHING ELSE: a phrasing that sits INSIDE THE QUOTED
# ARGUMENT of a search command (`grep`, `git grep`, `rg`, `ag`) or inside a
# regex ASSIGNMENT (`RE='…'`, `CLAIM_PATTERN="…"`). Those are not claims about
# this repo at all — they are the census's own search string, quoted so a human
# can re-run it. Wave 35 proved this the expensive way: eight of the forty-one
# census rows on main AT THAT COMMIT were documentation OF THIS GUARD, and the
# guard reddened on all eight. A required check that fails because someone wrote
# down how it works is a guard that punishes its own audit trail.
#
# MEASURED at main ef77af274 (wave 37, re-derived — see the recipe below, and
# RUN IT rather than trusting this line): 42 raw rows -> 33 fenced, removing 9 —
# 7 by the search-argument fence (charter D106, which quotes `grep -c "…"`, plus
# the wave-35 grip-ledger lines quoting `grep -rn`, `git grep -nIE` or
# `git grep --untracked -lIE`) and 2 by the regex-assignment fence (`RE='…'`).
#
# THE FIGURES ABOVE DRIFTED ONCE ALREADY, which is why the recipe is here. Wave
# 36 wrote "41 raw -> 33, removing exactly 8"; one new raw row arrived after
# #9849 and the search-argument fence ate it, so the removal count moved to 9
# while the FENCED total stayed 33 — the section stayed green while its own
# reproduction recipe misled the next reader. Re-derive, do not quote:
#
#   RE='(no|No|NO|zero|Zero) branch protection|main is NOT PROTECTED|no CI check in this repo can block a merge'
#   raw() { git grep --untracked -lE "$RE" -- .claude/workflows .github docs scripts \
#             tooling/grip/ledger CLAUDE.md ':!scripts/required-checks.test.sh' \
#           | tr '\n' '\0' | xargs -0 grep -nHE "$RE"; }
#   raw | wc -l                                        # raw rows        -> 42
#   raw | grep -vE "$ARG_RE" | grep -vE "$ASSIGN_RE" | wc -l   # fenced  -> 33
#
# (ARG_RE/ASSIGN_RE are the two variables assigned immediately below; the counts
# are of ROWS, and the fenced total is what the pin list is a set-equality over.)
#
# WHY NOT THE CHEAP ALTERNATIVE — SCOPING `tooling/grip/ledger` OUT, the shape
# §13 uses and this section's own comment offered as the fallback. REFUSED, and
# the refusal is MEASURED, not argued: the ledger directory is exactly where a
# wave writes its reading of `main`'s protection, so exempting it blinds the
# census in its highest-yield corpus. Planted specimen 3 below is a LIVE class-A
# claim written into `tooling/grip/ledger/` — the fence still FIRES on it, and a
# ledger-scoped variant misses it entirely. That contrast is the ruling; the two
# mutation clauses at the end of this section pin it so the fence cannot be
# widened back into a path exemption without reddening.
#
# THE FENCE CAN LOSE, BY CONSTRUCTION. It requires the quote to be the search
# command's own argument (command, then flags, then the opening quote), so
# co-mentioning a `grep` on the same line as a live claim does NOT buy an
# exemption — specimen 2 is exactly that shape and still fires. It matches on
# the SHAPE of a search invocation, not on a path, a filename or a phrase, so
# there is no "exempt directory" for a false claim to hide in.
PROTECTION_PATTERN_ARG_RE="(^|[^[:alnum:]_-])(git[[:space:]]+grep|grep|rg|ag)([[:space:]]+-[^[:space:]]+)*[[:space:]]+('[^']*($PROTECTION_CLAIM_RE)|\"[^\"]*($PROTECTION_CLAIM_RE))"
PROTECTION_PATTERN_ASSIGN_RE="(^|[^[:alnum:]_])[A-Za-z0-9_]*(RE|REGEX|PATTERN)=('[^']*($PROTECTION_CLAIM_RE)|\"[^\"]*($PROTECTION_CLAIM_RE))"

sha12() { # <string> — first 12 hex of its sha256, on Linux CI and stock macOS
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-12
  else
    printf '%s' "$1" | shasum -a 256 | cut -c1-12
  fi
}

# ONE scan, driven five times (real / new-claim canary / stale-pin canary /
# the two fence specimens). The canary runs append a path to the SAME function
# rather than re-typing the grep.
#
# The fence is applied HERE, to the matched LINE — never to the path. A path
# filter would be a directory exemption wearing a different hat; see the refusal
# above.
protection_claim_hits() { # [extra path…]
  {
    ( cd "$REPO_ROOT" && git grep --untracked -lE "$PROTECTION_CLAIM_RE" -- "${PROTECTION_SCAN[@]}" ) || true
    printf '%s\n' "$@"
  } \
    | grep -v '^$' \
    | ( cd "$REPO_ROOT" && tr '\n' '\0' | xargs -0 grep -nHE "$PROTECTION_CLAIM_RE" 2>/dev/null ) \
    | grep -vE "$PROTECTION_PATTERN_ARG_RE" \
    | grep -vE "$PROTECTION_PATTERN_ASSIGN_RE" || true
}

# The census is a SET EQUALITY, never a count. A count gate waves through the
# commit that fixes one member and ships another; this reports BOTH directions —
# UNPINNED (a claim nobody has reviewed) and STALE (a pin whose line is gone,
# i.e. someone fixed a member and left its pin behind to rot).
#
# The list lives in a FILE, not in a `"$(cat <<'PINS' … )"` assignment: stock
# macOS bash 3.2 mis-parses an apostrophe inside a heredoc nested in a quoted
# command substitution ("unexpected EOF while looking for matching `''"), and
# this suite must run on the maintainer's laptop as well as on ubuntu CI.
PROTECTION_PINS="$TMP/protection-pins.txt"
cat > "$PROTECTION_PINS" <<'PINS'
604fdeb69db8  C  .claude/workflows/bp-authoring-excellence-charter.md:267   D77 correction absorbed, dated
e11a1cf18c5b  C  .claude/workflows/bp-chat-tui-charter.md:386               reviewer-enforced ruling, measured then
2f149e72ca0b  B  .claude/workflows/bp-cloud-console-hardening-charter.md:326  D58 + inline dated retraction
be0074b37a5c  B  .claude/workflows/bp-cloud-console-hardening-charter.md:332  D64 + inline dated retraction
89ed1af64d9b  B  .claude/workflows/bp-cloud-console-hardening-charter.md:1539 READ 2026-08-06: scoped "at the time this wave-5 movement was written" and retracted in the SAME sentence, D397 + the 07-28T22:42:10Z date
6d06875ebcb3  B  .claude/workflows/bp-cloud-console-hardening-charter.md:4567 READ 2026-08-06: same shape in the wave-5 debrief — "as measured then", inline [RETRACTED … protection is live]; kept as reasoning, not as a claim
120ac92d2b12  C  .claude/workflows/bp-cloud-gui-remake-charter.md:113        GR86, measured at its Decide
7a7329787516  C  .claude/workflows/bp-cloud-gui-remake-charter.md:1294       wave narrative, dated record
1b56c84f49c0  C  .claude/workflows/bp-connectors-charter.md:541              D87, live-verified at its date
391861503ed4  C  .claude/workflows/bp-connectors-charter.md:801              D144, re-confirmed at its date
75ab60a12375  C  .claude/workflows/bp-connectors-charter.md:1243             D266, parenthetical context
4e66434d7ce9  C  .claude/workflows/bp-enterprise-ready-auth-charter.md:78    merge protocol as decided then
92fbc3a3a7c2  B  .claude/workflows/bp-felix-pristine-charter.md:2271         says the premise is FALSE
f4da604f5fe4  B  .claude/workflows/bp-felix-pristine-charter.md:2286         says the claim is now false
6c7c848eb784  B  .claude/workflows/bp-honest-gates-charter.md:205            quotes a premise that INVERTS
1a670aa32410  B  .claude/workflows/bp-honest-gates-charter.md:416            quotes what was REWRITTEN away
6cb651ae08bd  C  .claude/workflows/bp-pd-everything-editable-charter.md:83   dated record
0465a805d654  C  .claude/workflows/bp-scaffy-charter.md:22                   D9, verified at its date
84d0cb6c5f00  C  .claude/workflows/bp-search-template-charter.md:96          D65/SR-1, foreign epic's record
df2a0ce56f7b  C  .claude/workflows/bp-studio-space-priority-charter.md:47    D23, dated record
271f2d41437a  C  .claude/workflows/bp-studio-space-priority-charter.md:1405  dated record
43ae16023d04  C  .claude/workflows/bp-studio-space-priority-charter.md:1722  dated record
e56a9d69eae8  B  .claude/workflows/bp-studio-space-priority-charter.md:2445  D250 STRIKES the old memory
9dacf1fcfe5d  C  .claude/workflows/bp-studio-structure-polish-charter.md:63  R1, verified at its date
c1679f421f3e  C  .claude/workflows/bp-truth-grip-charter.md:134              dated record
a8aa0142eb43  B  docs/ops/merge-gates.md:239                                 "false since 2026-07-28"
a6fb32e3a3bc  C  tooling/grip/ledger/bpgraph-tripwire-selftest-2026-07-26.md:14        dated recipe ledger
798c02f0775f  C  tooling/grip/ledger/cch-w35-protection-claim-census-2026-08-06.md:79   READ 2026-08-06: quotes the blanket claim as the SHAPE advisory_prose_check cannot reach — a bare quoted phrase, so the fence correctly does NOT exempt it
041309eecfc1  C  tooling/grip/ledger/cch-w35-protection-claim-census-2026-08-06.md:126  READ 2026-08-06: dated finding about a FOREIGN charter's :96 and why that alternation branch is enumerated; true of that file on that day
e16a9d8d62d7  C  tooling/grip/ledger/felix-w23-gate-topology-d75-2026-07-28.md:8       dated recipe ledger
e1288ba46a68  B  tooling/grip/ledger/felix-w24-wave23-criteria-closes-2026-07-29.md:23 "both are FALSE today"
25db097ed62f  C  tooling/grip/ledger/felix-w25-sobelow-row-verdicts-2026-08-17.md:39      dated recipe ledger — quotes the DEAD premise to retire it (D75 amended away, felix-w23-s3/felix-w24-s5)
451500fdf367  C  tooling/grip/ledger/felix-w25-sobelow-row-verdicts-2026-08-17.md:40      dated recipe ledger — git show #7557 re-grounds Sobelow topology on S4, NOT the dead premise
af83a4d184e8  D  tooling/grip/ledger/jarl-gates-live-status-2026-07-31.md:45           OTHER REPO, still true of it
e9afea44318b  C  tooling/grip/ledger/second-review-and-credential-2026-07-26.md:17     dated recipe ledger
25db097ed62f  C  tooling/grip/ledger/felix-w25-sobelow-row-verdicts-2026-08-17.md:39  names the dead "no branch protection" premise, dated recipe ledger
451500fdf367  C  tooling/grip/ledger/felix-w25-sobelow-row-verdicts-2026-08-17.md:40  git show recipe quoting #7557's dated subject, dated recipe ledger
PINS

protection_census_report() { # [extra path…] — emits UNPINNED/STALE lines, or nothing
  local seen line path rest lineno text h pin note
  seen="$(mktemp "$TMP/census-seen.XXXXXX")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line%%:*}"; rest="${line#*:}"; lineno="${rest%%:*}"; text="${rest#*:}"
    h="$(sha12 "$path|$text")"
    printf '%s\n' "$h" >> "$seen"
    grep -q "^$h  " "$PROTECTION_PINS" \
      || printf 'UNPINNED  %s  %s:%s  %s\n' "$h" "$path" "$lineno" "$(printf '%s' "$text" | cut -c1-90)"
  done <<<"$(protection_claim_hits "$@")"
  while read -r pin note; do
    [ -n "$pin" ] || continue
    grep -qx "$pin" "$seen" || printf 'STALE  %s  %s\n' "$pin" "$note"
  done < "$PROTECTION_PINS"
}

CENSUS_OUT="$(protection_census_report)"
if [ -z "$CENSUS_OUT" ]; then
  ok "the protection-claim census matches its pin list exactly — no new claim, no pin left rotting"
else
  bad "the protection-claim census moved (UNPINNED = a new/edited claim nobody reviewed; STALE = a fixed member whose pin was left behind — drop the pin in the SAME commit):"
  printf '%s\n' "$CENSUS_OUT" | sed 's/^/       /' >&2
fi

# MUTATION 1 — a NEW claim in a file the scan covers must come back UNPINNED.
# The canary is planted in $TMP and fed to the same function as an extra path,
# which is also what proves the `--untracked` corpus is real rather than decorative.
CENSUS_CANARY="$TMP/protection-canary.md"
printf 'note: main has no branch protection, so merge when the gate is green\n' > "$CENSUS_CANARY"
if grep -q '^UNPINNED.*protection-canary' <<<"$(protection_census_report "$CENSUS_CANARY")"; then
  ok "…and it FIRES on a planted new claim (mutation-proven able to fail, not a grep that only passes)"
else
  bad "the census did not report the planted claim as UNPINNED — it is a grep that can only pass"
fi

# MUTATION 2 — the arm a `count <= N` gate misses entirely: a member is FIXED but
# its pin stays. Simulated by adding a pin no line can satisfy, in a subshell so
# the real list is untouched.
STALE_PINS="$TMP/protection-pins-stale.txt"
cp "$PROTECTION_PINS" "$STALE_PINS"
printf '0000deadbeef  C  fake/planted-pin.md:1  a pin whose member no longer exists\n' >> "$STALE_PINS"
STALE_OUT="$( PROTECTION_PINS="$STALE_PINS"; protection_census_report )"
if grep -q '^STALE  0000deadbeef' <<<"$STALE_OUT"; then
  ok "…and a pin whose line is GONE is reported STALE — fixing a member without dropping its pin reds"
else
  bad "a pin with no matching line was not reported STALE — the census is a count gate in disguise"
fi

# MUTATION 3 — THE EVASIVE SPECIMEN. A LIVE class-A claim on a line that also
# mentions a `grep` invocation. If the fence ever degrades from "inside the
# search command's own quoted argument" to "this line mentions grep", this is
# the shape that walks through it, and this clause reds instead.
CENSUS_EVASIVE="$TMP/protection-evasive.md"
printf 'We ran `grep -rn "protected" docs/` and it turns out main has no branch protection today.\n' > "$CENSUS_EVASIVE"
if grep -q '^UNPINNED.*protection-evasive' <<<"$(protection_census_report "$CENSUS_EVASIVE")"; then
  ok "…and the fence still FIRES on a live claim that merely CO-MENTIONS a grep on the same line"
else
  bad "the quoted-pattern fence exempted a line that only MENTIONS grep — it has widened into 'any line with grep on it'"
fi

# MUTATION 4 — THE LEDGER SPECIMEN, and the whole reason ledger-scoping was
# refused. The specimen is planted at a path CONTAINING `tooling/grip/ledger/`,
# so any variant that exempts the ledger directory drops it silently; the fence,
# which reads the LINE, does not. The contrast is asserted rather than argued:
# this clause proves the fence FIRES on it, and mutation 5 below re-runs the same
# specimen through a ledger-scoped rival and proves that rival MISSES it.
mkdir -p "$TMP/tooling/grip/ledger"
CENSUS_LEDGER="$TMP/tooling/grip/ledger/cch-planted-claim-2026-08-06.md"
printf 'Note for the next wave: main has no branch protection, so merge on a green gate.\n' > "$CENSUS_LEDGER"
if grep -q '^UNPINNED.*cch-planted-claim' <<<"$(protection_census_report "$CENSUS_LEDGER")"; then
  ok "…and it FIRES on a live claim planted INSIDE tooling/grip/ledger/ — the census is not blind in its highest-yield corpus"
else
  bad "a live claim in tooling/grip/ledger/ was not reported UNPINNED — the ledger directory has been exempted"
fi

# MUTATION 5 (added in review) — THE RIVAL, ACTUALLY RUN. The clause above says
# the ledger-scoped rival "misses this specimen entirely"; until this clause that
# was a sentence in a comment, not something the suite could lose on — the exact
# shape this epic exists to delete. The rival is modelled the only way it could
# ever be implemented: a path exemption for `tooling/grip/ledger/`, applied to
# the SAME report. It must let the planted claim through. If a future edit makes
# the rival catch it too, the refusal above has lost its evidence and this reds.
if ! grep -q 'cch-planted-claim' \
     <<<"$(protection_census_report "$CENSUS_LEDGER" | grep -v 'tooling/grip/ledger/')"; then
  ok "…and the ledger-scoped rival DROPS that same claim — the refusal to path-exempt is measured, not argued"
else
  bad "the ledger-scoped rival caught the planted ledger claim — re-derive why path exemption was refused"
fi

# The three wave-35 offenders are FIXED, not pinned. If any of them comes back,
# the fix was reverted and the census would only say UNPINNED — say it by name.
for fixed in .github/workflows/bp-graph-drift.yml scripts/check-bp-graph-drift.sh; do
  if ! ( cd "$REPO_ROOT" && grep -qE "$PROTECTION_CLAIM_RE" "$fixed" ); then
    ok "$fixed no longer teaches that this repo has no branch protection"
  else
    bad "$fixed claims again that main is unprotected — it is protected since 2026-07-28T22:42:10Z"
  fi
done


section "19. docs/ops/merge-gates.md never calls a TRANSITIVE UPSTREAM of a required aggregator non-blocking"

# THE DEFECT THIS CLAUSE EXISTS FOR. Two canonical artifacts disagreed about the
# same two check names. `.github/required-checks.json` files `mix-prod-compile`
# and `validation-perf` under "S3 SUBSUMED: an upstream `needs` of a required
# aggregator — the aggregator already fails when it fails". docs/ops/merge-gates.md
# — canonical-for: merge-gates, the page an agent actually reads before pushing —
# said they "do not block". The spec is right: elixir.yml:667 declares
# `needs: [changes, mix-test, mix-prod-compile, validation-perf, path-escape]`
# and the aggregator's Decide body fails closed over every upstream result, so a
# red in either one reds `Elixir gate`, which is one of exactly four required
# contexts under `enforce_admins: true`.
#
# WHY A GUARD AND NOT JUST A COMMIT. The doc was not wrong about topology it
# never mentioned; it was wrong about a CONSEQUENCE, and a consequence drifts
# back the moment someone adds a job to `needs:` and describes it here from
# memory. So the two lists are DERIVED, never typed: the aggregators' `needs:`
# come out of `.github/workflows/`, the required contexts out of
# `.github/required-checks.json`. Editing either one re-aims the guard.
#
# THREE CLASSES, AND THE GUARD MUST NOT COLLAPSE THEM. Some jobs really ARE
# advisory — `continue-on-error: true`, and deliberately NOT in any required
# aggregator's `needs:` — so a guard that simply deleted every "do not block"
# sentence would ship a NEW lie about those. The guard therefore reds only on a
# name that is a transitive upstream, which is what forces the doc to make the
# split rather than to soften the wording.
#
# THE 2026-09-04 FLIP, AND WHY THE SPECIMEN IS NOW DERIVED. Until #15971
# (15f3d9607a, task-e31b816b4b416db6) this section and §20 named `format` as
# THE canonical advisory specimen, typed into both the mutation below and §20's
# clause 5. That PR dropped `format`'s `continue-on-error` and put it in
# `elixir-gate`'s `needs:` — diff-scoped, but a real blocking upstream — and
# rewrote merge-gates.md's format disclosure. Both typed premises flipped at
# once, so five assertions across §19/§20 went red on a CORRECT tree and main's
# `Required-check spec gate` stayed red for twelve hours (run 33907498184,
# b2529b02c, "239 passed, 5 failed"; the run on 68d85542e twelve hours earlier
# was green). NOTHING here names a specimen any more: `rc_advisory_specimen`
# derives one from the live graph and `rc_doc_disclosure_specimen` picks the one
# merge-gates.md actually discloses, and if the tree ever runs out of advisory
# jobs the fixture PLANTS one. The next job that changes class re-aims this
# section instead of reddening main.
#
# SENTENCE-SCOPED, NOT LINE-SCOPED, AND THIS IS MEASURED. merge-gates.md soft-
# wraps its prose at ~78 columns, so a subject and its predicate routinely sit on
# different physical lines: the fixed sentence at the head of item 4 spans four.
# A line-scoped prototype run against this file found ONE of THREE promises — a
# vacuous green inside the suite written to attack vacuous greens. Mutation 3
# below runs the line-scoped rival on a specimen and proves it misses.
#
# THE UNIT IS A MARKDOWN BLOCK (paragraph, list item, heading), split into
# sentences on `. ` / `! ` / `? `. Within a unit the guard carries the SUBJECT
# forward, because "…nothing mechanically enforces it" — the second false
# sentence fixed in this commit — names no job at all; its subject is the
# `validation-perf` heading two sentences earlier. Carry applies ONLY when the
# sentence names no job whatsoever: a sentence that names `format` is a sentence
# about `format`, not about whatever the item started with, which is exactly the
# false positive that killed the naive version on item 2.
#
# NAMES ARE MATCHED BACKTICKED, deliberately. Job ids in this tree include
# `test`, `compile` and `changes`; matching those as bare words would red on
# ordinary English. The doc's own convention is a backticked job id or a
# backticked rendered check name, and a name written without backticks is out of
# reach — stated here rather than discovered later.
#
# THE STANDING COST, so nobody discovers it as a surprise and silences the
# section: a sentence that MENTIONS a blocking job while denying about a
# different one is reported. Measured on the pre-fix doc — item 2's "It was
# split out of `mix-test` … but today a red `format` check does not block merge"
# came back as a CLAIM against `mix-test`, and the fix is to end the sentence
# after the clause about `mix-test` (which is what the shipped item 2 does).
# That is a fair price rather than a defect: a sentence carrying both a blocking
# and a non-blocking subject is genuinely ambiguous to a reader too.
#
# WHAT IT CANNOT DO: it is a phrase matcher, not a reader. A fresh paraphrase
# ("`validation-perf` is a courtesy signal") walks straight through it, the same
# limit §18 records for its census. It closes the SHAPE that was actually
# present, and reds when that shape returns.
MERGE_GATES_DOC="$REPO_ROOT/docs/ops/merge-gates.md"

# `<file>\t<job id>\t<name: template>\t<needs csv>` for every job in a workflow
# directory. Independent of required-checks-generate.sh's own index ON PURPOSE:
# a guard that shared the generator's parser would inherit its blind spots and
# could only ever agree with it.
rc_job_index() { # <workflow-dir>
  local dir="$1" f
  for f in "$dir"/*.yml; do
    [ -f "$f" ] || continue
    awk -v file="$(basename "$f")" '
      BEGIN { injobs = 0; job = ""; jname = ""; needs = ""; inneeds = 0 }
      function flush() { if (job != "") print file "\t" job "\t" jname "\t" needs }
      /^jobs:[[:space:]]*$/ { injobs = 1; next }
      injobs && /^[^[:space:]#]/ { flush(); job = ""; jname = ""; needs = ""; injobs = 0; next }
      injobs && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
        flush()
        j = $0; sub(/^  /, "", j); sub(/:.*$/, "", j)
        job = j; jname = ""; needs = ""; inneeds = 0; next
      }
      injobs && job != "" {
        if ($0 ~ /^    name:/) {
          v = $0; sub(/^    name:[[:space:]]*/, "", v)
          gsub(/^["'"'"']|["'"'"']$/, "", v); jname = v; next
        }
        if ($0 ~ /^    needs:[[:space:]]*\[/) {
          v = $0; sub(/^    needs:[[:space:]]*\[/, "", v); sub(/\].*$/, "", v)
          gsub(/[[:space:]]/, "", v); needs = v; inneeds = 0; next
        }
        if ($0 ~ /^    needs:[[:space:]]*$/) { inneeds = 1; next }
        if (inneeds && $0 ~ /^      - /) {
          v = $0; sub(/^      - /, "", v); gsub(/[[:space:]]/, "", v)
          needs = (needs == "" ? v : needs "," v); next
        }
        if (inneeds && $0 !~ /^      /) { inneeds = 0 }
      }
      END { flush() }
    ' "$f"
  done
}

# Every name a merge-gates.md sentence could be ABOUT: job ids plus the rendered
# `name:` of any job whose template interpolates nothing.
rc_all_job_names() { # <index>
  local f j n rest
  while IFS=$'\t' read -r f j n rest; do
    [ -n "$j" ] || continue
    printf '%s\n' "$j"
    if [ -n "$n" ] && ! grep -q '\${{' <<<"$n"; then printf '%s\n' "$n"; fi
  done <<EOF
$1
EOF
}

# Walk one aggregator's `needs:` transitively, emitting `JOB<TAB><name>` for each
# upstream. A `needs:` entry naming a job that does not exist in that workflow is
# `UNRESOLVED` — the guard FAILS on it rather than quietly walking a shorter
# graph, because a rename that outruns this file must refuse, not pass.
rc_walk_needs() { # <index> <file> <needs-csv>
  local idx="$1" file="$2" queue="$3" seen="" cur rest row rf rj rn rneeds
  while [ -n "$queue" ]; do
    cur="${queue%%,*}"; rest="${queue#*,}"
    [ "$rest" = "$queue" ] && rest=""
    queue="$rest"
    [ -n "$cur" ] || continue
    case ",$seen," in *",$cur,"*) continue ;; esac
    seen="$seen,$cur"
    row="$(awk -F'\t' -v f="$file" -v j="$cur" '$1 == f && $2 == j { print; exit }' <<EOF
$idx
EOF
)"
    if [ -z "$row" ]; then
      printf 'UNRESOLVED\t%s declares `needs: %s`, which is not a job in that workflow\n' "$file" "$cur"
      continue
    fi
    IFS=$'\t' read -r rf rj rn rneeds <<<"$row"
    printf 'JOB\t%s\n' "$rj"
    if [ -n "$rn" ] && ! grep -q '\${{' <<<"$rn"; then printf 'JOB\t%s\n' "$rn"; fi
    [ -n "$rneeds" ] && queue="${queue:+$queue,}$rneeds"
  done
}

# The required contexts, resolved to jobs, expanded to their transitive
# upstreams. A required context matching no job `name:` is UNRESOLVED — the same
# refusal: an aggregator someone renamed must red here, never silently vanish
# from the guard's scope taking its whole upstream set with it.
rc_transitive_upstreams() { # <workflow-dir> <spec-json>
  local idx ctx row rf rj rn rneeds
  idx="$(rc_job_index "$1")"
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    row="$(awk -F'\t' -v c="$ctx" '$3 == c { print; exit }' <<EOF
$idx
EOF
)"
    if [ -z "$row" ]; then
      printf 'UNRESOLVED\trequired context `%s` matches no job `name:` under %s\n' "$ctx" "$1"
      continue
    fi
    IFS=$'\t' read -r rf rj rn rneeds <<<"$row"
    rc_walk_needs "$idx" "$rf" "$rneeds"
  done <<EOF
$(jq -r '.protection.required_status_checks.checks[].context' "$2")
EOF
}

# The phrasings that assert a check cannot stop a merge. Narrow on purpose:
# bare "advisory" is NOT here — merge-gates.md uses the word correctly about
# `format` and about the shape of an advisory job, and matching it would red a
# truth (the same reasoning §18 applies to `no rulesets`).
RC_NONBLOCKING_RE='do(es)? not block|do not block|don.t block|never blocks?|not blocking|non-blocking|cannot block|unable to block|do(es)? not gate|nothing mechanically enforces|nothing enforces|is advisory|are advisory|purely advisory|merely advisory|advisory only|is not required to pass|does not stop a merge|cannot stop a merge'

# <doc> <all-names-file> <target-names-file> -> `CLAIM<TAB><name><TAB><sentence>`
rc_nonblocking_claims() {
  awk -v allf="$2" -v tgtf="$3" -v neg="$RC_NONBLOCKING_RE" '
    function trunc(s) { return (length(s) > 120 ? substr(s, 1, 117) "…" : s) }
    function flush(   u, n, parts, i, s, k, named, nnamed, hit, m) {
      if (unit == "") return
      u = unit; unit = ""
      gsub(/[[:space:]]+/, " ", u)
      n = split(u, parts, /[.!?] +/)
      for (i = 1; i <= n; i++) {
        s = parts[i]
        nnamed = 0
        for (k = 1; k <= na; k++) if (index(s, "`" ALL[k] "`") > 0) {
          named[++nnamed] = ALL[k]
          carry[++nc] = ALL[k]
        }
        if (s ~ neg) {
          if (nnamed > 0) {
            for (k = 1; k <= nnamed; k++) if (named[k] in TGT) print "CLAIM\t" named[k] "\t" trunc(s)
          } else {
            for (k = 1; k <= nc; k++) if (carry[k] in TGT) print "CLAIM\t" carry[k] "\t" trunc(s)
          }
        }
        for (k = 1; k <= nnamed; k++) delete named[k]
      }
      for (k = 1; k <= nc; k++) delete carry[k]
      nc = 0
    }
    BEGIN {
      while ((getline l < allf) > 0) if (l != "") ALL[++na] = l
      while ((getline l < tgtf) > 0) if (l != "") TGT[l] = 1
      fence = 0; unit = ""; nc = 0
    }
    /^[[:space:]]*```/ { flush(); fence = !fence; next }
    fence { next }
    /^[[:space:]]*$/ { flush(); next }
    /^#/ { flush(); next }
    /^[[:space:]]*([-*+][[:space:]]|[0-9]+\.[[:space:]])/ { flush() }
    { unit = (unit == "" ? $0 : unit " " $0) }
    END { flush() }
  ' "$1"
}

# One driver, pointed at a workflow dir / spec / doc, so every mutation below
# re-runs the SAME code path rather than a look-alike.
rc_gate_report() { # <workflow-dir> <spec-json> <doc>
  local up all tgt
  up="$(rc_transitive_upstreams "$1" "$2")"
  grep '^UNRESOLVED' <<<"$up" || true
  all="$TMP/rc19-all.txt"; tgt="$TMP/rc19-tgt.txt"
  rc_all_job_names "$(rc_job_index "$1")" | sort -u > "$all"
  grep '^JOB' <<<"$up" | cut -f2 | sort -u > "$tgt"
  [ -s "$tgt" ] || printf 'UNRESOLVED\tno required aggregator resolved to a single upstream job — the derivation produced an empty target set\n'
  rc_nonblocking_claims "$3" "$all" "$tgt"
}

# Job ids carrying a JOB-LEVEL `continue-on-error: true`. Step-level ones are
# out of scope on purpose: they do not change `needs.<job>.result`, which is the
# whole mechanism this class is about (elixir.yml's format guard STEP is exactly
# that case and must not be mistaken for the job).
rc_coe_jobs() { # <workflow-dir>
  local f
  for f in "$1"/*.yml; do
    [ -f "$f" ] || continue
    awk '
      BEGIN { injobs = 0; job = "" }
      /^jobs:[[:space:]]*$/ { injobs = 1; next }
      injobs && /^[^[:space:]#]/ { job = ""; injobs = 0; next }
      injobs && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
        j = $0; sub(/^  /, "", j); sub(/:.*$/, "", j); job = j; next
      }
      # A TRAILING COMMENT IS THE COMMON SHAPE, not the exception:
      # reland-check.yml writes `continue-on-error: true # advisory — report,
      # never block`, and an end-anchored `true$` dropped it silently — measured,
      # the derived candidate list came back one job short and §20 clause 5 had
      # nothing to mutate.
      injobs && job != "" && /^    continue-on-error:[[:space:]]*true([[:space:]]*#.*)?[[:space:]]*$/ { print job }
    ' "$f"
  done | sort -u
}

# THE SPECIMEN, DERIVED. Every `continue-on-error: true` job that is neither a
# required context nor a transitive upstream of one — i.e. every job the doc may
# honestly call non-blocking. Emitted sorted, so the pick below is deterministic
# and a reader can reproduce it with two greps.
rc_advisory_specimen() { # <workflow-dir> <spec-json> [must-appear-in-doc]
  local tgt doc j
  tgt="$( { rc_transitive_upstreams "$1" "$2" | grep '^JOB' | cut -f2
            jq -r '.protection.required_status_checks.checks[].context' "$2"; } | sort -u )"
  doc="${3:-}"
  while IFS= read -r j; do
    [ -n "$j" ] || continue
    if grep -qxF "$j" <<EOF
$tgt
EOF
    then continue; fi
    if [ -n "$doc" ] && ! grep -qF "\`$j\`" "$doc"; then continue; fi
    printf '%s\n' "$j"
  done <<EOF
$(rc_coe_jobs "$1")
EOF
}

# The `needs:` line of the job that publishes a required context, BY JOB KEY —
# never by its current contents. #15971 appended one entry to `elixir-gate`'s
# list and three mutations below, each `sed`-anchored on the five-name line,
# silently stopped applying. An anchor that reads the job key survives the next
# append.
rc_needs_lineno() { # <workflow-file> <job-key>
  awk -v key="  $2:" '
    $0 == key { inj = 1; next }
    inj && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { exit }
    inj && /^    needs:[[:space:]]*\[/ { print NR; exit }
  ' "$1"
}

RC19_TARGETS="$(rc_transitive_upstreams "$REPO_ROOT/.github/workflows" "$SPEC" | grep '^JOB' | cut -f2 | sort -u | tr '\n' ' ')"
if [ -n "$RC19_TARGETS" ]; then
  ok "derived the required aggregators' transitive upstreams from source, nothing typed: $RC19_TARGETS"
else
  bad "no transitive upstreams derived — the guard would pass by having nothing to check"
fi

RC19_OUT="$(rc_gate_report "$REPO_ROOT/.github/workflows" "$SPEC" "$MERGE_GATES_DOC")"
if [ -z "$RC19_OUT" ]; then
  ok "merge-gates.md calls no transitive upstream of a required aggregator non-blocking"
else
  bad "merge-gates.md tells a reader that a check which reds a REQUIRED aggregator cannot stop a merge:"
  printf '%s\n' "$RC19_OUT" | sed 's/^/       /' >&2
fi

# THE ADVISORY SPECIMEN FOR MUTATION 2, DERIVED FROM THE LIVE GRAPH. If the
# tree ever carries no advisory job at all, one is PLANTED into a fixture copy
# rather than the split going untested — a section that quietly stops testing
# the split is the same vacuous green this suite exists to delete. The workflow
# dir the two clauses below run against is therefore a variable, not a constant.
#
# NEVER `| head -1` HERE. This file runs under `set -euo pipefail`: `head` closes
# the pipe on line one, the producer takes SIGPIPE, and the whole SUITE dies
# mid-section with "printf: write error: Broken pipe" — measured, once, on the
# first draft of this very clause. The first line is taken by expansion instead.
RC19_WFDIR="$REPO_ROOT/.github/workflows"
RC19_ADV_ALL="$(rc_advisory_specimen "$RC19_WFDIR" "$SPEC")"
RC19_ADV="${RC19_ADV_ALL%%$'\n'*}"
if [ -n "$RC19_ADV" ]; then
  ok "derived the advisory specimen from the live graph: \`$RC19_ADV\` carries continue-on-error and is in no required aggregator's needs (candidates: $(tr '\n' ' ' <<<"$RC19_ADV_ALL"))"
else
  RC19_WFDIR="$TMP/rc19-planted-workflows"
  rm -rf "$RC19_WFDIR"; mkdir -p "$RC19_WFDIR"
  cp "$REPO_ROOT"/.github/workflows/*.yml "$RC19_WFDIR/"
  cat > "$RC19_WFDIR/rc19-planted.yml" <<'YAML'
name: rc19 planted advisory
on: pull_request
jobs:
  rc19-planted-advisory:
    name: rc19 planted advisory
    runs-on: ubuntu-latest
    continue-on-error: true
YAML
  RC19_ADV_ALL="$(rc_advisory_specimen "$RC19_WFDIR" "$SPEC")"
  RC19_ADV="${RC19_ADV_ALL%%$'\n'*}"
  if [ "$RC19_ADV" = "rc19-planted-advisory" ]; then
    ok "no advisory job survives on the live tree, so one is PLANTED in the fixture copy — the split below is still tested rather than skipped"
  else
    bad "no advisory job on the live tree and the planted one did not derive either (got '${RC19_ADV:-<empty>}') — the split is untested"
  fi
fi

# MUTATION 1 — DIRECTION 1, the doc lies. A copy of the doc with the retired
# sentence put back must be reported, naming the check.
RC19_DOC_CANARY="$TMP/merge-gates-canary.md"
cp "$MERGE_GATES_DOC" "$RC19_DOC_CANARY"
printf '\nEverything else on a PR is advisory: `mix-prod-compile`, `validation-perf`\nand `%s` do not block.\n' "$RC19_ADV" >> "$RC19_DOC_CANARY"
RC19_CANARY_N="$(grep -cF "and \`$RC19_ADV\` do not block." "$RC19_DOC_CANARY" || true)"
if [ "$RC19_CANARY_N" -eq 1 ] && ! diff -q "$MERGE_GATES_DOC" "$RC19_DOC_CANARY" >/dev/null; then
  ok "the canary sentence APPLIED exactly once, naming the derived specimen \`$RC19_ADV\` — the two clauses below are not reading a doc copy that never changed"
else
  bad "the canary sentence landed $RC19_CANARY_N time(s) — the two mutation proofs below would be vacuous"
fi
RC19_CANARY_OUT="$(rc_gate_report "$RC19_WFDIR" "$SPEC" "$RC19_DOC_CANARY")"
if grep -q '^CLAIM	mix-prod-compile' <<<"$RC19_CANARY_OUT" \
   && grep -q '^CLAIM	validation-perf' <<<"$RC19_CANARY_OUT"; then
  ok "…and it FIRES, BY NAME, on the retired sentence put back (mutation-proven able to fail)"
else
  bad "the planted 'do not block' sentence was not reported — the guard is a grep that can only pass:"
  printf '%s\n' "$RC19_CANARY_OUT" | sed 's/^/       /' >&2
fi

# MUTATION 2 — the SPLIT. The same planted sentence names the DERIVED advisory
# job. If the guard ever red on it, the honest fix (say the mechanism) and the
# dishonest one (delete the sentence) would be indistinguishable, and deleting
# it would ship a new lie about that job. THE NAME HERE WAS TYPED AS `format`
# until 2026-09-04: #15971 made `format` a blocking upstream and this clause
# reddened on a correct tree for twelve hours. It is derived now.
if ! grep -q "^CLAIM	$RC19_ADV	" <<<"$RC19_CANARY_OUT"; then
  ok "…and it does NOT fire on \`$RC19_ADV\`, which is genuinely advisory — the split is measured, not asserted"
else
  bad "the guard reddened on \`$RC19_ADV\`, a continue-on-error job in no required aggregator's needs — it has become a word filter"
fi

# MUTATION 3 — SENTENCE vs LINE, run rather than argued. The specimen is one
# sentence soft-wrapped so that the check name and the phrase land on different
# physical lines. The shipped scanner catches it; a line-scoped rival, modelled
# the only way it could be written, misses it. That contrast is why this guard
# is not three greps.
#
# The specimen is its own file, NOT an append to the doc: a rival run against
# the whole doc could score a hit on some OTHER line and look competent. Both
# scanners see exactly the same two lines and nothing else.
RC19_WRAP="$TMP/merge-gates-wrapped.md"
printf 'The `validation-perf` bench is worth watching, though a red run of it\ndoes not block anything on this repo.\n' > "$RC19_WRAP"
if grep -q '^CLAIM	validation-perf' <<<"$(rc_gate_report "$REPO_ROOT/.github/workflows" "$SPEC" "$RC19_WRAP")"; then
  ok "…and it FIRES on a claim soft-wrapped across two lines — the scope is the sentence, not the line"
else
  bad "a soft-wrapped claim was missed — the scanner has degraded to line scope on a file that wraps at 78 columns"
fi
if ! grep -qE "\`validation-perf\`.*($RC_NONBLOCKING_RE)" "$RC19_WRAP"; then
  ok "…and the LINE-scoped rival DROPS that same claim — the sentence scope is measured, not preferred"
else
  bad "the line-scoped rival caught the wrapped specimen — re-derive why sentence scope was required"
fi

# MUTATION 4 — DIRECTION 2, the graph moves under the doc. A renamed aggregator
# must make the guard REFUSE. The failure mode being closed is the comfortable
# one: an unresolvable name silently removes an aggregator's whole upstream set
# from scope, and every claim about those checks turns green overnight.
RC19_WF="$TMP/rc19-workflows"
rm -rf "$RC19_WF"; mkdir -p "$RC19_WF"
cp "$REPO_ROOT"/.github/workflows/*.yml "$RC19_WF/"
sed -i.bak 's/^    name: Elixir gate$/    name: Elixir gate v2/' "$RC19_WF/elixir.yml" && rm -f "$RC19_WF/elixir.yml.bak"
if grep -q '^UNRESOLVED.*Elixir gate' <<<"$(rc_gate_report "$RC19_WF" "$SPEC" "$MERGE_GATES_DOC")"; then
  ok "…and a RENAMED required aggregator is UNRESOLVED, not silently out of scope (the guard refuses rather than passes)"
else
  bad "renaming \`Elixir gate\` did not make the guard refuse — a rename would silently empty its upstream set"
fi

# MUTATION 5 — a `needs:` edge pointed at a job that does not exist. Same
# refusal, one level down: the walk must not simply find nothing and continue.
cp "$REPO_ROOT"/.github/workflows/elixir.yml "$RC19_WF/elixir.yml"
# ANCHORED ON THE JOB KEY, NOT ON THE LIST'S CONTENTS. This sed used to match the
# literal five-name `needs:` line; #15971 appended `format` to it on 2026-09-04,
# the mutation silently stopped applying, and the clause below reddened while
# asserting nothing about the guard at all. `rc_needs_lineno` finds the line by
# walking to the `elixir-gate` job key, so the next append re-aims it.
RC19_NEEDS_LN="$(rc_needs_lineno "$RC19_WF/elixir.yml" elixir-gate)"
if [ -n "$RC19_NEEDS_LN" ]; then
  sed -i.bak "${RC19_NEEDS_LN}s/mix-prod-compile/mix-prod-compile-renamed/" \
    "$RC19_WF/elixir.yml" && rm -f "$RC19_WF/elixir.yml.bak"
fi
RC19_DANGLE_N="$(grep -c 'mix-prod-compile-renamed' "$RC19_WF/elixir.yml" || true)"
if [ -n "$RC19_NEEDS_LN" ] && [ "$RC19_DANGLE_N" -eq 1 ] \
   && ! diff -q "$REPO_ROOT/.github/workflows/elixir.yml" "$RC19_WF/elixir.yml" >/dev/null; then
  ok "the dangling-\`needs:\` mutation APPLIED: \`elixir-gate\`'s needs line (line $RC19_NEEDS_LN, found by job key) now names a job that does not exist, exactly once"
else
  bad "the dangling-\`needs:\` mutation did not apply (needs line '${RC19_NEEDS_LN:-<none>}', $RC19_DANGLE_N occurrence(s)) — the clause below would be reding on an UNMUTATED tree"
fi
if grep -q '^UNRESOLVED.*mix-prod-compile-renamed' <<<"$(rc_gate_report "$RC19_WF" "$SPEC" "$MERGE_GATES_DOC")"; then
  ok "…and a \`needs:\` entry naming no job is UNRESOLVED — a job rename refuses instead of shrinking the graph"
else
  bad "a dangling \`needs:\` entry was walked past in silence — the derivation fails open"
fi

# MUTATION 6 — the derivation reads the SPEC, not a list in this file. Drop
# `Elixir gate` from a copy of the spec and its upstreams must leave the target
# set; if they survive, they were typed here.
RC19_SPEC="$TMP/rc19-spec.json"
jq '.protection.required_status_checks.checks |= map(select(.context != "Elixir gate"))' "$SPEC" > "$RC19_SPEC"
if ! grep -qx 'mix-prod-compile' \
     <<<"$(rc_transitive_upstreams "$REPO_ROOT/.github/workflows" "$RC19_SPEC" | grep '^JOB' | cut -f2 | sort -u)"; then
  ok "…and dropping a context from the SPEC drops its upstreams — the required list is read, not hardcoded"
else
  bad "\`mix-prod-compile\` survived removing \`Elixir gate\` from the spec — the target set is typed into this file"
fi


# ── 20 ───────────────────────────────────────────────────────────────────────
# §19 reds when the page UNDERSTATES a gate. Nothing red when it OVERSTATED one,
# and on 2026-08-07 four checks that cannot stop a merge were listed on this page
# as checks a PR must clear: `plugin-node` ("the workflow is always present in
# the required-status list", contradicted by the same page 380 lines on),
# `vendored-assets` (under "A PR targeting `main` must clear:", no disclosure, in
# no aggregator's `needs:`), the `PR task gate self-test` job (item 7 reasoned
# ABOUT required names while implying the self-test carries one), and `doc-gates`
# (whose own spec files it S4 PATHS-FILTERED). §20 is §19's exact inverse, over
# the same three derived sets and the SAME RC_NONBLOCKING_RE: 19 reds on a
# disclosure that is FALSE, 20 reds on a disclosure that is MISSING.
#
# THREE CONSTRUCTION RULES, EACH LEARNED BY A MEASURED FAILURE:
#
# (i) THE NAME UNIVERSE MUST INCLUDE THE WORKFLOW-LEVEL `name:`, not only job ids
# and job `name:`s. The overstatements are made about WORKFLOWS: neither
# `vendored-assets` nor `plugin-node` is a job id or a job name anywhere in this
# tree (vendored-assets.yml's only job is `check` / "deploy.sh ↔ embedded asset
# in sync"), so with §19's two-source universe the two loudest instances are
# INVISIBLE and this section passes with three of the four standing. A clause
# below re-derives the universe from job sources alone and asserts both names are
# missing from it, so the third source cannot be dropped quietly.
#
# (ii) NAMING SCOPE IS THE HEADING TEXT; DISCLOSURE SCOPE IS THE SECTION BODY. A
# prototype that took names from the whole section body reported SEVEN names the
# page makes no claim about (`release`, `console-harness`, `gate-shape`,
# `sobelow`, `Security gate`, `mix-audit`, `Doc budgets + anchors` — all off
# ordinary prose under "Security gates" and "When to override"). Narrowing the
# NAMING scope to the heading — and, for a roster item, to its **bold** lead,
# which is how this page writes an assertion — took false positives to zero
# while keeping all four instances. The body still supplies the disclosure: a
# section that says anywhere in its body that a check cannot block is excused.
#
# (iii) THE CARDINALITY CLAUSE IS SENTENCE-SCOPED, NOT LINE-SCOPED. The offending
# phrase soft-wrapped — "…is one of the two\nrequired contexts" — so a line-
# scoped grep ran GREEN against the very page it exists to catch: §19's vacuous-
# green lesson recurring one clause over. The count itself is PARSED from
# `.github/required-checks.json`, never typed here; a clause below grows a copy
# of the spec to five contexts and watches the page's honest "four" get reported.
#
# THE STANDING COST, stated so the next wave fixes the sentence instead of
# silencing the section: a unit whose heading names a check that is neither
# required nor a transitive upstream is reported for ANY reason it is named,
# including item 7 — which is fundamentally about a check that IS required and
# earns its green from one disclosure clause about the self-test. Symmetrically,
# ONE disclosure anywhere in a body excuses every name in that heading: the unit,
# not the sentence, is the grain. Both are the price of a scope narrow enough to
# have zero false positives on a 700-line page.
#
# WHAT IT CANNOT DO: like §19 it is a phrase matcher. A check named only in prose
# the page never asserts about, or a disclosure written in a phrasing outside
# RC_NONBLOCKING_RE, is out of reach. And its window is merge-gates.md alone —
# `.github/workflows/required-checks-drift.yml:9-11` commits the same offence
# about its own `Required-check spec gate` and is not in scope (filed as
# cch-w49-bl-required-checks-drift-calls-its-own-job-blocking).
section "20. docs/ops/merge-gates.md never presents a check that CANNOT block as one a PR must clear"

# THE 2026-09-04 FLIP (same one §19's header records). Clause 5 and clause 7 both
# named a moving part in a string literal — clause 5 sed'd one sentence of
# merge-gates.md about `format`, clause 7 sed'd `elixir-gate`'s five-name
# `needs:` line. #15971 (15f3d9607a) rewrote the sentence AND appended `format`
# to the line, so both mutations stopped applying and both clauses reddened
# while proving nothing. Neither is typed any more: the DELETE specimen is
# derived from the graph crossed with the page, and the ADD anchor walks to the
# job key. A mutation that does not apply is now its own FAIL, said in those
# words, so the next flip reports "the mutation did not apply" instead of
# accusing the tree.

# The third name source §19 does not need and this section cannot work without.
rc20_workflow_names() { # <workflow-dir> -> `<file>\t<workflow name>`
  local f n
  for f in "$1"/*.yml; do
    [ -f "$f" ] || continue
    n="$(awk '/^name:[[:space:]]*/ { sub(/^name:[[:space:]]*/, ""); gsub(/^["'"'"']|["'"'"']$/, ""); print; exit }' "$f")"
    [ -n "$n" ] && printf '%s\t%s\n' "$(basename "$f")" "$n"
  done
}

# Every name a merge-gates.md heading could be ABOUT: §19's job ids and rendered
# job names, PLUS the workflow-level names.
rc20_all_names() { # <workflow-dir>
  { rc_all_job_names "$(rc_job_index "$1")"; rc20_workflow_names "$1" | cut -f2; } | sort -u
}

# Every name that CAN stop a merge: the required contexts themselves, the jobs
# they resolve to, those jobs' transitive upstreams, and the workflow-level name
# of each file that carries a required aggregator. All of it derived — the spec
# supplies the contexts, `.github/workflows/` supplies the graph.
rc20_blocking_names() { # <workflow-dir> <spec-json>
  local idx wfn ctx row rf rj rn rneeds
  idx="$(rc_job_index "$1")"
  wfn="$(rc20_workflow_names "$1")"
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    printf '%s\n' "$ctx"
    row="$(awk -F'\t' -v c="$ctx" '$3 == c { print; exit }' <<EOF
$idx
EOF
)"
    [ -n "$row" ] || continue
    IFS=$'\t' read -r rf rj rn rneeds <<<"$row"
    printf '%s\n' "$rj"
    if [ -n "$rn" ] && ! grep -q '\${{' <<<"$rn"; then printf '%s\n' "$rn"; fi
    awk -F'\t' -v f="$rf" '$1 == f { print $2 }' <<EOF
$wfn
EOF
    rc_walk_needs "$idx" "$rf" "$rneeds" | grep '^JOB' | cut -f2 || true
  done <<EOF
$(jq -r '.protection.required_status_checks.checks[].context' "$2")
EOF
}

# <doc> <all-names> <blocking-names> [naming-scope: heading|body]
# -> `OVER<TAB><name><TAB><kind><TAB><excerpt>`
rc20_overstatements() {
  awk -v allf="$2" -v blkf="$3" -v neg="$RC_NONBLOCKING_RE" -v scope="${4:-heading}" '
    function trunc(s) { gsub(/[[:space:]]+/, " ", s); return (length(s) > 110 ? substr(s, 1, 107) "…" : s) }
    # A roster item asserts in its **bold** lead, exactly as a section asserts in
    # its heading; the rest of the item is prose about the mechanism.
    function bolds(t,   out) {
      out = ""
      while (match(t, /\*\*[^*]+\*\*/)) {
        out = out " " substr(t, RSTART + 2, RLENGTH - 4)
        t = substr(t, RSTART + RLENGTH)
      }
      return out
    }
    function consider(naming, body, kind,   k, nm) {
      gsub(/[[:space:]]+/, " ", naming)
      gsub(/[[:space:]]+/, " ", body)
      if (scope == "body") naming = body
      for (k = 1; k <= na; k++) {
        nm = ALL[k]
        if (nm in BLK) continue
        if (nm in SEEN) continue
        # Backticked is the page convention; a BARE hyphenated name is matched
        # too (`doc-gates`, `vendored-assets` appear unbackticked in headings),
        # never a bare English word, and never inside a path or a filename.
        if (index(naming, "`" nm "`") == 0) {
          if (nm !~ /^[a-z0-9]+(-[a-z0-9]+)+$/) continue
          if (naming !~ ("(^|[^A-Za-z0-9`_/.-])" nm "([^A-Za-z0-9`_/.-]|$)")) continue
        }
        if (body ~ neg) continue
        SEEN[nm] = 1
        print "OVER\t" nm "\t" kind "\t" trunc(naming)
      }
    }
    BEGIN {
      while ((getline l < allf) > 0) if (l != "") ALL[++na] = l
      while ((getline l < blkf) > 0) if (l != "") BLK[l] = 1
    }
    { line[++n] = $0 }
    END {
      f = 0
      for (i = 1; i <= n; i++) {
        if (line[i] ~ /^[[:space:]]*```/) { f = !f; masked[i] = 1; continue }
        masked[i] = f
      }
      # 1. the roster under the page assertive stem
      start = 0
      for (i = 1; i <= n; i++) if (!masked[i] && line[i] ~ /must clear:[[:space:]]*$/) { start = i; break }
      if (start == 0)
        print "UNRESOLVED\tthe assertive stem (\"A PR targeting `main` must clear:\") is not on the page — the roster scope resolved to nothing"
      else {
        item = ""
        for (i = start + 1; i <= n; i++) {
          if (masked[i]) continue
          s = line[i]
          if (s ~ /^[[:space:]]*$/) continue
          if (s ~ /^#/) break
          if (s ~ /^[0-9]+\.[[:space:]]/) { if (item != "") consider(bolds(item), item, "roster item"); item = s; continue }
          if (s ~ /^[[:space:]]/) { if (item != "") item = item " " s; continue }
          break
        }
        if (item != "") consider(bolds(item), item, "roster item")
      }
      # 2. headings — naming scope is the heading TEXT, disclosure scope is the
      #    body down to the next heading of the same or higher level
      for (i = 1; i <= n; i++) {
        if (masked[i]) continue
        if (line[i] !~ /^#+[[:space:]]/) continue
        h = line[i]; sub(/[^#].*$/, "", h); lvl = length(h)
        head = line[i]; sub(/^#+[[:space:]]*/, "", head)
        body = ""
        for (j = i + 1; j <= n; j++) {
          if (!masked[j] && line[j] ~ /^#+[[:space:]]/) {
            hh = line[j]; sub(/[^#].*$/, "", hh)
            if (length(hh) <= lvl) break
          }
          body = body " " line[j]
        }
        consider(head, body, "heading")
      }
      # 3. any block that labels its subject `(blocking)`
      blk = ""
      for (i = 1; i <= n + 1; i++) {
        if (i <= n && !masked[i] && line[i] !~ /^[[:space:]]*$/) { blk = blk " " line[i]; continue }
        if (blk != "") { if (index(blk, "(blocking)") > 0) consider(bolds(blk), blk, "(blocking) label"); blk = "" }
      }
    }
  ' "$1"
}

rc20_count_word() { # <n>
  case "$1" in
    1) echo one ;; 2) echo two ;; 3) echo three ;; 4) echo four ;; 5) echo five ;;
    6) echo six ;; 7) echo seven ;; 8) echo eight ;; 9) echo nine ;; 10) echo ten ;;
    *) echo "$1" ;;
  esac
}

# SENTENCE-scoped: the phrase this exists to catch wraps between "the two" and
# "required contexts". `one of the` is stripped first — it is an idiom, not a
# count — and the number must sit directly against the noun, so a sentence that
# merely contains a digit and the words "required contexts" is not a claim.
rc20_cardinality_claims() { # <doc> <n> <word>
  awk -v want="$2" -v word="$3" '
    function trunc(s) { gsub(/[[:space:]]+/, " ", s); return (length(s) > 110 ? substr(s, 1, 107) "…" : s) }
    function flush(   u, m, parts, i, s, t, num) {
      if (unit == "") return
      u = unit; unit = ""
      gsub(/[[:space:]]+/, " ", u)
      m = split(u, parts, /[.!?] +/)
      for (i = 1; i <= m; i++) {
        s = parts[i]; t = s
        gsub(/[*`_]/, "", t)
        gsub(/one of the /, "", t)
        if (t !~ /(required contexts?|contexts? (are|is) required)/) continue
        if (match(t, /(zero|one|two|three|four|five|six|seven|eight|nine|ten|[0-9]+) +(required contexts?|contexts? (are|is) required)/)) {
          num = substr(t, RSTART, RLENGTH); sub(/ .*$/, "", num)
          if (num != want && num != word) print "COUNT\t" num "\t" trunc(s)
        }
      }
    }
    /^[[:space:]]*```/ { flush(); fence = !fence; next }
    fence { next }
    /^[[:space:]]*$/ { flush(); next }
    /^#/ { flush(); next }
    /^[[:space:]]*([-*+][[:space:]]|[0-9]+\.[[:space:]])/ { flush() }
    { unit = (unit == "" ? $0 : unit " " $0) }
    END { flush() }
  ' "$1"
}

RC20_ALL="$TMP/rc20-all.txt"
RC20_BLK="$TMP/rc20-blk.txt"
rc20_all_names "$REPO_ROOT/.github/workflows" > "$RC20_ALL"
rc20_blocking_names "$REPO_ROOT/.github/workflows" "$SPEC" | sort -u > "$RC20_BLK"

# CLAUSE 1 — the name universe really is three-sourced, and the third source is
# load-bearing rather than decorative.
RC20_JOBS_ONLY="$(rc_all_job_names "$(rc_job_index "$REPO_ROOT/.github/workflows")" | sort -u)"
if grep -qx 'vendored-assets' "$RC20_ALL" && grep -qx 'plugin-node' "$RC20_ALL" \
   && ! grep -qx 'vendored-assets' <<<"$RC20_JOBS_ONLY" && ! grep -qx 'plugin-node' <<<"$RC20_JOBS_ONLY"; then
  ok "the name universe includes WORKFLOW-level \`name:\` — \`vendored-assets\` and \`plugin-node\` are names ONLY that source reaches (job ids + job names alone do not contain them)"
else
  bad "the workflow-level name source is missing or redundant — without it the two loudest overstatements are invisible to this section"
fi

# CLAUSE 2 — the blocking set is derived, and it is not empty.
if [ -s "$RC20_BLK" ] && grep -qx 'Elixir gate' "$RC20_BLK" && grep -qx 'mix-prod-compile' "$RC20_BLK" \
   && grep -qx 'elixir' "$RC20_BLK"; then
  ok "derived what CAN block from source: $(wc -l < "$RC20_BLK" | tr -d ' ') names — required contexts, their jobs, their transitive upstreams, and the workflows that carry them"
else
  bad "the blocking set did not derive — every name would look non-blocking and the section would red on the whole page"
fi

# CLAUSE 3 — the page itself.
RC20_OUT="$(rc20_overstatements "$MERGE_GATES_DOC" "$RC20_ALL" "$RC20_BLK")"
if [ -z "$RC20_OUT" ]; then
  ok "merge-gates.md presents no check as one a PR must clear that is neither required, transitively upstream of a required context, nor disclosed as non-blocking"
else
  bad "merge-gates.md tells a reader a PR must clear a check that cannot stop a merge:"
  printf '%s\n' "$RC20_OUT" | sed 's/^/       /' >&2
fi

# THE CANARY — the four sentences as they stood on `main` before this commit,
# copied verbatim rather than paraphrased, so the proof is that the section
# catches what was actually there. It is its own file, never an append: a run
# against the whole page could score its hits somewhere else and look competent.
RC20_CANARY="$TMP/rc20-canary.md"
cat > "$RC20_CANARY" <<'MD'
A PR targeting `main` must clear:

5. **`plugin-node` CI job** — `.github/workflows/plugin-node.yml`. Discovers
   plugins under `api/priv/plugins/` whose `plugin.json` declares a top-level
   `"node"` object and runs `npm ci` + lint + typecheck per plugin. Emits a
   no-op success when no plugin declares Node, so the workflow is always
   present in the required-status list.
6. **`vendored-assets` CI job** — `.github/workflows/vendored-assets.yml`,
   path-triggered on `deploy.sh` / `internal/cli/setup/assets/**`. Runs
   `make cli-assets-check` so the go:embedded deploy.sh copy can never drift
   from the root copy again (it diverged both ways on main, fixed 2026-07-02).
   Edit the ROOT deploy.sh, then `make cli-assets-sync`.

7. **`pr-task-gate` CI job** — `.github/workflows/pr-task-gate.yml`. The pure
   ledger decision is the unit-tested `scripts/pr-task-gate.sh`
   (`bash scripts/pr-task-gate.test.sh`, hermetic, and run in CI by this same
   workflow's **`PR task gate self-test`** job — deliberately not in
   `shell-harnesses.yml`, which is paths-filtered and so can never carry a
   required name); the workflow only plumbs PR context in.

## Documentation review rules (doc-gates)

`doc-gates` is a single job (`Doc budgets + anchors`) whose name badly
undersells it: it runs **17 steps labelled `(blocking)`** plus 6 `(tripwire)`
self-tests that prove a scanner still reds on a planted defect.

**This gate is now BINDING** — `PR references an active task` is one of the two
required contexts live on `main` (2026-07-28; see *Pre-merge gates*).
MD
RC20_CANARY_OUT="$(rc20_overstatements "$RC20_CANARY" "$RC20_ALL" "$RC20_BLK")"

# CLAUSE 4 — mutation-proven able to fail, on all four instances at once.
RC20_MISSED=""
for nm in 'plugin-node' 'vendored-assets' 'PR task gate self-test' 'doc-gates'; do
  grep -q "^OVER	$nm	" <<<"$RC20_CANARY_OUT" || RC20_MISSED="$RC20_MISSED $nm"
done
if [ -z "$RC20_MISSED" ]; then
  ok "…and it FIRES, BY NAME, on all four retired claims put back verbatim (plugin-node, vendored-assets, PR task gate self-test, doc-gates)"
else
  bad "the canary put back the pre-fix sentences and this section missed:$RC20_MISSED"
  printf '%s\n' "$RC20_CANARY_OUT" | sed 's/^/       /' >&2
fi

# CLAUSE 5 — DELETE. A genuinely advisory job that this page lists as one a PR
# must clear is saved from the report by ONE thing: its disclosure. Strip it from
# a copy and the name must appear. The green on that roster item is therefore
# earned by the sentence, not by blindness.
#
# THE SPECIMEN IS DERIVED, TWICE OVER, AND THAT IS THE 2026-09-04 LESSON. It used
# to be `format`, with the mutation a `sed` on one typed sentence. #15971 made
# `format` blocking (so it can never be reported here again) AND rewrote that
# exact sentence, so the sed matched nothing and the clause reddened on a correct
# tree. Now: `rc_advisory_specimen` supplies the jobs that CANNOT block, and
# `rc20_disclosure_saved` asks the section itself which of them the live page
# would report if its disclosure vanished. Nothing about the page's wording is
# typed here.
#
# THE MUTATION IS A REPLACEMENT, NOT A PHRASE EDIT, on purpose: merge-gates.md
# soft-wraps, so a disclosure ("**Advisory\n only**") routinely straddles two
# physical lines and no line-scoped sed can reliably remove it. The whole roster
# item is replaced by a disclosure-FREE item naming the same job, which is
# exactly the drift being guarded against.

# The names the live page would report if the disclosure regex matched nothing —
# i.e. the names a disclosure is currently saving.
# SUBSHELL, not a `VAR=x func` prefix: bash keeps such an assignment after a
# FUNCTION call (unlike a command), which would silently disarm the disclosure
# regex for every clause below it.
rc20_disclosure_saved() { # <doc> <all-names> <blocking-names>
  ( RC_NONBLOCKING_RE='RC20_DISCLOSURE_REGEX_THAT_MATCHES_NOTHING'
    rc20_overstatements "$1" "$2" "$3" ) | grep '^OVER' | cut -f2
}

# Replace <name>'s numbered roster item with a disclosure-free one. Range is
# found by the item's own numbering, never by line number.
rc20_strip_disclosure() { # <doc> <name> <out>
  awk -v nm="$2" '
    BEGIN { inside = 0; done = 0 }
    /^[0-9]+\.[[:space:]]/ {
      if (inside) { inside = 0 }
      if (!done && index($0, "`" nm "`") > 0) {
        num = $0; sub(/\..*$/, "", num)
        print num ". **`" nm "` CI job** — see `.github/workflows/`."
        inside = 1; done = 1; next
      }
      print; next
    }
    inside && /^[[:space:]]/ { next }
    inside && /^[[:space:]]*$/ { inside = 0; print; next }
    inside { inside = 0 }
    { print }
  ' "$1" > "$3"
}

# Same SIGPIPE rule as §19: no `| head -1` under `pipefail`.
RC20_ADV_SAVED_ALL="$(comm -12 \
  <(rc_advisory_specimen "$REPO_ROOT/.github/workflows" "$SPEC" "$MERGE_GATES_DOC" | sort -u) \
  <(rc20_disclosure_saved "$MERGE_GATES_DOC" "$RC20_ALL" "$RC20_BLK" | sort -u))"
RC20_ADV_SAVED="${RC20_ADV_SAVED_ALL%%$'\n'*}"
if [ -n "$RC20_ADV_SAVED" ]; then
  ok "derived the DELETE specimen: \`$RC20_ADV_SAVED\` is on the must-clear roster, carries continue-on-error, is in no required aggregator's needs, and is reported the moment its disclosure stops matching"
else
  bad "no roster item names a genuinely advisory job whose disclosure is load-bearing — clause 5 has nothing to mutate and would pass by having nothing to test"
fi
RC20_DEL="$TMP/rc20-nodisclosure.md"
rc20_strip_disclosure "$MERGE_GATES_DOC" "$RC20_ADV_SAVED" "$RC20_DEL"
RC20_DEL_ITEM_N="$(grep -cF "**\`$RC20_ADV_SAVED\` CI job** — see \`.github/workflows/\`." "$RC20_DEL" || true)"
if [ "$RC20_DEL_ITEM_N" -eq 1 ] && ! diff -q "$MERGE_GATES_DOC" "$RC20_DEL" >/dev/null \
   && ! grep -qE "$RC_NONBLOCKING_RE" <<<"$(grep -F "\`$RC20_ADV_SAVED\` CI job" "$RC20_DEL")"; then
  ok "the DELETE mutation APPLIED: \`$RC20_ADV_SAVED\`'s roster item is replaced EXACTLY ONCE by a disclosure-free item that still names it"
else
  bad "the disclosure-strip did not apply ($RC20_DEL_ITEM_N replacement(s)) — the clause below would be reding on an unmutated page"
fi
RC20_DEL_OUT="$(rc20_overstatements "$RC20_DEL" "$RC20_ALL" "$RC20_BLK")"
if grep -q "^OVER	$RC20_ADV_SAVED	" <<<"$RC20_DEL_OUT" && ! grep -q "^OVER	$RC20_ADV_SAVED	" <<<"$RC20_OUT"; then
  ok "…and DELETING \`$RC20_ADV_SAVED\`'s disclosure reds it by name, while the unmutated page does not report it at all — the disclosure is what earns the green"
else
  bad "removing the \`$RC20_ADV_SAVED\` disclosure changed nothing (or \`$RC20_ADV_SAVED\` was already reported) — the section is not reading the disclosure:"
  printf '%s\n' "$RC20_DEL_OUT" | sed 's/^/       /' >&2
fi

# CLAUSE 6 — the NAMING scope really is the heading. The body-scoped rival — the
# prototype that reported seven names off ordinary prose — is run on a FIXED
# specimen, not on the live page: a clause whose contrast depends on the doc
# still happening to mention a non-blocking name in some body would red on an
# innocent edit. The live page's own extras are reported in the message.
RC20_PROSE="$TMP/rc20-prose.md"
cat > "$RC20_PROSE" <<'MD'
## Security gates (Sobelow + mix_audit)

The `sobelow` job is Phoenix-aware static analysis and `mix-audit` runs
`mix_audit` against a live advisory database. Neither is claimed here to be
anything; this paragraph is prose ABOUT them.
MD
# The specimen carries no roster stem, so both runs also emit the UNRESOLVED
# line for it; this clause is about the OVER rows and reads only those.
RC20_PROSE_HEAD="$(rc20_overstatements "$RC20_PROSE" "$RC20_ALL" "$RC20_BLK" | grep '^OVER' || true)"
RC20_PROSE_BODY="$(rc20_overstatements "$RC20_PROSE" "$RC20_ALL" "$RC20_BLK" body | grep '^OVER' || true)"
RC20_BODY_OUT="$(rc20_overstatements "$MERGE_GATES_DOC" "$RC20_ALL" "$RC20_BLK" body)"
RC20_BODY_EXTRA="$(comm -13 <(cut -f2 <<<"$RC20_OUT" | sort -u) <(cut -f2 <<<"$RC20_BODY_OUT" | sort -u) | tr '\n' ' ')"
if [ -z "$RC20_PROSE_HEAD" ] \
   && grep -q '^OVER	sobelow	' <<<"$RC20_PROSE_BODY" && grep -q '^OVER	mix-audit	' <<<"$RC20_PROSE_BODY"; then
  ok "…and on a specimen that only MENTIONS \`sobelow\` and \`mix-audit\` the body-scoped rival reports both while the shipped heading scope reports neither — the narrowing is measured, not preferred (on the live page the rival's extras today are:${RC20_BODY_EXTRA:- none})"
else
  bad "the heading/body scope contrast did not reproduce on the fixed specimen — heading scope has widened to the body, or the rival is broken:"
  printf 'head: %s\nbody: %s\n' "$RC20_PROSE_HEAD" "$RC20_PROSE_BODY" | sed 's/^/       /' >&2
fi

# CLAUSE 7 — ADD. Wire a `doc-gates` job into the required `Elixir gate`'s
# `needs:` in a SCRATCH workflow tree and change not one byte of the doc: the
# canary's doc-gates claim becomes TRUE and must stop being reported. Paired
# with a non-vacuity assertion, so an empty or broken run cannot buy the flip.
RC20_WF="$TMP/rc20-workflows"
rm -rf "$RC20_WF"; mkdir -p "$RC20_WF"
cp "$REPO_ROOT"/.github/workflows/*.yml "$RC20_WF/"
# ANCHORED ON THE JOB KEY. Same 2026-09-04 lesson as §19's mutation 5: this sed
# matched the literal five-name `needs:` line, #15971 appended `format`, and the
# clause below reddened because `doc-gates` was never actually wired.
RC20_NEEDS_LN="$(rc_needs_lineno "$RC20_WF/elixir.yml" elixir-gate)"
if [ -n "$RC20_NEEDS_LN" ]; then
  sed -i.bak "${RC20_NEEDS_LN}s/\]$/, doc-gates]/" \
    "$RC20_WF/elixir.yml" && rm -f "$RC20_WF/elixir.yml.bak"
fi
RC20_ADD_N="$(grep -c ', doc-gates\]$' "$RC20_WF/elixir.yml" || true)"
if [ -n "$RC20_NEEDS_LN" ] && [ "$RC20_ADD_N" -eq 1 ] \
   && ! diff -q "$REPO_ROOT/.github/workflows/elixir.yml" "$RC20_WF/elixir.yml" >/dev/null; then
  ok "the ADD mutation APPLIED: \`doc-gates\` joined \`elixir-gate\`'s needs line (line $RC20_NEEDS_LN, found by job key), exactly once"
else
  bad "the doc-gates ADD mutation did not apply (needs line '${RC20_NEEDS_LN:-<none>}', $RC20_ADD_N occurrence(s)) — the topology flip below would be vacuous"
fi
cat >> "$RC20_WF/elixir.yml" <<'YAML'
  doc-gates:
    name: Doc budgets + anchors
    runs-on: ubuntu-latest
YAML
RC20_ADD_ALL="$TMP/rc20-add-all.txt"; RC20_ADD_BLK="$TMP/rc20-add-blk.txt"
rc20_all_names "$RC20_WF" > "$RC20_ADD_ALL"
rc20_blocking_names "$RC20_WF" "$SPEC" | sort -u > "$RC20_ADD_BLK"
RC20_ADD_OUT="$(rc20_overstatements "$RC20_CANARY" "$RC20_ADD_ALL" "$RC20_ADD_BLK")"
if ! grep -q '^OVER	doc-gates	' <<<"$RC20_ADD_OUT" && grep -q '^OVER	doc-gates	' <<<"$RC20_CANARY_OUT"; then
  ok "…and ADDING \`doc-gates\` to the required aggregator's \`needs:\` (scratch tree, doc untouched) drops it from the report — the section reads TOPOLOGY, not keywords"
else
  bad "wiring \`doc-gates\` upstream of \`Elixir gate\` did not change the verdict — the section is matching names, not the graph"
fi
if grep -q '^OVER	plugin-node	' <<<"$RC20_ADD_OUT" && grep -q '^OVER	vendored-assets	' <<<"$RC20_ADD_OUT"; then
  ok "…and that same run STILL reports \`plugin-node\` and \`vendored-assets\` — the flip above was one name changing class, not a run that stopped reporting"
else
  bad "the ADD run went quiet on the other instances too — the doc-gates flip is vacuous"
fi

# CLAUSE 8 — the cardinality of the required set, read from the spec.
RC20_N="$(jq '.protection.required_status_checks.checks | length' "$SPEC")"
RC20_W="$(rc20_count_word "$RC20_N")"
RC20_CARD_OUT="$(rc20_cardinality_claims "$MERGE_GATES_DOC" "$RC20_N" "$RC20_W")"
if [ -z "$RC20_CARD_OUT" ]; then
  ok "every sentence on the page that counts the required contexts says $RC20_W ($RC20_N), matching \`.github/required-checks.json\`"
else
  bad "the page states a required-context count that the spec does not support (it is $RC20_N):"
  printf '%s\n' "$RC20_CARD_OUT" | sed 's/^/       /' >&2
fi

# CLAUSE 9 — and it catches the SOFT-WRAPPED phrase that was actually there,
# where the line-scoped rival ran green.
if grep -q '^COUNT	two	' <<<"$(rc20_cardinality_claims "$RC20_CANARY" "$RC20_N" "$RC20_W")"; then
  ok "…and it FIRES on \"one of the two<newline>required contexts\" — the scope is the sentence, not the line"
else
  bad "the soft-wrapped cardinality claim was missed — the clause has degraded to line scope on a page that wraps at 78 columns"
fi
if ! grep -qE "(one|two|three|five|six|[0-9]+) +required contexts" "$RC20_CANARY"; then
  ok "…and the LINE-scoped rival DROPS that same claim — this is why the clause is not a grep"
else
  bad "the line-scoped rival caught the wrapped specimen — re-derive why sentence scope was required"
fi

# CLAUSE 10 — the count is READ. Grow a copy of the spec and the page's honest
# "four" must start being reported.
RC20_SPEC5="$TMP/rc20-spec5.json"
jq '.protection.required_status_checks.checks += [{"context": "Fifth gate", "app_id": 15368}]' "$SPEC" > "$RC20_SPEC5"
RC20_N5="$(jq '.protection.required_status_checks.checks | length' "$RC20_SPEC5")"
if grep -q '^COUNT	four	' <<<"$(rc20_cardinality_claims "$MERGE_GATES_DOC" "$RC20_N5" "$(rc20_count_word "$RC20_N5")")"; then
  ok "…and growing the SPEC to $RC20_N5 contexts makes the page's \"four\" get reported — the number is parsed from the spec, never typed here"
else
  bad "adding a required context to a copy of the spec changed nothing — the expected count is hardcoded in this file"
fi

# CLAUSE 11 — the doc-gates roster's own arithmetic. The page claimed 17 while
# the workflow declared 19; the two the table omitted were
# `Never-cancel-main concurrency ratchet` and `Nil-polarity fail-closed gate`.
RC20_DG_YML="$REPO_ROOT/.github/workflows/doc-gates.yml"
# The label token is a UNION, and both arms are load-bearing. cgsiw-s1 renamed
# all 21 of these step names from `(blocking)` to `(fails this job)`, because
# doc-gates publishes ONE context and that context is not required — the steps
# fail the job, and the job blocks nothing. The count is what this clause is
# about, so it must survive the rename; keeping the old arm means a workflow
# that reverts to the old label is still counted rather than silently read as
# zero. RESIDUE, DISCHARGED 2026-08-19: merge-gates.md used to spell the label
# `(blocking)` in its prose, teach that word as current, and name
# `grep -c '(blocking)' .github/workflows/doc-gates.yml` as the producer of the
# 21 — a command that returns 1 on main and so refuted the page's own number.
# cgsiw-s1-followup-merge-gates-step-label is closed by
# pws-s2-merge-authority-corrections: the prose now quotes the old words as a
# correction, names the anchored derivation
# `grep -cE '^[[:space:]]*- name: .*\(fails this job\)'`, and states the
# boundary negatively. The arithmetic below was never affected (it compares
# NUMBERS) and is unchanged, including the pass message's `(blocking)` wording.
#
# The `|| true` is not a softening: `grep -c` exits 1 on a count of zero, and
# under `set -e` that KILLED this suite mid-section-20 with no summary and no
# message when the rename landed. A guard that dies is strictly worse than one
# that reds — the `-gt 0` test below is the decision, and it still reds on zero.
RC20_DG_REAL="$({ grep -cE '^[[:space:]]*- name: .*(\(blocking\)|\(fails this job\))' "$RC20_DG_YML" || true; } | tr -d ' ')"
rc20_roster_claim() { grep -oE '\*\*[0-9]+ steps labelled' "$1" | head -1 | grep -oE '[0-9]+'; }
rc20_roster_rows() {
  awk '/^\|[[:space:]]*#[[:space:]]*\|[[:space:]]*Step[[:space:]]*\|/ { t = 1; next }
       t && $0 !~ /^\|/ { t = 0 }
       t && /^\|[[:space:]]*[0-9]+[[:space:]]*\|/ { c++ }
       END { print c + 0 }' "$1"
}
RC20_DG_CLAIM="$(rc20_roster_claim "$MERGE_GATES_DOC")"
RC20_DG_ROWS="$(rc20_roster_rows "$MERGE_GATES_DOC")"
if [ "$RC20_DG_REAL" -gt 0 ] && [ "$RC20_DG_CLAIM" = "$RC20_DG_REAL" ] && [ "$RC20_DG_ROWS" = "$RC20_DG_REAL" ]; then
  ok "the doc-gates roster counts what the workflow declares: $RC20_DG_REAL \`(blocking)\` steps, $RC20_DG_CLAIM claimed in prose, $RC20_DG_ROWS rows in the table"
else
  bad "the doc-gates roster miscounts: doc-gates.yml declares $RC20_DG_REAL \`(blocking)\` steps, the page claims $RC20_DG_CLAIM and tables $RC20_DG_ROWS"
fi

# CLAUSE 12 — and that arithmetic is able to fail: the canary's 17 is reported
# against the same derived 19.
if [ "$(rc20_roster_claim "$RC20_CANARY")" != "$RC20_DG_REAL" ]; then
  ok "…and the pre-fix \"17 steps labelled \`(blocking)\`\" does NOT match the $RC20_DG_REAL derived from doc-gates.yml — the count is derived by running, not transcribed"
else
  bad "the canary's 17 matched the derived count — the derivation is not reading doc-gates.yml"
fi


# ── 21 ───────────────────────────────────────────────────────────────────────
# §19 reds when the page UNDERSTATES a gate, §20 when it OVERSTATES one. Neither
# covers OMISSION, and omission is the shape that was actually on the page: on
# 2026-08-08 merge-gates.md — 744 lines, canonical-for: merge-gates, opening with
# "Why a PR cannot be merged until every gate below is green" — had ZERO hits
# across `nothing ran`, `not applicable`, `not dispatched`, `::notice`, `did not
# run`. Meanwhile three of the four required contexts routinely conclude GREEN
# having dispatched nothing: on merged #10565 (head bb15f596d, a single ledger
# `.md`) the per-commit check-runs read `Cloud control-plane (compile + format) |
# skipped`, `Cloud control-plane (test) | skipped`, `Cloud gate | success` with
# one annotation; #10450 (head 5a43bf893) is the same shape. The PLUMBING is
# honest — each path-gated aggregator emits a `::notice` saying so, and
# scripts/gate-announces-skips.test.sh pins the DELIVERED title from inside the
# `Elixir gate` aggregator's own `needs:`. The PAGE a human reads was silent.
#
# WHAT THIS SECTION HOLDS: both sides of one roster, neither side typed here.
# Side A is the emission set, grepped out of `.github/workflows/` — a gate is an
# emitter iff its workflow contains `::notice title=<gate>: green — nothing ran`.
# Side B is the table under merge-gates.md's `| Gate | … nothing ran … |` header.
# It reds when a gate EMITS and the page does not list it (the omission that was
# there), when the page lists a gate whose workflow no longer emits (the stale
# claim), when the page's `—` row claims a gate does not emit while it does, and
# when the page's `Required context` column disagrees with
# `.github/required-checks.json`. It also reds when a REQUIRED context is absent
# from the roster entirely, which is what keeps `PR references an active task` —
# the path-unfiltered fourth, exempt by construction — on the page.
#
# THE MATCHER IS A TABLE PARSE, NOT A PHRASE MATCHER, AND THAT IS THE POINT.
# §19 and §20 each needed three construction rules learned by measured failure
# (D559), because both must read English about checks. This section refuses that
# problem instead of re-solving it: the disclosure's machine-checkable part is a
# THREE-COLUMN ROSTER, so the doc side is `awk -F'|'` over the rows under one
# header, and no sentence anywhere else on the page — or in the repo — can enter
# the report. The false-positive census below is therefore about SELECTION (does
# the parser grab a neighbouring table?) rather than about interpretation, and
# it is run against the live page and against a decoy-table specimen.
#
# WHAT IT CANNOT DO: it holds the roster, not the prose around it. The
# taxonomy paragraph, the quoted annotation and the `gh api` recipe are ordinary
# doc content — deleting them leaves the table intact and this section green.
# The clause that DOES bite on a table left standing over a dead emission is
# clause 5; a page that keeps a correct table beside wrong prose is out of reach
# here, as it is for every other doc guard in this file.
section "21. every gate that announces \`green — nothing ran\` is disclosed on merge-gates.md, and every gate the page says announces it still does"

# SIDE A. Derived: the annotation title IS the contract, so a gate is an emitter
# iff its workflow prints one. `<workflow basename>\t<gate name>`.
rc21_emitters() { # <workflow-dir>
  local f
  for f in "$1"/*.yml; do
    [ -f "$f" ] || continue
    { grep -o '::notice title=[^:]*: green — nothing ran::' "$f" || true; } \
      | sed 's/^::notice title=//; s/: green — nothing ran::$//' \
      | while IFS= read -r g; do
          [ -n "$g" ] && printf '%s\t%s\n' "$(basename "$f")" "$g"
        done
  done | sort -u
}

# SIDE B. The roster rows under the page's own header. `<gate>\t<workflow
# basename or ->\t<required yes|no>`. The header is matched on BOTH the leading
# `Gate` cell and the phrase the roster is about, so no other table on this page
# — the doc-gates step roster, the break-glass table — can be selected instead.
rc21_doc_roster() { # <doc>
  awk -F'|' '
    function clean(s) {
      gsub(/`/, "", s); gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s
    }
    /^\|[[:space:]]*Gate[[:space:]]*\|/ && /nothing ran/ { t = 1; next }
    t && $0 !~ /^\|/ { t = 0 }
    t && /^\|[[:space:]]*-{2,}/ { next }
    t {
      g = clean($2); src = clean($3); req = clean($4)
      if (g == "") next
      n = split(src, p, "/"); if (n > 1) src = p[n]
      print g "\t" src "\t" req
    }
  ' "$1"
}

# The one driver every clause below re-runs, so no mutation exercises a
# look-alike. `MISSING` = emits, page silent. `STALE` = page claims an emission
# the workflow no longer makes (both directions of the `—` row included).
# `REQ` = the page's required column disagrees with the spec. `UNLISTED` = a
# required context the roster does not carry at all. `UNRESOLVED` = a side that
# came back empty, which must refuse rather than pass.
rc21_report() { # <workflow-dir> <spec-json> <doc>
  local emit roster gates ctx g src req file
  emit="$(rc21_emitters "$1")"
  roster="$(rc21_doc_roster "$3")"
  if [ -z "$emit" ]; then
    printf 'UNRESOLVED\tno workflow under %s emits `gate: green — nothing ran` — side A derived empty\n' "$1"
    return
  fi
  if [ -z "$roster" ]; then
    printf 'UNRESOLVED\t%s carries no `| Gate | … nothing ran … |` roster — the page side derived empty\n' "$3"
    return
  fi
  gates="$(cut -f2 <<<"$emit" | sort -u)"

  # 1. emits ⇒ listed, with the right workflow named.
  while IFS=$'\t' read -r file g; do
    [ -n "$g" ] || continue
    if ! awk -F'\t' -v g="$g" -v f="$file" '$1 == g && $2 == f { found = 1 }
                                            END { exit !found }' <<<"$roster"; then
      printf 'MISSING\t%s\t%s emits the notice and the page does not disclose it against that workflow\n' "$g" "$file"
    fi
  done <<EOF
$emit
EOF

  # 2. listed ⇒ still emits (and a `—` row means it must NOT emit).
  while IFS=$'\t' read -r g src req; do
    [ -n "$g" ] || continue
    if [ "$src" = "—" ] || [ "$src" = "-" ]; then
      if grep -qxF "$g" <<<"$gates"; then
        printf 'STALE\t%s\tthe page says it does not announce, but a workflow emits the notice for it\n' "$g"
      fi
    elif ! awk -F'\t' -v g="$g" -v f="$src" '$2 == g && $1 == f { found = 1 }
                                             END { exit !found }' <<<"$emit"; then
      printf 'STALE\t%s\tthe page says %s emits the notice for it; that workflow does not\n' "$g" "$src"
    fi
    # 3. the required column is the spec's, not the page's opinion.
    if jq -e --arg c "$g" '.protection.required_status_checks.checks
                           | any(.context == $c)' "$2" >/dev/null; then
      [ "$req" = "yes" ] || printf 'REQ\t%s\tthe page says required=%s; required-checks.json lists it as a required context\n' "$g" "$req"
    else
      [ "$req" = "no" ] || printf 'REQ\t%s\tthe page says required=%s; required-checks.json does not list it\n' "$g" "$req"
    fi
  done <<EOF
$roster
EOF

  # 4. every required context appears in the roster — including the exempt one.
  while IFS= read -r ctx; do
    [ -n "$ctx" ] || continue
    awk -F'\t' -v c="$ctx" '$1 == c { found = 1 } END { exit !found }' <<<"$roster" \
      || printf 'UNLISTED\t%s\ta required context the roster does not carry — a merger cannot tell whether its green ran anything\n' "$ctx"
  done <<EOF
$(jq -r '.protection.required_status_checks.checks[].context' "$2")
EOF
}

RC21_EMIT="$(rc21_emitters "$REPO_ROOT/.github/workflows")"
RC21_EMIT_LIST="$(cut -f2 <<<"$RC21_EMIT" | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
RC21_MISSING_EMITTER=""
for g in 'Cloud gate' 'Console gate' 'Elixir gate'; do
  grep -qxF "$g" <<<"$(cut -f2 <<<"$RC21_EMIT")" || RC21_MISSING_EMITTER="$RC21_MISSING_EMITTER $g"
done
if [ -n "$RC21_EMIT" ] && [ -z "$RC21_MISSING_EMITTER" ]; then
  ok "derived the announcing gates from the workflow sources, nothing typed: $RC21_EMIT_LIST"
else
  bad "side A did not derive the announcing gates (missing:${RC21_MISSING_EMITTER:- none}) — the section would hold an empty roster and pass"
fi

# CLAUSE 2 — the doc side selects the roster and NOTHING else on a 700-line page
# carrying several other tables. The count is asserted against the parse itself
# so a selection that silently widened would have to widen visibly.
RC21_ROSTER="$(rc21_doc_roster "$MERGE_GATES_DOC")"
RC21_ROWS="$(printf '%s\n' "$RC21_ROSTER" | { grep -c . || true; } | tr -d ' ')"
if [ "$RC21_ROWS" -ge 4 ] && ! grep -q 'Doc budgets' <<<"$RC21_ROSTER" \
   && ! grep -qE '^[0-9]+\b' <<<"$RC21_ROSTER"; then
  ok "the page's roster parses to $RC21_ROWS gate rows and pulls in no row from any other table on the page"
else
  bad "the roster parse is wrong — it read $RC21_ROWS rows and they are not all gate rows:"
  printf '%s\n' "$RC21_ROSTER" | sed 's/^/       /' >&2
fi

# CLAUSE 3 — THE FALSE-POSITIVE CENSUS, direction one: the live page, unmodified.
RC21_OUT="$(rc21_report "$REPO_ROOT/.github/workflows" "$SPEC" "$MERGE_GATES_DOC")"
if [ -z "$RC21_OUT" ]; then
  ok "every gate that announces \`green — nothing ran\` is on the page against its own workflow, every required context is rostered, and the required column matches the spec"
else
  bad "merge-gates.md and the workflows disagree about which required greens ran nothing:"
  printf '%s\n' "$RC21_OUT" | sed 's/^/       /' >&2
fi

# CLAUSE 4 — THE FALSE-POSITIVE CENSUS, direction two: a DECOY page. Ordinary
# prose that talks about gates at length, plus a three-column table that is not
# the roster. A parser keyed on "a markdown table near the word gate" would take
# the decoy and report every real emitter MISSING; this one takes neither, and
# refuses (UNRESOLVED) rather than passing on an empty page side.
RC21_DECOY="$TMP/rc21-decoy.md"
cat > "$RC21_DECOY" <<'MD'
## Gates

`Cloud gate`, `Console gate` and `Elixir gate` are the path-gated aggregators.
Nothing ran on this head is a thing people say about them in passing.

| Gate | Owner | Notes |
| --- | --- | --- |
| `Cloud gate` | platform | green — nothing ran is a phrase in this cell |
| `Elixir gate` | api | see above |
MD
RC21_DECOY_ROWS="$(rc21_doc_roster "$RC21_DECOY" | { grep -c . || true; } | tr -d ' ')"
# The corpus figure is REPORTED, not asserted, on §20 clause 6's precedent: the
# shipped matcher is only ever pointed at merge-gates.md, so a second file
# growing this table shape is a fact worth seeing and never a reason for a
# merge-blocking suite to red. The assertion is on the fixed specimen.
RC21_CORPUS=0
while IFS= read -r md; do
  [ -n "$(rc21_doc_roster "$md")" ] && RC21_CORPUS=$((RC21_CORPUS + 1))
done <<EOF
$(find "$REPO_ROOT" -name .git -prune -o -name node_modules -prune -o -name _build -prune \
    -o -name '*.md' ! -path "$MERGE_GATES_DOC" -print)
EOF
if [ "$RC21_DECOY_ROWS" -eq 0 ] \
   && grep -q '^UNRESOLVED' <<<"$(rc21_report "$REPO_ROOT/.github/workflows" "$SPEC" "$RC21_DECOY")"; then
  ok "…and a decoy page — gate prose plus a three-column table that is NOT the roster — parses to 0 rows and makes the section REFUSE, never pass (in-repo census: $RC21_CORPUS other .md file(s) parse to any roster row at all)"
else
  bad "the roster parser selected a table that is not the roster ($RC21_DECOY_ROWS rows) — the selection is keyed too loosely"
fi

# CLAUSE 5 — MUTATION, DIRECTION 1 (the omission that was actually there). Drop
# `Cloud gate`'s row from a copy of the page: the gate still emits, so it must be
# reported MISSING by name. Paired with a non-vacuity assertion — the run must
# still be silent about `Console gate`, or a broken parse could buy the red.
RC21_DOC_DROP="$TMP/rc21-doc-drop.md"
grep -v '^| `Cloud gate` |' "$MERGE_GATES_DOC" > "$RC21_DOC_DROP"
RC21_DROP_OUT="$(rc21_report "$REPO_ROOT/.github/workflows" "$SPEC" "$RC21_DOC_DROP")"
if grep -q '^MISSING	Cloud gate	' <<<"$RC21_DROP_OUT" \
   && ! grep -q 'Console gate' <<<"$RC21_DROP_OUT"; then
  ok "…and DELETING the \`Cloud gate\` row reds it BY NAME while the rest of the roster stays green — the section reads the roster, not the page's length"
else
  bad "removing a rostered gate from the page changed nothing (or reddened the whole table) — the omission direction does not work:"
  printf '%s\n' "$RC21_DROP_OUT" | sed 's/^/       /' >&2
fi

# CLAUSE 6 — MUTATION, DIRECTION 2 (the page outliving the emission). Strip the
# `::notice` from cloud.yml in a SCRATCH workflow tree and change not one byte of
# the page: the roster's claim is now false and must be reported STALE. This is
# the clause that makes the ratchet two-sided — a gate that quietly stops
# disclosing cannot leave a page still promising that it does.
RC21_WF="$TMP/rc21-workflows"
rm -rf "$RC21_WF"; mkdir -p "$RC21_WF"
cp "$REPO_ROOT"/.github/workflows/*.yml "$RC21_WF/"
grep -v 'title=Cloud gate: green' "$REPO_ROOT/.github/workflows/cloud.yml" > "$RC21_WF/cloud.yml"
RC21_STALE_OUT="$(rc21_report "$RC21_WF" "$SPEC" "$MERGE_GATES_DOC")"
if grep -q '^STALE	Cloud gate	' <<<"$RC21_STALE_OUT" \
   && ! grep -q 'Elixir gate' <<<"$RC21_STALE_OUT"; then
  ok "…and STRIPPING the notice from a scratch \`cloud.yml\` (page untouched) reds \`Cloud gate\` as STALE while \`Elixir gate\` stays green — the emission side is read from source"
else
  bad "deleting the emission left the page's claim unchallenged — the section is one-directional:"
  printf '%s\n' "$RC21_STALE_OUT" | sed 's/^/       /' >&2
fi

# CLAUSE 7 — the `—` row is a CLAIM, not a blank. `PR references an active task`
# is the exempt fourth: path-unfiltered, always dispatched, so its green is a
# verdict. Flip its cell to name a workflow and the row becomes an emission claim
# no workflow supports.
RC21_DOC_FAKE="$TMP/rc21-doc-fake.md"
sed 's@^| `PR references an active task` | — |@| `PR references an active task` | `.github/workflows/pr-task-gate.yml` |@' \
  "$MERGE_GATES_DOC" > "$RC21_DOC_FAKE"
if grep -q '^STALE	PR references an active task	' \
     <<<"$(rc21_report "$REPO_ROOT/.github/workflows" "$SPEC" "$RC21_DOC_FAKE")"; then
  ok "…and claiming the path-unfiltered \`PR references an active task\` announces a nothing-ran green reds too — the exempt row is held, not ignored"
else
  bad "the exempt row can be turned into an unsupported emission claim without a red — the em-dash cell is being treated as a blank"
fi

# CLAUSE 8 — the required column and the roster's completeness are read from the
# SPEC. Grow a copy to five contexts: the new one is not on the page, so it must
# come back UNLISTED. This is what forces a future required context to be
# disclosed as ran-something or ran-nothing before it can sit next to a merge
# button.
RC21_SPEC5="$TMP/rc21-spec5.json"
jq '.protection.required_status_checks.checks += [{"context": "Fifth gate", "app_id": 15368}]' "$SPEC" > "$RC21_SPEC5"
if grep -q '^UNLISTED	Fifth gate	' \
     <<<"$(rc21_report "$REPO_ROOT/.github/workflows" "$RC21_SPEC5" "$MERGE_GATES_DOC")"; then
  ok "…and adding a context to a COPY of the spec makes the page's roster come back incomplete — the required set is parsed, never typed here"
else
  bad "growing the spec changed nothing — the required-context side of this section is hardcoded"
fi

# CLAUSE 9 — and the required column itself can lose. `Security gate` emits the
# same notice and is NOT required; the page says so. Flip that cell to `yes` and
# the spec must contradict it.
RC21_DOC_REQ="$TMP/rc21-doc-req.md"
sed 's@^\(| `Security gate` | `.github/workflows/security.yml` \)| no |$@\1| yes |@' \
  "$MERGE_GATES_DOC" > "$RC21_DOC_REQ"
if grep -q '^REQ	Security gate	' \
     <<<"$(rc21_report "$REPO_ROOT/.github/workflows" "$SPEC" "$RC21_DOC_REQ")"; then
  ok "…and promoting \`Security gate\` to required on the page contradicts \`.github/required-checks.json\` and reds — the weakest green on the roster cannot be dressed up"
else
  bad "the page can call a non-required gate required without a red — the third column is decorative"
fi


section "22. the merge-truth prose clause reads the WHOLE TRACKED corpus, and tells an assertion apart from a record of one"

# THE BLIND SPOT THIS SECTION PINS (cch-w34). `advisory_prose_check` scans
# `find "$WORKFLOWS_DIR" -maxdepth 1` — .github/workflows, one level. Every
# charter under `.claude/workflows/`, every page under `docs/`, every README is
# outside it, and those are what an agent is handed BY NAME, in full, before it
# has run a single `gh api`. The founding defect (cch-w32-s4) was a workflow
# comment calling `Console gate` advisory while it was required; the SAME
# sentence re-copied into a charter was invisible to every clause in the file.
#
# The widening is only half of it, and the smaller half. Pointed at narrative
# prose unchanged, the workflow clause's PROXIMITY reading is 94% noise — so the
# corpus widens and the lens tightens with it, to ATTRIBUTION: the span stops at
# the clause, the disclaimer must be predicated of the context by a copula, and
# a dated record / a quotation / a fenced transcript are fenced rather than
# asserted. This section is that discrimination, one context per case so all
# four are observable in ONE run (the scanner reports the first hit per context,
# so four cases sharing a name would hide three of themselves).

RC22_ROOT="$TMP/mt-prose"
mkdir -p "$RC22_ROOT/nested/deeper"
RC22_DOC="$RC22_ROOT/nested/deeper/bp-fixture-charter.md"
# TWO DIRECTORIES DEEP AND NAMED .md — the two properties the depth-1 workflow
# glob is structurally blind to. The filler paragraphs are load-bearing: the
# record fence reads 160 characters to the LEFT of a name, so without them one
# row's marker would classify the next row.
cat > "$RC22_DOC" <<'MD'
# Fixture corpus

- **D1 — the assertion.** Land on green. `Console gate` is ADVISORY today, so a
  red one does not stop the merge button; treat it as blocking anyway.

Filler paragraph, holding nothing for any rule here to bite on, long enough to
push the row above out of the window that the row below reads behind itself.

- **D2 — a quotation, which must stay green.** The seal printed *"`Cloud gate`
  is NOT a required status check on main"* under the spec of the day.

Filler paragraph, holding nothing for any rule here to bite on, long enough to
push the row above out of the window that the row below reads behind itself.

- **D3 — a dated record, which must stay green.** At the time this wave was
  written `Elixir gate` was advisory; it is required now.

Filler paragraph, holding nothing for any rule here to bite on, long enough to
push the row above out of the window that the row below reads behind itself.

- **D4 — proximity, not attribution, which must stay green.** The required set
  is `PR references an active task` and three others (branch-protection API) —
  doc-gates hosts the shell check but is NOT required.
MD

# Writes to a FILE and returns verify's exit code, rather than printing the
# output and setting a global: `X="$(fn)"` runs fn in a SUBSHELL, so a global
# assigned inside it never reaches the caller — under `set -u` the caller then
# dies on an unbound variable instead of grading anything.
RC22_OUT="$TMP/rc22-out.txt"
rc22_run() { # <prose-root> [extra args…]  -> writes $RC22_OUT, returns verify's rc
  local root="$1"; shift
  bash "$VERIFY" --spec "$SPEC" --readback "$TMP/rb.json" --runs "$TMP/runs.json" \
    --sha probe --prose "$root" "$@" > "$RC22_OUT" 2>&1
}

# (a) THE DEFECT. A charter the workflow glob cannot reach, calling a REQUIRED
#     context advisory, must red — and red by NAME. A bare non-zero would be
#     satisfied by a missing fixture or any other refusal in the file.
rc22_run "$RC22_ROOT" && RC22_RC=0 || RC22_RC=$?
RC22_A="$(cat "$RC22_OUT")"
# The path is printed absolute here: `rel` strips REPO_ROOT, and under --prose
# the fixture lives in $TMP instead. The assertion still names the file and the
# context, which is what "red by name" means.
if [ "$RC22_RC" -ne 0 ] \
   && grep -q 'UNPINNED .*nested/deeper/bp-fixture-charter.md' <<<"$RC22_A" \
   && grep -q 'claims "Console gate" is not blocking' <<<"$RC22_A"; then
  ok "a charter TWO directories deep, named .md, calling a required context advisory REDS by name (exit $RC22_RC) — the corpus the depth-1 workflow glob cannot reach"
else
  bad "the outside-workflows claim was not caught by name (exit $RC22_RC): $(grep -m2 -e FAIL -e UNPINNED <<<"$RC22_A")"
fi

# (b) …AND EVERYTHING ELSE IN THE SAME FILE STAYS GREEN, counted rather than
#     merely absent. Delete ONLY D1. If the quotation, the dated record or the
#     proximity row red, the widening is the 94%-noise clause that gets switched
#     off in a wave — and a green that never SAW them would prove nothing, so
#     the fence tallies are read off the pass line.
sed '/D1 — the assertion/,+1d' "$RC22_DOC" > "$RC22_DOC.x" && mv "$RC22_DOC.x" "$RC22_DOC"
rc22_run "$RC22_ROOT" && RC22_RC=0 || RC22_RC=$?
RC22_B="$(cat "$RC22_OUT")"
if [ "$RC22_RC" -eq 0 ] \
   && grep -q '1 dated record(s), 1 quotation(s)' <<<"$RC22_B"; then
  ok "…and with ONLY the assertion removed the file is GREEN with the quotation and the dated record COUNTED as fenced — seen and told apart, not merely absent"
else
  bad "the audit-trail half did not survive the widening (exit $RC22_RC): $(grep -e 'ok  *no tracked prose' -e UNPINNED <<<"$RC22_B" | head -2)"
fi

# (c) PROXIMITY NEVER FIRED AT ALL, which the tallies in (b) cannot show on
#     their own: `PR references an active task` sits one clause from `is NOT
#     required`, and rule 1 stops the attributed span at the `)` before it. On
#     its own, with no record and no quotation anywhere in the corpus, both
#     fence counters must read ZERO — a green reached by fencing would not.
RC22_PROX="$TMP/mt-prose-prox"
mkdir -p "$RC22_PROX"
cat > "$RC22_PROX/roster.md" <<'MD'
The required set is `PR references an active task` and three others
(branch-protection API) — doc-gates hosts the shell check but is NOT required.
MD
rc22_run "$RC22_PROX" && RC22_RC=0 || RC22_RC=$?
RC22_C="$(cat "$RC22_OUT")"
if [ "$RC22_RC" -eq 0 ] && grep -q '0 dated record(s), 0 quotation(s)' <<<"$RC22_C"; then
  ok "…and the proximity sentence is green with BOTH fences at zero — rule 1 stopped the span, so nothing was fenced away to get there"
else
  bad "the proximity sentence was not handled by attribution (exit $RC22_RC): $(grep -e 'ok  *no tracked prose' -e UNPINNED <<<"$RC22_C" | head -2)"
fi

# (d) THE TRANSCRIPT FENCE. The wave ledgers paste planted probe fixtures and
#     shell sessions verbatim inside ``` blocks — a fixture written to make THIS
#     suite red is not a sentence telling an agent anything. The identical
#     sentence from (a), inside a fence, must go green with the fence counted.
RC22_FENCE="$TMP/mt-prose-fence"
mkdir -p "$RC22_FENCE"
{ printf '%s\n' 'Transcript of the probe that was planted in wave 32:'
  printf '%s\n' '```'
  printf '%s\n' '# PROBE: `Console gate` is ADVISORY today and does not block a merge.'
  printf '%s\n' '```'
} > "$RC22_FENCE/ledger.md"
rc22_run "$RC22_FENCE" && RC22_RC=0 || RC22_RC=$?
RC22_D="$(cat "$RC22_OUT")"
if [ "$RC22_RC" -eq 0 ] && grep -qE '[1-9][0-9]* code-fence line\(s\) fenced' <<<"$RC22_D"; then
  ok "…and the SAME sentence inside a \`\`\` block is green with the code-fence lines COUNTED — a pasted transcript is evidence about a claim, not the claim"
else
  bad "the transcript fence did not hold or did not report its size (exit $RC22_RC): $(grep -e 'ok  *no tracked prose' -e UNPINNED <<<"$RC22_D" | head -2)"
fi

# (e) THE CENSUS IS THE WHOLE TRACKED CORPUS, and the count is checked against
#     `git ls-files` rather than trusted. This is the criterion the row states in
#     as many words ("any TRACKED text file"), and it is the one a root list
#     silently fails: `.claude/workflows docs CLAUDE.md` reached 217 files and
#     read as a green. A directory allowlist is the same shape as the depth-1
#     glob this clause exists to delete.
RC22_TRACKED="$(cd "$REPO_ROOT" && git ls-files -- '*.md' '*.markdown' '*.txt' \
  | while IFS= read -r f; do [ -f "$f" ] && printf 'x\n'; done | grep -c .)"
RC22_E="$(bash "$VERIFY" --spec "$SPEC" --readback "$TMP/rb.json" --runs "$TMP/runs.json" --sha probe 2>&1)" \
  && RC22_E_RC=0 || RC22_E_RC=$?
RC22_SCANNED="$(sed -n 's/.*(\([0-9]*\) tracked file(s) scanned outside .github\/workflows.*/\1/p' <<<"$RC22_E")"
if [ "$RC22_E_RC" -eq 0 ] && [ -n "$RC22_SCANNED" ] && [ "$RC22_SCANNED" = "$RC22_TRACKED" ]; then
  ok "the committed corpus scans all $RC22_TRACKED tracked *.md/*.markdown/*.txt — the census is \`git ls-files\`, not a directory allowlist, and the run is green"
else
  bad "the committed-corpus scan did not cover the tracked census (exit $RC22_E_RC, scanned '${RC22_SCANNED:-none}' of $RC22_TRACKED): $(grep -m2 -e FAIL -e UNPINNED <<<"$RC22_E")"
fi

# (f) THE PIN CANNOT ROT INTO AN EXEMPTION. A census is a SET EQUALITY, never a
#     count: a pin whose sentence has been fixed must be reported STALE, so the
#     commit that fixes a claim has to drop its pin in the same breath. Append a
#     pin that matches nothing and the clause must say so.
#
#     The mutant is SOURCED with `$0` set to the real script, because REPO_ROOT
#     is derived from `$0` and the committed-corpus arm runs `git ls-files` in
#     it — a copy in $TMP would scan a directory that is not a checkout and red
#     for a reason that has nothing to do with the pin.
RC22_PINMUT="$TMP/verify-stale-pin.sh"
perl -pe 's{^(PROSE_CLAIM_PINS=\x27.*)\x27$}{$1\ndocs/this-file-does-not-exist.md|Console gate|` is advisory in a file nobody has\x27}' \
  "$VERIFY" > "$RC22_PINMUT"
if ! grep -q 'this-file-does-not-exist' "$RC22_PINMUT"; then
  bad "the stale-pin mutation did not apply — PROSE_CLAIM_PINS is no longer a single-quoted assignment, so the proof below would be vacuous"
else
  ok "the mutation applies: a second pin, matching nothing in the committed corpus, is appended to a copy of verify"
  RC22_F="$(bash -c 'M="$1"; shift; . "$M"' "$VERIFY" "$RC22_PINMUT" \
    --spec "$SPEC" --readback "$TMP/rb.json" --runs "$TMP/runs.json" --sha probe 2>&1)" \
    && RC22_F_RC=0 || RC22_F_RC=$?
  if [ "$RC22_F_RC" -ne 0 ] && grep -q 'STALE  the pin "docs/this-file-does-not-exist.md' <<<"$RC22_F"; then
    ok "…and a pin matching nothing REDS as STALE — fixing a claim must drop its pin in the same commit, so a pin cannot outlive the sentence it excuses"
  else
    bad "a pin that matches nothing passed in silence (exit $RC22_F_RC) — the pin list is an exemption list: $(grep -m2 -e FAIL -e STALE <<<"$RC22_F")"
  fi
fi

# (g) MUTATION PROOF. Remove the clause's CALL from a copy and (a)'s exact
#     fixture must sail through green again. Without this, (a) passes on any
#     refusal the file happens to raise for another reason, and the BEFORE half
#     of this slice's claim is unproven. `--workflows` explicitly for the reason
#     §8b(d) already wrote down: the mutant's own REPO_ROOT is $TMP.
RC22_NOCLAUSE="$TMP/verify-no-merge-truth.sh"
sed -E 's%^( *)merge_truth_prose_check \|\| (rc=1|return 1)%\1: # MERGE-TRUTH CLAUSE REMOVED%' "$VERIFY" > "$RC22_NOCLAUSE"
RC22_MUTN="$(grep -c 'MERGE-TRUTH CLAUSE REMOVED' "$RC22_NOCLAUSE" || true)"
if [ "$RC22_MUTN" -ne 3 ]; then
  bad "the merge-truth mutation applied $RC22_MUTN times, not 3 (run_full's two arms and run_ci) — the call moved, so the proof below is vacuous"
else
  ok "the mutation applies: the merge-truth call is removed from all 3 of its call sites in a copy of verify"
  # Restore D1 — (b) deleted it in place.
  sed '1a\
- **D1 — the assertion.** `Console gate` is ADVISORY today, so a red one does not stop the merge button.' \
    "$RC22_DOC" > "$RC22_DOC.x" && mv "$RC22_DOC.x" "$RC22_DOC"
  RC22_G="$(bash "$RC22_NOCLAUSE" --spec "$SPEC" --readback "$TMP/rb.json" --runs "$TMP/runs.json" \
    --sha probe --prose "$RC22_ROOT" --workflows "$REPO_ROOT/.github/workflows" 2>&1)" \
    && RC22_G_RC=0 || RC22_G_RC=$?
  if [ "$RC22_G_RC" -eq 0 ]; then
    ok "…and WITHOUT it the SAME charter sails through green — the blind spot, reproduced on demand"
  else
    bad "the unguarded verify did not reproduce the blindness (exit $RC22_G_RC) — clause (a) may be reding for an unrelated reason: $(grep -m2 FAIL <<<"$RC22_G")"
  fi
fi

section "23. --ci reads live protection on enforced=false too — the arm every PR runs"

# THE DEFECT THIS SECTION PINS (cchi-w51). §8b closed this hole in `run_full`
# and deliberately stopped there: `--ci` is what `required-checks-drift.yml`
# runs on every PR, so flipping its polarity is a merge-path change that
# deserved its own review. Until this commit `run_ci`'s enforced=false branch
# printed four sentences arguing that enforced=false is a committed, reviewable
# state — and never read the live branch. The prose was not wrong; it was
# answering a question nobody asked. Reviewable is not the same as TRUE, and the
# one direction a spec-reader can never see is SPEC SAYS THE GATE IS OFF WHILE
# THE GATE IS ON.
#
# The three read-back fixtures are §8b's, deliberately: protected, GitHub's OWN
# 404 body, and a path that does not exist. A false red here blocks the repo.

RC23_UNAPPLIED="$TMP/rc23-unapplied.json"
jq '.enforced = false' "$SPEC" > "$RC23_UNAPPLIED"
RC23_UNPROTECTED="$TMP/rc23-rb-unprotected.json"
printf '%s\n' '{"message":"Branch not protected","documentation_url":"https://docs.github.com/rest/branches/branch-protection"}' > "$RC23_UNPROTECTED"

# (a) THE DRIFT DIRECTION, through --ci this time.
RC23_OUT="$(bash "$VERIFY" --ci --spec "$RC23_UNAPPLIED" --readback "$TMP/rb.json" --runs "$TMP/runs.json" --sha probe 2>&1)" && RC23_RC=0 || RC23_RC=$?
RC23_MISSING=""
while IFS= read -r c; do
  grep -qF "$c" <<<"$RC23_OUT" || RC23_MISSING="$RC23_MISSING $c"
done < <(SPEC_CONTEXTS)
if [ "$RC23_RC" -ne 0 ] && grep -q "IS PROTECTED right now" <<<"$RC23_OUT" && [ -z "$RC23_MISSING" ]; then
  ok "--ci on an enforced=false spec against a PROTECTED branch REDS (exit $RC23_RC) and names all $(SPEC_CONTEXTS | grep -c .) live context(s)"
else
  bad "the --ci enforced=false/protected drift was not caught as a named red (exit $RC23_RC, unnamed:${RC23_MISSING:- none}): $(grep -m2 FAIL <<<"$RC23_OUT")"
fi
# …and the four lines it used to print instead must be gone. A red that also
# says "committed, reviewable state" is read as OK by whoever skims it.
if grep -q "COMMITTED, reviewable state" <<<"$RC23_OUT"; then
  bad "the --ci drift red still printed the reviewable-state prose — a red that also reassures is read as a green"
else
  ok "…and the run does NOT print the \`COMMITTED, reviewable state\` prose it used to exit 0 on"
fi

# (b) THE LEGITIMATE CASE. Without this the fix is indistinguishable from
#     "always red here", which is how a guard on the merge path gets disabled.
#     Anchored on the live probe's OWN agreement line, not on the exit code:
#     `--ci` never prints run_full's "genuinely unprotected" summary, and a bare
#     exit 0 here would also be satisfied by the clause never running at all —
#     which is the defect, not the fix.
RC23_OK_OUT="$(bash "$VERIFY" --ci --spec "$RC23_UNAPPLIED" --readback "$RC23_UNPROTECTED" --runs "$TMP/runs.json" --sha probe 2>&1)" && RC23_OK_RC=0 || RC23_OK_RC=$?
if [ "$RC23_OK_RC" -eq 0 ] && grep -q "the spec's enforced=false claim matches reality" <<<"$RC23_OK_OUT"; then
  ok "…while --ci on the same spec against a genuinely unprotected branch still exits 0, having LOOKED and agreed — this is not \"always red\", and not a skip either"
else
  bad "the --ci pre-flip case broke (exit $RC23_OK_RC): $(tail -2 <<<"$RC23_OK_OUT")"
fi

# (c) COULD-NOT-LOOK IS NOT AGREEMENT — the whole finding is a guard that
#     greened because it declined to look.
RC23_BLIND_OUT="$(bash "$VERIFY" --ci --spec "$RC23_UNAPPLIED" --readback "$TMP/rc23-nope.json" --runs "$TMP/runs.json" --sha probe 2>&1)" && RC23_BLIND_RC=0 || RC23_BLIND_RC=$?
if [ "$RC23_BLIND_RC" -ne 0 ] && grep -q "could not look at live protection" <<<"$RC23_BLIND_OUT"; then
  ok "…and an unreadable live protection on --ci's enforced=false path REDS as \"could not look\", never as agreement"
else
  bad "the --ci no-read path did not degrade honestly (exit $RC23_BLIND_RC): $(tail -2 <<<"$RC23_BLIND_OUT")"
fi

# (d) MUTATION PROOF, §8b(d)'s shape. run_ci's call is the ONLY
#     `unapplied_spec_matches_reality || rc=1` in the file — run_full's is
#     `|| return 1` and §8b mutates that one — so the count is asserted, not
#     assumed.
RC23_NOCHECK="$TMP/verify-no-ci-clause.sh"
sed -E 's%^( *)unapplied_spec_matches_reality \|\| rc=1%\1: # RUN_CI CLAUSE REMOVED%' "$VERIFY" > "$RC23_NOCHECK"
RC23_MUTN="$(grep -c 'RUN_CI CLAUSE REMOVED' "$RC23_NOCHECK" || true)"
if [ "$RC23_MUTN" -ne 1 ]; then
  bad "the run_ci mutation applied $RC23_MUTN times, not once — the call moved or run_full's arm now shares its shape, so the proof below is vacuous"
else
  ok "the mutation applies: run_ci's live-probe call — and only run_ci's — is removed from a copy of verify"
  RC23_MUT_OUT="$(bash "$RC23_NOCHECK" --ci --spec "$RC23_UNAPPLIED" --readback "$TMP/rb.json" --runs "$TMP/runs.json" --sha probe --workflows "$REPO_ROOT/.github/workflows" --prose "$RC22_PROX" 2>&1)" && RC23_MUT_RC=0 || RC23_MUT_RC=$?
  if [ "$RC23_MUT_RC" -eq 0 ]; then
    ok "…and WITHOUT it the SAME protected read-back exits 0 through --ci — the old blindness on the arm every PR runs, reproduced on demand"
  else
    bad "the unguarded --ci did not reproduce the blindness (exit $RC23_MUT_RC) — clause (a) may be reding for an unrelated reason: $(tail -2 <<<"$RC23_MUT_OUT")"
  fi
fi

# ── 24 ───────────────────────────────────────────────────────────────────────
# `S7 EXCLUDED BY DECISION` reasons are hand-maintained prose that lives in TWO
# files at once: the `EXCLUDED_BY_DECISION_REASONS` constants in
# scripts/required-checks-generate.sh, and the `.reason` of the matching row in
# .github/required-checks.json. The emit unions the two ledgers as
# `group_by(.context) | map(.[-1])` with the committed rows FIRST and the freshly
# generated rows APPENDED, so the LAST row wins: the GENERATOR's copy silently
# overwrites the file's on every regeneration, and §14b asserts that precedence
# as intended.
#
# WHY THIS SECTION EXISTS, and it is a MEASURED near-miss rather than a worry.
# The file's copy of the spec-gate reason was corrected BY HAND on 2026-08-06
# (wave 36) to delete a re-evaluation trigger that could never fire. The
# generator's copy was not. An offline regeneration on origin/main OVERWROTE
# BOTH committed S7 rows — the dead trigger back in the highest-authority file
# in the estate, and nothing in this suite noticing. The constants were realigned
# in #14710; this section is the tripwire that keeps them aligned, and it
# deliberately did NOT ship in that PR, because a guard co-merged with its own
# fix has no red to point at and arrives with a vacuous fail arm.
#
# TWO FILE READS. No network, no `gh`, no credential, no fixture, no clock.
#
# THE COMPARISON IS ON BYTES, NOT CHARACTERS, and that distinction is not
# pedantry: both reasons carry em dashes, so a character count reads 1999/990
# where the byte count reads 2012/998 — a length check written in the wrong unit
# would agree with itself while the text differed. The reasons also carry
# backticks, apostrophes and double quotes that survive only if the constants are
# read the way bash itself reads them, so the arrays are SOURCED out of the
# generator rather than re-parsed with a regex (a regex would be testing this
# section's own pattern, not the value the generator assigns) and compared with
# `cmp`, which names the first differing byte offset instead of merely saying no.
#
# THE REVERSE DIRECTION, STATED SO IT IS NOT MISREAD. The committed spec holds
# FOUR contexts under S7; the generator names only TWO. `Dispatch (compose-smoke
# paths)` and `PR task gate self-test` have no generator constant BY DESIGN —
# they survive a regeneration through the BASE half of that same union. So "every
# S7 row in the spec has a generator constant" is FALSE on a healthy tree and is
# not asserted here. What is asserted is the direction that can erase a
# correction: every generator constant must have EXACTLY ONE committed row, and
# that row must match it byte for byte.

section "24. the generator's hand-maintained S7 reasons are byte-identical to the committed rows a regeneration would overwrite"

# A pure function of (generator, spec) so the mutation twins below can re-run it
# against a MUTATED COPY of either side and watch it red. It never exits
# non-zero; the verdict is in the lines it prints, which is what lets one call
# serve both the clean read and the four mutants.
s7_report() {  # $1 = generator, $2 = spec, $3 = tag for temp files
  local gen="$1" spec="$2" blk="$TMP/s7-consts-$3.sh"
  # Only the two array literals, lifted verbatim. If either block is ever
  # renamed the extraction comes back empty and the CHECKED line below reads 0,
  # which is a red — never a silent skip.
  sed -n '/^EXCLUDED_BY_DECISION_NAMES=(/,/^)/p
          /^EXCLUDED_BY_DECISION_REASONS=(/,/^)/p' "$gen" > "$blk"
  (
    EXCLUDED_BY_DECISION_NAMES=()
    EXCLUDED_BY_DECISION_REASONS=()
    # shellcheck source=/dev/null
    . "$blk"
    i=0
    printf 'CHECKED\t%s\t%s\n' \
      "${#EXCLUDED_BY_DECISION_NAMES[@]}" "${#EXCLUDED_BY_DECISION_REASONS[@]}"
    if [ "${#EXCLUDED_BY_DECISION_NAMES[@]}" -ne "${#EXCLUDED_BY_DECISION_REASONS[@]}" ]; then
      # An off-by-one here does not merely lose an entry: it pairs every later
      # name with the WRONG reason, and each of those still looks like prose.
      printf 'ARITY\t%s\t%s\n' \
        "${#EXCLUDED_BY_DECISION_NAMES[@]}" "${#EXCLUDED_BY_DECISION_REASONS[@]}"
    fi
    while [ "$i" -lt "${#EXCLUDED_BY_DECISION_NAMES[@]}" ]; do
      n="${EXCLUDED_BY_DECISION_NAMES[$i]}"
      case "${EXCLUDED_BY_DECISION_REASONS[$i]:-}" in
        "S7 EXCLUDED BY DECISION"*) : ;;
        *) printf 'SHAPE\t%s\n' "$n" ;;
      esac
      rows="$(jq --arg c "$n" '[.exclusions[] | select(.context == $c)] | length' "$spec")"
      if [ "$rows" -eq 0 ]; then
        printf 'MISSING\t%s\n' "$n"
      elif [ "$rows" -ne 1 ]; then
        # The union keeps `.[-1]` per context, so a duplicate row means the file
        # already disagrees with itself and the comparison below is a coin flip.
        printf 'DUP\t%s\t%s\n' "$n" "$rows"
      else
        printf '%s' "${EXCLUDED_BY_DECISION_REASONS[$i]}" > "$TMP/s7-gen-$3-$i.txt"
        jq -rj --arg c "$n" 'first(.exclusions[] | select(.context == $c) | .reason)' \
          "$spec" > "$TMP/s7-spec-$3-$i.txt"
        if cmp -s "$TMP/s7-gen-$3-$i.txt" "$TMP/s7-spec-$3-$i.txt"; then
          printf 'MATCH\t%s\t%s bytes\n' "$n" "$(wc -c < "$TMP/s7-spec-$3-$i.txt" | tr -d ' ')"
        else
          printf 'DRIFT\t%s\t%s\n' "$n" \
            "$(cmp "$TMP/s7-gen-$3-$i.txt" "$TMP/s7-spec-$3-$i.txt" 2>&1 | sed 's/.*differ: //')"
        fi
      fi
      i=$((i + 1))
    done
  )
}

RC24_CLEAN="$(s7_report "$GEN" "$SPEC" clean)"

# NON-VACUITY FIRST. Every clause below is an ABSENCE claim over this report, and
# an empty report satisfies all of them. So the report must first be shown to
# have actually read something.
RC24_NAMES="$(grep '^CHECKED	' <<<"$RC24_CLEAN" | cut -f2)"
RC24_REASONS="$(grep '^CHECKED	' <<<"$RC24_CLEAN" | cut -f3)"
if [ -n "$RC24_NAMES" ] && [ -n "$RC24_REASONS" ] \
   && [ "$RC24_NAMES" -ge 2 ] 2>/dev/null && [ "$RC24_REASONS" -ge 2 ] 2>/dev/null; then
  ok "the S7 constants are SOURCED out of the generator by bash itself — $RC24_NAMES names, $RC24_REASONS reasons, neither list empty"
else
  bad "the S7 array extraction came back empty or too short — every clause below would pass vacuously: $(grep '^CHECKED	' <<<"$RC24_CLEAN" | tr '\n' ' ' || echo '(no CHECKED line at all)')"
fi

RC24_MATCHES="$(grep -c '^MATCH	' <<<"$RC24_CLEAN" || true)"
if [ "$RC24_MATCHES" = "$RC24_NAMES" ]; then
  ok "every generator S7 constant matches its committed row byte for byte ($RC24_MATCHES of $RC24_NAMES: $(grep '^MATCH	' <<<"$RC24_CLEAN" | cut -f2,3 | tr '\n' ';' | sed 's/;$//'))"
else
  bad "a hand-maintained S7 reason has drifted from the row it will overwrite on the next regeneration: $(grep -v '^MATCH	' <<<"$RC24_CLEAN" | tr '\n' ' ')"
fi

# The pristine tree passing IS the byte-honesty proof: these reasons carry
# backticks, apostrophes, double quotes and em dashes, and a comparison that
# mangled any of them could not come back clean on an unmodified tree.
if ! grep -qE '^(ARITY|MISSING|DUP|SHAPE)	' <<<"$RC24_CLEAN"; then
  ok "…and the ledger is well-formed: paired arrays, one committed row per constant, every reason still an S7 hold"
else
  bad "the S7 ledger is malformed: $(grep -E '^(ARITY|MISSING|DUP|SHAPE)	' <<<"$RC24_CLEAN" | tr '\n' ' ')"
fi

# ── MUTATION TWIN 1: the generator drifts away from the file. ────────────────
# This is the defect's own shape — the generator holding an older wording than
# the row it overwrites — reproduced by changing ONE character.
RC24_GEN_DRIFT="$TMP/rc24-gen-drift.sh"
sed 's/green on main head 6e53d2782/green on main head 6e53d2783/' "$GEN" > "$RC24_GEN_DRIFT"
if [ "$(grep -c '6e53d2783' "$RC24_GEN_DRIFT" || true)" = "1" ] \
   && [ "$(grep -c '6e53d2782' "$RC24_GEN_DRIFT" || true)" = "0" ]; then
  ok "the drift mutation applies: a COPY of the generator carries one changed character inside the \`Security gate\` reason"
else
  bad "the drift mutation did not apply — the anchor moved, so the clause below is vacuous"
fi
RC24_D="$(s7_report "$RC24_GEN_DRIFT" "$SPEC" gendrift)"
if grep -q '^DRIFT	Security gate	' <<<"$RC24_D"; then
  ok "…and the check REDS on it, naming the context and the first differing byte: $(grep '^DRIFT	Security gate	' <<<"$RC24_D" | cut -f3)"
else
  bad "one changed character in a generator S7 reason passed: $(tr '\n' ' ' <<<"$RC24_D")"
fi

# ── MUTATION TWIN 2: the file drifts away from the generator. ────────────────
# The mirror direction, and it is not the same clause: a hand-edit to the
# committed row that nobody carried back into the generator is exactly what
# 2026-08-06 did, and it is the state this section was written to catch.
RC24_SPEC_DRIFT="$TMP/rc24-spec-drift.json"
jq '(.exclusions[] | select(.context == "Required-check spec gate") | .reason)
    |= sub("wave 36"; "wave 37")' "$SPEC" > "$RC24_SPEC_DRIFT"
if [ "$(jq '[.exclusions[] | select(.reason | contains("wave 37"))] | length' "$RC24_SPEC_DRIFT")" = "1" ]; then
  ok "the spec-side mutation applies: a COPY of the committed file carries an edited \`Required-check spec gate\` reason"
else
  bad "the spec-side mutation did not apply — the anchor moved, so the clause below is vacuous"
fi
RC24_S="$(s7_report "$GEN" "$RC24_SPEC_DRIFT" specdrift)"
if grep -q '^DRIFT	Required-check spec gate	' <<<"$RC24_S"; then
  ok "…and the check REDS on that side too: $(grep '^DRIFT	Required-check spec gate	' <<<"$RC24_S" | cut -f3)"
else
  bad "a hand-edit to a committed S7 reason passed unnoticed: $(tr '\n' ' ' <<<"$RC24_S")"
fi

# ── MUTATION TWIN 3: the committed row disappears entirely. ──────────────────
# A DRIFT clause alone cannot see this: with no row to compare against, a
# comparison-only check has nothing to say and stays green while the hold is
# gone from the file the merge oracle reads.
RC24_SPEC_LOSS="$TMP/rc24-spec-loss.json"
jq 'del(.exclusions[] | select(.context == "Security gate"))' "$SPEC" > "$RC24_SPEC_LOSS"
if [ "$(jq '[.exclusions[] | select(.context == "Security gate")] | length' "$RC24_SPEC_LOSS")" = "0" ]; then
  ok "the loss mutation applies: a COPY of the committed file no longer carries a \`Security gate\` exclusion row"
else
  bad "the loss mutation did not apply — the row survived the delete, so the clause below is vacuous"
fi
if grep -q '^MISSING	Security gate$' <<<"$(s7_report "$GEN" "$RC24_SPEC_LOSS" specloss)"; then
  ok "…and the check REDS on the absence, not just on a difference"
else
  bad "a generator S7 constant with no committed row at all passed"
fi

# ── MUTATION TWIN 4: the two arrays fall out of step. ────────────────────────
# The quietest failure of the four. Drop a NAME and every later name inherits
# the wrong reason — each of which still reads as plausible S7 prose, so no
# per-row text comparison can be trusted until the pairing is.
RC24_GEN_ARITY="$TMP/rc24-gen-arity.sh"
sed 's/^  "Security gate"$//' "$GEN" > "$RC24_GEN_ARITY"
if [ "$(grep -c '^  "Security gate"$' "$RC24_GEN_ARITY" || true)" = "0" ]; then
  ok "the arity mutation applies: a COPY of the generator names one fewer context than it carries reasons"
else
  bad "the arity mutation did not apply — the entry survived, so the clause below is vacuous"
fi
if grep -q '^ARITY	1	2$' <<<"$(s7_report "$RC24_GEN_ARITY" "$SPEC" genarity)"; then
  ok "…and the check REDS on the unpaired lists before it compares a single reason"
else
  bad "the S7 name and reason arrays can fall out of step without a red — every pairing below the gap would be silently wrong"
fi


section "25. the exit-code contract: a PRODUCER THAT REFUSED is 4, an ASSERTION THAT DRIFTED is 1, and neither can wear the other's code"

# WHY THIS SECTION EXISTS AT ALL. #14371 made a generator refusal READABLE and
# deliberately left the machine half alone, because promoting unreadable-input
# to its own exit code is a CONTRACT change and a contract change smuggled
# inside an outage fix is how a gate acquires two owners and no reviewer. This
# is that contract change, paid separately — and a contract with no mutation
# behind it re-conflates the moment someone writes the next `bad`. Both
# directions are pinned here, because a single-direction proof is worthless:
# the whole value is that the two are SEPARABLE.
#
# The end-to-end shape (chmod the generator unreadable, run the whole suite,
# watch it exit 4) cannot live inside the suite — it would have to re-invoke
# itself, and a ~4-minute run per clause is not a test, it is a second CI job.
# What lives here is the two things that decide the code: the TABLE, and the
# ROUTER that feeds it. Everything above them is ordinary assertion counting.

# (a) THE TABLE. rc_exit_code is the single copy of the rule the tally line
# also uses, so this clause is asserting the shipped mapping, not a restatement
# of it. Blocked outranks failed, and zero/zero is the only 0.
RC25_TABLE=""
for RC25_CASE in "0 0 0" "3 0 1" "0 2 4" "5 2 4"; do
  # shellcheck disable=SC2086
  set -- $RC25_CASE
  RC25_TABLE="$RC25_TABLE f=$1,b=$2->$(rc_exit_code "$1" "$2") expected $3;"
done
if [ "$RC25_TABLE" = " f=0,b=0->0 expected 0; f=3,b=0->1 expected 1; f=0,b=2->4 expected 4; f=5,b=2->4 expected 4;" ]; then
  ok "the exit-code table holds: clean=0, drift-only=1, blocked-only=4, and BOTH=4 (a run that could not read an input has no verdict to report, so the hold outranks the partial red)"
else
  bad "rc_exit_code does not implement the header's table: $RC25_TABLE"
fi

# (b) THE ROUTER, BOTH DIRECTIONS, against the REAL fail_emit — not a copy of
# its condition. The counters are saved and restored around the specimens so
# this section costs the tally exactly the assertions it declares.
RC25_P0=$PASS; RC25_F0=$FAIL; RC25_B0=$BLOCKED; RC25_ERR0="$GEN_EMIT_ERR"

GEN_EMIT_ERR="SELFTEST SPECIMEN: the generator REFUSED (exit 9), wrote no spec.json"
fail_emit "SELFTEST SPECIMEN — not a real failure, section 25 is proving the router" 2>/dev/null
RC25_REFUSAL_B=$((BLOCKED - RC25_B0)); RC25_REFUSAL_F=$((FAIL - RC25_F0))

GEN_EMIT_ERR=""
fail_emit "SELFTEST SPECIMEN — not a real failure, section 25 is proving the router" 2>/dev/null
RC25_DRIFT_B=$((BLOCKED - RC25_B0 - RC25_REFUSAL_B)); RC25_DRIFT_F=$((FAIL - RC25_F0 - RC25_REFUSAL_F))

PASS=$RC25_P0; FAIL=$RC25_F0; BLOCKED=$RC25_B0; GEN_EMIT_ERR="$RC25_ERR0"

if [ "$RC25_REFUSAL_B" -eq 1 ] && [ "$RC25_REFUSAL_F" -eq 0 ]; then
  ok "(a) with the producer's own refusal on record, a consuming site counts BLOCKED and not failed — the code the tally maps to 4"
else
  bad "a producer refusal did not route to BLOCKED (blocked +$RC25_REFUSAL_B, failed +$RC25_REFUSAL_F) — every generator outage would report as spec drift again, which is exactly what #14371 left unpaid"
fi
if [ "$RC25_DRIFT_F" -eq 1 ] && [ "$RC25_DRIFT_B" -eq 0 ]; then
  ok "(b) …and with NO refusal on record the identical call counts FAILED and not blocked — genuine drift still maps to 1, so 4 can never absorb a real verdict"
else
  bad "an ordinary assertion failure routed to BLOCKED (blocked +$RC25_DRIFT_B, failed +$RC25_DRIFT_F) — drift would be reported as a hold and nobody would fix the repo"
fi

# (c) THE RATCHET. The two clauses above prove the router; this one proves the
# router is still WIRED. A future site written as a bare `bad` over a file the
# generator never wrote re-conflates the contract silently — the suite would
# stay green and exit 1 on an outage again. The needles are SPLIT so this
# clause cannot match its own source lines (the trap that makes a self-grep
# report a phantom hit).
RC25_OLD_NEEDLE='bad "$('"why_emit"
RC25_NEW_NEEDLE='fail_emit "$('"why_emit"
RC25_OLD_N="$(grep -cF "$RC25_OLD_NEEDLE" "$0" || true)"
RC25_NEW_N="$(grep -cF "$RC25_NEW_NEEDLE" "$0" || true)"
if [ "$RC25_NEW_N" -gt 0 ]; then
  ok "the ratchet is non-vacuous: $RC25_NEW_N site(s) consume a generator-written spec through the router"
else
  bad "no site routes a generator-written spec through fail_emit — the two clauses above are proving a function nothing calls"
fi
if [ "$RC25_OLD_N" -eq 0 ]; then
  ok "…and NO site still reds a generator-written spec with a bare failure — the exit-4 contract cannot be silently re-conflated one call site at a time"
else
  bad "$RC25_OLD_N site(s) still red a generator-written spec with a bare failure, so a generator outage there is reported as spec drift (exit 1): $(grep -nF "$RC25_OLD_NEEDLE" "$0" | head -3 | tr '\n' '⏎')"
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
echo "required-checks: $PASS passed, $FAIL failed, $BLOCKED blocked$([ "$HERMETIC" -eq 1 ] && echo " (hermetic — the API stage was skipped)")"
if [ "$BLOCKED" -gt 0 ]; then
  echo "required-checks: $BLOCKED site(s) BLOCKED — an input could not be read or a producer refused, so this run has NO verdict about the required set. Exit 4 means HOLD, not drift."
fi
# The run reached its own end. Anything that exits 0 without passing through
# this line is a crash, and the EXIT trap turns it into a 70.
RC_TALLY_REACHED=1
exit "$(rc_exit_code "$FAIL" "$BLOCKED")"
