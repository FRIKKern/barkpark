#!/usr/bin/env bash
#
# Ratchet: the baseline that the MERGE WOULD PRODUCE must still hash true.
#
# WHAT THIS ADDS THAT THE THREE PER-HEAD RATCHETS CANNOT
# ------------------------------------------------------
# sobelow-baseline-fingerprint-check.sh, -staleness-check.sh and
# -inline-overlap-check.sh all read ONE tree — whatever is checked out. On a
# pull_request that tree is the merge ref GitHub computed WHEN THE PR WAS LAST
# PUSHED, against the base AS IT WAS THEN. Nothing recomputes the check run when
# the base moves underneath an already-green PR.
#
# So take two PRs, both open, neither containing the other, both inserting lines
# above the SAME Config.CSRF waiver, and both re-anchoring it CORRECTLY against
# their own base. Their edits to api/.sobelow-skips are then BYTE-IDENTICAL, and
# git's 3-way merge takes two identical hunks clean — no conflict, no reviewer.
# The shifts in router.ex, however, ADD. Each PR is right alone, the pair is
# wrong, and no per-head run ever saw the pair:
#
#     base        pipeline at 14      row pinned 14,H14   green
#     PR A        pipeline at 17      row pinned 17,H17   green (A alone)
#     PR B        pipeline at 17      row pinned 17,H17   green (B alone)
#     A + B       pipeline at 20      row pinned 17,H17   DEAD WAIVER
#
# This checker runs the fingerprint ratchet against `git merge-tree`'s result —
# the tree the merge WOULD produce — so the pair is measured before it lands.
#
# IT DOES NOT REIMPLEMENT THE HASH. It materialises the merged tree and shells
# out to sobelow-baseline-fingerprint-check.sh, which owns phash2 and owns the
# row classification. A second hasher would be a second thing to keep true.
#
# HONEST SIZING, so nobody buys this for more than it is worth
# -----------------------------------------------------------
# 1. THE SUM IS DETECTED AFTER MERGE ALREADY. security.yml carries a
#    `push: branches: [main]` arm with a per-sha concurrency group (#15661,
#    2026-09-02T21:22Z) so every main push runs the blocking fingerprint job to
#    a verdict. A bad sum therefore REDS MAIN within minutes; it does not land
#    silently. The prize here is "main never goes red for this", not "nobody
#    would ever know".
# 2. THE CLASS HAS NEVER FIRED. A complete search over the 53 commits and 46
#    PRs that have ever touched api/.sobelow-skips (all 1035 pairs, open-interval
#    overlap, containment checked with a controlled is-ancestor instrument) found
#    3 overlapping pairs — #2579x#2590, #13736x#13740, #14425x#14434 — and all
#    three were SEQUENTIAL: the later PR was rebased onto the merged earlier one
#    before landing. That is a HABIT OF THE MERGE QUEUE, not a guard. Nothing in
#    the merge machinery forbids the configuration.
# 3. api/.sobelow-skips IS THE ONLY FILE THAT CAN HOST IT. Every other baseline
#    in this repo is keyed on something that cannot slide (path+function,
#    path+kind+code text, counts, citation text). The blast radius is one file.
#
# WHY CI RUNS ONLY `--selftest`, WRITTEN DOWN RATHER THAN LEFT TO INFERENCE
# ------------------------------------------------------------------------
# The live arm needs BOTH histories back to the merge base. `actions/checkout@v4`
# on a pull_request clones the merge ref at depth 1, so `merge-tree` has no merge
# base to compute and the arm would exit 2 — a check that reds on its own
# plumbing rather than on the defect. Deepening the fetch to cover a repo that
# lands ~100 commits a day is a flake surface bought for a class with a base rate
# of zero. So the wired arm is the hermetic `--selftest`, which EXECUTES this
# checker against a real git fixture (real branches, a real `merge-tree`) and
# proves both directions; the live arm is a runbook command:
#
#     git fetch origin main
#     bash api/scripts/sobelow-waiver-merge-time-check.sh --base origin/main
#
# Run it from a full clone before merging a PR that touches api/.sobelow-skips
# while another such PR is open. The durable post-merge verdict stays where it
# already is: the push-to-main fingerprint job.
#
# EXIT CODES
#   0  the merged tree's reconstructible baseline rows all hash true
#   1  the merged tree carries a DEAD WAIVER (the sibling names the rows)
#   2  fail-closed: usage error, no git, no merge base, merge conflicts, a
#      missing sibling checker, or a merged tree with no api/.sobelow-skips.
#      A tree that could not be built has not passed.

