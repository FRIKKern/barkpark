#!/usr/bin/env bash
#
# committed-symlink-check.sh — NO SYMLINK IS EVER COMMITTED TO THIS REPO.
#
# WHY THIS EXISTS (PR #2907, and the fix that did not close the class)
# -------------------------------------------------------------------
# PR #2907 committed `api/deps` as mode 120000 pointing at
# /opt/barkpark/api/deps: self-referential on the prod box, DANGLING everywhere
# else, where it stops `mix` from running at all. The only thing that kept it
# out of main was a LOCAL, UNCOMMITTED `.git/info/exclude` line on one machine.
# A fresh clone had no such guard.
#
# PR #12736 fixed the pattern — `api/deps/` with a trailing slash cannot match a
# non-directory, so the slashless `api/deps` was added. That closed ONE PATH.
# It did not close the CLASS, for two reasons that are worth stating plainly:
#
#   1. .gitignore is not a gate. `git add -f` walks straight past it.
#   2. 30 of the 31 trailing-slash patterns in the committed .gitignore /
#      api/.gitignore still fail to match a symlink or a plain file at the same
#      path. `api/deps` was the one that bit only because it is the ONLY path
#      any committed recipe tells anyone to symlink (`ln -s <primary>/api/deps`,
#      the fresh-worktree deps-borrow recipe). The next directory-only pattern
#      someone writes re-opens exactly the same hole.
#
# So the guard belongs on the OUTCOME (a symlink reached a commit), not on the
# thirty-one patterns that might individually fail to prevent it.
#
# WHOLE TREE, NOT THE PR DIFF — AND WHY
# -------------------------------------
# This asserts over the ENTIRE committed tree at HEAD, not over the PR's diff
# against main. Both were on the table; the whole-tree reading won on three
# counts:
#
#   · It is strictly stronger. A diff reading only sees symlinks this PR ADDS.
#     One that arrives by a merge, a revert, a cherry-pick, or that predates the
#     gate is invisible to it. The whole-tree reading cannot be routed around.
#   · It needs no base ref. A diff reading needs origin/main fetched to a real
#     merge-base, which is this repo's most reliable source of a check that is
#     green because it looked at nothing (a shallow clone, a stale base, a
#     clobbered FETCH_HEAD). This reads only the checkout it was handed.
#   · It costs nothing to adopt. main carries ZERO committed symlinks today, so
#     the whole-tree assertion is green on arrival — there is no backlog to
#     grandfather and therefore no reason to accept the weaker reading.
#
# The tradeoff, stated: a legitimately-needed symlink must be added to the
# allowlist rather than merged quietly. That is the intended cost. The allowlist
# is empty and each entry is reviewable; a stale entry (allowlisted path that is
# no longer a committed symlink) is itself a failure, so exemptions cannot rot
# into permanent holes.
#
# EXIT CODES
# ----------
#   0  clean — the tree was read and carries no committed symlink
#   1  violation — a committed symlink, or a stale allowlist entry
#   2  REFUSED TO MEASURE — no readable git tree, or a tree with zero entries.
#      This is the whole point of a third code. "Zero symlinks found" and "found
#      nothing because there was nothing to read" are different facts, and a
#      guard that reports them identically is the exact defect it exists to
#      catch.

set -u

SELF="$0"
DEFAULT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${COMMITTED_SYMLINK_CHECK_ROOT:-$DEFAULT_ROOT}"
ALLOW_REL=".github/committed-symlinks.allow"

# ── the scan, in ONE place so --selftest drives the real code path ───────────
# `git ls-tree -r HEAD` emits: <mode> SP <type> SP <object> TAB <path>
# core.quotepath=false keeps non-ASCII paths readable; a path containing a raw
# newline or quote would still be git-quoted, which does not hide it — the mode
# is what this reads, and a quoted name still prints.
list_tree() { git -C "$ROOT" -c core.quotepath=false ls-tree -r HEAD 2>/dev/null; }

