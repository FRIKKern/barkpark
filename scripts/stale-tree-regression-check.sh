#!/usr/bin/env bash
#
# stale-tree-regression-check.sh — does this head silently REVERT the base?
#
# THE SHAPE IT HUNTS (#15930, 2026-09-04). A builder works in a worktree cut
# from origin/main at 4e20a992a. Hours later they fetch, `git reset --soft` (or
# squash) onto the NEWER main 95b079ef1, and commit. The commit's TREE is still
# the old one, so its diff against the new parent carries the 4e20a992a state of
# twenty files the builder never opened: cloud/priv/static/app.js re-shrunk by
# 497 lines, scripts/pds-draft-twin-sweep.sh DELETED, deploy/instance-deploy.sh
# reverted. Every one of those is a silent regression of merged work, and no
# test on the branch goes red for it — the branch is internally consistent. The
# only symptom in #15930 was a merge conflict on ONE of the twenty files; had
# main not moved on that file, the branch would have been 4/4-eligible.
#
# TWO ARMS, both local, no network:
#
#   (a) DELETED HERE, ALIVE THERE. A path the head deletes against the
#       merge-base M, which the base ref changed AFTER M. If the base is still
#       working on the file, this head is unlikely to be the one that meant to
#       remove it. This arm alone would have caught #15930.
#
#   (b') REVERTED TO A PAST STATE. A path the head modifies whose head-side blob
#       is byte-identical to that same path's blob at an ancestor of M that is
#       strictly OLDER than M. A stale tree does not invent content; it restores
#       content that used to be there. An honest edit almost never reproduces an
#       old revision byte for byte. The ancestor walk is capped at WALK_CAP=200
#       commits per path, and the path list at PATH_CAP=500; both caps can only
#       make this arm MISS, never fire falsely, and hitting PATH_CAP prints a
#       NOTE line so a partial sweep never reads as a full one.
#
# WHAT IT CANNOT DO — read this before you trust a green or argue with a red.
# Arm (a) cannot tell an INTENTIONAL delete from a stale-tree delete: both look
# exactly like "gone here, changed there", and the stale squash's single commit
# "touches" the path too, so head-side authorship discriminates nothing. A
# branch whose whole purpose is to retire a file the base touched last week WILL
# red, and that red is right as a question ("did you mean to drop the base's
# newer work on this file?") and wrong as a verdict. There is deliberately NO
# allowlist: a tripwire that grows stops discriminating. Deleting a file the
# base is still editing is rare enough that saying so once, out loud, in the PR
# is the right cost. The red line names the base-side commits, so the judgement
# takes one glance.
#
# Usage:  scripts/stale-tree-regression-check.sh [-C <repo>] <base-ref> [<head>]
#   <base-ref>  what the head claims to be based on, e.g. origin/main
#   <head>      default HEAD
#
# Exit codes — a failed read is NEVER byte-identical to a clean run:
#   0  OK            one OK line, nothing found
#   1  RED           one RED line per finding, plus a summary RED line
#   2  CANNOT READ   a ref or the repo did not resolve; nothing was compared
#   3  usage

set -u

WALK_CAP=200 # ancestor commits examined per path in arm (b')
PATH_CAP=500 # paths examined in arm (b') before we say we stopped

usage() {
  echo "usage: $0 [-C <repo>] <base-ref> [<head>]" >&2
  exit 3
}

REPO="."
while [ $# -gt 0 ]; do
  case "$1" in
    -C)
      REPO="${2:-}"
      [ -n "$REPO" ] || usage
      shift 2
      ;;
    -h | --help) usage ;;
    --)
      shift
      break
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage
      ;;
    *) break ;;
  esac
done

