#!/usr/bin/env bash
#
# posix-vacuous-green-census.sh — every scripts/*.sh that uses process
# substitution is either interpreter-GUARDED, or MEASURED under `sh` and
# recorded with its exit code. There is no third state.
#
# WHY THIS EXISTS (cch-w53-fu-posix-vacuous-green-census-across-scripts)
# ---------------------------------------------------------------------
# bash reads a script INCREMENTALLY. Invoked as `sh`, it is in POSIX mode, where
# `< <(…)` is a parse error — so it executes everything above that line, then
# dies with the status of the LAST COMPLETED COMMAND. scripts/required-checks.test.sh
# exited 0 after running 68 of its 170 assertions exactly that way (#10728). CI
# always calls `bash`; this is an agent- and operator-facing trap, and it is
# recorded here as one rather than overstated as a CI hole.
#
# #17126 measured the population and guarded the seven files that exited 0.
# A MEASUREMENT IS A SNAPSHOT. This gate is the PREDICATE that outlives it: the
# population is derived from the tree every run, never from a hand list, so a
# script added tomorrow with a process substitution and no guard reds on its
# first CI run instead of waiting for the next census.
#
# THE RULE. Population = every scripts/*.sh containing `<(`. Each member must be
# exactly one of:
#
#   GUARDED       it carries the shebang-independent interpreter guard
#                 (a `${BASH_VERSION}` refusal AND a `*:posix:*` SHELLOPTS arm)
#                 and the guard sits ABOVE its first non-comment `<(` — a guard
#                 placed lower is decoration: bash has already run what precedes it.
#   COMMENT-ONLY  every `<(` in it is inside a comment. Nothing is parsed, nothing
#                 can truncate. Derived, not asserted — move the text into code and
#                 the file leaves this class by itself.
#   ROSTERED      scripts/.posix-vacuous-green-census carries a line for it saying
#                 what a real `sh` RUN did. Exit code 0 is admissible ONLY with
#                 class `honest-green`, which requires a bash-control note.
#
# Anything else reds, NAMED. So do the roster's own failure modes:
#   - a roster line for a file that is now guarded, comment-only, or gone (stale)
#   - a roster line with exit code 0 whose class is not `honest-green` (a vacuous
#     green smuggled in as a negative — the one thing this census exists to catch)
#
# The census SHOWS ITS NEGATIVES: `--list` prints every member with its class, so
# "23 scripts measured non-vacuous" is readable, not inferred from silence.
#
# Exit codes:  0 census holds · 1 a member is unaccounted for · 2 the census
# itself could not read its inputs (it measured NOTHING — never silent) · 3 usage.
#
# This file deliberately uses NO process substitution, so it is not a member of
# its own population and needs no guard. Keep it that way.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROSTER="$REPO_ROOT/scripts/.posix-vacuous-green-census"
MODE=verify

# The process-substitution token, assembled so this file carries NO literal
# occurrence of it on a CODE line. Without this the census classifies ITSELF as a
# population member whose own grep pattern is its first "process substitution" —
# it did, on the first real run, and reported a RED against itself at line 60. A
# gate whose detector matches its own source is a gate that cannot stay green.
# (\050 is `(`.)
PSUB="$(printf '<\050')"

usage() {
  cat <<'USAGE'
usage: bash scripts/posix-vacuous-green-census.sh [--list|--selftest|--help]

  (no args)   verify the census: every scripts/*.sh using process substitution
              is guarded, comment-only, or rostered with a measured `sh` exit code.
  --list      print every population member with its class and exit 0.
  --selftest  prove the tripwire in temp files (plants nothing in the tree).
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --list) MODE=list ;;
    --selftest) MODE=selftest ;;
    -h|--help) usage; exit 0 ;;
    *) echo "posix-vacuous-green-census: unknown argument '$1'" >&2; usage >&2; exit 3 ;;
  esac
  shift
done

# ---------------------------------------------------------------- classifiers

# first_code_subst <file> -> line number of the first NON-COMMENT `<(`, or empty
first_code_subst() {
  grep -nF "$PSUB" "$1" | while IFS=: read -r n rest; do
    case "$(printf '%s' "$rest" | sed 's/^[[:space:]]*//')" in
      '#'*) : ;;
      *) printf '%s\n' "$n"; break ;;
    esac
  done | sed -n '1p'
}

