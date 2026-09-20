#!/usr/bin/env bash
#
# stranded-branch-report.sh — classify every branch, and measure what resuming
# one would DESTROY.
#
# THE RULE THIS ENFORCES
#
#   A BRANCH LIST IS STALE THE HOUR IT LANDS. A PREDICATE IS NOT.
#   This script exists because a ledger row named four branches by hand, and
#   two months later every number in it was wrong: the deltas had all landed
#   on main independently, the worktrees it wanted pruned no longer existed,
#   and one of the four had never touched the file the row said it diffed.
#   Nothing was wrong with the reasoning — the enumeration had simply aged.
#   So this reports a RULE over the current refs, never a list.
#
# THE MEASUREMENT THAT MATTERS: REVERT SURFACE
#
#   "Behind by N commits" is not the hazard; it is a proxy for it. The hazard
#   is that a stale branch carries the OLD state of every file it did NOT
#   change. Resume it, merge it, or reset onto it, and those files go
#   backwards — silently, because the branch's own diff looks tiny and
#   innocent.
#
#   revert_lines = lines the BASE has that this ref does NOT
#                = deletions in `git diff --numstat <base>..<ref> -- <paths>`
#
#   That number, not the age, is the thing to be afraid of. A branch one day
#   old with revert_lines=900 is more dangerous than a branch six months old
#   with revert_lines=0.
#
# THE THREE BUCKETS — evaluated in this order, first match wins
#
#   MERGED    the ref is an ancestor of <base>. Its content is already on the
#             base by definition. Safe to CONSIDER stranded.
#   OPEN-PR   an open pull request has this ref as its head. NOT stranded, no
#             matter how old it looks. This bucket is checked BEFORE divergence
#             precisely because a live branch mid-campaign reads as diverged.
#   DIVERGED  neither of the above. This is UNKNOWN INTENT, never "abandoned".
#             The script reports it; it does not judge it.
#
#   `git cherry` adds a second, independent opinion for DIVERGED refs:
#   upstream_applied counts the ref's own commits whose patch is ALREADY on the
#   base (rewritten, squashed, or re-landed by someone else), upstream_new
#   counts those that are not. A DIVERGED ref with upstream_new=0 is work that
#   already arrived by another road.
#
# WHAT THIS SCRIPT WILL NEVER DO
#
#   It does not delete anything. It has no --prune, no --delete, no write path
#   of any kind, and it never invokes `git push`, `git branch -d/-D`, or
#   `gh api -X DELETE`. Retiring a ref is an OWNER decision made with this
#   report in hand, not an action this report takes. That is deliberate: every
#   input here is a heuristic, and the one bucket that would be catastrophic to
#   get wrong (OPEN-PR) depends on a network call that can fail.
#
# USAGE
#
#   scripts/stranded-branch-report.sh [options]
#
#     --base <ref>        comparison base. Default origin/main.
#     --refs local|remote|all
#                         which refs to classify. Default remote.
#     --pattern <glob>    only refs whose short name matches (shell glob).
#     --paths <p1,p2,..>  measure revert surface only over these paths.
#                         Default: the whole tree.
#     --no-pr             skip the `gh` call. Every ref that would have been
#                         OPEN-PR reports as DIVERGED and the header says the
#                         PR signal is MISSING — an unchecked ref is never
#                         quietly downgraded to "stranded".
#     --format table|tsv  default table.
#     --selftest          run the hermetic fixture suite and exit.
#
#   Open-PR heads may also be injected from a file (one ref name per line) via
#   STRANDED_PR_LIST_FILE. That seam is what makes the OPEN-PR bucket testable
#   without a network, and it is what --selftest drives.
#
# EXIT CODES
#   0  report produced (or selftest passed)
#   1  at least one DIVERGED ref carries revert_lines > 0 (a regression carrier
#      exists) — or the selftest failed
#   2  usage error
#   3  the PR signal could not be read and --no-pr was not given: the OPEN-PR
#      bucket is unverified, so no ref may be called stranded on this run
#
set -uo pipefail

BASE="origin/main"
REFS="remote"
PATTERN=""
PATHSPEC=""
FORMAT="table"
WANT_PR=1
SELFTEST=0

