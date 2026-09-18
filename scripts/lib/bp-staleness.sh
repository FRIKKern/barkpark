#!/usr/bin/env bash
# bp-staleness.sh — THE one reading of "is the installed bp behind origin/main".
#
# SOURCE it; do not execute it. It defines one function:
#
#   bp_staleness_verdict   echoes "<verdict> <commit-or-->", always returns 0
#
#     no-bp                no bp on PATH at all
#     unstamped            bp exists but carries no ldflags build commit
#     skip-unknown-commit  the stamped commit is not in this object database
#     skip-no-origin-main  origin/main does not resolve (offline / never fetched)
#     skip-no-merge-base   no common ancestry between the stamp and origin/main
#     diverged             neither commit contains the other — a REBUILD LOOPS
#     stale                Go inputs changed merge-base→origin/main
#     current              nothing Go-side changed since the stamp
#
# WHY A SHARED FILE. This ladder used to live only in scripts/doctor.sh section
# 2, where it false-greened twice in one week (regex #5935, then the compare
# target). scripts/local-update.sh — the FIXER doctor points at — had no reading
# of the installed binary at all: it decided the bp rebuild purely from its own
# `git pull` delta, so a checkout that was already current left a stale bp
# installed forever. Two readers of one fact is how the second one drifts, so
# there is now exactly one, and doctor.test.sh's 11-cell verdict matrix drives
# it through doctor.sh.
#
# THE COMPARE-TARGET IS origin/main VIA merge-base, never local HEAD: a binary
# built in a diverged worktree false-greens against HEAD because the binary and
# the worktree miss the same merged commits. The merge-base collapse is also
# what keeps a binary AHEAD with unpushed local Go commits GREEN.
#
# NEVER `go version -m` vcs stamps: Go's -buildvcs walk-up binds to the nearest
# ancestor `.git` DIRECTORY, so in a worktree nested under the primary checkout
# it stamps the ANCESTOR repo's HEAD. Only the ldflags stamp reflects the code
# that was actually built.

# shellcheck shell=bash
bp_staleness_verdict() {
  # A subshell with `set +e` so the ladder is identical whether the caller runs
  # under `set -euo pipefail` (local-update.sh) or `set -uo pipefail`
  # (doctor.sh). No pipes into an early-closing reader either: under pipefail a
  # SIGPIPE'd writer returns 141 and a size-dependent false verdict with it.
  (
    set +e
    command -v bp >/dev/null 2>&1 || { printf 'no-bp -\n'; exit 0; }

    # Capture the bare hex SHA even when the build was dirty: a dirty tree
    # stamps e.g. "2a8b147ee-dirty-purpose", so allow a non-quote suffix after
    # the hex (\{7,\} anchors on a real short/long SHA, never a stray hex
    # fragment) and emit only \1 — the bare hex git cat-file is fed below.
    bp_commit="$(bp version 2>/dev/null | sed -n 's/.*"commit": *"\([0-9a-f]\{7,\}\)[^"]*".*/\1/p')"
    [ -n "$bp_commit" ] || { printf 'unstamped -\n'; exit 0; }

    git cat-file -e "$bp_commit^{commit}" 2>/dev/null \
      || { printf 'skip-unknown-commit %s\n' "$bp_commit"; exit 0; }
    git rev-parse --verify --quiet origin/main >/dev/null 2>&1 \
      || { printf 'skip-no-origin-main %s\n' "$bp_commit"; exit 0; }

    base="$(git merge-base "$bp_commit" origin/main 2>/dev/null)"
    [ -n "$base" ] || { printf 'skip-no-merge-base %s\n' "$bp_commit"; exit 0; }

    # DIVERGED is its own rung, not "behind": the binary carries commits main
    # has never seen, so a rebuild from this checkout reinstalls the same
    # off-history binary. Only a rebase/pull ends it.
    if ! git merge-base --is-ancestor "$bp_commit" origin/main 2>/dev/null \
       && ! git merge-base --is-ancestor origin/main "$bp_commit" 2>/dev/null; then
      printf 'diverged %s\n' "$bp_commit"; exit 0
    fi

    if [ -n "$(git diff --name-only "$base" origin/main -- '*.go' go.mod go.sum internal cmd deploy.sh 2>/dev/null)" ]; then
      printf 'stale %s\n' "$bp_commit"
    else
      printf 'current %s\n' "$bp_commit"
    fi
  )
}
