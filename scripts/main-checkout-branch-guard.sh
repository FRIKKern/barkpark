#!/usr/bin/env bash
#
# main-checkout-branch-guard.sh — Golden Rule 8's only possible observer.
#
# THE RULE
#
#   CLAUDE.md Golden Rule 8: "The main checkout stays on `main` — ALWAYS."
#   Many concurrent agent sessions share one working copy of this repo. A
#   branch switch there carries every one of their uncommitted edits onto a
#   foreign branch, or silently discards them. The failure is invisible at the
#   moment it happens and unattributable an hour later.
#
# WHAT THIS CAN AND CANNOT DO — read this before trusting it
#
#   IT CANNOT REFUSE. git has no pre-checkout hook, and MEASURED on git
#   2.39.5: `git switch` moves HEAD by rewriting the symref directly, so the
#   `reference-transaction` hook — the one hook that CAN abort a ref update —
#   never fires for it (probe: an RT hook printing on every state saw the
#   `refs/heads/*` updates of `git worktree add` and saw NOTHING for a plain
#   `git switch`). And MEASURED the same way: `post-checkout` exiting 1 leaves
#   the switch DONE and `git switch` still exits 0. git documents post-checkout
#   as non-vetoing and it behaves that way.
#
#   IT CAN OBSERVE, IMMEDIATELY AND WITHOUT FALSE POSITIVES. That is the whole
#   remit: turn a silent, deniable event into a loud, timestamped one that
#   names the restore command while the reflog entry is still the top one.
#
#   CI STRUCTURALLY CANNOT SEE THIS AT ALL. A local branch switch produces no
#   push, no ref on origin, no PR. No workflow can ever observe it. This hook
#   is the only venue, which is why it is machine state (an installed hook)
#   rather than repo state (a gate).
#
# THE PREDICATE — a rule, never a list of forbidden spellings
#
#   It never reads the command line. It observes the RESULT, so `git switch`,
#   `git checkout <branch>`, `git checkout -b`, `git checkout <sha>`, an alias,
#   a wrapper, `git -C <dir> …` and a `$(…)`-built argument are all caught by
#   the same three tests, and the next spelling is caught too.
#
#     1. BRANCH CHECKOUT   post-checkout arg 3 == 1. A file checkout
#                          (`git checkout -- <path>`) passes 0 and is quiet.
#     2. PRIMARY CHECKOUT  --git-dir and --git-common-dir resolve to the SAME
#                          directory. In a linked worktree git-dir is
#                          <common>/worktrees/<name>, so every worktree — and
#                          `git worktree add`, whose post-checkout runs in the
#                          NEW worktree — is quiet. This is the arm that
#                          matters: a guard that shouts at legitimate work gets
#                          deleted, and then it guards nothing.
#     3. OFF THE BRANCH    HEAD's symref is not $BARKPARK_PROTECTED_BRANCH
#                          (default `main`). Detached HEAD has no symref and
#                          counts as off.
#
# USAGE
#
#   post-checkout hook:  main-checkout-branch-guard.sh <prev> <new> <flag>
#   ad hoc:              main-checkout-branch-guard.sh --check
#   proof:               main-checkout-branch-guard.sh --selftest
#
# EXIT CODES
#   0  quiet — not a branch checkout, not the primary checkout, or still on main
#   1  VIOLATION reported (git ignores this from post-checkout; a human does not)
#   2  usage error
#
# INSTALL — OWNER-ONLY, deliberately not automatic
#   `make hooks` (core.hooksPath=.githooks) activates .githooks/post-checkout,
#   which is a three-line shim onto this script. Shipping the file changes
#   nothing until an owner runs that.

set -uo pipefail

PROTECTED="${BARKPARK_PROTECTED_BRANCH:-main}"

usage() {
  cat <<'EOF'
usage: main-checkout-branch-guard.sh <prev_head> <new_head> <branch_flag>
       main-checkout-branch-guard.sh --check
       main-checkout-branch-guard.sh --selftest

exit: 0 quiet   1 VIOLATION reported   2 usage error
EOF
}

