#!/usr/bin/env bash
# lib.sh — shared constants + helpers for the Scaffy W6 duel harness.
# Sourced by warm-worktree.sh, run-cell.sh, boundary-setup.sh. Not executable on its own.
#
# Serial-only (D66): every script here assumes ONE cell runs at a time. No locking,
# no parallelism — the run-duels slice drives cells sequentially and appends to RUNLOG.

set -euo pipefail

# The registered pin (charter D64). Every cell worktree is checked out here.
SCAFFY_DUELS_PIN="591fdcd53"

# Where cell worktrees live — an isolated tmp root, NEVER the primary checkout.
SCAFFY_DUELS_WT_ROOT="${SCAFFY_DUELS_WT_ROOT:-/private/tmp}"

# Directory of this library (tooling/scaffy-duels/).
SCAFFY_DUELS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAFFY_DUELS_RESULTS="${SCAFFY_DUELS_DIR}/results"
SCAFFY_DUELS_MATRIX="${SCAFFY_DUELS_DIR}/matrix.json"

# The primary checkout that owns api/deps (mix.lock must byte-match the pin).
# Derived from the shared git common-dir so this works from any linked worktree.
_scaffy_duels_primary() {
  local common
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  # common-dir is <primary>/.git ; its parent is the primary worktree.
  ( cd "$(dirname "$common")" && pwd )
}

# Worktree path for a cell slug.
_scaffy_duels_wt() { printf '%s/scaffy-duel-%s' "$SCAFFY_DUELS_WT_ROOT" "$1"; }

# Fail loudly with a prefixed message.
die() { printf 'scaffy-duels: FATAL: %s\n' "$*" >&2; exit 1; }
note() { printf 'scaffy-duels: %s\n' "$*" >&2; }

# Cross-platform sha256 of stdin -> hex.
sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}';
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}';
  else die "no sha256sum/shasum available"; fi
}

# Cross-platform md5 of a file -> hex.
md5_file() {
  if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | awk '{print $1}';
  elif command -v md5 >/dev/null 2>&1; then md5 -q "$1";
  else die "no md5sum/md5 available"; fi
}

# Read a value out of matrix.json by python path (dotted), e.g. chores.add-error-shape.command
matrix_get() {
  python3 - "$SCAFFY_DUELS_MATRIX" "$1" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
cur = doc
for part in sys.argv[2].split('.'):
    if isinstance(cur, list):
        cur = cur[int(part)]
    else:
        cur = cur[part]
print(cur if not isinstance(cur, (dict, list)) else json.dumps(cur))
PY
}
