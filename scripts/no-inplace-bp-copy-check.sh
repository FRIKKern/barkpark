#!/usr/bin/env bash
# Refuse any INSTRUCTION to copy a freshly built `dist/bp` on top of an already
# installed `bp`.
#
# WHY THIS EXISTS (hq-residue-bp-install-recipe). `cp` writes THROUGH an
# existing inode. A running `bp`, an editor, or an MCP client holding the old
# binary open keeps the old image, so the copy "succeeds" and the caller keeps
# running the binary they thought they had just replaced. A charter sentence
# saying `cp dist/bp ~/.local/bin/bp` cost two scouts a day against an
# 89-commit-stale binary that reported itself as current.
#
# `make cli-install` runs `install -m 0755`, which UNLINKS and recreates the
# target on a FRESH INODE, so every open handle is left with the old file and
# the next exec picks up the new one. That is the whole difference, and it is
# why this gate names the remedy instead of just refusing.
#
# WHAT THIS DELIBERATELY DOES NOT MATCH — a tripwire that grows stops
# discriminating, so the pattern is narrow on purpose:
#
#   * `./dist/bp <verb>` — INVOKING the fresh build directly is the sanctioned
#     way to use it without installing at all, and several charters say so.
#   * `install -m 0755 dist/bp "$BINDIR/bp"` — the Makefile and
#     scripts/local-update.sh do exactly the right thing.
#   * prose ABOUT the hazard, including this file and internal/cli/upgrade.go's
#     comment, which exist to warn about it.
#
# Only `cp … dist/bp … <something>/bp` is refused: a copy whose SOURCE is the
# built artefact and whose DESTINATION is an installed bp.
#
# SCOPE, stated so nobody mistakes a pass for more than it is: this uses
# `git grep`, so it sees TRACKED files only. That is the right scope — the
# criterion is about COMMITTED recipes and CI runs on a committed tree — but it
# does mean an untracked scratch file will not trip it, and a mutation proof
# written against an untracked probe reads as a false PASS. `git add` the probe.
set -euo pipefail

REPO_ROOT=${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}
cd "$REPO_ROOT"

# SELF-EXCLUSION, and only self. This file must be allowed to quote the very
# recipe it forbids, or the gate could not explain itself; nothing else gets an
# exemption, because the eighth allowlist entry is waved through by the seven
# above it.
SELF="scripts/no-inplace-bp-copy-check.sh"

PATTERN='(^|[^[:alnum:]_./-])cp([[:space:]]+-[[:alnum:]]+)*[[:space:]]+[^|;&]*dist/bp[[:space:]]+[^|;&]*/bp([[:space:]]|$|["'"'"'`])'

set +e
HITS=$(git grep -n -E "$PATTERN" -- \
        ':!'"$SELF" \
        2>/dev/null)
RC=$?
set -e

# git grep exits 1 for "no matches", which is this gate's PASS. Any other
# non-zero is a real failure of the instrument and must not read as a pass.
if [ "$RC" -gt 1 ]; then
  echo "no-inplace-bp-copy-check: ERROR — git grep exited $RC (the check did not run)"
  exit 2
fi

if [ -n "$HITS" ]; then
  echo "no-inplace-bp-copy-check: FAILED — an in-place bp copy recipe is back."
  printf '%s\n' "$HITS" | sed 's/^/      /'
  echo ""
  echo "      cp writes THROUGH the existing inode, so a process holding the old"
  echo "      bp open keeps running it and the copy silently changes nothing."
  echo "      Use 'make cli-install' (install -m 0755 -> fresh inode), or invoke"
  echo "      the build in place as './dist/bp <verb>'."
  exit 1
fi

echo "no-inplace-bp-copy-check: OK — no in-place bp copy recipe on this tree"