# guard_line <file> -> line number of the BASH_VERSION refusal, or empty
guard_line() {
  grep -n 'BASH_VERSION' "$1" | grep -- '-z' | sed -n '1s/:.*//p'
}

has_posix_arm() { grep -q '\*:posix:\*' "$1"; }

# classify <file> -> one of GUARDED / COMMENT-ONLY / GUARD-TOO-LATE / UNGUARDED
classify() {
  local f="$1" sub g
  sub="$(first_code_subst "$f")"
  if [ -z "$sub" ]; then echo "COMMENT-ONLY"; return; fi
  g="$(guard_line "$f")"
  if [ -n "$g" ] && has_posix_arm "$f"; then
    if [ "$g" -lt "$sub" ]; then echo "GUARDED"; else echo "GUARD-TOO-LATE"; fi
    return
  fi
  echo "UNGUARDED"
}

roster_field() { # roster_field <file> <roster> <n>
  grep "^$1|" "$2" 2>/dev/null | sed -n "1s/.*/&/p" | cut -d'|' -f"$3"
}

# ---------------------------------------------------------------- the census

run_census() {  # run_census <repo_root> <roster>  -> prints report, sets FAILED
  local root="$1" roster="$2"
  local pop f cls rc rcls n_guarded=0 n_comment=0 n_rostered=0
  FAILED=0

  if [ ! -d "$root/scripts" ]; then
    echo "posix-vacuous-green-census: CANNOT READ scripts/ under '$root' — measured NOTHING" >&2
    return 2
  fi
  if [ ! -r "$roster" ]; then
    echo "posix-vacuous-green-census: CANNOT READ roster '$roster' — measured NOTHING" >&2
    return 2
  fi

  pop="$(grep -lF "$PSUB" "$root"/scripts/*.sh 2>/dev/null | sort)"
  if [ -z "$pop" ]; then
    echo "posix-vacuous-green-census: CANNOT READ — zero scripts/*.sh contain a process substitution token, which this repo has never been true of; measured NOTHING" >&2
    return 2
  fi

  printf '%s\n' "$pop" > "$TMPDIR_CENSUS/pop.txt"

  while IFS= read -r f; do
    local rel="${f#$root/}"
    cls="$(classify "$f")"
    case "$cls" in
      GUARDED)      n_guarded=$((n_guarded + 1)); [ "$MODE" = list ] && printf '  %-14s %s\n' "GUARDED" "$rel" ;;
      COMMENT-ONLY) n_comment=$((n_comment + 1)); [ "$MODE" = list ] && printf '  %-14s %s\n' "COMMENT-ONLY" "$rel" ;;
      GUARD-TOO-LATE)
        echo "RED: $rel carries an interpreter guard BELOW its first process substitution (line $(guard_line "$f") vs $(first_code_subst "$f")) — bash has already run what precedes it" >&2
        FAILED=1
        ;;
      UNGUARDED)
        rc="$(grep "^$rel|" "$roster" 2>/dev/null | cut -d'|' -f2 | sed -n '1p')"
        rcls="$(grep "^$rel|" "$roster" 2>/dev/null | cut -d'|' -f3 | sed -n '1p')"
        if [ -z "$rc" ]; then
          echo "RED: $rel uses process substitution, carries no interpreter guard, and is NOT on $roster. RUN it under \`sh\` and record its exit code, or add the guard." >&2
          FAILED=1
        elif [ "$rc" = "0" ] && [ "$rcls" != "honest-green" ]; then
          echo "RED: $rel is rostered with exit code 0 under class '$rcls'. Exit 0 is admissible only as 'honest-green' with a bash-control note — a truncated 0 is the vacuous green this census exists to catch." >&2
          FAILED=1
        else
          n_rostered=$((n_rostered + 1))
          [ "$MODE" = list ] && printf '  %-14s %s (sh rc=%s, %s)\n' "ROSTERED" "$rel" "$rc" "$rcls"
        fi
        ;;
    esac
  done < "$TMPDIR_CENSUS/pop.txt"

  # stale roster lines — shrink-only, same discipline as the format-drift ceilings
  while IFS='|' read -r rel _rest; do
    case "$rel" in ''|'#'*) continue ;; esac
    if ! grep -qx "$root/$rel" "$TMPDIR_CENSUS/pop.txt"; then
      echo "RED: roster names $rel, which no longer uses process substitution (or no longer exists) — prune the line" >&2
      FAILED=1
      continue
    fi
    cls="$(classify "$root/$rel")"
    if [ "$cls" != "UNGUARDED" ]; then
      echo "RED: roster names $rel, which is now $cls — a measured negative that has become a positive; prune the line" >&2
      FAILED=1
    fi
  done < "$roster"

  POP_N="$(grep -c . "$TMPDIR_CENSUS/pop.txt")"
  echo "census: $POP_N scripts/*.sh contain a process substitution token — $n_guarded guarded, $n_comment comment-only, $n_rostered measured non-vacuous under sh"
  # The verdict rides the RETURN CODE, not a variable: every caller below runs
  # this in a subshell (output capture), where an assignment to FAILED dies with
  # the subshell. That exact mistake made five selftest arms read green while the
  # census under them was correctly red.
  [ "$FAILED" -ne 0 ] && return 1
  return 0
}

