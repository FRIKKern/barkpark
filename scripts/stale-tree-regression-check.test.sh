#!/usr/bin/env bash
#
# stale-tree-regression-check.test.sh — the harness for the stale-tree detector.
#
# FULLY HERMETIC. Every probe runs against a throwaway git repository this file
# BUILDS ITSELF under $(mktemp -d). Nothing reads this repo, the network, or any
# ref that outlives the run, so no case can pass because main happened to look a
# certain way today.
#
# THE FIXTURE reproduces #15930 exactly, in four files:
#
#   c0  Y="y v1", Z="z v1"                (X does not exist yet)  ← feat cut here
#   c1  main adds X="x v1", Y→"y v2"      (the state the builder FETCHED)
#   c2  main X→"x v2", Y→"y v3"           (main kept moving after the squash)
#
#   stale = tree of c0 + feat's honest edit (Z→"z v2"), PARENT c1.
#           Built the way the trap is really sprung: commit on the old tree,
#           `git reset --soft c1`, commit again. X is absent. Y is "y v1".
#           Nothing about that commit is internally inconsistent; every test on
#           it would pass. Its diff against c1 DELETES X and REVERTS Y.
#
#   honest = c2 + feat's honest edit only. The rebuild the lead did by hand.
#
# THE CASES:
#
#   1  the #15930 shape reds, naming X on arm (a) and Y on arm (b'),
#      and NOT naming Z — the one file feat actually meant to change.
#      Both arms are asserted BY THEIR OWN WORDING, so a red from the
#      wrong arm cannot pay for a case it did not earn.
#   2  the honest rebuild is GREEN, exit 0, one OK line. Case 1 without
#      case 2 would pass for a script that reds on everything.
#   3  THE ARM-(a) BLIND SPOT, stated rather than hidden: when main has
#      NOT moved past the squash parent, `git log M..base -- X` is empty
#      and arm (a) cannot fire at all. Arm (b') still catches Y. This is
#      why the detector has two arms.
#   4  THE CONTROL / the honest false positive: a branch that LEGITIMATELY
#      deletes X, with its own commit, on top of a main that then touches X.
#      Arm (a) FIRES, and it is right to. The script cannot distinguish an
#      intentional delete from a stale-tree delete — both are exactly
#      "gone here, changed there", and the stale squash's commit "touches"
#      the path too, so authorship discriminates nothing. The case asserts
#      the red arrives on arm (a) with its "say which" sentence, which is
#      the script telling the reader it is asking a question, not passing a
#      verdict. Documented, not special-cased: an allowlist would grow until
#      it stopped discriminating.
#   5  CANNOT READ is never byte-identical to an OK: a bad base ref, a bad
#      head ref, and a non-repo each exit 2 with a CANNOT READ line and no
#      OK line. A read that did not happen must never look clean.
#   6  usage is exit 3, and distinct from both 0 and 2.
#   7  unrelated histories (no merge-base) are CANNOT READ, not GREEN.
#
#   bash scripts/stale-tree-regression-check.test.sh

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${STALE_TREE_SCRIPT:-$HERE/stale-tree-regression-check.sh}"

PASS=0
FAIL=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/stale-tree-test.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

ok() {
  PASS=$((PASS + 1))
  echo "  ok   $*"
}
bad() {
  FAIL=$((FAIL + 1))
  echo "  FAIL $*" >&2
}
section() {
  echo
  echo "-- $* --"
}

# D37: never read the exit status of `producer | grep -q`. Here-strings only.
has() { grep -qF -- "$2" <<<"$1"; }
hasnt() { ! grep -qF -- "$2" <<<"$1"; }

# ── the fixture ──────────────────────────────────────────────────────────────

FIX="$TMP/repo"
mkdir -p "$FIX"

gf() { git -C "$FIX" "$@"; }

commit_all() {
  gf add -A
  gf -c user.name=fixture -c user.email=fixture@example.invalid \
    commit -q --no-gpg-sign -m "$1"
}

build_fixture() {
  gf init -q -b main .
  gf config commit.gpgsign false

  printf 'y v1\n' >"$FIX/Y"
  printf 'z v1\n' >"$FIX/Z"
  commit_all "c0: Y and Z"
  C0="$(gf rev-parse HEAD)"

  printf 'x v1\n' >"$FIX/X"
  printf 'y v2\n' >"$FIX/Y"
  commit_all "c1: main adds X, edits Y"
  C1="$(gf rev-parse HEAD)"

  # ── the stale squash. Cut feat at c0 (the OLD tree), make the honest edit,
  # then reset --soft onto the newer main and commit. The tree never moves.
  gf checkout -q -b feat-stale "$C0"
  printf 'z v2\n' >"$FIX/Z"
  commit_all "feat: Z"
  gf reset -q --soft "$C1"
  commit_all "feat: Z (squashed onto newer main)"
  STALE="$(gf rev-parse HEAD)"

  # ── main keeps moving after the squash parent, as it did in #15930.
  gf checkout -q main
  printf 'x v2\n' >"$FIX/X"
  printf 'y v3\n' >"$FIX/Y"
  commit_all "c2: main edits X and Y again"
  C2="$(gf rev-parse HEAD)"

  # ── the honest rebuild: feat's real change, and only that, on top of c2.
  gf checkout -q -b feat-honest "$C2"
  printf 'z v2\n' >"$FIX/Z"
  commit_all "feat: Z (rebuilt on c2)"

  # ── the control: a branch that MEANS to delete X, with its own commit.
  gf checkout -q -b retire-x "$C1"
  gf rm -q "$FIX/X" 2>/dev/null || gf rm -q X
  commit_all "retire X on purpose"

  gf checkout -q main
}

build_fixture

