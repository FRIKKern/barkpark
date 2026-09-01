#!/usr/bin/env bash
# local-update.test.sh — the pull must refuse rather than rebase a branch it
# was not given, and must never autostash into a SHARED stash stack.
#
#   bash scripts/local-update.test.sh      (exit 0 = all green)
#
# WHY THIS EXISTS. `make update` is Golden Rule 8's prescribed recovery, and
# until 2026-09-01 `scripts/local-update.sh:32` was a bare
# `git pull --rebase --autostash` with no branch assertion — so the recovery
# could not detect the condition it exists to recover from.
#
# Measured on this machine at the time of writing: 436 registered worktrees;
# of the 425 carrying a branch, only 40 have a directory basename matching that
# branch. 385 do not. Thirteen worktrees are all named `wt`. A directory named
# for your branch is 9% evidence, not identity.
#
# HERMETIC. Every case runs against a throwaway repo pair under mktemp. Nothing
# touches the real repo, the real stash stack, or any network.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${LOCAL_UPDATE_SH:-$HERE/local-update.sh}"
pass=0; fail=0

check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf 'ok   %-56s (%s)\n' "$1" "$3"
  else fail=$((fail+1)); printf 'FAIL %-56s want %s got %s\n' "$1" "$2" "$3"; fi
}

[ -r "$SCRIPT" ] || { echo "FAIL: cannot read $SCRIPT" >&2; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lu-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ── a throwaway origin + clone, so `git pull` has a real upstream ───────────
git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
cd "$TMP/work" || exit 2
git config user.email t@t; git config user.name t
mkdir -p scripts
printf 'seed\n' > seed.txt
git add seed.txt; git commit -qm seed
git branch -M main
git push -q -u origin main 2>/dev/null

# The subject runs `cd "$(dirname $0)/.."`, so place it at <repo>/scripts/.
cp "$SCRIPT" scripts/local-update.sh
chmod +x scripts/local-update.sh
git add scripts/local-update.sh; git commit -qm harness

run() { # run [env...] -> prints "rc=<n>"; stdout+stderr captured
  ( cd "$TMP/work" && "$@" bash scripts/local-update.sh >"$TMP/out.txt" 2>&1 )
  printf 'rc=%s' "$?"
}

echo "== 1. the branch-binding refusal =="
got="$(run env BP_EXPECT_BRANCH=some-other-branch)"
check "expected-branch mismatch REFUSES"        "rc=2" "$got"
check "  ...and names both branches"            1 "$(grep -c "not the expected 'some-other-branch'" "$TMP/out.txt" | awk '{print ($1>0)?1:0}')"
check "  ...and says nothing was changed"       1 "$(grep -c 'Nothing has been changed' "$TMP/out.txt" | awk '{print ($1>0)?1:0}')"
# NON-VACUITY: the SAME env var, set correctly, must NOT refuse.
got="$(run env BP_EXPECT_BRANCH=main)"
check "matching expected-branch does NOT refuse" 1 "$([ "$got" != "rc=2" ] && echo 1 || echo 0)"

echo ""
echo "== 2. the dirty-tree refusal — never autostash into a shared stack =="
printf 'uncommitted\n' > "$TMP/work/dirty.txt"
git -C "$TMP/work" add dirty.txt
got="$(run env)"
check "dirty tree REFUSES"                      "rc=2" "$got"
check "  ...and explains the SHARED stash stack" 1 "$(grep -c 'SHARED across' "$TMP/out.txt" | awk '{print ($1>0)?1:0}')"
check "  ...and offers a uniquely-tagged stash"  1 "$(grep -c 'git stash push -u -m' "$TMP/out.txt" | awk '{print ($1>0)?1:0}')"
# THE LOAD-BEARING ASSERTION: the refusal must leave the work in the tree,
# not in a stash. Before the fix, --autostash moved it.
check "  ...and the work is STILL in the tree"   1 "$([ -f "$TMP/work/dirty.txt" ] && echo 1 || echo 0)"
check "  ...and created NO stash entry"          0 "$(git -C "$TMP/work" stash list | wc -l | tr -d ' ')"
rm -f "$TMP/work/dirty.txt"; git -C "$TMP/work" reset -q

echo ""
echo "== 3. detached HEAD has no branch to pull into =="
git -C "$TMP/work" checkout -q --detach
got="$(run env)"
check "detached HEAD REFUSES"                   "rc=2" "$got"
check "  ...and says so by name"                1 "$(grep -c 'detached HEAD' "$TMP/out.txt" | awk '{print ($1>0)?1:0}')"
git -C "$TMP/work" checkout -q main

echo ""
echo "== 4. NON-VACUITY — a clean, correctly-bound tree still pulls =="
# Without this, a script that refused unconditionally would pass every case above.
got="$(run env BP_EXPECT_BRANCH=main)"
check "clean tree does NOT refuse"              1 "$([ "$got" != "rc=2" ] && echo 1 || echo 0)"
check "  ...and announces branch AND upstream"  1 "$(grep -cE '>> Pulling main from ' "$TMP/out.txt" | awk '{print ($1>0)?1:0}')"

echo ""
echo "== 4b. an UNTRACKED file must NOT block the pull =="
# `--autostash` never stashed untracked files, so refusing on them would block
# `make update` for anyone holding a build artifact — and in this fleet a peer's
# ?? file can appear in your tree unbidden.
printf 'scratch\n' > "$TMP/work/untracked.txt"
got="$(run env BP_EXPECT_BRANCH=main)"
check "untracked file does NOT refuse"          1 "$([ "$got" != "rc=2" ] && echo 1 || echo 0)"
check "  ...and the untracked file survives"    1 "$([ -f "$TMP/work/untracked.txt" ] && echo 1 || echo 0)"
rm -f "$TMP/work/untracked.txt"

echo ""
echo "== 5. the flag that caused it is gone =="
# The invariant is narrow on purpose: no `git pull` may carry --autostash.
# A blanket grep is wrong twice over — the header explains the flag by name,
# and the refusal MESSAGE quotes it back to the operator. Both are correct
# occurrences, and a check that reds on them would be deleted within a week.
check "no git pull carries --autostash"        0 "$(grep -E '^[[:space:]]*git[[:space:]]+pull' "$SCRIPT" | grep -c -- '--autostash' | tr -d ' ')"
# NON-VACUITY, both halves: there IS a git pull to check, and the flag IS still
# named in the file — so the check above is looking at something real.
check "  (a git pull line exists at all)"      1 "$(grep -cE '^[[:space:]]*git[[:space:]]+pull' "$SCRIPT" | awk '{print ($1>0)?1:0}')"
check "  (the file still explains the flag)"   1 "$(grep -c -- '--autostash' "$SCRIPT" | awk '{print ($1>0)?1:0}')"

echo ""
echo "---"
echo "local-update: $pass passed, $fail failed"
[ "$fail" = 0 ]
