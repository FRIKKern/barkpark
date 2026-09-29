#!/usr/bin/env bash
#
# stranded-worktree-report.sh — find work that is stranded, which is exactly
# the work every git-based sweep is blind to.
#
# THE RULE THIS ENFORCES
#
#   UNCOMMITTED WORK IS THE ONLY KIND THAT CAN BE STRANDED, AND IT IS THE ONLY
#   KIND git grep CANNOT SEE.
#
#   Two surveyors once disagreed about whether a piece of work existed. Both
#   were honest. A filesystem grep across every worktree found exactly one hit;
#   `git grep` at the same branch found ZERO — because the work was an
#   uncommitted diff, and `git grep <pattern> <rev>` reads a COMMITTED TREE.
#   The zero was a true statement about the wrong corpus.
#
#   That generalises, and sharply: an agent sweeping worktrees for stranded
#   work with any git-based tool will SYSTEMATICALLY MISS precisely the work
#   that is stranded. Its blind spot is congruent with its target.
#
#   scripts/stranded-branch-report.sh is the sibling of this script and does
#   NOT cover this case by construction: it classifies BRANCHES, and stranded
#   work has no branch. Run both. They sweep disjoint corpora.
#
# THE THREE CORPORA, AND WHO READS THEM
#
#   corpus                     git grep <rev>   git grep (no rev)   THIS SCRIPT
#   ------------------------   --------------   -----------------   -----------
#   committed tree                  YES               YES               n/a
#   modified tracked file, WIP      no           yes, but only in       YES
#                                                 THAT worktree
#   untracked file                  no                 no               YES
#
#   Row 2's qualifier is the whole trap: `git grep` with no rev reads the
#   working tree of the worktree you are STANDING IN. A sweep run from the
#   primary checkout reads the primary checkout's files and nothing else, so
#   every other worktree's WIP is invisible to it with no error and no warning.
#
# WHAT IT REPORTS
#
#   STATES: CLEAN · DIRTY (real uncommitted work) · TRIVIAL (under --min-lines)
#   · GUTTED (deletions only, nothing added — a worktree whose contents were
#   removed without `git worktree remove`; not work, and not capturable) ·
#   MISSING / UNREADABLE (the sweep is incomplete and says so).
#
#   One row per registered worktree, with the diffstat of what is uncommitted:
#   tracked files changed, untracked files, and the +ins/-del of the tracked
#   delta against HEAD. A worktree is DIRTY when `git status --porcelain` is
#   non-empty. Rows under --min-lines are still printed, marked TRIVIAL.
#
# THE SECOND CORPUS: THE SHARED STASH STACK
#
#   `git stash` and `git stash pop` operate on ONE STACK PER REPOSITORY, not
#   per worktree. The stack lives at $GIT_COMMON_DIR/refs/stash — the COMMON
#   dir, which every linked worktree of a clone shares; only HEAD, the index
#   and a handful of per-worktree refs live under .git/worktrees/<name>/.
#   So `git stash` in worktree A pushes onto the same stack `git stash pop` in
#   worktree B pops from, and a BARE pop in B takes whatever is on top —
#   which, with dozens of concurrent worktrees, is routinely A's entry.
#
#   That is not a hypothesis. This repo's stack carries entries labelled
#   MISPOP-RECOVERY: a builder found foreign files in its tree after a bare
#   pop, stashed them back, and wrote down what happened. Verbatim, entry
#   stash@{2026-08-18 20:37:50}:
#
#     "MISPOP-RECOVERY: foreign js/packages/core/src/transport.ts (readBodyText
#      body-text error-taxonomy + abort passthrough) accidentally popped into
#      jscc-s2 builder worktree wf_4545d2ab-396-25 via shared stash-stack race;
#      ORIGINAL STASH DROPPED BY MY POP - reclaim me, owner is a concurrent
#      @barkpark/core transport slice"
#
#   READ THE CAPITALISED CLAUSE. For that entry, and for others like it, THIS
#   STACK IS NOT A BACKUP OF THE WORK — IT IS THE WORK. `git stash pop` DROPS
#   the entry it applies; when the applying worktree was the wrong one, the
#   only surviving copy is the recovery stash the mis-popper pushed back. A
#   reader who assumes these are duplicates will treat a failed reclaim as
#   harmless. It is not. See NO DISPOSAL, below.
#
#   ONE CORRECTION TO THE RECORD, measured 2026-09-23 by reading all eight
#   MISPOP messages rather than a summary of them: EXACTLY ONE of the eight
#   says in words that the original was dropped, not three. The stronger
#   claim is nonetheless the MECHANISM's, not any message's — a successful
#   `pop` drops what it applied, so every mispop consumed its original, and
#   the eight are sole copies whether or not their authors wrote it down.
#   The one documented exception cuts the other way: stash@{...} for worktree
#   wf_3bd767e4-776-36 records "a copy also lives at scratchpad/
#   foreign-tasks-controller-mispop.patch" — a scratchpad path, on one
#   machine, which is a weaker guarantee than the stack it is offered as an
#   alternative to. The SOLE-COPY count printed by this script is therefore a
#   FLOOR: it counts only the rows that SAY SO. Treat every MISPOP row as a
#   sole copy until its owner says otherwise.
#
#   WHERE A BARE STASH IS STILL REACHABLE IN THIS FLEET (swept on 2026-09-23):
#     - tooling/grip/screen.mjs:562 ALLOWS ONLY `git stash list`; every other
#       stash subcommand is refused ("git stash may only be used as
#       `git stash list`"). Agent git traffic routed through grip is screened.
#     - scripts/local-update.sh:91 PRINTS `git stash push -u -m "<your-tag>"`
#       as advice to a human with a dirty tree. It is a push, not a pop, and
#       it insists on a unique tag precisely so the entry can be found again;
#       the script itself dropped --autostash for this reason. The stack's
#       2026-09-05 "autostash" entry is residue of the older behaviour.
#     - .claude/skills/orchestrate-tasks/LEAD-BRIEF.md:215 and
#       .claude/workflows/ci-gate-script-integrity-charter.md:164 forbid it
#       in prose.
#   So the remaining exposure is MANUAL: a human, or an agent whose git calls
#   do not go through grip, typing `git stash pop` in a worktree.
#
#   THIS SCRIPT READS THAT STACK AND NEVER WRITES TO IT. Every entry is
#   reported with its date, the branch/worktree its message records, and its
#   tracked diffstat. The stack section does NOT affect the exit code: a
#   non-empty stack is a standing condition of this repo, not a fresh failure,
#   and flipping the exit on it would train every caller to ignore the exit.
#
# NO DISPOSAL, AND THE RECLAIM PROCEDURE
#
#   This script never runs `git stash drop`, `git stash clear`, `git stash
#   pop`, or `git stash push`. Not in the report, not in --capture, not in the
#   selftest against a real repo. To reclaim an entry WITHOUT popping it:
#
#     1. Read it:        git stash show -p 'stash@{N}'
#     2. Anchor it:      git branch reclaim/<name> "$(git rev-parse 'stash@{N}')"
#        A stash entry IS a commit; branching it is a pure ref write, it does
#        not touch any worktree, and the anchored branch survives gc and the
#        entry's eventual removal.
#     3. Apply it where it belongs, in that worktree only:
#                        git stash apply 'stash@{N}'      # APPLY, never POP
#        `apply` leaves the entry on the stack; `pop` drops it on success and
#        that drop is what created the MISPOP entries above.
#     4. Only once step 2's branch exists AND its owner has confirmed, is any
#        disposal even discussable — and then as a separate, authorised step
#        in the shape the harness-debris disposal uses: an explicit allow-list
#        of ids that REFUSES every id not on it. Nothing in this repo has that
#        allow-list today, so today the answer is: drop nothing.
#
# THE CAPTURE RECIPE (--capture), AND WHAT IT CANNOT DO
#
#   `git stash create` writes a commit object from the dirty state and prints
#   its sha WITHOUT touching the working tree and WITHOUT pushing onto the
#   stash reflog. `git branch <name> <that sha>` then anchors it so it survives
#   gc. The dirty worktree is left exactly as found — that is asserted by the
#   selftest, not assumed.
#
#   BUT: `git stash create` captures TRACKED modifications ONLY. A file that
#   was never `git add`-ed is NOT in the created commit. This script says so
#   per worktree instead of letting you believe otherwise: any worktree with
#   untracked files gets an UNANCHORED line naming them. Anchoring those is an
#   owner decision (git add -N then re-capture, or copy them out); this script
#   will not `git add` in a worktree it does not own.
#
# WHAT THIS SCRIPT WILL NEVER DO
#
#   It never modifies a worktree's working tree, index, or checked-out branch.
#   There is no --prune, no --delete, no stash POP, no stash DROP, no stash
#   CLEAR, no stash PUSH, no reset, no clean, and no `git add`. The single
#   write path is --capture, which creates ref objects only. Many sessions
#   share these worktrees AND one stash stack; a sweep that tidied either
#   would destroy the very work it was written to find.
#
# USAGE
#
#   scripts/stranded-worktree-report.sh [options]
#
#     --repo <path>       repository whose worktrees to enumerate.
#                         Default: the repo containing $PWD.
#     --min-lines <N>     changed-line floor below which a dirty worktree is
#                         marked TRIVIAL rather than counted. Default 1.
#     --capture <prefix>  for each DIRTY worktree, anchor its tracked delta on
#                         branch <prefix>/<worktree-basename>-<utc stamp>.
#                         Non-destructive; see above.
#     --format table|tsv  default table. tsv emits the worktree table, then a
#                         blank line, then the stash-stack table.
#     --no-stash          skip the shared-stash-stack corpus (worktrees only).
#     --stash-only        report ONLY the shared stash stack. On a clone with
#                         ~1350 registered worktrees the worktree sweep costs
#                         minutes; the stash corpus costs one `stash list` and
#                         one `stash show` per entry. Exit is always 0: this
#                         mode makes no claim about worktrees.
#     --selftest          run the hermetic fixture suite and exit.
#
# EXIT CODES
#   0  report produced, no worktree dirty at or above --min-lines
#      (or the selftest passed)
#   1  at least one worktree carries uncommitted work at or above --min-lines
#      — i.e. stranded work EXISTS and nothing else in the toolchain sees it.
#      Also the selftest's failure code.
#   2  usage error
#   3  a registered worktree path is missing or unreadable, so the sweep is
#      INCOMPLETE and its "none found" cannot be trusted
#
#   The stash-stack corpus never sets an exit code; see above for why.
#
set -uo pipefail

