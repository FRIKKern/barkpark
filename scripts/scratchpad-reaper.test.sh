#!/usr/bin/env bash
#
# scratchpad-reaper.test.sh — the reaper must be able to REFUSE, and its skip
# gates must be LOAD-BEARING, not incidental.
#
# EVERY fixture is built under a fresh `mktemp -d`. This harness NEVER names,
# reads or removes a real session directory, a real scratchpad root, or the
# machine's own worktree registry: the repo under test is a throwaway git repo
# created here, and the only `--repo` the reaper is ever pointed at is that one.
# A harness for a deleting tool that touched live trees would be a worse bug
# than the one it guards.
#
# THE THREE DIFFERENTIAL CONTROLS are the point. A skip is easy to observe and
# worthless as evidence unless the same directory REAPS when the reason for the
# skip is taken away:
#
#   C1  a registered worktree is SKIP-WORKTREE; `git worktree remove` it and
#       the identical path becomes WOULD-REAP.
#   C2  a checkout with a local-only commit is SKIP-UNPUSHED; push that commit
#       and the identical path becomes WOULD-REAP.
#   C3  the floor REFUSES above the measured free space and PASSES below it,
#       on the same path in the same second.
#
# EXIT: 0 all assertions passed · 1 at least one failed · 2 cannot measure
# (git missing, mktemp failed) — never a silent green.
#
# bash 3.2 compatible.

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REAPER="$HERE/scratchpad-reaper.sh"
fails=0
checks=0

cannot_measure() {
	printf 'scratchpad-reaper.test: CANNOT READ — %s\n' "$1" >&2
	exit 2
}

ok() {
	checks=$((checks + 1))
	printf 'ok   %s\n' "$1"
}

bad() {
	checks=$((checks + 1))
	fails=$((fails + 1))
	printf 'FAIL %s\n' "$1" >&2
	if [ "$#" -ge 2 ]; then
		printf '     ---- captured output ----\n' >&2
		printf '%s\n' "$2" >&2
		printf '     -------------------------\n' >&2
	fi
}

# has <label> <haystack> <needle>
has() {
	case "$2" in
	*"$3"*) ok "$1" ;;
	*) bad "$1 (expected to find: $3)" "$2" ;;
	esac
}

# lacks <label> <haystack> <needle>
lacks() {
	case "$2" in
	*"$3"*) bad "$1 (did NOT expect: $3)" "$2" ;;
	*) ok "$1" ;;
	esac
}

rc_is() {
	if [ "$2" = "$3" ]; then
		ok "$1 (rc=$2)"
	else
		bad "$1: rc=$2, want $3"
	fi
}

command -v git >/dev/null 2>&1 || cannot_measure "git is not on PATH; this harness builds git fixtures"
[ -r "$REAPER" ] || cannot_measure "cannot read the subject: $REAPER"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/reaper-test.XXXXXX") || cannot_measure "mktemp -d failed"
# RESOLVE the symlinks. On macOS $TMPDIR is /var/folders/... while /var is a
# symlink to /private/var, and `git worktree list` prints the REAL path. Without
# this the registration assertion compares two spellings of the same directory
# and the whole worktree control silently measures nothing.
TMP=$(cd -- "$TMP" && pwd -P) || cannot_measure "could not resolve the temp dir to a real path"
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=reaper-test GIT_AUTHOR_EMAIL=reaper@test
export GIT_COMMITTER_NAME=reaper-test GIT_COMMITTER_EMAIL=reaper@test

# Every candidate must be older than the default 2-day floor or the freshness
# gate alone would explain every skip and the other gates would go unmeasured.
STALE_TS=200001010000

age() { touch -t "$STALE_TS" "$1"; }

