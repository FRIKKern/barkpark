#!/usr/bin/env bash
# hold-vocabulary.sh — THE LOCK on the merge fleet's hold-label vocabulary.
#
# @canonical capability:hold-label-vocabulary-lock aka:owner-hold,MC_HOLD_LABELS,PR_HOLD_LABELS doc:scripts/merge-check.sh
#
# WHY THIS FILE EXISTS (task-cbba29645c9c65d9, 2026-09-23). Two merge instruments answer the
# same question — "is this PR held?" — and until now each carried its OWN copy of the label
# vocabulary, its own case handling and its own exit codes, with NO shared fixture:
#   scripts/merge-check.sh                                  (mc_hold_verdict, arms A17..A17m)
#   scripts/pr-required.sh  + its byte-identical mirror
#   .claude/skills/orchestrate-tasks/helpers/pr-required.sh (exit 4 on HELD)
# Two well-tested copies of one vocabulary with no shared fixture is an UNLOCKED MIRROR: change
# one and BOTH suites stay green while the fleet gets two different answers at the merge button.
# That is not hypothetical here — `owner-hold` (main's HOLD RULE v2, 2026-09-22T15:37Z) was
# taught to pr-required.sh by #19893 and was INVISIBLE to merge-check.sh, whose vocabulary was
# the single string `hold`. The prior cost of the same shape: #18705 merged past a six-day-old
# owner hold, and the revert (#19851) had to be built to get main's required Elixir gate green.
#
# THE MECHANISM. Each instrument DECLARES its vocabulary on one line carrying the marker
# `# @hold-vocabulary`, and DERIVES its matching from that declaration — the declaration is
# load-bearing, not a comment that says "mirrors X" (a comment saying "mirrors X" IS the tell
# for hand-maintained). This script decodes the declaration out of each file and asserts the
# files are TERM-IDENTICAL, in ORDER. Both suites run the check, so a mutation on either side
# reds the OTHER side too: a lock only one side checks is half a lock.
#
# ORDER IS MEANINGFUL: the list is in ASCENDING STRENGTH, and the STRONGEST member present on a
# PR is the one the refusal names. `hold owner-hold` therefore means owner-hold wins a PR
# carrying both. That is a RULE, not an enumeration — adding a third member needs no new branch.
#
# FAILS CLOSED. A file that is missing, that declares NO vocabulary, that declares MORE THAN ONE,
# or that declares an EMPTY one is a REFUSAL, never a silent agreement: an absence is never
# caught by inspection, so it is caught here by a count.
#
#   hold-vocabulary.sh --terms <file>            print the declared terms, one per line, in order
#   hold-vocabulary.sh --check <file> <file>...  refuse unless every file declares the same terms
#   hold-vocabulary.sh --selftest                the arm suite (hermetic, no network)
set -uo pipefail
if [ -z "${BASH_VERSION:-}" ]; then
  echo "hold-vocabulary.sh: needs bash; run: bash scripts/hold-vocabulary.sh" >&2; exit 2
fi

HV_MARKER='@hold-vocabulary'

# hv_terms <file> — prints the terms space-separated on ONE line; rc 0 ok, 2 unreadable/ambiguous.
# The extraction is deliberately narrow: a line of the shape  NAME="<terms>" # @hold-vocabulary
# and nothing else. A marker that drifts onto a different shape is an UNREAD, not a pass.
hv_terms() {
  local f="${1-}" hits n raw
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    printf 'UNREAD\tno such file: %s\n' "${f:-<none>}" >&2; return 2
  fi
  hits=$(sed -n 's/^[^#]*="\([^"]*\)"[[:space:]]*#[[:space:]]*'"$HV_MARKER"'[[:space:]]*$/\1/p' "$f")
  # Count into a variable; never `| grep -q`, which SIGPIPEs the upstream under pipefail.
  if [ -z "$hits" ]; then
    printf 'UNREAD\t%s declares NO %s line — an absent declaration is not an agreement\n' "$f" "$HV_MARKER" >&2; return 2
  fi
  n=$(printf '%s\n' "$hits" | grep -c .)
  if [ "$n" -ne 1 ]; then
    printf 'UNREAD\t%s declares %s %s lines; exactly ONE is the contract\n' "$f" "$n" "$HV_MARKER" >&2; return 2
  fi
  # Normalise whitespace so `hold  owner-hold` and `hold owner-hold` are the same declaration,
  # but do NOT sort: the order encodes precedence.
  raw=$(printf '%s' "$hits" | tr -s '[:space:]' ' ')
  raw="${raw# }"; raw="${raw% }"
  if [ -z "$raw" ]; then
    printf 'UNREAD\t%s declares an EMPTY vocabulary — a gate that knows no hold label refuses nothing\n' "$f" >&2; return 2
  fi
  printf '%s\n' "$raw"; return 0
}