REPO=""
MIN_LINES=1
CAPTURE=""
FORMAT="table"
SELFTEST=0
NO_STASH=0
STASH_ONLY=0

die() { printf 'stranded-worktree-report: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      [ $# -ge 2 ] || die "--repo needs a path";     REPO="$2"; shift 2 ;;
    --min-lines) [ $# -ge 2 ] || die "--min-lines needs a number"; MIN_LINES="$2"; shift 2 ;;
    --capture)   [ $# -ge 2 ] || die "--capture needs a branch prefix"; CAPTURE="$2"; shift 2 ;;
    --format)    [ $# -ge 2 ] || die "--format needs a value";  FORMAT="$2"; shift 2 ;;
    --no-stash)  NO_STASH=1; shift ;;
    --stash-only) STASH_ONLY=1; shift ;;
    --selftest)  SELFTEST=1; shift ;;
    -h|--help)   sed -n '2,190p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$FORMAT" in table|tsv) ;; *) die "--format must be table or tsv (got '$FORMAT')" ;; esac
case "$MIN_LINES" in ''|*[!0-9]*) die "--min-lines must be a non-negative integer (got '$MIN_LINES')" ;; esac

# ------------------------------------------------------------ worktree stream
#
# `git worktree list --porcelain` emits one blank-line-separated block per
# worktree, main checkout INCLUDED. Parsed as a stream: nothing here builds an
# array of worktrees, because the fault this script exists to prevent is
# exactly a hand-maintained enumeration going stale.
emit_worktrees() {
  local wt="" br="" line
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) wt="${line#worktree }"; br="(detached)" ;;
      branch\ *)   br="${line#branch refs/heads/}" ;;
      bare)        br="(bare)" ;;
      '')          [ -n "$wt" ] && printf '%s\t%s\n' "$wt" "$br"; wt=""; br="" ;;
    esac
  done
  [ -n "$wt" ] && printf '%s\t%s\n' "$wt" "$br"
  return 0
}