# is_primary_checkout — true when --git-dir and --git-common-dir name the same
# directory. Both are resolved to absolute physical paths first: git prints
# `.git` relative in the primary checkout and an absolute path in a linked
# worktree, so a raw string compare would be wrong in both directions.
is_primary_checkout() {
  local gd cd_
  gd="$(git rev-parse --git-dir 2>/dev/null)" || return 1
  cd_="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  gd="$(cd -- "$gd" 2>/dev/null && pwd -P)" || return 1
  cd_="$(cd -- "$cd_" 2>/dev/null && pwd -P)" || return 1
  [ "$gd" = "$cd_" ]
}

report_violation() {
  local prev="$1" new="$2" cur="$3" top dirty
  top="$(git rev-parse --show-toplevel 2>/dev/null || echo '<unknown>')"
  dirty="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  {
    echo
    echo "################################################################"
    echo "# GOLDEN RULE 8 VIOLATED — the primary checkout left '$PROTECTED'"
    echo "################################################################"
    echo "#   checkout : $top"
    echo "#   HEAD was : $prev"
    echo "#   HEAD now : $new  (${cur})"
    echo "#   uncommitted paths in the tree right now: $dirty"
    if [ "${dirty:-0}" != "0" ]; then
      echo "#   ^ those edits may belong to another agent's session. They were"
      echo "#     carried onto this branch, and switching back moves them again."
    fi
    echo "#"
    echo "#   Many concurrent sessions share this working copy. Get back NOW,"
    echo "#   while this is still the top reflog entry:"
    echo "#       git switch $PROTECTED"
    echo "#   Then do the work the supported way:"
    echo "#       git worktree add <dir> <branch>"
    echo "#"
    echo "#   This hook could not REFUSE the switch: git has no pre-checkout"
    echo "#   hook and ignores post-checkout's exit status. It can only tell"
    echo "#   you, immediately. See scripts/main-checkout-branch-guard.sh."
    echo "################################################################"
    echo
  } >&2
}

check() {
  local prev="${1:-}" new="${2:-}" flag="${3:-1}" cur
  [ "$flag" = "1" ] || return 0
  is_primary_checkout || return 0
  cur="$(git symbolic-ref --short -q HEAD 2>/dev/null || true)"
  [ -n "$cur" ] || cur="DETACHED HEAD"
  [ "$cur" = "$PROTECTED" ] && return 0
  report_violation "${prev:-<unknown>}" "${new:-<unknown>}" "$cur"
  return 1
}