die() { printf 'stranded-branch-report: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --base)    [ $# -ge 2 ] || die "--base needs a ref";      BASE="$2"; shift 2 ;;
    --refs)    [ $# -ge 2 ] || die "--refs needs a value";    REFS="$2"; shift 2 ;;
    --pattern) [ $# -ge 2 ] || die "--pattern needs a glob";  PATTERN="$2"; shift 2 ;;
    --paths)   [ $# -ge 2 ] || die "--paths needs a list";    PATHSPEC="$2"; shift 2 ;;
    --format)  [ $# -ge 2 ] || die "--format needs a value";  FORMAT="$2"; shift 2 ;;
    --no-pr)   WANT_PR=0; shift ;;
    --selftest) SELFTEST=1; shift ;;
    -h|--help) sed -n '2,80p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$REFS" in local|remote|all) ;; *) die "--refs must be local, remote or all (got '$REFS')" ;; esac
case "$FORMAT" in table|tsv) ;; *) die "--format must be table or tsv (got '$FORMAT')" ;; esac

# ---------------------------------------------------------------- ref stream
#
# Streamed, one ref per line, never aggregated by a paginating client. The
# original investigation of this hazard undercounted because an aggregate ran
# per page; `git for-each-ref` has no pages, and everything downstream of here
# reads that stream line by line.
emit_refs() {
  case "$REFS" in
    local)  git for-each-ref --format='%(refname:short)' refs/heads/ ;;
    remote) git for-each-ref --format='%(refname:short)' refs/remotes/origin/ \
              | sed 's|^origin/||' | grep -v '^HEAD$' ;;
    all)    { git for-each-ref --format='%(refname:short)' refs/heads/
              git for-each-ref --format='%(refname:short)' refs/remotes/origin/ \
                | sed 's|^origin/||' | grep -v '^HEAD$'; } | sort -u ;;
  esac
}

# The ref name as git can resolve it, given --refs.
resolve_ref() {
  case "$REFS" in
    local)  printf 'refs/heads/%s' "$1" ;;
    remote) printf 'refs/remotes/origin/%s' "$1" ;;
    all)    if git rev-parse --verify --quiet "refs/heads/$1" >/dev/null
            then printf 'refs/heads/%s' "$1"
            else printf 'refs/remotes/origin/%s' "$1"; fi ;;
  esac
}

# ------------------------------------------------------------ open-PR lookup
#
# ONE bulk fetch into a file, then a fixed-string lookup per ref. Per-ref `gh`
# calls would be thousands of network round trips on this repo, and a rate
# limit partway through would silently reclassify live branches as stranded.
PR_FILE=""
PR_STATUS="ok"
load_pr_heads() {
  # PORTABLE mktemp (explicit path + XXXXXX): `-t NAME` without XXXXXX is BSD-only.
  PR_FILE="$(mktemp "${TMPDIR:-/tmp}/strandedpr.XXXXXX")" || die "mktemp failed"
  if [ -n "${STRANDED_PR_LIST_FILE:-}" ]; then
    if [ ! -f "$STRANDED_PR_LIST_FILE" ]; then PR_STATUS="missing"; return 1; fi
    cat "$STRANDED_PR_LIST_FILE" > "$PR_FILE"
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then PR_STATUS="no-gh"; return 1; fi
  # Exit status is read on gh itself, never through a pipe.
  local raw
  raw="$(gh pr list --state open --limit 1000 --json headRefName -q '.[].headRefName' 2>/dev/null)"
  if [ $? -ne 0 ]; then PR_STATUS="gh-failed"; return 1; fi
  printf '%s\n' "$raw" | grep -v '^$' > "$PR_FILE"
  return 0
}

has_open_pr() {
  [ -s "$PR_FILE" ] || return 1
  grep -qxF -- "$1" "$PR_FILE"
}

# --------------------------------------------------------------- measurement
#
# revert_lines: deletions in base..ref = lines the BASE holds that the REF does
# not. `git diff --numstat` emits "-" for binary files; those are summed as 0
# rather than crashing the arithmetic, and that is why the awk guards on a
# numeric match instead of trusting field 2.
revert_lines() {
  local base="$1" ref="$2" out
  if [ -n "$PATHSPEC" ]; then
    local IFS=','; local -a ps; read -r -a ps <<< "$PATHSPEC"; unset IFS
    out="$(git diff --numstat "$base".."$ref" -- "${ps[@]}" 2>/dev/null)"
  else
    out="$(git diff --numstat "$base".."$ref" 2>/dev/null)"
  fi
  printf '%s\n' "$out" | awk '$2 ~ /^[0-9]+$/ { n += $2 } END { print n + 0 }'
}