# run <base> <head> ... -> $OUT, $RC
run() {
  OUT="$(bash "$SCRIPT" -C "$FIX" "$@" 2>&1)"
  RC=$?
}

# ── case 1: the #15930 shape ─────────────────────────────────────────────────

section "case 1 — the stale squash reds on both arms"
run main feat-stale
[ "$RC" -eq 1 ] && ok "exit 1" || bad "expected exit 1, got $RC"
if has "$OUT" "RED  X — deleted by this head"; then
  ok "arm (a) names X as deleted-here-changed-there"
else
  bad "arm (a) did not name X as a delete"
  echo "$OUT" >&2
fi
if has "$OUT" "RED  Y — reverts Y to"; then
  ok "arm (b') names Y as a revert to a pre-merge-base blob"
else
  bad "arm (b') did not name Y as a revert"
  echo "$OUT" >&2
fi
if hasnt "$OUT" "RED  Z"; then
  ok "Z — the file feat actually meant to change — is NOT named"
else
  bad "Z was named; the honest edit must not be a finding"
fi
if hasnt "$OUT" "OK   "; then ok "no OK line on a red run"; else bad "printed an OK line while red"; fi

# ── case 2: the honest rebuild ───────────────────────────────────────────────

section "case 2 — the honest rebuild is green"
run main feat-honest
[ "$RC" -eq 0 ] && ok "exit 0" || {
  bad "expected exit 0, got $RC"
  echo "$OUT" >&2
}
has "$OUT" "OK   no stale-tree regression" && ok "one OK line" || bad "no OK line"
hasnt "$OUT" "RED" && ok "no RED line" || bad "a RED line on the honest rebuild"

# ── case 3: arm (a) is blind when the base has not moved past the squash ──────

section "case 3 — base still AT the squash parent: arm (a) cannot fire, (b') does"
run "$C1" feat-stale
[ "$RC" -eq 1 ] && ok "still exit 1" || bad "expected exit 1, got $RC"
if hasnt "$OUT" "deleted by this head"; then
  ok "arm (a) is silent — 'git log M..base -- X' is empty by construction"
else
  bad "arm (a) fired with nothing on the base after the merge-base"
fi
has "$OUT" "RED  Y — reverts Y to" && ok "arm (b') carries the case alone" ||
  bad "arm (b') missed Y; with (a) blind, the whole shape would ship"

# ── case 4: the control — a legitimate delete ────────────────────────────────

section "case 4 — CONTROL: an intentional delete reds on arm (a), and should"
gf checkout -q main
printf 'x v3\n' >"$FIX/X"
commit_all "c3: main edits X again"
run main retire-x
[ "$RC" -eq 1 ] && ok "exit 1 — this is the documented false positive" ||
  bad "expected exit 1, got $RC"
if has "$OUT" "RED  X — deleted by this head"; then
  ok "arm (a) fires, and names X"
else
  bad "arm (a) did not fire on the control"
fi
if has "$OUT" "say which"; then
  ok "the line asks a question ('say which') rather than passing a verdict — this is how the script tells the two apart: it does not, the reader does"
else
  bad "the arm-(a) line does not ask the reader to say which"
fi
if hasnt "$OUT" "reverts X"; then
  ok "arm (b') stays out of it — X is deleted here, not reverted"
else
  bad "arm (b') claimed a revert on a deleted path"
fi

# ── case 5: a read that did not happen is never an OK ─────────────────────────

section "case 5 — CANNOT READ is exit 2 and never looks clean"
run no-such-base feat-stale
[ "$RC" -eq 2 ] && ok "bad base ref: exit 2" || bad "bad base ref: expected 2, got $RC"
has "$OUT" "CANNOT READ" && ok "bad base ref: names the failed read" || bad "no CANNOT READ line"
hasnt "$OUT" "OK   " && ok "bad base ref: no OK line" || bad "a failed read printed an OK line"

run main no-such-head
[ "$RC" -eq 2 ] && ok "bad head ref: exit 2" || bad "bad head ref: expected 2, got $RC"
has "$OUT" "CANNOT READ" && ok "bad head ref: names the failed read" || bad "no CANNOT READ line"

OUT="$(bash "$SCRIPT" -C "$TMP/not-a-repo" main 2>&1)"
RC=$?
[ "$RC" -eq 2 ] && ok "non-repo: exit 2" || bad "non-repo: expected 2, got $RC"
has "$OUT" "CANNOT READ" && ok "non-repo: names the failed read" || bad "no CANNOT READ line"

# ── case 6: usage ────────────────────────────────────────────────────────────

section "case 6 — usage is 3, distinct from 0 and 2"
OUT="$(bash "$SCRIPT" -C "$FIX" 2>&1)"
RC=$?
[ "$RC" -eq 3 ] && ok "no args: exit 3" || bad "no args: expected 3, got $RC"
OUT="$(bash "$SCRIPT" -C "$FIX" main HEAD extra 2>&1)"
RC=$?
[ "$RC" -eq 3 ] && ok "too many args: exit 3" || bad "too many args: expected 3, got $RC"

# ── case 7: unrelated histories ──────────────────────────────────────────────

section "case 7 — no merge-base is CANNOT READ, not GREEN"
gf checkout -q --orphan orphan
gf rm -q -rf . >/dev/null 2>&1 || true
printf 'unrelated\n' >"$FIX/W"
commit_all "orphan root"
gf checkout -q main
run main orphan
[ "$RC" -eq 2 ] && ok "exit 2" || bad "expected exit 2, got $RC"
has "$OUT" "CANNOT READ" && ok "names the missing merge-base" || bad "no CANNOT READ line"

# ── verdict ──────────────────────────────────────────────────────────────────

echo
echo "stale-tree-regression-check: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