# ------------------------------------------------- the shared stash corpus
#
# READ-ONLY, BY CONSTRUCTION. The only stash subcommands here are `stash list`
# and `stash show`, neither of which writes a ref, an object or a working
# tree. There is deliberately no code path in this file that can push, pop,
# drop or clear.
#
# Entries are addressed by COMMIT SHA, not by `stash@{N}` text: `%gd` renders
# as `stash@{<date>}` rather than `stash@{0}` whenever a date format is in
# effect (--date, or the repo's log.date config), and a selector we parsed out
# of someone's config is a selector we do not control. The index printed
# beside each row is counted here, in `git stash list` order, which IS the
# stack order.
report_stash_corpus() {
  local repo="$1" fmt="$2"
  local list
  list="$(git -C "$repo" stash list --format='%H%x09%cI%x09%gs' 2>/dev/null)"

  local n=0 mispop=0 solecopy=0 reclaim=0 unknown=0
  local oldest="" newest="" rows=""
  local sha iso msg
  while IFS=$'\t' read -r sha iso msg; do
    [ -n "$sha" ] || continue
    local idx="stash@{$n}"
    n=$((n + 1))
    [ -n "$newest" ] || newest="${iso%%T*}"
    oldest="${iso%%T*}"

    # The message records where the entry was taken from: "WIP on <branch>",
    # "On <branch>", "On worktree-<id>". On a SHARED stack that recorded name
    # is frequently the only surviving hint of who owns the work.
    local where="${msg%%:*}"
    case "$where" in
      "WIP on "*) where="${where#WIP on }" ;;
      "On "*)     where="${where#On }" ;;
      *)          where="(unrecorded)" ;;
    esac

    # `stash show --numstat` reports the TRACKED delta only, exactly as
    # `stash create` captures only tracked modifications. An entry pushed with
    # -u carries untracked files in a third parent that this diffstat does not
    # count; the row is a floor, not a total.
    local files=0 ins=0 del=0 a b rest
    while IFS=$'\t' read -r a b rest; do
      [ -n "$rest" ] || continue
      case "$a" in ''|*[!0-9]*) a=0 ;; esac
      case "$b" in ''|*[!0-9]*) b=0 ;; esac
      files=$((files + 1)); ins=$((ins + a)); del=$((del + b))
    done <<< "$(git -C "$repo" stash show --numstat "$sha" 2>/dev/null)"

    # CLASS is the row's most urgent label, and SOLE-COPY outranks MISPOP:
    # a MISPOP entry whose message records that the ORIGINAL was dropped by
    # the pop has no other copy anywhere, and that is the fact a reader must
    # see first. The COUNTERS are independent — such a row is counted in both
    # totals — so "8 MISPOP · 1 SOLE-COPY" is not a partition and does not
    # add up to the entry count.
    local class="WIP"
    case "$msg" in *MISPOP-RECOVERY*) class="MISPOP"; mispop=$((mispop + 1)) ;; esac
    case "$msg" in *"dropped by"*) class="SOLE-COPY"; solecopy=$((solecopy + 1)) ;; esac
    case "$msg" in *"reclaim me"*)   reclaim=$((reclaim + 1)) ;; esac
    case "$msg" in *"owner unknown"*) unknown=$((unknown + 1)) ;; esac

    # Real TABs, not the two-character "\t": bash does not expand escapes in
    # a double-quoted string, and a literal backslash-t here would make every
    # field of every row read back as one blob and print empty.
    local T=$'\t'
    rows="${rows}${class}${T}${idx}${T}${sha}${T}${iso}${T}${where}${T}${files}${T}${ins}${T}${del}${T}${msg}"$'\n'
  done <<< "$list"

  if [ "$fmt" = "tsv" ]; then
    printf '\n'
    printf 'class\tstash\tsha\twhen\twhere\tfiles\tins\tdel\tmessage\n'
    printf '%s' "$rows"
    return 0
  fi

  printf '\nSHARED STASH STACK — ONE STACK PER REPOSITORY, shared by every worktree of this clone.\n'
  if [ "$n" -eq 0 ]; then
    # THE NEGATIVE ANSWER. A reporter never seen to say zero cannot be
    # trusted when it says a number; --selftest drives this branch on an
    # empty-stack fixture and the populated branch on a non-empty one.
    printf 'STASH STACK: EMPTY — 0 entries.\n'
    return 0
  fi
  printf '%d entries: %d MISPOP · %d SOLE-COPY (original dropped by the pop) · %d say "reclaim me" · %d say "owner unknown"\n' \
    "$n" "$mispop" "$solecopy" "$reclaim" "$unknown"
  if [ "$mispop" -gt 0 ]; then
    printf 'SOLE-COPY is a FLOOR: it counts rows that SAY SO. A successful `pop` DROPS what it\n'
    printf 'applied, so every MISPOP row consumed its original — assume sole copy until an owner\n'
    printf 'says otherwise. These classes overlap and do not partition the %d entries.\n' "$n"
  fi
  printf 'oldest %s · newest %s. `git grep` cannot see ANY of these: a stash is not in any branch.\n' "$oldest" "$newest"
  if [ "$solecopy" -gt 0 ]; then
    printf 'FOR THE SOLE-COPY ROWS THIS STACK IS NOT A BACKUP OF THE WORK — IT IS THE WORK.\n'
    printf 'Their own messages say the ORIGINAL was dropped by the pop that took it. Reclaim with\n'
    printf '`git branch` + `git stash apply`; NEVER `pop`. Procedure: this file, NO DISPOSAL section.\n'
  fi
  printf '\n%-10s %-11s %-11s %-7s %-6s %-6s %s\n' 'CLASS' 'STASH' 'WHEN' 'FILES' '+INS' '-DEL' 'WHERE'
  local c i h w wh f a d m
  while IFS=$'\t' read -r c i h w wh f a d m; do
    [ -n "$c" ] || continue
    printf '%-10s %-11s %-11s %-7s %-6s %-6s %s\n' "$c" "$i" "${w%%T*}" "$f" "$a" "$d" "$wh"
    # The message is printed IN FULL, never truncated: for the MISPOP rows the
    # message is the entire provenance record, and a clipped one loses the
    # clause that says the original was dropped.
    printf '           %s\n' "$m"
  done <<< "$rows"
  return 0
}