run_report() {
  if [ "$WANT_PR" -eq 1 ]; then
    if ! load_pr_heads; then
      printf 'stranded-branch-report: the open-PR signal could not be read (%s).\n' "$PR_STATUS" >&2
      printf '  Refusing to report: without it, every live branch in this campaign\n' >&2
      printf '  classifies as DIVERGED and reads as abandoned. Re-run with --no-pr to\n' >&2
      printf '  get a report that says so in its own header.\n' >&2
      exit 3
    fi
  else
    PR_FILE="$(mktemp "${TMPDIR:-/tmp}/strandedpr.XXXXXX")" || die "mktemp failed"
    : > "$PR_FILE"; PR_STATUS="skipped"
  fi

  git rev-parse --verify --quiet "$BASE" >/dev/null || die "base ref '$BASE' does not resolve"

  local n_merged=0 n_pr=0 n_div=0 n_carrier=0
  local rows; rows="$(mktemp "${TMPDIR:-/tmp}/strandedrows.XXXXXX")" || die "mktemp failed"

  local short full merged ahead behind rl bucket ca cn cherry
  while IFS= read -r short; do
    [ -n "$short" ] || continue
    if [ -n "$PATTERN" ]; then
      case "$short" in $PATTERN) ;; *) continue ;; esac
    fi
    full="$(resolve_ref "$short")"
    git rev-parse --verify --quiet "$full" >/dev/null || continue

    if git merge-base --is-ancestor "$full" "$BASE" 2>/dev/null; then
      bucket="MERGED"; n_merged=$((n_merged + 1))
    elif has_open_pr "$short"; then
      bucket="OPEN-PR"; n_pr=$((n_pr + 1))
    else
      bucket="DIVERGED"; n_div=$((n_div + 1))
    fi

    ahead="$(git rev-list --count "$BASE".."$full" 2>/dev/null || echo 0)"
    behind="$(git rev-list --count "$full".."$BASE" 2>/dev/null || echo 0)"

    if [ "$bucket" = "MERGED" ]; then
      rl=0; cherry="-"
    else
      rl="$(revert_lines "$BASE" "$full")"
      ca="$(git cherry "$BASE" "$full" 2>/dev/null | grep -c '^-')"
      cn="$(git cherry "$BASE" "$full" 2>/dev/null | grep -c '^+')"
      cherry="${ca}/${cn}"
    fi
    if [ "$bucket" = "DIVERGED" ] && [ "$rl" -gt 0 ]; then
      n_carrier=$((n_carrier + 1))
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$bucket" "$short" "$ahead" "$behind" "$rl" "$cherry" >> "$rows"
  done <<EOF
$(emit_refs)
EOF

  if [ "$FORMAT" = "tsv" ]; then
    printf 'bucket\tref\tahead\tbehind\trevert_lines\tcherry_applied/new\n'
    sort -k1,1 -k5,5nr "$rows"
  else
    printf '# stranded-branch-report  base=%s  refs=%s  pr-signal=%s\n' "$BASE" "$REFS" "$PR_STATUS"
    [ "$WANT_PR" -eq 0 ] && printf '# PR SIGNAL SKIPPED: no ref below may be called stranded on this run.\n'
    printf '# revert_lines = lines %s holds that the ref does NOT. This is the hazard.\n' "$BASE"
    printf '# cherry = ref commits already upstream / not upstream.\n\n'
    { printf 'BUCKET\tREF\tAHEAD\tBEHIND\tREVERT_LINES\tCHERRY\n'
      sort -k1,1 -k5,5nr "$rows"; } | awk -F'\t' '{ printf "%-9s %-58s %6s %7s %13s %10s\n", $1,$2,$3,$4,$5,$6 }'
    printf '\nMERGED %d   OPEN-PR %d   DIVERGED %d   (regression carriers: %d)\n' \
      "$n_merged" "$n_pr" "$n_div" "$n_carrier"
    printf 'Retiring any ref is an OWNER decision. This script deletes nothing.\n'
  fi

  rm -f "$rows" "$PR_FILE"
  [ "$n_carrier" -gt 0 ] && return 1
  return 0
}