# ── the throwaway "repo under test" and its bare remote ──────────────────────
ORIGIN="$TMP/origin.git"
# -b main is LOAD-BEARING, and its absence is a Linux-only failure this harness
# caught in CI on 2026-09-13. GIT_CONFIG_GLOBAL=/dev/null above erases any
# init.defaultBranch, so a bare init lands HEAD on the git build's own default
# (`master` on the ubuntu runner). Every later `git clone` of this remote then
# prints `remote HEAD refers to nonexistent ref, unable to checkout` and yields
# a checkout with NO working tree and NO local branch — and every fixture built
# from it measures nothing. The precondition asserts below refuse on that
# rather than passing, which is how it was found.
git init -q --bare -b main "$ORIGIN" || cannot_measure "git init --bare failed"

REPO="$TMP/repo"
git init -q -b main "$REPO" || cannot_measure "git init failed"
printf 'seed\n' >"$REPO/seed.txt"
git -C "$REPO" add seed.txt >/dev/null 2>&1
git -C "$REPO" commit -q -m seed
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -q origin main || cannot_measure "push to the fixture remote failed"

# ── the fake scratchpad root ────────────────────────────────────────────────
ROOT="$TMP/scratch"
mkdir -p "$ROOT"

# A: a plain stale extract — nothing git about it. The ONLY thing that should
# ever be reaped by default.
mkdir -p "$ROOT/a-plain/nested"
printf 'x\n' >"$ROOT/a-plain/nested/file"
age "$ROOT/a-plain"

# B: a REGISTERED worktree of the fixture repo, deliberately CLEAN and fully
# pushed, so the only possible reason to skip it is the registration.
git -C "$REPO" worktree add -q "$ROOT/b-worktree" -b wt-branch main 2>/dev/null \
	|| cannot_measure "git worktree add failed in the fixture"
git -C "$REPO" push -q origin wt-branch || cannot_measure "pushing the fixture worktree branch failed"
age "$ROOT/b-worktree"

# C: an UNREGISTERED clone carrying a commit that exists on no remote.
git clone -q "$ORIGIN" "$ROOT/c-unpushed" || cannot_measure "git clone failed"
printf 'local only\n' >"$ROOT/c-unpushed/local.txt"
git -C "$ROOT/c-unpushed" add local.txt >/dev/null 2>&1
git -C "$ROOT/c-unpushed" commit -q -m "local only"
age "$ROOT/c-unpushed"

# D: an UNREGISTERED clone that is clean and fully pushed — reapable.
git clone -q "$ORIGIN" "$ROOT/d-pushed" || cannot_measure "git clone failed"
age "$ROOT/d-pushed"

# E: an UNREGISTERED clone that is clean and pushed but holds an UNTRACKED file.
git clone -q "$ORIGIN" "$ROOT/e-dirty" || cannot_measure "git clone failed"
printf 'scratch\n' >"$ROOT/e-dirty/untracked.txt"
age "$ROOT/e-dirty"

# F: a checkout with NO remote at all — nothing here can be proved pushed.
mkdir -p "$ROOT/f-noremote"
git init -q -b main "$ROOT/f-noremote"
printf 'y\n' >"$ROOT/f-noremote/y.txt"
git -C "$ROOT/f-noremote" add y.txt >/dev/null 2>&1
git -C "$ROOT/f-noremote" commit -q -m y
age "$ROOT/f-noremote"

# G: a plain dir that is FRESH (mtime now) — the age gate's own subject.
mkdir -p "$ROOT/g-fresh"
printf 'z\n' >"$ROOT/g-fresh/z"

# H: a reapable plain dir with a pushed clone buried THREE levels down, to
# prove the unpushed scan is not a top-level-only check.
mkdir -p "$ROOT/h-nested/one/two"
git clone -q "$ORIGIN" "$ROOT/h-nested/one/two/deep" || cannot_measure "git clone failed"
printf 'buried\n' >"$ROOT/h-nested/one/two/deep/buried.txt"
git -C "$ROOT/h-nested/one/two/deep" add buried.txt >/dev/null 2>&1
git -C "$ROOT/h-nested/one/two/deep" commit -q -m buried
age "$ROOT/h-nested"