run_report() {
  local gitdir_probe
  if [ -n "$REPO" ]; then
    [ -d "$REPO" ] || { printf 'stranded-worktree-report: --repo path does not exist: %s\n' "$REPO" >&2; return 2; }
    gitdir_probe="$REPO"
  else
    gitdir_probe="$PWD"
  fi
  git -C "$gitdir_probe" rev-parse --git-dir >/dev/null 2>&1 || {
    printf 'stranded-worktree-report: not a git repository: %s\n' "$gitdir_probe" >&2; return 2; }

  local stamp; stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local wt_list; wt_list="$(git -C "$gitdir_probe" worktree list --porcelain 2>/dev/null | emit_worktrees)"

  local total=0 dirty=0 trivial=0 gutted=0 unreadable=0
  local rows="" notes=""

  local wt br
  while IFS=$'\t' read -r wt br; do
    [ -n "$wt" ] || continue
    total=$((total + 1))
    if [ ! -d "$wt" ]; then
      unreadable=$((unreadable + 1))
      rows="${rows}MISSING	${wt}	${br}	-	-	-	-"$'\n'
      notes="${notes}  MISSING     ${wt} — registered but absent; run \`git worktree prune\` or restore it. The sweep is INCOMPLETE."$'\n'
      continue
    fi
    local st
    st="$(git -C "$wt" status --porcelain 2>/dev/null)"
    if [ $? -ne 0 ]; then
      unreadable=$((unreadable + 1))
      rows="${rows}UNREADABLE	${wt}	${br}	-	-	-	-"$'\n'
      notes="${notes}  UNREADABLE  ${wt} — git status failed here. The sweep is INCOMPLETE."$'\n'
      continue
    fi
    if [ -z "$st" ]; then
      rows="${rows}CLEAN	${wt}	${br}	0	0	0	0"$'\n'
      continue
    fi

    # tracked vs untracked, counted from the porcelain stream itself
    local tracked untracked
    tracked="$(printf '%s\n' "$st" | grep -cv '^??' || true)"
    untracked="$(printf '%s\n' "$st" | grep -c '^??' || true)"

    # tracked delta vs HEAD, staged and unstaged together
    local ins=0 del=0 a b rest
    while IFS=$'\t' read -r a b rest; do
      case "$a" in ''|*[!0-9]*) a=0 ;; esac
      case "$b" in ''|*[!0-9]*) b=0 ;; esac
      ins=$((ins + a)); del=$((del + b))
    done <<< "$(git -C "$wt" diff --numstat HEAD 2>/dev/null)"

    local changed=$((ins + del))
    local state="DIRTY"
    if [ "$ins" -eq 0 ] && [ "$untracked" -eq 0 ] && [ "$del" -gt 0 ]; then
      # DELETIONS ONLY, NOTHING ADDED. Measured on a live machine: 1350
      # worktrees, and the largest "dirty" rows by diffstat were gutted
      # directories — 7597 files, 1.7M deleted lines, zero insertions —
      # i.e. somebody removed a worktree's CONTENTS without `git worktree
      # remove`. Counting those as stranded work is how a real 24-row
      # finding drowns in 400 rows of nothing. Nobody wrote this delta, so
      # nobody can lose it.
      state="GUTTED"; gutted=$((gutted + 1))
    elif [ "$changed" -lt "$MIN_LINES" ] && [ "$untracked" -eq 0 ]; then
      state="TRIVIAL"; trivial=$((trivial + 1))
    else
      dirty=$((dirty + 1))
    fi
    rows="${rows}${state}	${wt}	${br}	${tracked}	${untracked}	${ins}	${del}"$'\n'

    if [ "$untracked" -gt 0 ]; then
      local names
      names="$(printf '%s\n' "$st" | sed -n 's/^?? //p' | tr '\n' ' ')"
      notes="${notes}  UNANCHORED  ${wt} — ${untracked} untracked file(s) \`git stash create\` will NOT capture: ${names}"$'\n'
    fi

    if [ -n "$CAPTURE" ] && [ "$state" = "DIRTY" ]; then
      local sha; sha="$(git -C "$wt" stash create 2>/dev/null)"
      if [ -n "$sha" ]; then
        local bn; bn="$(basename "$wt")"
        local cb="${CAPTURE}/${bn}-${stamp}"
        if git -C "$wt" branch "$cb" "$sha" >/dev/null 2>&1; then
          notes="${notes}  CAPTURED    ${wt} -> ${cb} (${sha})"$'\n'
        else
          notes="${notes}  CAPTURE-FAILED ${wt} — could not create branch ${cb}"$'\n'
        fi
      else
        notes="${notes}  CAPTURE-EMPTY ${wt} — \`git stash create\` produced nothing (no TRACKED modifications here)"$'\n'
      fi
    fi
  done <<< "$wt_list"

  if [ "$FORMAT" = "tsv" ]; then
    printf 'state\tworktree\tbranch\ttracked\tuntracked\tins\tdel\n'
    printf '%s' "$rows"
    [ "$NO_STASH" -eq 1 ] || report_stash_corpus "$gitdir_probe" tsv
  else
    printf 'STRANDED WORKTREE REPORT  %s\n' "$stamp"
    printf 'repo: %s   worktrees: %d   dirty: %d   trivial: %d   gutted: %d   unreadable: %d   min-lines: %d\n' \
      "$(git -C "$gitdir_probe" rev-parse --show-toplevel 2>/dev/null)" "$total" "$dirty" "$trivial" "$gutted" "$unreadable" "$MIN_LINES"
    printf '%s\n' 'git grep CANNOT see any row below that is not CLEAN. That is the point.'
    printf '\n%-10s %-9s %-9s %-7s %-6s %s\n' 'STATE' 'TRACKED' 'UNTRACK' '+INS' '-DEL' 'WORKTREE [branch]'
    local s w b t u i d
    while IFS=$'\t' read -r s w b t u i d; do
      [ -n "$s" ] || continue
      printf '%-10s %-9s %-9s %-7s %-6s %s [%s]\n' "$s" "$t" "$u" "$i" "$d" "$w" "$b"
    done <<< "$rows"
    if [ -n "$notes" ]; then printf '\nNOTES\n%s' "$notes"; fi
    [ "$NO_STASH" -eq 1 ] || report_stash_corpus "$gitdir_probe" table
    printf '\n'
    if [ "$unreadable" -gt 0 ]; then
      # An incomplete sweep must never print the reassuring sentence. The
      # selftest caught this exact line claiming a clean result over a repo
      # two of whose three worktrees it could not read.
      printf 'SWEEP INCOMPLETE: %d of %d worktree(s) could not be read (see NOTES).\n' "$unreadable" "$total"
      printf 'No conclusion about stranded work is available from this run.\n'
    elif [ "$dirty" -eq 0 ]; then
      printf 'NO STRANDED WORK FOUND in %d worktree(s).\n' "$total"
      printf 'This line is only worth believing because --selftest proves the sweep can print the other answer.\n'
    else
      printf '%d WORKTREE(S) CARRY UNCOMMITTED WORK. Nothing else in the toolchain reports them.\n' "$dirty"
      printf 'Anchor before anyone resets: scripts/stranded-worktree-report.sh --capture rescue\n'
    fi
  fi

  [ "$unreadable" -gt 0 ] && return 3
  [ "$dirty" -gt 0 ] && return 1
  return 0
}