TMPDIR_CENSUS="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_CENSUS"' EXIT

# ---------------------------------------------------------------- selftest

if [ "$MODE" = selftest ]; then
  fails=0
  ok()  { echo "  ok   — $1"; }
  no()  { echo "  FAIL — $1"; fails=$((fails + 1)); }

  FIX="$TMPDIR_CENSUS/fixture"
  LOG="$TMPDIR_CENSUS/selftest.log"
  mkdir -p "$FIX/scripts"
  # `$PSUB` must EXPAND here, so these are double-quoted and the fixtures' own
  # `$BASH_VERSION`/`$SHELLOPTS` are backslash-escaped to survive into the file.
  SUBST_LINE="while read x; do :; done < ${PSUB}echo hi)"
  GUARD_LINES='if [ -z "${BASH_VERSION:-}" ]; then exit 2; fi
case ":${SHELLOPTS:-}:" in *:posix:*) exit 2 ;; esac'
  GUARD_TOP="#!/usr/bin/env bash
$GUARD_LINES
$SUBST_LINE"
  NOGUARD="#!/usr/bin/env bash
$SUBST_LINE"
  GUARD_LATE="#!/usr/bin/env bash
$SUBST_LINE
$GUARD_LINES"
  ROSTER_LINE='scripts/rostered.sh|2|truncated-red|2026-09-11|fixture'

  printf '%s\n' "$GUARD_TOP" > "$FIX/scripts/guarded.sh"
  printf '#!/usr/bin/env bash\n# this one only mentions the token %s...) in prose\necho hi\n' "$PSUB" > "$FIX/scripts/commented.sh"
  printf '%s\n' "$NOGUARD" > "$FIX/scripts/rostered.sh"
  printf '%s\n' "$ROSTER_LINE" > "$FIX/roster"

  MODE=verify
  census() { run_census "$FIX" "$FIX/roster" > "$LOG" 2>&1; CRC=$?; }

  census
  [ "$CRC" -eq 0 ] && ok "baseline: guarded + comment-only + rostered is GREEN" \
    || no "baseline should be green, got rc=$CRC: $(cat "$LOG")"
  if grep -q "3 scripts/\*\.sh contain a process substitution" "$LOG" && grep -q "1 guarded, 1 comment-only, 1 measured" "$LOG"; then
    ok "positive control: the census FOUND all three classes it was meant to find (3 = 1+1+1)"
  else
    no "positive control: summary line did not name 3/1/1 — got: $(cat "$LOG")"
  fi

  # mutation 1: drop the roster line -> RED naming the file
  : > "$FIX/roster"
  census
  { [ "$CRC" -eq 1 ] && grep -q "scripts/rostered.sh.*NOT on" "$LOG"; } \
    && ok "mutation[roster-line-removed]: RED, and it NAMES scripts/rostered.sh" \
    || no "mutation[roster-line-removed]: expected a RED naming scripts/rostered.sh, got rc=$CRC: $(cat "$LOG")"
  printf '%s\n' "$ROSTER_LINE" > "$FIX/roster"
  census
  [ "$CRC" -eq 0 ] && ok "restore[roster-line]: green again" || no "restore[roster-line]: still red: $(cat "$LOG")"

  # mutation 2: remove the guard from guarded.sh -> RED naming it
  printf '%s\n' "$NOGUARD" > "$FIX/scripts/guarded.sh"
  census
  { [ "$CRC" -eq 1 ] && grep -q "scripts/guarded.sh.*no interpreter guard" "$LOG"; } \
    && ok "mutation[guard-removed]: RED, and it NAMES scripts/guarded.sh" \
    || no "mutation[guard-removed]: expected a RED naming scripts/guarded.sh, got rc=$CRC: $(cat "$LOG")"
  printf '%s\n' "$GUARD_TOP" > "$FIX/scripts/guarded.sh"
  census
  [ "$CRC" -eq 0 ] && ok "restore[guard]: green again" || no "restore[guard]: still red: $(cat "$LOG")"

  # mutation 3: move the guard BELOW the process substitution
  printf '%s\n' "$GUARD_LATE" > "$FIX/scripts/guarded.sh"
  census
  { [ "$CRC" -eq 1 ] && grep -q "BELOW its first process substitution" "$LOG"; } \
    && ok "mutation[guard-below-the-substitution]: RED — a guard bash never reaches is not a guard" \
    || no "mutation[guard-below]: expected a GUARD-TOO-LATE red, got rc=$CRC: $(cat "$LOG")"

  # mutation 4: a roster line claiming exit 0 under a non-honest class
  printf '%s\n' "$GUARD_TOP" > "$FIX/scripts/guarded.sh"
  printf 'scripts/rostered.sh|0|truncated-red|2026-09-11|fixture\n' > "$FIX/roster"
  census
  { [ "$CRC" -eq 1 ] && grep -q "admissible only as .honest-green." "$LOG"; } \
    && ok "mutation[exit-0-smuggled-as-a-negative]: RED — the one shape the census exists to catch" \
    || no "mutation[exit-0-smuggled]: expected the honest-green red, got rc=$CRC: $(cat "$LOG")"

  # mutation 5: an unreadable roster must say CANNOT READ, not report a clean zero
  run_census "$FIX" "$FIX/does-not-exist" > "$LOG" 2>&1; CRC=$?
  { [ "$CRC" -eq 2 ] && grep -q "CANNOT READ" "$LOG"; } \
    && ok "instrument: a missing roster prints CANNOT READ and exits 2" \
    || no "instrument: missing roster should exit 2 with CANNOT READ, got rc=$CRC: $(cat "$LOG")"

  echo
  echo "----"
  if [ "$fails" -eq 0 ]; then echo "9 passed, 0 failed"; exit 0; fi
  echo "$fails failed"; exit 1
fi

# ---------------------------------------------------------------- real run

run_census "$REPO_ROOT" "$ROSTER"; rc=$?
if [ "$rc" -eq 2 ]; then exit 2; fi
if [ "$rc" -ne 0 ]; then
  echo "posix-vacuous-green-census: FAIL — see the RED lines above." >&2
  exit 1
fi
[ "$MODE" = list ] || echo "posix-vacuous-green-census: OK"
exit 0