# ── ASSERT the fixture actually reached the state the assertions assume ─────
# A setup that silently died would make every skip below a vacuous green.
[ -d "$ROOT/b-worktree/.git" ] || [ -f "$ROOT/b-worktree/.git" ] \
	|| cannot_measure "fixture B is not a worktree checkout"
wt_out=$(git -C "$REPO" worktree list --porcelain 2>/dev/null) \
	|| cannot_measure "git worktree list failed on the fixture repo"
case "$wt_out" in
*"$ROOT/b-worktree"*) ;;
*) cannot_measure "fixture B is not REGISTERED in the fixture repo's worktree list" ;;
esac
# A clone that produced no working tree is the Linux failure above. Assert the
# CHECKOUT, not just the directory: a bare `[ -d ]` passes on an empty clone.
for clone in c-unpushed d-pushed e-dirty h-nested/one/two/deep; do
	[ -f "$ROOT/$clone/seed.txt" ] \
		|| cannot_measure "fixture clone $clone has no working tree (the bare remote's HEAD does not name the pushed branch)"
done
unpushed_c=$(git -C "$ROOT/c-unpushed" rev-list --count main --not --remotes 2>/dev/null)
[ "$unpushed_c" = "1" ] || cannot_measure "fixture C does not hold exactly one unpushed commit (got '$unpushed_c')"
unpushed_d=$(git -C "$ROOT/d-pushed" rev-list --count main --not --remotes 2>/dev/null)
[ "$unpushed_d" = "0" ] || cannot_measure "fixture D is not fully pushed (got '$unpushed_d')"

printf '== fixture asserted: registered worktree present, C has 1 unpushed commit, D has 0 ==\n'

run_dry() {
	"$REAPER" --dry-run --root "$ROOT" --repo "$REPO" 2>&1
}

printf '\n== CLASSIFICATION (dry run deletes nothing) ==\n'
out=$(run_dry)
rc=$?
rc_is "a dry run over a mixed root exits clean" "$rc" 0
has "A plain stale extract is the reap candidate" "$out" "WOULD-REAP     $ROOT/a-plain"
has "B a registered worktree is skipped even though it is clean and pushed" "$out" "SKIP-WORKTREE  $ROOT/b-worktree"
has "C a local-only commit blocks the reclaim" "$out" "SKIP-UNPUSHED  $ROOT/c-unpushed"
has "D a clean fully-pushed clone is reapable" "$out" "WOULD-REAP     $ROOT/d-pushed"
has "E an untracked file blocks the reclaim" "$out" "SKIP-UNPUSHED  $ROOT/e-dirty"
has "F a checkout with no remote can never be proved pushed" "$out" "SKIP-UNPUSHED  $ROOT/f-noremote"
has "F names WHY it cannot be proved" "$out" "no remote configured"
has "G a fresh directory is below the age floor" "$out" "SKIP-FRESH     $ROOT/g-fresh"
has "H a buried unpushed checkout is found three levels down" "$out" "SKIP-UNPUSHED  $ROOT/h-nested"
has "the run reports df, not du" "$out" "DF-BEFORE-ROOT $ROOT"
lacks "no reclaim is ever sized by du" "$out" "du "
has "the entry count the incident used is reported" "$out" "ENTRIES-BEFORE $ROOT"

printf '\n== the dry run really deleted NOTHING ==\n'
still=0
for d in a-plain b-worktree c-unpushed d-pushed e-dirty f-noremote g-fresh h-nested; do
	[ -d "$ROOT/$d" ] || still=$((still + 1))
done
if [ "$still" -eq 0 ]; then
	ok "all 8 candidates survive a dry run"
else
	bad "$still candidate(s) vanished during a DRY run"
fi

