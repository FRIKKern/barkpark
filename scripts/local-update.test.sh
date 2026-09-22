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
# …and it SOURCES scripts/lib/bp-staleness.sh, so the fixture carries that too.
mkdir -p scripts/lib
cp "${BP_STALENESS_SH:-$HERE/lib/bp-staleness.sh}" scripts/lib/bp-staleness.sh
git add scripts/local-update.sh scripts/lib/bp-staleness.sh; git commit -qm harness

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
echo "== 6. OLD==NEW must STILL rebuild a bp that is behind origin/main =="
# THE DEFECT. The rebuild used to be decided purely from this invocation's pull
# delta, and the OLD==NEW arm exited 0 before reaching it — so when another
# session had already pulled this shared checkout (or the operator ran a bare
# `git pull` first), `make update` printed "Already up to date" and left the
# stale binary installed. `make doctor` reds on exactly that binary, so the
# gauge could see what the prescribed fixer could not fix.
#
# HERMETIC: its own origin+clone, a fake `bp` whose `version` prints an OLD
# commit, and a fake `make` whose cli-build writes a recognisable dist/bp.
# BP_INSTALL points AT the fake bp, so "was it reinstalled" is a file read.
B="$TMP/behind"; mkdir -p "$B/bin"
GITQ="git -c user.email=t@t -c user.name=t -c commit.gpgsign=false -c init.defaultBranch=main"
$GITQ init -q --bare "$B/origin.git"
$GITQ clone -q "$B/origin.git" "$B/work" 2>/dev/null
mkdir -p "$B/work/scripts/lib"
cp "$SCRIPT" "$B/work/scripts/local-update.sh"
cp "${BP_STALENESS_SH:-$HERE/lib/bp-staleness.sh}" "$B/work/scripts/lib/bp-staleness.sh"
printf 'package main\n\nfunc main() {}\n' > "$B/work/main.go"
$GITQ -C "$B/work" add -A; $GITQ -C "$B/work" commit -qm A
$GITQ -C "$B/work" branch -M main
$GITQ -C "$B/work" push -q -u origin main 2>/dev/null
OLD_SHA="$($GITQ -C "$B/work" rev-parse HEAD)"     # the commit the fake bp was built at
# origin/main moves on with a GO change, and this checkout pulls it — so the
# checkout is ALREADY current and the run below has OLD==NEW.
printf 'package main // v2\n\nfunc main() {}\n' > "$B/work/main.go"
$GITQ -C "$B/work" add -A; $GITQ -C "$B/work" commit -qm 'B: go change'
$GITQ -C "$B/work" push -q origin main 2>/dev/null
$GITQ -C "$B/work" fetch -q origin 2>/dev/null

make_fake_bp() { # <path> <sha>
  cat > "$1" <<EOF
#!/bin/sh
[ "\$1" = version ] && { printf '{"cli_version":"fixture","commit": "%s"}\n' "$2"; exit 0; }
exit 0
EOF
  chmod +x "$1"
}
cat > "$B/bin/make" <<'EOF'
#!/bin/sh
if [ "$1" = cli-build ]; then
  mkdir -p dist
  printf 'FRESHLY-BUILT %s
' "$(git rev-parse HEAD)" > dist/bp
  chmod +x dist/bp
  exit 0
fi
exit 0
EOF
chmod +x "$B/bin/make"

run_behind() { ( cd "$B/work" && env PATH="$B/bin:$PATH" BP_INSTALL="$B/bin/bp" \
    bash scripts/local-update.sh >"$TMP/out6.txt" 2>&1 ); printf 'rc=%s' "$?"; }

make_fake_bp "$B/bin/bp" "$OLD_SHA"
got="$(run_behind)"
check "already-current checkout: run succeeds"        "rc=0" "$got"
check "  ...and REPORTS it was already up to date"    1 "$(grep -c 'Already up to date' "$TMP/out6.txt" | awk '{print ($1>0)?1:0}')"
# THE LOAD-BEARING ASSERTION: the stale binary was actually replaced on disk.
check "  ...and the STALE bp was rebuilt+installed"   1 "$(grep -c '^FRESHLY-BUILT ' "$B/bin/bp" | awk '{print ($1>0)?1:0}')"
check "  ...and says WHY (it predates origin/main)"   1 "$(grep -c 'predates Go changes on origin/main' "$TMP/out6.txt" | awk '{print ($1>0)?1:0}')"

echo ""
echo "== 6b. NON-VACUITY — a CURRENT bp must NOT be rebuilt =="
# Without this, a script that rebuilt unconditionally would pass 6 outright.
TIP_SHA="$($GITQ -C "$B/work" rev-parse origin/main)"
make_fake_bp "$B/bin/bp" "$TIP_SHA"
got="$(run_behind)"
check "current bp: run succeeds"                      "rc=0" "$got"
check "  ...and bp was NOT rebuilt"                   0 "$(grep -c '^FRESHLY-BUILT ' "$B/bin/bp" | tr -d ' ')"
check "  ...and says the installed bp is current"     1 "$(grep -c 'is current with origin/main' "$TMP/out6.txt" | awk '{print ($1>0)?1:0}')"

echo ""
echo "== 6c. a DIVERGED bp is warned about, never rebuilt (a rebuild loops) =="
# `make cli-build` compiles THIS checkout — the same off-history tree the
# binary came from — so rebuilding reinstalls the identical binary. doctor.sh
# says the remedy is a rebase; the fixer must not contradict the gauge.
$GITQ -C "$B/work" checkout -q -b diverge "$OLD_SHA"
printf 'sibling\n' > "$B/work/SIBLING.md"
$GITQ -C "$B/work" add -A; $GITQ -C "$B/work" commit -qm 'E: divergent sibling'
DIV_SHA="$($GITQ -C "$B/work" rev-parse HEAD)"
$GITQ -C "$B/work" checkout -q main
make_fake_bp "$B/bin/bp" "$DIV_SHA"
got="$(run_behind)"
check "diverged bp: run WARNS (exit 1, not silent)"   "rc=1" "$got"
check "  ...and bp was NOT rebuilt"                   0 "$(grep -c '^FRESHLY-BUILT ' "$B/bin/bp" | tr -d ' ')"
check "  ...and prescribes the rebase, not a rebuild" 1 "$(grep -c 'git pull --rebase' "$TMP/out6.txt" | awk '{print ($1>0)?1:0}')"

echo ""
echo "---"
echo "local-update: $pass passed, $fail failed"
[ "$fail" = 0 ]