main() {
  echo "== committed-symlink-check: no symlink is ever committed =="

  if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "REFUSED TO MEASURE: $ROOT is not a git repository (a \`git archive\` extract, or a copied tree?)."
    echo "  This guard reads the COMMITTED tree; without an object database it would certify a tree it never saw."
    return 2
  fi

  local tree entries
  tree="$(list_tree)"
  entries="$(printf '%s' "$tree" | grep -c . || true)"
  if [ "$entries" -eq 0 ]; then
    echo "REFUSED TO MEASURE: \`git ls-tree -r HEAD\` returned ZERO entries at $ROOT."
    echo "  An empty reading is not a clean reading. Run this from a real checkout or worktree."
    return 2
  fi
  echo "ok:   read $entries tracked entries at HEAD"

  # committed symlinks (mode 120000)
  local found
  found="$(printf '%s\n' "$tree" | awk -F'\t' '$1 ~ /^120000 / { print $2 }' | sort)"

  # allowlist: one path per line, # comments and blanks ignored
  local allow=""
  if [ -f "$ROOT/$ALLOW_REL" ]; then
    allow="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$ROOT/$ALLOW_REL" | grep . | sort || true)"
  fi

  local rc=0

  # (a) any committed symlink that is not allowlisted
  local offenders
  if [ -n "$allow" ]; then
    offenders="$(comm -23 <(printf '%s\n' "$found" | grep . | sort) <(printf '%s\n' "$allow") || true)"
  else
    offenders="$(printf '%s\n' "$found" | grep . || true)"
  fi
  if [ -n "$offenders" ]; then
    echo "FAIL: a SYMLINK is committed to this repo (mode 120000):"
    printf '%s\n' "$offenders" | sed 's/^/        /'
    echo "      A committed symlink is self-referential on exactly one machine and DANGLING everywhere"
    echo "      else — PR #2907 committed api/deps -> /opt/barkpark/api/deps and it stops \`mix\` running"
    echo "      on every checkout but the prod box. Commit the real file or directory, or (only if the"
    echo "      symlink is genuinely the artifact) add a justified entry to $ALLOW_REL."
    rc=1
  else
    echo "ok:   no committed symlinks"
  fi

  # (b) anti-rot: an allowlist entry that is no longer a committed symlink
  if [ -n "$allow" ]; then
    local stale
    stale="$(comm -13 <(printf '%s\n' "$found" | grep . | sort) <(printf '%s\n' "$allow") || true)"
    if [ -n "$stale" ]; then
      echo "FAIL: stale entry in $ALLOW_REL — allowlisted but NOT a committed symlink:"
      printf '%s\n' "$stale" | sed 's/^/        /'
      echo "      An exemption that no longer describes anything is a hole nobody is watching. Remove it."
      rc=1
    else
      echo "ok:   every $ALLOW_REL entry still describes a committed symlink"
    fi
  fi

  [ "$rc" -eq 0 ] && echo "committed-symlink-check: PASS"
  [ "$rc" -ne 0 ] && echo "committed-symlink-check: FAILED"
  return "$rc"
}

