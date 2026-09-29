#!/usr/bin/env bash
# workflow-root-only-check.sh — A WORKFLOW FILE OUTSIDE THE ROOT .github/workflows/
# IS INERT, AND READS LIKE CI.
#
# task-7a49b8c2e3104aa2. GitHub Actions reads workflow definitions from ONE
# directory: `.github/workflows/` at the REPOSITORY ROOT. A `.github/workflows/`
# nested under any subdirectory is never parsed, never dispatched, and never
# appears in the Actions UI — but it is still a YAML file named `ci.yml` with
# `on: pull_request` at the top, so every reader who greps for a workflow finds
# one and stops.
#
# WHAT THIS REPO ACTUALLY HAD. `js/.github/workflows/` carried five files —
# ci.yml, contract.yml, promote-latest.yml, release.yml, vercel-preview.yml —
# none of which had ever run. TWO OF THE FIVE WERE SAME-NAMED SHADOWS of real
# root workflows (ci.yml, release.yml), which is precisely how the tree stayed
# invisible: a reader greps `ci.yml`, finds a file, and never asks WHICH ONE
# GITHUB READS. The measurement that settles it is not a grep at all:
#
#     $ gh run list --workflow js/.github/workflows/ci.yml
#     HTTP 404: workflow ... not found on the default branch
#     $ gh run list --workflow js-tests.yml
#     completed  failure  ...  js-tests  main  push  35506278753
#
# The nested tree also held the ONLY caller of js/scripts/vercel-preview-smoke.sh,
# a stub that exited 0 for every input. A gate that cannot fail, wired to a
# workflow that cannot run: the repo's inventory of what is checked carried six
# entries that were all fiction.
#
# THE POPULATION IS A PREDICATE, NOT A LIST. Nothing here names js/. Membership
# is recomputed from the tracked tree on every run: every tracked path whose
# `.github/workflows/` segment does not start at character zero. Delete the five
# files and add `web/.github/workflows/x.yml` tomorrow and this reds on that
# commit — which is the whole point, since the next one will be added by someone
# who never heard of the first.
#
# TRACKED, NOT ON-DISK. The question is "what does GitHub see in the repository",
# and GitHub sees the committed tree. `git ls-files` answers that; `find` would
# also sweep a local scratch directory and report a nested tree that no clone has.
#
# THE CONTROL IS NOT OPTIONAL. A scanner that enumerates nothing reports no
# nested workflows and prints a clean bill of health for a tree it never opened —
# exactly the vacuous green this guard exists to remove one level up. So every
# invocation first requires the scan to FIND the root `.github/workflows/` with
# at least ROOT_FLOOR files in it. If it cannot see the directory that is
# supposed to be there, its silence about the ones that are not supposed to be
# there means nothing, and it REFUSES (exit 3) instead of passing.
#
# WHAT THIS DELIBERATELY DOES NOT CLAIM, stated rather than implied:
#   * `.github/actions/` and composite actions ARE legitimately referenced from
#     nested paths (`uses: ./some/dir/action.yml`). This guard is about
#     `workflows/` and only `workflows/`; widening it to all of `.github/` would
#     red on a correct layout.
#   * It says nothing about whether a ROOT workflow is any good — that is
#     workflow-owner-check.sh, workflow-trigger-coverage.sh and their siblings.
#     This one answers a single question: can GitHub read the file at all?
#   * It does not discriminate by FILENAME. `js/.github/workflows/nonsense.txt`
#     is reported too, because the defect is the LOCATION; a file in that
#     directory is claiming to be a workflow by where it sits.
#
# usage: bash scripts/workflow-root-only-check.sh [--selftest]
#
# Exit codes, kept distinct so a failed READ is never a clean read:
#   0  every workflow file in the tracked tree is at the repository root.
#   1  at least one workflow file sits outside the root .github/workflows/.
#   3  HARNESS FAILURE: the scan could not read its population, or the control
#      failed (it could not find the root workflow directory).
#   2  bad usage.
set -uo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "workflow-root-only-check.sh: needs bash; run: bash scripts/workflow-root-only-check.sh" >&2
  exit 3