# ------------------------------------------------------------------ selftest
#
# Hermetic: builds a throwaway repo whose branches have KNOWN classifications
# and KNOWN revert surfaces, then asserts the report. The open-PR bucket is
# driven through STRANDED_PR_LIST_FILE, so all three buckets are exercised
# without a network.
selftest() {
  local fails=0 tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/strandedself.XXXXXX")" || { echo "mktemp -d failed"; return 1; }
  local SCRIPT; SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"

  (
    cd "$tmp" || exit 1
    git init -q . && git config user.email t@t && git config user.name t
    # base: a file that GROWS, which is what makes stale branches dangerous
    printf 'l1\nl2\nl3\n' > big.txt; printf 'x\n' > other.txt
    git add -A && git commit -qm base
    git branch b_old                      # 3-line big.txt — will be left behind
    git branch -q -M main
    # main grows big.txt by 5 lines
    printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n' > big.txt
    git add -A && git commit -qm grow
    # a merged ancestor
    git branch b_merged HEAD~1
    git tag -f origin-main HEAD >/dev/null
    # b_old adds one harmless line to other.txt -> diverged, revert surface 5
    git checkout -q b_old && printf 'x\ny\n' > other.txt
    git add -A && git commit -qm "tiny harmless change"
    # a live branch off current main, adds only -> revert surface 0
    git checkout -q main && git checkout -q -b b_live && printf 'z\n' >> other.txt
    git add -A && git commit -qm live
    git checkout -q main
  ) || { echo "selftest fixture build failed"; return 1; }

  local prf="$tmp/prheads"; printf 'b_live\n' > "$prf"
  local out
  out="$(cd "$tmp" && STRANDED_PR_LIST_FILE="$prf" bash "$SCRIPT" \
          --base main --refs local --format tsv 2>&1)"
  local rc=$?

  echo "--- selftest report ---"; echo "$out"; echo "--- (exit $rc) ---"

  # Assertions grep a FILE, never `printf … | grep -q`. Under `set -o pipefail`
  # that shape can return 141: grep -q exits on its first match, printf takes
  # SIGPIPE, and the pipeline's status becomes the signal — so a PASSING
  # assertion reports FAIL, and only for outputs long enough that printf is
  # still writing when grep leaves. This harness was first written with the
  # pipe and case 5 failed on correct code while cases 1-3 passed. The file
  # form reads $? from grep itself.
  local outf="$tmp/out.txt"; printf '%s\n' "$out" > "$outf"
  ck() { # ck <label> <regex>
    if grep -qE "$2" "$outf"; then echo "  PASS  $1"
    else echo "  FAIL  $1  (no line matching: $2)"; fails=$((fails + 1)); fi
  }
  # 1. an ancestor of the base is MERGED, and MERGED never reports a hazard
  ck "b_merged classifies MERGED with revert_lines 0" '^MERGED	b_merged	0	1	0	-$'
  # 2. THE BUCKET THAT MUST NOT BE WRONG: an open PR beats divergence.
  #    b_live is behind nothing but is NOT an ancestor; without the PR signal
  #    it would read DIVERGED. If this line regresses, the report names a live
  #    campaign branch as sweepable.
  ck "b_live classifies OPEN-PR, not DIVERGED" '^OPEN-PR	b_live	1	0	'
  # 3. the whole point: a branch whose OWN diff is one harmless line still
  #    carries a 5-line revert surface on a file it never touched.
  ck "b_old is DIVERGED and carries revert_lines=5" '^DIVERGED	b_old	1	1	5	'
  # 4. exit 1 signals "a regression carrier exists"
  if [ "$rc" -eq 1 ]; then echo "  PASS  exit 1 when a regression carrier exists"
  else echo "  FAIL  expected exit 1 (regression carrier present), got $rc"; fails=$((fails + 1)); fi
  # 5. --no-pr must NOT silently promote b_live to DIVERGED without saying so
  local out2 rc2
  out2="$(cd "$tmp" && bash "$SCRIPT" --base main --refs local --no-pr 2>&1)"; rc2=$?
  printf '%s\n' "$out2" > "$tmp/out2.txt"
  if grep -q 'PR SIGNAL SKIPPED' "$tmp/out2.txt"; then
    echo "  PASS  --no-pr header warns the report cannot call anything stranded"
  else echo "  FAIL  --no-pr produced no PR-SIGNAL-SKIPPED header"; fails=$((fails + 1)); fi
  # 6. a missing PR signal must REFUSE (exit 3), never report a downgraded set
  local rc3
  (cd "$tmp" && STRANDED_PR_LIST_FILE="$tmp/nope" bash "$SCRIPT" --base main --refs local >/dev/null 2>&1)
  rc3=$?
  if [ "$rc3" -eq 3 ]; then echo "  PASS  unreadable PR signal refuses with exit 3"
  else echo "  FAIL  expected exit 3 on unreadable PR signal, got $rc3"; fails=$((fails + 1)); fi

  rm -rf "$tmp"
  if [ "$fails" -eq 0 ]; then echo "selftest: 6/6 PASS"; return 0; fi
  echo "selftest: $fails FAILED"; return 1
}

if [ "$SELFTEST" -eq 1 ]; then selftest; exit $?; fi
run_report; exit $?