# ── selftest: prove the gate BITES, and prove it stays SILENT when it should ──
#
# Every case builds a throwaway repo and re-invokes THIS script against it via
# COMMITTED_SYMLINK_CHECK_ROOT, so the assertions drive the shipping code path
# rather than a second implementation of it that could agree while both are
# wrong.
selftest() {
  local tmp bad=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  say() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; bad=$((bad + 1)); fi; }

  fresh() { # a minimal committed repo with one ordinary file
    rm -rf "$tmp/r"; mkdir -p "$tmp/r"
    git -C "$tmp/r" init -q
    git -C "$tmp/r" config user.email t@t; git -C "$tmp/r" config user.name t
    mkdir -p "$tmp/r/api"; echo hello > "$tmp/r/api/real.txt"
    git -C "$tmp/r" add -A >/dev/null; git -C "$tmp/r" commit -qm base
  }
  probe() { COMMITTED_SYMLINK_CHECK_ROOT="$tmp/r" bash "$SELF" > "$tmp/out" 2>&1; echo $?; }

  echo "committed-symlink-check --selftest (throwaway repos)"

  # 1. SILENT ARM — a clean repo must not fire.
  fresh; rc="$(probe)"
  { [ "$rc" -eq 0 ] && grep -q "no committed symlinks" "$tmp/out"; } \
    && say "clean repo -> PASS (the gate stays silent with no symlink)" 0 \
    || { say "clean repo -> PASS (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 2. BITE ARM — a committed symlink must fail AND be named.
  fresh
  ln -s /opt/barkpark/api/deps "$tmp/r/api/deps"      # dangling, exactly #2907's shape
  git -C "$tmp/r" add -A >/dev/null; git -C "$tmp/r" commit -qm sym
  rc="$(probe)"
  { [ "$rc" -eq 1 ] && grep -q "api/deps" "$tmp/out"; } \
    && say "committed DANGLING symlink -> FAIL, path named" 0 \
    || { say "committed DANGLING symlink -> FAIL, path named (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 3. BITE ARM — a symlink whose target RESOLVES is still a symlink.
  fresh
  ln -s real.txt "$tmp/r/api/alias.txt"
  git -C "$tmp/r" add -A >/dev/null; git -C "$tmp/r" commit -qm sym2
  rc="$(probe)"
  { [ "$rc" -eq 1 ] && grep -q "api/alias.txt" "$tmp/out"; } \
    && say "committed RESOLVING symlink -> FAIL (not just dangling ones)" 0 \
    || { say "committed RESOLVING symlink -> FAIL (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 4. the allowlist actually exempts.
  fresh
  ln -s /opt/barkpark/api/deps "$tmp/r/api/deps"
  mkdir -p "$tmp/r/.github"
  printf '# justified:\napi/deps\n' > "$tmp/r/$ALLOW_REL"
  git -C "$tmp/r" add -A >/dev/null; git -C "$tmp/r" commit -qm allow
  rc="$(probe)"
  { [ "$rc" -eq 0 ] && grep -q "still describes a committed symlink" "$tmp/out"; } \
    && say "allowlisted symlink -> PASS" 0 \
    || { say "allowlisted symlink -> PASS (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 5. anti-rot: an allowlist entry describing nothing is itself a failure.
  fresh
  mkdir -p "$tmp/r/.github"
  printf 'api/deps\n' > "$tmp/r/$ALLOW_REL"
  git -C "$tmp/r" add -A >/dev/null; git -C "$tmp/r" commit -qm stale
  rc="$(probe)"
  { [ "$rc" -eq 1 ] && grep -q "stale entry" "$tmp/out"; } \
    && say "allowlist entry that is not a symlink -> FAIL (exemptions cannot rot)" 0 \
    || { say "allowlist entry that is not a symlink -> FAIL (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 6. REFUSED TO MEASURE — not a git repo. Silence here would be the defect.
  rm -rf "$tmp/r"; mkdir -p "$tmp/r"; echo x > "$tmp/r/f"
  rc="$(probe)"
  { [ "$rc" -eq 2 ] && grep -q "REFUSED TO MEASURE" "$tmp/out"; } \
    && say "not a git repo -> REFUSED TO MEASURE (2), never a silent PASS" 0 \
    || { say "not a git repo -> REFUSED TO MEASURE (2) (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  # 7. REFUSED TO MEASURE — a real repo whose HEAD tree is EMPTY.
  rm -rf "$tmp/r"; mkdir -p "$tmp/r"
  git -C "$tmp/r" init -q
  git -C "$tmp/r" config user.email t@t; git -C "$tmp/r" config user.name t
  git -C "$tmp/r" commit -q --allow-empty -m empty
  rc="$(probe)"
  { [ "$rc" -eq 2 ] && grep -q "ZERO entries" "$tmp/out"; } \
    && say "empty HEAD tree -> REFUSED TO MEASURE (2), not 'clean'" 0 \
    || { say "empty HEAD tree -> REFUSED TO MEASURE (2) (got $rc)" 1; sed 's/^/        /' "$tmp/out"; }

  echo ""
  if [ "$bad" -eq 0 ]; then echo "committed-symlink-check --selftest: PASS (7/7)"; return 0; fi
  echo "committed-symlink-check --selftest: FAILED ($bad case(s))"; return 1
}

case "${1:-}" in
  --selftest) selftest ;;
  "")         main ;;
  *)          echo "usage: $0 [--selftest]" >&2; exit 64 ;;
esac