fi

_SELF="${BASH_SOURCE[0]}"; case "$_SELF" in */*) _DIR="${_SELF%/*}";; *) _DIR=".";; esac
_DIR=$(cd "$_DIR" 2>/dev/null && pwd) || { echo "cannot resolve own dir" >&2; exit 3; }
_DEFAULT_ROOT="$(cd "$_DIR/.." && pwd)"

# The floor is the one expectation that does NOT come from the tree it measures.
# A derived population agrees with an emptied directory by construction: delete
# every root workflow and a bare "no nested workflows found" is still true and
# still worthless. This literal is what makes that a refusal instead. Set low
# enough that it is a control and not a second, accidental ratchet on the
# workflow count (this repo has 78; the number is allowed to move).
ROOT_FLOOR=5

# ── the predicate, in one place, so the guard and its selftest cannot disagree ──
# Prints every tracked path that lives in a `.github/workflows/` directory which
# is NOT the repository root one. The test is positional: the segment must begin
# at offset 0 of the path for the file to be reachable by GitHub.
_nested() {
  local root="$1"
  git -C "$root" ls-files -z 2>/dev/null \
    | tr '\0' '\n' \
    | grep -E '(^|/)\.github/workflows/' \
    | grep -vE '^\.github/workflows/' \
    || true
}

_root_workflows() {
  local root="$1"
  git -C "$root" ls-files -z 2>/dev/null \
    | tr '\0' '\n' \
    | grep -E '^\.github/workflows/[^/]+$' \
    || true
}

run_check() {
  # RESOLVED PER CALL, NOT AT LOAD. A root bound once at file scope makes every
  # fixture-driven selftest arm measure the REAL repo instead of its fixture —
  # all arms then pass against a clean tree and report the same OK line, and a
  # guard whose arms cannot fire is the disease one layer out.
  local ROOT="${WROC_ROOT:-$_DEFAULT_ROOT}"

  git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
    || { echo "REFUSE: $ROOT is not a git work tree — cannot read the tracked population" >&2; return 3; }

  local rootwf n_root
  rootwf="$(_root_workflows "$ROOT")"
  n_root=$(grep -c . <<<"$rootwf" || true)

  # CONTROL, EVERY INVOCATION — see the header. Without this, an empty or
  # unreadable tree yields "0 nested workflows" and exit 0.
  if [ "${n_root:-0}" -lt "$ROOT_FLOOR" ]; then
    echo "REFUSE: control failed — found only ${n_root:-0} file(s) in the root .github/workflows/, below the floor of $ROOT_FLOOR." >&2
    echo "        A scan that cannot see the workflow directory that IS there proves nothing about the ones that are not." >&2
    return 3
  fi

  local nested n_nested
  nested="$(_nested "$ROOT")"
  n_nested=$(grep -c . <<<"$nested" || true)

  if [ "${n_nested:-0}" -eq 0 ]; then
    echo "OK: $n_root workflow file(s), all in the repository-root .github/workflows/; 0 elsewhere in the tracked tree."
    return 0
  fi

  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    echo "RED inert workflow: $f"
    echo "    It is in a .github/workflows/ directory that is NOT the repository root, so GitHub Actions never reads it."
    echo "    It cannot be dispatched, cannot publish a check, and cannot fail — while reading to any grep like CI that runs."
    echo "    MEASURE IT: gh run list --workflow $f   (expect: HTTP 404 ... not found on the default branch)"
    echo "    FIX: move it to .github/workflows/ and own it as a real workflow, or delete it."
  done <<<"$nested"
  echo "workflow-root-only-check: $n_nested inert workflow file(s) outside the repository-root .github/workflows/." >&2
  return 1
}

# ──────────────────────────────────────────────────────────────── selftest ────
# BOTH DIRECTIONS, per house law: an arm that REDS on the exact input the guard
# claims to catch, and an arm that STAYS QUIET on a genuinely-clean tree. A red
# alone would be satisfied by a script that hates every tree.
run_selftest() {
  local pass=0 fail=0 tmp out rc
  _ok() { printf 'PASS %-44s %s\n' "$1" "${2:-}"; pass=$((pass + 1)); }
  _no() { printf 'FAIL %-44s %s\n' "$1" "${2:-}"; fail=$((fail + 1)); }

  bash -n "$_SELF" && _ok "parses" "bash -n clean" || _no "parses" "bash -n FAILED"

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/workflow-root-only.XXXXXX") || { echo "mktemp failed" >&2; return 3; }
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  git -C "$tmp" init -q >/dev/null 2>&1
  git -C "$tmp" config user.email harness@example.invalid
  git -C "$tmp" config user.name "root-only harness"
  mkdir -p "$tmp/.github/workflows"
  local i
  for i in 1 2 3 4 5 6; do
    printf 'name: real-%s\non:\n  pull_request:\njobs: {}\n' "$i" >"$tmp/.github/workflows/real-$i.yml"
  done
  git -C "$tmp" add -A >/dev/null 2>&1
  git -C "$tmp" commit -qm 'fixture: six real root workflows' >/dev/null 2>&1

  # QUIET ARM — a genuinely clean tree passes. Without it every red below could
  # come from a permanently-angry script.
  out=$(WROC_ROOT="$tmp" run_check 2>&1); rc=$?
  if [ $rc -eq 0 ] && grep -q 'all in the repository-root' <<<"$out"; then
    _ok "QUIET ARM: root-only tree" "exit 0 — $out"
  else _no "QUIET ARM: root-only tree" "exit $rc: $out"; fi

  # RED ARM 1 — THE ARM THIS FILE EXISTS FOR. A nested workflow directory is
  # added, exactly as js/.github/workflows/ was.
  mkdir -p "$tmp/js/.github/workflows"
  printf 'name: ci\non:\n  pull_request:\njobs: {}\n' >"$tmp/js/.github/workflows/ci.yml"
  git -C "$tmp" add -A >/dev/null 2>&1
  git -C "$tmp" commit -qm 'fixture: nested workflow' >/dev/null 2>&1
  out=$(WROC_ROOT="$tmp" run_check 2>&1); rc=$?
  if [ $rc -eq 1 ] && grep -q 'RED inert workflow: js/\.github/workflows/ci\.yml' <<<"$out"; then
    _ok "RED ARM 1: nested workflow" "refused BY PATH"
  else _no "RED ARM 1: nested workflow" "exit $rc: $out"; fi

  # THE DISCRIMINATION ARM. `ci.yml` exists at the root too, and the root copy
  # must NOT be named. This is what proves the guard keys on PATH and not on
  # FILENAME — the same-named shadow is the shape that hid the real tree.
  printf 'name: ci\non:\n  pull_request:\njobs: {}\n' >"$tmp/.github/workflows/ci.yml"
  git -C "$tmp" add -A >/dev/null 2>&1
  git -C "$tmp" commit -qm 'fixture: a root ci.yml with the same basename' >/dev/null 2>&1
  out=$(WROC_ROOT="$tmp" run_check 2>&1); rc=$?
  if [ $rc -eq 1 ] \
     && grep -q 'js/\.github/workflows/ci\.yml' <<<"$out" \
     && ! grep -qE 'RED inert workflow: \.github/workflows/ci\.yml' <<<"$out"; then
    _ok "DISCRIMINATES BY PATH: same basename" "root ci.yml untouched, nested ci.yml named"
  else _no "DISCRIMINATES BY PATH: same basename" "exit $rc: $out"; fi

  # RED ARM 2 — a DEEPER nest, to prove the predicate is positional and not a
  # hard-coded `js/` prefix wearing a regex.
  mkdir -p "$tmp/packages/web/.github/workflows"
  printf 'name: deep\non:\n  push:\njobs: {}\n' >"$tmp/packages/web/.github/workflows/deep.yml"
  git -C "$tmp" add -A >/dev/null 2>&1
  git -C "$tmp" commit -qm 'fixture: a deeper nest' >/dev/null 2>&1
  out=$(WROC_ROOT="$tmp" run_check 2>&1); rc=$?
  if [ $rc -eq 1 ] && grep -q 'packages/web/\.github/workflows/deep\.yml' <<<"$out"; then
    _ok "RED ARM 2: nest at any depth" "not a js/ prefix"
  else _no "RED ARM 2: nest at any depth" "exit $rc: $out"; fi

  # QUIET ARM — remove both nests and the SAME tree goes green again. Polarity:
  # without this, the reds above could be a script that never recovers.
  git -C "$tmp" rm -rq js packages >/dev/null 2>&1
  git -C "$tmp" commit -qm 'fixture: nests removed' >/dev/null 2>&1
  out=$(WROC_ROOT="$tmp" run_check 2>&1); rc=$?
  if [ $rc -eq 0 ]; then _ok "QUIET ARM: nests removed" "exit 0 — $out"
  else _no "QUIET ARM: nests removed" "exit $rc: $out"; fi

  # QUIET ARM — a nested `.github/` that is NOT `workflows/`. Composite actions
  # and issue templates live in nested .github/ directories legitimately; a guard
  # that reds on them is wrong about a correct layout.
  mkdir -p "$tmp/js/.github/actions/setup"
  printf 'name: setup\nruns:\n  using: composite\n' >"$tmp/js/.github/actions/setup/action.yml"
  git -C "$tmp" add -A >/dev/null 2>&1
  git -C "$tmp" commit -qm 'fixture: a nested composite action' >/dev/null 2>&1
  out=$(WROC_ROOT="$tmp" run_check 2>&1); rc=$?
  if [ $rc -eq 0 ] && ! grep -q 'actions/setup' <<<"$out"; then
    _ok "QUIET ARM: nested .github/actions" "exit 0, never named"
  else _no "QUIET ARM: nested .github/actions" "exit $rc: $out"; fi

  # CONTROL ARM — a tree whose ROOT workflow directory is (nearly) empty must
  # REFUSE, not pass. This is the arm that makes every green above mean
  # something: it proves the scan is required to have SEEN its population.
  git -C "$tmp" rm -rq .github/workflows >/dev/null 2>&1
  mkdir -p "$tmp/.github/workflows"
  printf 'name: lonely\non:\n  pull_request:\njobs: {}\n' >"$tmp/.github/workflows/lonely.yml"
  git -C "$tmp" add -A >/dev/null 2>&1
  git -C "$tmp" commit -qm 'fixture: root workflows emptied' >/dev/null 2>&1
  out=$(WROC_ROOT="$tmp" run_check 2>&1); rc=$?
  if [ $rc -eq 3 ] && grep -q 'control failed' <<<"$out"; then
    _ok "CONTROL: empty root dir REFUSES" "exit 3, not a clean 0"
  else _no "CONTROL: empty root dir REFUSES" "exit $rc: $out"; fi

  # CONTROL ARM — a non-git directory REFUSES rather than reporting a clean tree.
  local nogit; nogit=$(mktemp -d "${TMPDIR:-/tmp}/workflow-root-only-nogit.XXXXXX")
  out=$(WROC_ROOT="$nogit" run_check 2>&1); rc=$?
  if [ $rc -eq 3 ] && grep -q 'not a git work tree' <<<"$out"; then
    _ok "CONTROL: non-git tree REFUSES" "exit 3"
  else _no "CONTROL: non-git tree REFUSES" "exit $rc: $out"; fi
  rm -rf "$nogit"

  # THE REAL TREE stays quiet. An instrument that has only ever met synthetic
  # input is not yet an instrument — and this is the arm that reds the day
  # someone adds the next nested workflow directory to THIS repo.
  out=$(run_check 2>&1); rc=$?
  if [ $rc -eq 0 ]; then _ok "QUIET ARM: this repo" "$out"
  else _no "QUIET ARM: this repo" "exit $rc: $out"; fi

  echo "── $pass passed, $fail failed ──"
  [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --selftest) run_selftest; exit $? ;;
  "")         run_check;    exit $? ;;
  *) echo "usage: bash scripts/workflow-root-only-check.sh [--selftest]" >&2; exit 2 ;;
esac