# hv_check <file>... — rc 0 identical, 1 divergent, 2 unreadable. Prints one line either way.
hv_check() {
  local first="" f t rc bad=0 detail=""
  [ "$#" -ge 2 ] || { printf 'HOLD-VOCAB UNREAD: --check needs at least two files\n'; return 2; }
  for f in "$@"; do
    t=$(hv_terms "$f" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
      printf 'HOLD-VOCAB UNREAD: %s\n' "$(printf '%s' "$t" | tr '\t' ' ')"; return 2
    fi
    detail="$detail
  $f: [$t]"
    if [ -z "$first" ]; then first="$t"
    elif [ "$t" != "$first" ]; then bad=1; fi
  done
  if [ "$bad" -eq 1 ]; then
    printf 'HOLD-VOCAB DIVERGED: the merge instruments do NOT agree on what a hold label is:%s\n' "$detail"
    printf '  Fix the %s declaration in each file so every list is term-identical AND in the same (ascending-strength) order.\n' "$HV_MARKER"
    return 1
  fi
  printf 'HOLD-VOCAB LOCKED: %s file(s) agree on [%s]\n' "$#" "$first"
  return 0
}

# hv_default_files — the three instruments, resolved off the git toplevel of THIS script.
# Prints nothing when this copy is not inside a checkout holding them (callers then NOTE).
hv_default_files() {
  local self="${BASH_SOURCE[0]}" dir top a b c
  case "$self" in */*) dir="${self%/*}";; *) dir=".";; esac
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$top" ] || return 1
  a="$top/scripts/merge-check.sh"
  b="$top/scripts/pr-required.sh"
  c="$top/.claude/skills/orchestrate-tasks/helpers/pr-required.sh"
  [ -f "$a" ] && [ -f "$b" ] && [ -f "$c" ] || return 1
  printf '%s\n%s\n%s\n' "$a" "$b" "$c"
}

hv_selftest() {
  local d p f n out rc
  p=0; f=0
  _p(){ printf 'PASS %-34s %s\n' "$1" "$2"; p=$((p+1)); }
  _f(){ printf 'FAIL %-34s %s\n' "$1" "$2"; f=$((f+1)); }
  d=$(mktemp -d) || { echo "HOLD-VOCAB SELFTEST: CANNOT READ — no tempdir"; return 3; }

  printf '%s\n' 'X_HOLD="hold owner-hold" # @hold-vocabulary' > "$d/a.sh"
  printf '%s\n' 'Y_HOLD="hold owner-hold" # @hold-vocabulary' > "$d/b.sh"
  printf '%s\n' 'Z_HOLD="hold" # @hold-vocabulary'            > "$d/c.sh"
  printf '%s\n' 'W_HOLD="owner-hold hold" # @hold-vocabulary' > "$d/d.sh"
  printf '%s\n' '# nothing here'                              > "$d/none.sh"
  printf '%s\n%s\n' 'A="hold" # @hold-vocabulary' 'B="hold owner-hold" # @hold-vocabulary' > "$d/two.sh"
  printf '%s\n' 'E_HOLD="" # @hold-vocabulary'                > "$d/empty.sh"
  printf '%s\n' '# A_HOLD="hold owner-hold" # @hold-vocabulary' > "$d/commented.sh"

  out=$(hv_terms "$d/a.sh"); rc=$?
  if [ "$rc" = 0 ] && [ "$out" = "hold owner-hold" ]; then _p "terms decode in order" "[$out]"
  else _f "terms decode in order" "rc=$rc out=[$out]"; fi

  out=$(hv_check "$d/a.sh" "$d/b.sh" 2>&1); rc=$?
  if [ "$rc" = 0 ]; then _p "identical files LOCK" "$out"; else _f "identical files LOCK" "rc=$rc $out"; fi

  # THE MUTATION ARM, both directions: drop a term on ONE side and the check must go RED.
  out=$(hv_check "$d/a.sh" "$d/c.sh" 2>&1); rc=$?
  case "$rc:$out" in
    1:HOLD-VOCAB\ DIVERGED*) _p "a dropped term DIVERGES" "one side lost owner-hold and the lock red" ;;
    *) _f "a dropped term DIVERGES" "rc=$rc out=$out — the lock does not notice a missing member" ;;
  esac
  # ORDER is precedence, so a reordered list is NOT the same vocabulary.
  out=$(hv_check "$d/a.sh" "$d/d.sh" 2>&1); rc=$?
  case "$rc:$out" in
    1:HOLD-VOCAB\ DIVERGED*) _p "a reordered list DIVERGES" "order encodes which hold WINS" ;;
    *) _f "a reordered list DIVERGES" "rc=$rc out=$out — precedence can be swapped silently" ;;
  esac
  # FAILS CLOSED on every unreadable shape. An absence must never read as agreement.
  for n in none two empty commented; do
    out=$(hv_check "$d/a.sh" "$d/$n.sh" 2>&1); rc=$?
    case "$rc:$out" in
      2:HOLD-VOCAB\ UNREAD*) _p "UNREAD: $n" "refused rather than agreed" ;;
      *) _f "UNREAD: $n" "rc=$rc out=$out — an unreadable declaration read as a verdict" ;;
    esac
  done
  out=$(hv_check "$d/a.sh" "$d/missing.sh" 2>&1); rc=$?
  case "$rc:$out" in
    2:HOLD-VOCAB\ UNREAD*) _p "UNREAD: missing file" "refused rather than agreed" ;;
    *) _f "UNREAD: missing file" "rc=$rc out=$out" ;;
  esac
  # Whitespace normalisation: the same terms, differently spaced, are the SAME vocabulary.
  printf '%s\n' 'S_HOLD="hold   owner-hold" # @hold-vocabulary' > "$d/sp.sh"
  out=$(hv_check "$d/a.sh" "$d/sp.sh" 2>&1); rc=$?
  if [ "$rc" = 0 ]; then _p "spacing is not divergence" "$out"; else _f "spacing is not divergence" "rc=$rc $out"; fi

  # THE LIVE ARM: the three real instruments, if this copy sits in a checkout holding them.
  if n=$(hv_default_files); then
    # shellcheck disable=SC2046
    out=$(hv_check $(printf '%s ' $n) 2>&1); rc=$?
    if [ "$rc" = 0 ]; then _p "the LIVE three agree" "$out"
    else _f "the LIVE three agree" "rc=$rc $out"; fi
  else
    printf 'NOTE %-34s NOT RUN: this copy is not in a checkout holding all three instruments\n' "the LIVE three agree"
  fi

  rm -rf "$d"
  local total=$((p+f))
  if [ "$total" -lt 11 ]; then echo "HOLD-VOCAB SELFTEST: CANNOT READ — only $total arm(s) ran"; return 3; fi
  if [ "$f" -eq 0 ]; then echo "HOLD-VOCAB SELFTEST: $p/$total arms pass"; return 0; fi
  echo "HOLD-VOCAB SELFTEST: $f of $total arm(s) FAILED"; return 1
}

case "${1:-}" in
  --terms)    shift; hv_terms "${1-}";;
  --check)    shift; hv_check "$@";;
  --check-live)
    if FILES=$(hv_default_files); then
      # shellcheck disable=SC2046
      hv_check $(printf '%s ' $FILES)
    else
      echo "HOLD-VOCAB UNREAD: not inside a checkout holding all three instruments"; exit 2
    fi;;
  --selftest) hv_selftest;;
  *) sed -n '1,40p' "${BASH_SOURCE[0]}" | sed -n '/^#   hold-vocabulary/,$p'; exit 2;;
esac