# ── selftest ────────────────────────────────────────────────────────────────
selftest() {
  tmp=""
  local self fails=0
  self="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
  # tmp is deliberately NOT local: the EXIT trap fires outside this function's
  # scope, and a local would be unset by then (and `set -u` would abort there).
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gr8guard.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT

  local repo="$tmp/primary"
  git init -q "$repo"
  git -C "$repo" symbolic-ref HEAD "refs/heads/$PROTECTED"
  echo seed > "$repo/seed.txt"
  git -C "$repo" add seed.txt
  git -C "$repo" -c user.email=g@g -c user.name=g commit -qm seed
  git -C "$repo" branch feature

  # Install the guard as the real post-checkout hook so every arm below runs
  # through git itself, not through a hand-rolled call.
  mkdir -p "$repo/.git/hooks"
  cat > "$repo/.git/hooks/post-checkout" <<EOF
#!/bin/sh
exec "$self" "\$@"
EOF
  chmod +x "$repo/.git/hooks/post-checkout"

  local out
  _arm() { # _arm <label> <expect: FIRES|QUIET> <captured output>
    local label="$1" expect="$2" text="$3" saw
    # Substring match in the shell, NOT `printf | grep -q`: under `pipefail`
    # grep -q closes the pipe on its first hit, printf takes SIGPIPE, and the
    # pipeline returns 141 — the arm would read QUIET on the very output that
    # proves it FIRES. That inversion is the failure mode this test exists to
    # catch, so the test must not contain it.
    case "$text" in
      *"GOLDEN RULE 8 VIOLATED"*) saw=FIRES ;;
      *)                          saw=QUIET ;;
    esac
    if [ "$saw" = "$expect" ]; then
      echo "  PASS  $label  (expected $expect, got $saw)"
    else
      echo "  FAIL  $label  (expected $expect, got $saw)"
      fails=$((fails + 1))
    fi
  }

  echo "ARM (a) — the guard must FIRE on a real branch switch in the primary checkout"
  out="$( (cd "$repo" && git switch feature) 2>&1 )"
  _arm "git switch feature" FIRES "$out"
  (cd "$repo" && git switch -q "$PROTECTED") >/dev/null 2>&1
  out="$( (cd "$repo" && git checkout feature) 2>&1 )"
  _arm "git checkout feature" FIRES "$out"
  (cd "$repo" && git switch -q "$PROTECTED") >/dev/null 2>&1
  out="$( (cd "$repo" && git checkout -b spelling-nobody-listed) 2>&1 )"
  _arm "git checkout -b <new>" FIRES "$out"
  (cd "$repo" && git switch -q "$PROTECTED") >/dev/null 2>&1
  out="$( (cd "$repo" && git checkout --detach HEAD) 2>&1 )"
  _arm "detached HEAD" FIRES "$out"
  (cd "$repo" && git switch -q "$PROTECTED") >/dev/null 2>&1
  # -C from OUTSIDE the checkout: the predicate reads the result, not the argv.
  out="$(git -C "$repo" switch feature 2>&1)"
  _arm "git -C <dir> switch (argv the guard never parses)" FIRES "$out"
  git -C "$repo" switch -q "$PROTECTED" >/dev/null 2>&1

  echo "ARM (b) — the guard must stay QUIET on every legitimate path"
  out="$(git -C "$repo" worktree add "$tmp/wt-feature" feature 2>&1)"
  _arm "git worktree add (post-checkout runs in the NEW worktree)" QUIET "$out"
  out="$( (cd "$tmp/wt-feature" && git switch -c inside-a-worktree) 2>&1 )"
  _arm "branch switch INSIDE a linked worktree" QUIET "$out"
  out="$( (cd "$tmp/wt-feature" && git checkout -b another-one) 2>&1 )"
  _arm "second switch inside that worktree" QUIET "$out"
  echo dirty >> "$repo/seed.txt"
  out="$( (cd "$repo" && git checkout -- seed.txt) 2>&1 )"
  _arm "file checkout in the primary (branch_flag=0)" QUIET "$out"
  # The arm above cannot isolate the branch_flag test while HEAD is on
  # $PROTECTED — test 3 would silence it anyway, so neutering test 1 leaves it
  # green (measured). This arm puts the primary OFF $PROTECTED first, so a file
  # checkout there is quiet ONLY because branch_flag is 0. It also pins the
  # behaviour that matters to a human mid-recovery: the SWITCH alarms once, and
  # every file operation afterwards does not scream at them.
  (cd "$repo" && git switch -q feature) >/dev/null 2>&1
  echo dirty2 >> "$repo/seed.txt"
  out="$( (cd "$repo" && git checkout -- seed.txt) 2>&1 )"
  _arm "file checkout in a primary ALREADY off $PROTECTED (isolates branch_flag)" QUIET "$out"
  (cd "$repo" && git switch -q "$PROTECTED") >/dev/null 2>&1
  out="$( (cd "$repo" && git switch "$PROTECTED") 2>&1 )"
  _arm "re-checkout of $PROTECTED itself in the primary" QUIET "$out"
  out="$(git -C "$repo" clone -q . "$tmp/plainclone" 2>&1; (cd "$tmp/plainclone" && git switch -q -c x 2>&1))"
  _arm "an unrelated clone with no hook installed" QUIET "$out"

  echo
  if [ "$fails" -eq 0 ]; then
    echo "selftest: PASS — 5 refusing arms, 7 quiet arms, 0 failures"
    return 0
  fi
  echo "selftest: FAIL — $fails arm(s) wrong"
  return 1
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  --check)    check "" "" 1; exit $? ;;
  -h|--help)  usage; exit 0 ;;
  "")         usage >&2; exit 2 ;;
esac

if [ "$#" -ne 3 ]; then usage >&2; exit 2; fi
check "$1" "$2" "$3"
exit $?