printf '\n== C1 DIFFERENTIAL: the worktree skip is load-bearing ==\n'
# Same directory, same content, same age. The ONLY change is the registration.
git -C "$REPO" worktree remove --force "$ROOT/b-worktree" >/dev/null 2>&1
# Rebuild the identical directory as a plain (now unregistered) checkout.
git clone -q "$ORIGIN" "$ROOT/b-worktree" || cannot_measure "rebuilding fixture B failed"
age "$ROOT/b-worktree"
wt_out2=$(git -C "$REPO" worktree list --porcelain 2>/dev/null) || cannot_measure "worktree list failed after remove"
case "$wt_out2" in
*"$ROOT/b-worktree"*) cannot_measure "fixture B is STILL registered after worktree remove — the control did not change anything" ;;
*) ;;
esac
out2=$(run_dry)
has "C1 with the registration gone the identical path becomes reapable" "$out2" "WOULD-REAP     $ROOT/b-worktree"
lacks "C1 and no longer claims a worktree fence it does not have" "$out2" "SKIP-WORKTREE  $ROOT/b-worktree"

printf '\n== C2 DIFFERENTIAL: the unpushed skip is load-bearing ==\n'
git -C "$ROOT/c-unpushed" push -q origin main || cannot_measure "pushing fixture C failed"
unpushed_c2=$(git -C "$ROOT/c-unpushed" rev-list --count main --not --remotes 2>/dev/null)
[ "$unpushed_c2" = "0" ] || cannot_measure "fixture C still holds unpushed commits after the push (got '$unpushed_c2') — the control did not change anything"
age "$ROOT/c-unpushed"
out3=$(run_dry)
has "C2 once the commit is on a remote the identical path becomes reapable" "$out3" "WOULD-REAP     $ROOT/c-unpushed"
lacks "C2 and the stale unpushed verdict is gone" "$out3" "SKIP-UNPUSHED  $ROOT/c-unpushed"

printf '\n== REAP requires an explicit --yes-delete ==\n'
out4=$("$REAPER" --reap --root "$ROOT" --repo "$REPO" 2>&1)
rc4=$?
rc_is "--reap without --yes-delete is a usage refusal" "$rc4" 4
has "and it names the missing flag" "$out4" "requires --yes-delete"
[ -d "$ROOT/a-plain" ] && ok "the refused reap deleted nothing" || bad "the refused reap deleted a-plain"

printf '\n== REAP removes exactly the proved-safe candidates ==\n'
out5=$("$REAPER" --reap --yes-delete --root "$ROOT" --repo "$REPO" 2>&1)
rc5=$?
rc_is "the reclaim run exits clean" "$rc5" 0
has "a-plain is reaped and sized by df" "$out5" "REAPED         $ROOT/a-plain"
has "the REAPED line carries the df delta" "$out5" "freed_kb="
has "the run states its sizing method" "$out5" "Sized by df, never du."
[ -d "$ROOT/a-plain" ] && bad "a-plain survived a reclaim run" || ok "a-plain is gone"
[ -d "$ROOT/d-pushed" ] && bad "d-pushed survived a reclaim run" || ok "d-pushed is gone"
[ -d "$ROOT/e-dirty" ] && ok "e-dirty (untracked file) SURVIVED the reclaim" || bad "e-dirty was deleted despite untracked work"
[ -d "$ROOT/f-noremote" ] && ok "f-noremote (unprovable) SURVIVED the reclaim" || bad "f-noremote was deleted without proof"
[ -d "$ROOT/g-fresh" ] && ok "g-fresh (under the age floor) SURVIVED the reclaim" || bad "g-fresh was deleted while fresh"
[ -d "$ROOT/h-nested" ] && ok "h-nested (buried unpushed commit) SURVIVED the reclaim" || bad "h-nested was deleted with a buried unpushed commit"

printf '\n== a REGISTERED worktree survives a real reclaim run ==\n'
# Re-register one, then run the real reclaim over it. This is the criterion the
# incident bought with 17 live worktrees: never strand built work.
rm -rf -- "$ROOT/b-worktree"
git -C "$REPO" worktree add -q "$ROOT/b-worktree" wt-branch 2>/dev/null \
	|| cannot_measure "re-registering the worktree fixture failed"