[ $# -ge 1 ] && [ $# -le 2 ] || usage
BASE="$1"
HEAD_REF="${2:-HEAD}"

g() { git -C "$REPO" "$@"; }

cannot_read() {
  echo "CANNOT READ: $*"
  exit 2
}

g rev-parse --git-dir >/dev/null 2>&1 || cannot_read "not a git repository: $REPO"

BASE_SHA="$(g rev-parse --verify --quiet "${BASE}^{commit}" 2>/dev/null)"
[ -n "$BASE_SHA" ] || cannot_read "base ref does not resolve to a commit: $BASE"
HEAD_SHA="$(g rev-parse --verify --quiet "${HEAD_REF}^{commit}" 2>/dev/null)"
[ -n "$HEAD_SHA" ] || cannot_read "head ref does not resolve to a commit: $HEAD_REF"

M="$(g merge-base "$BASE_SHA" "$HEAD_SHA" 2>/dev/null)"
[ -n "$M" ] || cannot_read "no merge-base between $BASE and $HEAD_REF (unrelated histories?)"
M_SHORT="$(g rev-parse --short "$M")"

findings=0
red() {
  findings=$((findings + 1))
  echo "RED  $*"
}

# ── arm (a): deleted here, changed on the base after the merge-base ──────────

deleted="$(g diff --diff-filter=D --name-only "$M" "$HEAD_SHA" 2>/dev/null)" ||
  cannot_read "could not diff $M..$HEAD_SHA"

while IFS= read -r p; do
  [ -n "$p" ] || continue
  after="$(g log --format='%h' "$M..$BASE_SHA" -- "$p" 2>/dev/null)"
  [ -n "$after" ] || continue
  n="$(printf '%s\n' "$after" | grep -c .)"
  latest="$(printf '%s\n' "$after" | head -1)"
  red "$p — deleted by this head, but $BASE changed it in $n commit(s) AFTER the merge-base $M_SHORT (latest $latest). A stale tree deletes files it never opened; so does an intentional removal — say which."
done <<PATHS_DELETED
$deleted
PATHS_DELETED

# ── arm (b'): head blob equals a blob from strictly before the merge-base ─────
# Only meaningful when M has a parent: with no history before M there is no past
# state to revert to, so the arm is vacuous rather than wrong.

PRE_M="$(g rev-parse --verify --quiet "${M}^" 2>/dev/null)" || PRE_M=""

if [ -n "$PRE_M" ]; then
  modified="$(g diff --diff-filter=M --name-only "$M" "$HEAD_SHA" 2>/dev/null)" ||
    cannot_read "could not diff $M..$HEAD_SHA"

  examined=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ "$examined" -ge "$PATH_CAP" ]; then
      echo "NOTE stopped arm (b') after $PATH_CAP paths; re-run on a narrower range to cover the rest."
      break
    fi
    examined=$((examined + 1))

    head_blob="$(g rev-parse --verify --quiet "$HEAD_SHA:$p" 2>/dev/null)"
    [ -n "$head_blob" ] || continue

    ancestors="$(g log --format='%H' --max-count="$WALK_CAP" "$PRE_M" -- "$p" 2>/dev/null)"
    hit=""
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      old_blob="$(g rev-parse --verify --quiet "$c:$p" 2>/dev/null)"
      if [ -n "$old_blob" ] && [ "$old_blob" = "$head_blob" ]; then
        hit="$c"
        break
      fi
    done <<ANCESTORS
$ancestors
ANCESTORS

    if [ -n "$hit" ]; then
      hit_short="$(g rev-parse --short "$hit")"
      red "$p — reverts $p to $hit_short (the head's blob for it is byte-identical to that path at $hit_short, an ancestor strictly older than the merge-base $M_SHORT). A stale tree restores old content; an honest edit rarely reproduces an old revision byte for byte."
    fi
  done <<PATHS_MODIFIED
$modified
PATHS_MODIFIED
fi

if [ "$findings" -gt 0 ]; then
  echo "RED  $findings finding(s): this head against $BASE (merge-base $M_SHORT) looks like a stale tree. Rebuild the head as an honest patch on $BASE — git diff <old-base>..<head> -- <the paths you meant> | git apply --3way — before pushing."
  exit 1
fi

changed="$(g diff --name-only "$M" "$HEAD_SHA" 2>/dev/null | grep -c .)"
echo "OK   no stale-tree regression: $changed path(s) changed against $BASE (merge-base $M_SHORT; arms: deleted-here-changed-there, reverts-to-a-pre-merge-base-blob)."
exit 0