set -euo pipefail

REPO="."
BASE=""
HEAD_REF="HEAD"
SELFTEST=0

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SIBLING="$HERE/sobelow-baseline-fingerprint-check.sh"

usage() {
  cat <<'USAGE'
usage: sobelow-waiver-merge-time-check.sh --base REF [--head REF] [--repo DIR]
       sobelow-waiver-merge-time-check.sh --selftest

  --base REF   the ref the merge lands ON (e.g. origin/main). REQUIRED.
  --head REF   the ref being merged (default: HEAD)
  --repo DIR   git repo to read (default: .)
  --selftest   build a git fixture in which two — and three — independently
               correct re-anchors of the same waiver sum, and prove this
               checker reds on the sum while staying green on each alone
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      [[ $# -ge 2 ]] || { echo "error: --base needs a value" >&2; exit 2; }
      BASE=$2; shift 2 ;;
    --head)
      [[ $# -ge 2 ]] || { echo "error: --head needs a value" >&2; exit 2; }
      HEAD_REF=$2; shift 2 ;;
    --repo)
      [[ $# -ge 2 ]] || { echo "error: --repo needs a value" >&2; exit 2; }
      REPO=$2; shift 2 ;;
    --selftest)
      SELFTEST=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

command -v git >/dev/null 2>&1 || { echo "error: git not on PATH" >&2; exit 2; }
[[ -f "$SIBLING" ]] || {
  echo "error: sibling checker not found next to this script: $SIBLING" >&2
  exit 2
}

# --- the live arm -----------------------------------------------------------

check_merged_tree() {
  local repo=$1 base=$2 head=$3
  local merged out rc=0 tmp

  git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null || {
    echo "error: --base does not resolve to a commit in $repo: $base" >&2; exit 2; }
  git -C "$repo" rev-parse --verify --quiet "$head^{commit}" >/dev/null || {
    echo "error: --head does not resolve to a commit in $repo: $head" >&2; exit 2; }

  git -C "$repo" merge-base "$base" "$head" >/dev/null 2>&1 || {
    echo "error: no merge base between $base and $head — a shallow clone cannot" >&2
    echo "       be measured here. Deepen it, or run this from a full clone." >&2
    exit 2; }

  out=$(git -C "$repo" merge-tree --write-tree "$base" "$head" 2>&1) || rc=$?
  merged=$(printf '%s\n' "$out" | head -1)

  if [[ $rc -ne 0 ]]; then
    echo "error: merging $head onto $base CONFLICTS — this check has no verdict" >&2
    echo "       (a conflict is reviewer-visible; the silent sum is what this" >&2
    echo "        checker exists for). git merge-tree said:" >&2
    printf '%s\n' "$out" | sed 's/^/       /' >&2
    exit 2
  fi

  git -C "$repo" rev-parse --verify --quiet "$merged^{tree}" >/dev/null || {
    echo "error: git merge-tree did not name a tree (got: $merged)" >&2; exit 2; }

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/sobelow-merge-time.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf -- '$tmp'" RETURN
  git -C "$repo" archive --format=tar "$merged" | tar -x -C "$tmp"

  [[ -f "$tmp/api/.sobelow-skips" ]] || {
    echo "error: the merged tree carries no api/.sobelow-skips — refusing a pass" >&2
    exit 2; }

  echo "merge-time check: $head onto $base -> tree $merged"
  local frc=0
  bash "$SIBLING" --baseline "$tmp/api/.sobelow-skips" --api-dir "$tmp/api" || frc=$?
  if [[ $frc -eq 0 ]]; then
    echo "MERGE-TIME PASS: the tree this merge would produce still hashes true"
  fi
  return "$frc"
}

# --- selftest ---------------------------------------------------------------

# The expected hashes are COMPUTED the way the sibling computes them, from the
# fixture. A selftest that hardcoded them would be testing its own arithmetic.
fixture_hash() {
  elixir -e '
    [type, src, file, line] = System.argv()
    IO.write([type, String.to_atom(src), file, String.to_integer(line)]
             |> :erlang.phash2() |> Integer.to_string(16))
  ' "$1" "$2" "$3" "$4"
}

# A router with three insertion REGIONS, spaced far enough apart that git merges
# edits in different regions without a conflict, and one pipeline BELOW all
# three. `pipeline :alpha` is at line 14.
fixture_router() {
  cat <<'ROUTER'
defmodule BarkparkWeb.Router do
  # region-a
  # pad
  # pad
  # pad
  # region-b
  # pad
  # pad
  # pad
  # region-c
  # pad
  # pad
  # pad
  pipeline :alpha do
    plug(:fetch_session)
  end
end
ROUTER
}

# Insert three lines directly below a region marker: the shape of a PR that adds
# routes above a waived pipeline.
fixture_insert_below() {
  local file=$1 marker=$2 tag=$3
  awk -v m="$marker" -v t="$tag" '
    { print }
    $0 ~ m && !done { print "  # " t; print "  # " t; print "  # " t; done = 1 }
  ' "$file" > "$file.new"
  mv "$file.new" "$file"
}

expect_status() {
  local label=$1 want=$2
  shift 2
  local got=0 out
  out=$("$@" 2>&1) || got=$?
  if [[ $got -ne $want ]]; then
    printf 'SELFTEST FAIL: %s — expected exit %d, got %d\n%s\n' "$label" "$want" "$got" "$out" >&2
    return 1
  fi
  printf '  ok  %-56s exit %d\n' "$label" "$got"
}

run_selftest() {
  command -v elixir >/dev/null 2>&1 || {
    echo "error: elixir not on PATH — the sibling recomputes :erlang.phash2" >&2
    exit 2
  }

  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/sobelow-merge-time-selftest.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf -- '$tmp'" RETURN

  local F="$tmp/repo"
  local csrf="Config.CSRF: Missing CSRF Protections"
  local router="lib/barkpark_web/router.ex"
  local h14 h17
  h14=$(fixture_hash "$csrf" alpha "$router" 14)
  h17=$(fixture_hash "$csrf" alpha "$router" 17)

  mkdir -p "$F/api/lib/barkpark_web"
  fixture_router > "$F/api/$router"
  printf '%s\n' "$csrf,$router:14,$h14" > "$F/api/.sobelow-skips"
  echo "fixture" > "$F/README.md"

  git -C "$F" init -q -b main
  git -C "$F" config user.email fixture@example.invalid
  git -C "$F" config user.name fixture
  git -C "$F" add -A
  git -C "$F" commit -q -m base

  # Three PRs, each cut from the SAME base, each inserting three lines above the
  # waived pipeline in a DIFFERENT region, each re-anchoring the row CORRECTLY
  # against its own base: 14 -> 17. All three baseline edits are byte-identical.
  local b region tag
  local i=0
  for b in pr-a pr-b pr-c; do
    i=$((i + 1))
    case $i in
      1) region="region-a"; tag="from-a" ;;
      2) region="region-b"; tag="from-b" ;;
      *) region="region-c"; tag="from-c" ;;
    esac
    git -C "$F" checkout -q -b "$b" main
    fixture_insert_below "$F/api/$router" "$region" "$tag"
    printf '%s\n' "$csrf,$router:17,$h17" > "$F/api/.sobelow-skips"
    git -C "$F" commit -q -am "$b: three routes above the waiver, row re-anchored 14 -> 17"
    git -C "$F" checkout -q main
  done

  # A PR that touches neither the router nor the baseline — the clean-merge
  # negative control. Without it, "reds on the sum" is unfalsifiable: a checker
  # that reds on EVERY merge would pass every red arm below.
  git -C "$F" checkout -q -b pr-unrelated main
  echo "a docs change" >> "$F/README.md"
  git -C "$F" commit -q -am "pr-unrelated: touches no waiver"
  git -C "$F" checkout -q main

  # The two-way sum, built the way it would really arrive: pr-a LANDS on main,
  # and pr-b — cut before that and never rebased — is still open against it.
  git -C "$F" checkout -q -b main-after-a main
  git -C "$F" merge -q --no-edit pr-a
  # The three-way sum: pr-b lands on top of that too.
  git -C "$F" checkout -q -b main-after-ab main-after-a
  git -C "$F" merge -q --no-edit pr-b
  git -C "$F" checkout -q main

  # PROOF THE SUM MERGES CLEAN. If git conflicted here the whole finding would
  # be moot, so this is asserted, never assumed.
  git -C "$F" merge-tree --write-tree main-after-a pr-b >/dev/null 2>&1 || {
    echo "SELFTEST FAIL: the two-PR sum CONFLICTED — the fixture does not model the finding" >&2
    return 1
  }
  echo "  ok  the two-PR sum merges CLEAN (no conflict, no reviewer)"

  local me=${BASH_SOURCE[0]}
  local failures=0
  echo "selftest: merge-time fixtures"

  # ---- GREEN arms: each re-anchor is correct ALONE ------------------------
  expect_status "GREEN  pr-a alone onto base main" 0 \
    bash "$me" --repo "$F" --base main --head pr-a || failures=1
  expect_status "GREEN  pr-b alone onto base main" 0 \
    bash "$me" --repo "$F" --base main --head pr-b || failures=1
  expect_status "GREEN  pr-c alone onto base main" 0 \
    bash "$me" --repo "$F" --base main --head pr-c || failures=1
  expect_status "GREEN  clean merge touching no waiver" 0 \
    bash "$me" --repo "$F" --base main --head pr-unrelated || failures=1
  expect_status "GREEN  a landed sum-free main re-checks clean" 0 \
    bash "$me" --repo "$F" --base main-after-a --head main-after-a || failures=1

  # ---- RED arms: the shifts ADD ------------------------------------------
  expect_status "RED    two-way sum: pr-b onto main-after-a" 1 \
    bash "$me" --repo "$F" --base main-after-a --head pr-b || failures=1
  expect_status "RED    three-way sum: pr-c onto main-after-ab" 1 \
    bash "$me" --repo "$F" --base main-after-ab --head pr-c || failures=1

  # ---- fail-closed arms ---------------------------------------------------
  expect_status "FAIL-CLOSED  unknown argument" 2 \
    bash "$me" --nope || failures=1
  expect_status "FAIL-CLOSED  unresolvable base ref" 2 \
    bash "$me" --repo "$F" --base no/such/ref --head pr-a || failures=1

  # THE PER-HEAD GATE IS BLIND TO ALL OF THIS, asserted rather than claimed: the
  # sibling ratchet, run on pr-b's OWN tree, passes — which is precisely why the
  # sum reaches main.
  local blind="$tmp/blind"
  mkdir -p "$blind"
  git -C "$F" archive --format=tar pr-b | tar -x -C "$blind"
  expect_status "CONTROL  per-head fingerprint gate is GREEN on pr-b alone" 0 \
    bash "$SIBLING" --baseline "$blind/api/.sobelow-skips" --api-dir "$blind/api" || failures=1

  if [[ $failures -ne 0 ]]; then
    echo "SELFTEST FAILED" >&2
    return 1
  fi
  echo "SELFTEST PASS: the merge-time ratchet greens on each re-anchor alone and on a clean merge, reds on the two-way AND three-way sum of independently-correct re-anchors, and fails closed on a bad argument and an unresolvable base — while the per-head fingerprint gate stays green on the very head that produces the sum"
}

if [[ $SELFTEST -eq 1 ]]; then
  run_selftest
  exit $?
fi

[[ -n "$BASE" ]] || { echo "error: --base is required" >&2; usage >&2; exit 2; }
check_merged_tree "$REPO" "$BASE" "$HEAD_REF"