age "$ROOT/b-worktree"
out6=$("$REAPER" --reap --yes-delete --root "$ROOT" --repo "$REPO" 2>&1)
rc_is "the second reclaim run exits clean" "$?" 0
has "the registered worktree is refused by name" "$out6" "SKIP-WORKTREE  $ROOT/b-worktree"
[ -d "$ROOT/b-worktree" ] && ok "the registered worktree still exists after a REAL reclaim" || bad "a REGISTERED WORKTREE WAS DELETED"

printf '\n== C3 THE FLOOR CAN FAIL, on the same path in the same run ==\n'
avail_gb=$(df -P -k "$TMP" 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}')
case "$avail_gb" in
'' | *[!0-9]*) cannot_measure "could not read a GiB figure from df for $TMP" ;;
esac
above=$((avail_gb + 1000))
out7=$("$REAPER" --floor "$above" "$TMP" 2>&1)
rc7=$?
rc_is "a floor above the measured free space REFUSES" "$rc7" 2
has "the refusal names the floor and the measured free space" "$out7" "BELOW the stated floor of $above GiB"
out8=$("$REAPER" --floor 0 "$TMP" 2>&1)
rc8=$?
rc_is "a floor of 0 GiB passes on the same path" "$rc8" 0
has "the pass is worded differently from the refusal" "$out8" "FLOOR OK"
if [ "$rc7" = "$rc8" ]; then
	bad "C3 the floor returned the SAME exit code for a refusal and a pass — it is not distinguishable"
else
	ok "C3 refusal ($rc7) and pass ($rc8) are distinguishable by exit code alone"
fi

printf '\n== --no-entries-census drops the census WITHOUT changing the verdicts ==\n'
# The flag exists because the census is two extra full walks per root. It must
# not become a way to change what gets reaped.
out_c=$("$REAPER" --dry-run --no-entries-census --root "$ROOT" --repo "$REPO" 2>&1)
rc_is "a no-census run still exits clean" "$?" 0
has "the census is reported as skipped, not silently absent" "$out_c" "ENTRIES-BEFORE $ROOT SKIPPED"
has "and so is the after count" "$out_c" "ENTRIES-AFTER $ROOT SKIPPED"
verd_on=$(run_dry | grep -E 'WOULD-REAP|SKIP-' | sed "s/ — .*//" | sort)
verd_off=$(printf '%s\n' "$out_c" | grep -E 'WOULD-REAP|SKIP-' | sed "s/ — .*//" | sort)
if [ "$verd_on" = "$verd_off" ]; then
	ok "the per-candidate verdicts are identical with and without the census"
else
	bad "the census flag CHANGED the verdicts" "with:
$verd_on
without:
$verd_off"
fi

printf '\n== BLIND beats a false green ==\n'
out9=$("$REAPER" --dry-run --root "$TMP/does-not-exist" --repo "$REPO" 2>&1)
rc_is "a missing root is BLIND, not an empty success" "$?" 3
has "and the missing root is named" "$out9" "root is not a directory"
out10=$("$REAPER" --dry-run --repo "$REPO" 2>&1)
rc_is "a sweep with no --root is a usage refusal" "$?" 4
out11=$("$REAPER" --floor abc "$TMP" 2>&1)
rc_is "a non-numeric floor is a usage refusal" "$?" 4
out12=$("$REAPER" --dry-run --root "$TMP/a b" --repo "$REPO" 2>&1)
rc_is "a root path containing whitespace is refused rather than silently split" "$?" 4
has "and it says why" "$out12" "contains whitespace"

printf '\n%d checks, %d failures\n' "$checks" "$fails"
if [ "$fails" -ne 0 ]; then
	printf 'scratchpad-reaper.test: FAILED\n' >&2
	exit 1
fi
printf 'scratchpad-reaper.test: OK\n'
exit 0
