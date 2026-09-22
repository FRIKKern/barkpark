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
#   There is no --prune, no --delete, no stash POP, no reset, no clean, and no
#   `git add`. The single write path is --capture, which creates ref objects
#   only. Many sessions share these worktrees; a sweep that tidied one would
#   destroy the very work it was written to find.
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
#     --format table|tsv  default table.
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
set -uo pipefail

REPO=""
MIN_LINES=1
CAPTURE=""
FORMAT="table"
SELFTEST=0

die() { printf 'stranded-worktree-report: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)      [ $# -ge 2 ] || die "--repo needs a path";     REPO="$2"; shift 2 ;;
    --min-lines) [ $# -ge 2 ] || die "--min-lines needs a number"; MIN_LINES="$2"; shift 2 ;;
    --capture)   [ $# -ge 2 ] || die "--capture needs a branch prefix"; CAPTURE="$2"; shift 2 ;;
    --format)    [ $# -ge 2 ] || die "--format needs a value";  FORMAT="$2"; shift 2 ;;
    --selftest)  SELFTEST=1; shift ;;
    -h|--help)   sed -n '2,120p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
  if [ -z "$(git -C "$tmp/wt-wip" stash list)" ]; then
    echo "  PASS  D: the stash list is still empty (create, never push)"
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
run_report; exit $?