# ------------------------------------------------------------------ selftest
#
# NON-VACUITY IS THE WHOLE POINT OF THIS SUITE. A sweep that reports "nothing
# found" when it is structurally incapable of finding anything is the exact
# failure mode this script was written against, so the fixture drives it
# through BOTH answers — first clean, then dirty — and asserts each.
selftest() {
  local SCRIPT="${BASH_SOURCE[0]}"
  local fails=0 tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/swr-selftest.XXXXXX")" || { echo "mktemp failed"; return 1; }

  local TOKEN="STRANDEDTOKEN_ZQX7"
  local UTOKEN="UNTRACKEDTOKEN_ZQX7"

  # --- fixture: a repo with one committed file and two extra worktrees
  (
    set -e
    cd "$tmp"
    git init -q base
    cd base
    git config user.email s@t.test; git config user.name s
    git config commit.gpgsign false
    printf 'committed line\n' > kept.txt
    git add kept.txt
    git commit -qm init
    git branch wip
    git branch idle
    git worktree add -q "$tmp/wt-wip" wip
    git worktree add -q "$tmp/wt-idle" idle
  ) >/dev/null 2>&1 || { echo "  FAIL  fixture setup"; rm -rf "$tmp"; return 1; }

  ck() { # ck <label> <regex> <file>
    if grep -Eq "$2" "$3"; then echo "  PASS  $1"
    else echo "  FAIL  $1"; fails=$((fails + 1)); fi
  }
  ckn() { # ckn <label> <regex> <file>  — must NOT match
    if grep -Eq "$2" "$3"; then echo "  FAIL  $1"; fails=$((fails + 1))
    else echo "  PASS  $1"; fi
  }

  echo "selftest: stranded-worktree-report"
  echo "--- STATE A: no dirty worktrees ---"

  local outA rcA
  outA="$tmp/outA.txt"
  bash "$SCRIPT" --repo "$tmp/base" > "$outA" 2>&1; rcA=$?
  # 1. clean state reports none, and says so in words
  ck "A: reports NO STRANDED WORK FOUND when nothing is dirty" 'NO STRANDED WORK FOUND in 3 worktree' "$outA"
  # 2. and exits 0 — the negative answer has its own exit code
  if [ "$rcA" -eq 0 ]; then echo "  PASS  A: exit 0 on a clean sweep"
  else echo "  FAIL  A: expected exit 0, got $rcA"; fails=$((fails + 1)); fi
  # 3. all three worktrees were actually VISITED — a sweep that enumerated
  #    nothing would also print "none found", which is the vacuous failure
  ck "A: enumerates the main checkout too" 'CLEAN .*/base \[' "$outA"
  ck "A: enumerates wt-wip"  'CLEAN .*/wt-wip \[wip\]'  "$outA"
  ck "A: enumerates wt-idle" 'CLEAN .*/wt-idle \[idle\]' "$outA"
  # 3b. THE STASH REPORTER'S NEGATIVE ANSWER. The base fixture's stack is
  #     empty, and the reporter says so in words. Arm G drives the SAME code
  #     over a populated stack. A reporter that has only ever been seen to
  #     print one of those two answers is not evidence for either.
  ck "A: stash reporter prints the EMPTY answer on an empty stack" 'STASH STACK: EMPTY .* 0 entries' "$outA"

  echo "--- STATE B: one deliberately dirty worktree ---"

  # a MODIFIED TRACKED file and an UNTRACKED file: the two shapes of stranding
  printf '%s\n' "$TOKEN" >> "$tmp/wt-wip/kept.txt"
  printf '%s\n' "$UTOKEN" > "$tmp/wt-wip/never-added.txt"

  local outB rcB
  outB="$tmp/outB.txt"
  bash "$SCRIPT" --repo "$tmp/base" > "$outB" 2>&1; rcB=$?
  # 4. the SAME instrument now prints the other answer
  ck "B: reports wt-wip DIRTY" '^DIRTY .*/wt-wip \[wip\]' "$outB"
  ck "B: headline counts the dirty worktree" '1 WORKTREE\(S\) CARRY UNCOMMITTED WORK' "$outB"
  # 5. and the exit code flips
  if [ "$rcB" -eq 1 ]; then echo "  PASS  B: exit 1 when stranded work exists"
  else echo "  FAIL  B: expected exit 1, got $rcB"; fails=$((fails + 1)); fi
  # 6. the clean siblings stay clean — the report discriminates, it does not
  #    simply flip every row once anything anywhere is dirty
  ck "B: wt-idle still CLEAN (the report discriminates)" '^CLEAN .*/wt-idle \[idle\]' "$outB"
  # 7. untracked files are named as UNANCHORED, not silently folded in
  ck "B: names the untracked file stash-create cannot capture" 'UNANCHORED .*never-added.txt' "$outB"

  echo "--- CONTROL: git grep cannot see any of it ---"

  # 8. the exact fault from the field: git grep AT A REV reads a committed tree
  local g1
  g1="$(git -C "$tmp/base" grep -l "$TOKEN" wip 2>&1)"
  if [ -z "$g1" ]; then echo "  PASS  C: \`git grep <token> wip\` finds NOTHING (committed tree)"
  else echo "  FAIL  C: git grep at rev unexpectedly found: $g1"; fails=$((fails + 1)); fi
  # 9. git grep with no rev reads only the worktree you STAND IN
  local g2
  g2="$(git -C "$tmp/wt-idle" grep -l "$TOKEN" 2>&1)"
  if [ -z "$g2" ]; then echo "  PASS  C: \`git grep <token>\` from a SIBLING worktree finds NOTHING"
  else echo "  FAIL  C: sibling-worktree git grep found: $g2"; fails=$((fails + 1)); fi
  # 10. an untracked file is invisible to git grep even standing IN its worktree
  local g3
  g3="$(git -C "$tmp/wt-wip" grep -l "$UTOKEN" 2>&1)"
  if [ -z "$g3" ]; then echo "  PASS  C: \`git grep <utoken>\` IN its own worktree finds NOTHING (untracked)"
  else echo "  FAIL  C: git grep found an untracked file: $g3"; fails=$((fails + 1)); fi
  # 11. the positive control — a filesystem grep DOES see it, so steps 8-10 are
  #     measuring git's corpus and not a typo in the token
  if grep -rq "$TOKEN" "$tmp/wt-wip" && grep -rq "$UTOKEN" "$tmp/wt-wip"; then
    echo "  PASS  C: a filesystem grep DOES find both tokens (the control)"
  else echo "  FAIL  C: control grep found nothing — the fixture is broken"; fails=$((fails + 1)); fi

  echo "--- CAPTURE: non-destructive, and actually anchors ---"

  local before after
  before="$(git -C "$tmp/wt-wip" status --porcelain)"
  local outC; outC="$tmp/outC.txt"
  bash "$SCRIPT" --repo "$tmp/base" --capture rescue > "$outC" 2>&1
  after="$(git -C "$tmp/wt-wip" status --porcelain)"
  # 12. THE non-destructive proof: byte-identical porcelain before and after
  if [ "$before" = "$after" ] && [ -n "$after" ]; then
    echo "  PASS  D: git status --porcelain is UNCHANGED after capture"
  else
    echo "  FAIL  D: worktree changed across capture"
    printf '    before: %s\n    after:  %s\n' "$before" "$after"; fails=$((fails + 1))
  fi
  # 13. and specifically the same dirty file is still dirty
  if grep -q 'kept.txt' <<<"$after"; then
    echo "  PASS  D: the same dirty file is still dirty afterwards"
  else echo "  FAIL  D: kept.txt no longer dirty after capture"; fails=$((fails + 1)); fi
  # 14. capture is not a no-op: the anchor branch holds the token
  local cb
  cb="$(head -1 <<<"$(git -C "$tmp/base" branch --list 'rescue/*' --format='%(refname:short)')")"
  local anchored; anchored="$(git -C "$tmp/base" show "$cb:kept.txt" 2>/dev/null)"
  if [ -n "$cb" ] && grep -q "$TOKEN" <<<"$anchored"; then
    echo "  PASS  D: the anchor branch ($cb) carries the stranded token"
  else echo "  FAIL  D: no anchor branch carrying the token"; fails=$((fails + 1)); fi
  # 15. the stash REFLOG was never touched — stash create only writes an object
  #
  #     KEEP THIS ARM. IT IS NOT SUPERSEDED BY ARM G, IT IS ARM G'S
  #     EMPTY-FIXTURE SPECIAL CASE.
  #
  #     Its intent is right and its assertion is TRUE: `stash create` writes a
  #     commit object without pushing onto the stash reflog, which is a real
  #     non-destructiveness property worth pinning. Its LIMIT is that this
  #     fixture's stack is empty by construction, so "still empty" is the
  #     identical green an instrument that CANNOT SEE A STACK AT ALL would
  #     print — the passing condition does not distinguish the property from
  #     the blindness. Arm G removes that ambiguity by running the same
  #     capture over a POPULATED stack and asserting unchanged COUNT and
  #     unchanged stash@{0} SHA, which is strictly stronger: it also rules out
  #     "pushed one entry" (which `[ -n "$(git stash list)" ]` would happily
  #     call a pass, non-emptiness being monotone in the wrong direction).
  #     Delete neither. G proves the general case; 15 pins the zero case,
  #     where "unchanged count" has the weakest possible content.
  if [ -z "$(git -C "$tmp/wt-wip" stash list)" ]; then
    echo "  PASS  D: the stash list is still empty (create, never push) [empty-stack special case of arm G]"
  else echo "  FAIL  D: capture pushed onto the stash reflog"; fails=$((fails + 1)); fi
  # 16. honesty: the untracked file did NOT make it into the anchor, and the
  #     report says so rather than implying a complete rescue
  if git -C "$tmp/base" show "$cb:never-added.txt" >/dev/null 2>&1; then
    echo "  FAIL  D: untracked file unexpectedly in the anchor — update the docs"; fails=$((fails + 1))
  else echo "  PASS  D: untracked file is NOT in the anchor, exactly as documented"; fi
  ck "D: the report names the untracked gap on the capture run" 'UNANCHORED' "$outC"

  echo "--- GUTTED: deletions-only is not stranded work ---"

  # wt-idle loses its only tracked file and gains nothing. That is somebody
  # deleting a worktree's contents, not work anyone can lose, and folding it
  # into the DIRTY count is how a real finding drowns.
  rm -f "$tmp/wt-idle/kept.txt"
  local outG rcG; outG="$tmp/outG.txt"
  bash "$SCRIPT" --repo "$tmp/base" > "$outG" 2>&1; rcG=$?
  ck "F: deletions-only worktree classifies GUTTED, not DIRTY" '^GUTTED .*/wt-idle \[idle\]' "$outG"
  ck "F: GUTTED is counted in its own bucket" 'gutted: 1' "$outG"
  # the real WIP next door is UNAFFECTED — GUTTED must not swallow it
  ck "F: the genuinely dirty worktree is still DIRTY" '^DIRTY .*/wt-wip \[wip\]' "$outG"
  ck "F: headline still counts exactly 1 worktree of real work" '1 WORKTREE\(S\) CARRY UNCOMMITTED WORK' "$outG"
  if [ "$rcG" -eq 1 ]; then echo "  PASS  F: exit still 1 (the DIRTY row alone earns it)"
  else echo "  FAIL  F: expected exit 1, got $rcG"; fails=$((fails + 1)); fi
  # and with the real WIP reverted, a GUTTED-only tree exits 0 — GUTTED never
  # manufactures a stranded-work verdict on its own
  git -C "$tmp/wt-wip" checkout -- kept.txt 2>/dev/null
  rm -f "$tmp/wt-wip/never-added.txt"
  local outH rcH; outH="$tmp/outH.txt"
  bash "$SCRIPT" --repo "$tmp/base" > "$outH" 2>&1; rcH=$?
  if [ "$rcH" -eq 0 ]; then echo "  PASS  F: a GUTTED-only sweep exits 0"
  else echo "  FAIL  F: expected exit 0 on a GUTTED-only sweep, got $rcH"; fails=$((fails + 1)); fi
  ck "F: and says NO STRANDED WORK FOUND" 'NO STRANDED WORK FOUND' "$outH"

  echo "--- G: NON-EMPTY STASH STACK is read, and is UNCHANGED across capture ---"

  # This arm needs a repo whose stash stack is POPULATED. It builds its OWN
  # throwaway repo with `git init` under the selftest's mktemp dir and stashes
  # only there. NOTHING in this suite ever pushes, pops, drops or clears
  # against a real repository's stack: that stack is shared by every worktree
  # of its clone and several of this repo's entries are the only surviving
  # copy of their work. A separate fixture also keeps arm 15's precondition
  # intact — $tmp/base's stack must stay empty for arm 15 to mean anything.
  local G="$tmp/stackbase"
  (
    set -e
    cd "$tmp"
    git init -q stackbase
    cd stackbase
    git config user.email s@t.test; git config user.name s
    git config commit.gpgsign false
    printf 'committed line\n' > kept.txt
    git add kept.txt
    git commit -qm init
    git branch stackwip
    git worktree add -q "$tmp/wt-stack" stackwip
    # two entries, one of them wearing the MISPOP shape the field produced
    printf 'first stashed edit\n' >> kept.txt
    git stash push -q -m "FIXTURE-STASH-ALPHA plain wip"
    printf 'second stashed edit\n' >> kept.txt
    git stash push -q -m "MISPOP-RECOVERY: FIXTURE-STASH-BETA foreign slice, original stash dropped by my pop - reclaim me, owner unknown"
    # and a dirty worktree so --capture has real work to do
    printf '%s\n' "STACKTOKEN_ZQX7" >> "$tmp/wt-stack/kept.txt"
  ) >/dev/null 2>&1 || { echo "  FAIL  G: fixture setup"; fails=$((fails + 1)); }

  # PRECONDITION, asserted rather than assumed: this fixture's stack really is
  # non-empty. A control says nothing if the setup it controls never happened,
  # and an "unchanged" verdict over an empty stack is arm 15, not arm G.
  local g_count_before g_top_before
  g_count_before="$(git -C "$G" stash list | wc -l | tr -d ' ')"
  g_top_before="$(git -C "$G" rev-parse 'stash@{0}' 2>/dev/null)"
  if [ "$g_count_before" -eq 2 ] && [ -n "$g_top_before" ]; then
    echo "  PASS  G: precondition — the fixture stack holds 2 entries (non-empty)"
  else
    echo "  FAIL  G: precondition — expected 2 fixture stash entries, got '$g_count_before'"; fails=$((fails + 1))
  fi

  local outI; outI="$tmp/outI.txt"
  bash "$SCRIPT" --repo "$G" --capture rescue > "$outI" 2>&1

  local g_count_after g_top_after
  g_count_after="$(git -C "$G" stash list | wc -l | tr -d ' ')"
  g_top_after="$(git -C "$G" rev-parse 'stash@{0}' 2>/dev/null)"

  # G1. THE STRONG NON-DESTRUCTIVENESS PROOF: same COUNT and same stash@{0}
  #     SHA before and after. Count alone would miss a push-then-drop; top-sha
  #     alone would miss an append below the top. Both, together, are what
  #     "did not touch the stack" means. Contrast `[ -n "$(git stash list)" ]`,
  #     which a script that PUSHED an entry also passes.
  if [ "$g_count_before" = "$g_count_after" ] && [ "$g_top_before" = "$g_top_after" ]; then
    echo "  PASS  G: stash stack UNCHANGED across capture (count $g_count_before, stash@{0} ${g_top_before:0:12})"
  else
    echo "  FAIL  G: the stash stack MOVED across capture"
    printf '    count  %s -> %s\n    top    %s -> %s\n' \
      "$g_count_before" "$g_count_after" "$g_top_before" "$g_top_after"
    fails=$((fails + 1))
  fi

  # G2. and the capture actually ran, so G1 is not vacuously green over a
  #     no-op: the anchor branch exists and carries the worktree's token.
  local gcb ganchored
  gcb="$(head -1 <<<"$(git -C "$G" branch --list 'rescue/*' --format='%(refname:short)')")"
  ganchored="$(git -C "$G" show "$gcb:kept.txt" 2>/dev/null)"
  if [ -n "$gcb" ] && grep -q "STACKTOKEN_ZQX7" <<<"$ganchored"; then
    echo "  PASS  G: the capture under test really ran (anchor $gcb carries the token)"
  else echo "  FAIL  G: no anchor branch — G1 measured a no-op"; fails=$((fails + 1)); fi

  # G3. the reporter ENUMERATES the entries it found — the whole point of the
  #     second corpus. Both fixture messages appear, in full.
  ck "G: reports the stack size"            'SHARED STASH STACK'              "$outI"
  ck "G: counts 2 entries"                  '^2 entries:'                     "$outI"
  ck "G: enumerates the ALPHA entry"        'FIXTURE-STASH-ALPHA plain wip'   "$outI"
  ck "G: enumerates the BETA entry in full" 'FIXTURE-STASH-BETA.*dropped by my pop - reclaim me, owner unknown' "$outI"
  ck "G: counts the MISPOP entry"           '^2 entries: 1 MISPOP'            "$outI"
  # SOLE-COPY outranks MISPOP on the row label; the counters are independent.
  ck "G: labels the sole-copy row SOLE-COPY" '^SOLE-COPY +stash@\{0\}'        "$outI"
  ck "G: counts the sole-copy entry"        '1 SOLE-COPY'                     "$outI"
  ck "G: labels the plain entry WIP"        '^WIP +stash@\{1\}'              "$outI"
  ck "G: says the stack IS the work"        'NOT A BACKUP OF THE WORK'        "$outI"
  ckn "G: and does NOT print the empty answer over a populated stack" 'STASH STACK: EMPTY' "$outI"

  # G3b. --stash-only reads the same stack without sweeping worktrees, and
  #      refuses to imply a worktree verdict it did not measure.
  local outK rcK; outK="$tmp/outK.txt"
  bash "$SCRIPT" --repo "$G" --stash-only > "$outK" 2>&1; rcK=$?
  ck  "G: --stash-only still enumerates the stack"   '^2 entries: 1 MISPOP'   "$outK"
  ckn "G: --stash-only claims nothing about worktrees" 'NO STRANDED WORK FOUND' "$outK"
  if [ "$rcK" -eq 0 ]; then echo "  PASS  G: --stash-only exits 0"
  else echo "  FAIL  G: --stash-only expected exit 0, got $rcK"; fails=$((fails + 1)); fi

  # G4. --no-stash still suppresses the whole section (the opt-out is real)
  local outJ; outJ="$tmp/outJ.txt"
  bash "$SCRIPT" --repo "$G" --no-stash > "$outJ" 2>&1
  ckn "G: --no-stash suppresses the stash corpus" 'SHARED STASH STACK' "$outJ"

  echo "--- INCOMPLETE SWEEP must refuse, not report 'none' ---"

  # 17. a registered-but-missing worktree makes "none found" a lie; exit 3
  rm -rf "$tmp/wt-wip" "$tmp/wt-idle"
  local outE rcE; outE="$tmp/outE.txt"
  bash "$SCRIPT" --repo "$tmp/base" > "$outE" 2>&1; rcE=$?
  ck "E: names the missing worktree" 'MISSING' "$outE"
  ckn "E: does NOT claim a clean sweep while incomplete" 'NO STRANDED WORK FOUND' "$outE"
  ck "E: says the sweep is INCOMPLETE instead" 'SWEEP INCOMPLETE: 2 of 3' "$outE"
  if [ "$rcE" -eq 3 ]; then echo "  PASS  E: exit 3 on an incomplete sweep"
  else echo "  FAIL  E: expected exit 3, got $rcE"; fails=$((fails + 1)); fi

  rm -rf "$tmp"
  if [ "$fails" -eq 0 ]; then echo "selftest: ALL PASS"; return 0; fi
  echo "selftest: $fails FAILED"; return 1
}

if [ "$SELFTEST" -eq 1 ]; then selftest; exit $?; fi

if [ "$STASH_ONLY" -eq 1 ]; then
  [ "$NO_STASH" -eq 0 ] || die "--stash-only and --no-stash contradict each other"
  probe="${REPO:-$PWD}"
  git -C "$probe" rev-parse --git-dir >/dev/null 2>&1 || {
    printf 'stranded-worktree-report: not a git repository: %s\n' "$probe" >&2; exit 2; }
  printf 'SHARED STASH STACK ONLY  %s\n' "$(date -u +%Y%m%dT%H%M%SZ)"
  printf 'repo: %s\n' "$(git -C "$probe" rev-parse --show-toplevel 2>/dev/null)"
  printf 'NO WORKTREE SWEEP RAN. This output says nothing about stranded worktrees.\n'
  report_stash_corpus "$probe" "$FORMAT"
  exit 0
fi

run_report; exit $?
