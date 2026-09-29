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
          echo "RED: $rel uses process substitution, carries no interpreter guard, and is NOT on $roster. RUN it under \`sh\` and record its exit code, or add the guard. DO NOT reach for \`sh -n\`: it is blind to this class BY CONSTRUCTION and answers 0 on a script that then exits 0 having compared NOTHING — proved, not remembered, by the sh-n-blindness and procsub-under-posix arms of \`--selftest\`; the class is owned by docs/ops/merge-gates.md, section 'PARSED BUT NOT RUN'." >&2
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
  passes=0
  ok()  { echo "  ok   — $1"; passes=$((passes + 1)); }
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

  # ------------------------------------------------- the VERDICT WIRING, whole program
  # task-92a213f01ca30817. Every mutation above grades run_census IN PROCESS;
  # none executes the real-run tail that turns its return code into the
  # PROCESS exit, so flipping that `exit 1` to `exit 0` kept this selftest
  # green while CI certified an unrostered file. Same idiom as PR #13405 /
  # #20180: RE-EXEC THE WHOLE PROGRAM on a fixture root and assert the PROCESS
  # exit. REPO_ROOT and ROSTER derive from the script's own location, so a copy
  # at <e2e>/scripts/ reads only the fixture — no override is added.
  E2E="$TMPDIR_CENSUS/e2e"
  mkdir -p "$E2E/scripts"
  cp "$0" "$E2E/scripts/posix-vacuous-green-census.sh"
  printf '%s\n' "$GUARD_TOP" > "$E2E/scripts/guarded.sh"
  printf '%s\n' "$NOGUARD" > "$E2E/scripts/rostered.sh"
  : > "$E2E/scripts/.posix-vacuous-green-census"
  bash "$E2E/scripts/posix-vacuous-green-census.sh" > "$LOG" 2>&1; CRC=$?
  { [ "$CRC" -eq 1 ] && grep -q "scripts/rostered.sh.*NOT on" "$LOG"; } \
    && ok "whole-program[planted-unrostered]: the PROCESS exits 1, naming scripts/rostered.sh" \
    || no "whole-program[planted-unrostered]: expected process exit 1 naming scripts/rostered.sh, got rc=$CRC: $(cat "$LOG")"
  printf '%s\n' "$ROSTER_LINE" > "$E2E/scripts/.posix-vacuous-green-census"
  bash "$E2E/scripts/posix-vacuous-green-census.sh" > "$LOG" 2>&1; CRC=$?
  [ "$CRC" -eq 0 ] && ok "whole-program[plant-rostered]: the PROCESS exits 0" \
    || no "whole-program[plant-rostered]: expected process exit 0, got rc=$CRC: $(cat "$LOG")"

  # ------------------------------------------------- (a) sh -n blindness, PORTABLE
  #
  # THE POINT OF THIS ARM. Everything above proves the census catches the class.
  # This proves the check a reader reaches for INSTEAD cannot — and it proves it
  # on EVERY interpreter, because it does not depend on one.
  #
  # The shape of the class: a comparison's operands are captured in a command
  # substitution; the capture FAILS at run time; the assignment throws the exit
  # status away; both operands come back EMPTY; emptiness reads as "no
  # differences"; the harness announces a pass having compared NOTHING. `-n`
  # reads the file and answers 0, because nothing about it is ill-formed.
  #
  # The TRIGGER here is a comparator that is not installed. The trigger in the
  # incident this census was built from was a process substitution the running
  # interpreter refuses. The trigger is platform-shaped (arm (b) below measures
  # exactly how); the SHAPE is not, and the shape is what `-n` cannot see.
  BLIND="$TMPDIR_CENSUS/blind-fixture.sh"
  cat > "$BLIND" <<'FIXTURE'
#!/usr/bin/env bash
# Shaped like the real harnesses. $CMP is the comparator, $1/$2 the operands.
fails=0
only_left=$("$CMP" -13 "$1" "$2" 2>/dev/null)
only_right=$("$CMP" -23 "$1" "$2" 2>/dev/null)
[ -z "$only_left" ]  || { echo "FAIL: left operand differs";  fails=$((fails + 1)); }
[ -z "$only_right" ] || { echo "FAIL: right operand differs"; fails=$((fails + 1)); }
echo "---- $fails failure(s), 2 pass(es)"
[ "$fails" -eq 0 ] && echo "FIXTURE TEST PASSED"
exit "$fails"
FIXTURE
  printf 'a\n' > "$TMPDIR_CENSUS/left"
  printf 'b\n' > "$TMPDIR_CENSUS/right"

  bash -n "$BLIND" > "$TMPDIR_CENSUS/blind.parse" 2>&1; BLIND_PARSE_RC=$?
  [ "$BLIND_PARSE_RC" -eq 0 ] \
    && ok "sh-n-blindness[parse]: \`bash -n\` on the fixture EXITS $BLIND_PARSE_RC — the static check sees nothing wrong, on every platform" \
    || no "sh-n-blindness[parse]: expected the parse check to exit 0 (that IS the blindness), got rc=$BLIND_PARSE_RC: $(cat "$TMPDIR_CENSUS/blind.parse")"

  CMP="comparator-that-is-not-installed" bash "$BLIND" "$TMPDIR_CENSUS/left" "$TMPDIR_CENSUS/right" \
    > "$TMPDIR_CENSUS/blind.out" 2> "$TMPDIR_CENSUS/blind.err"; BLIND_RUN_RC=$?
  { [ "$BLIND_RUN_RC" -eq 0 ] && grep -q "FIXTURE TEST PASSED" "$TMPDIR_CENSUS/blind.out" \
      && ! grep -q "operand differs" "$TMPDIR_CENSUS/blind.out"; } \
    && ok "sh-n-blindness[compared-nothing]: the run EXITS $BLIND_RUN_RC and prints \"$(grep -- '---- ' "$TMPDIR_CENSUS/blind.out")\" + FIXTURE TEST PASSED, with both operands EMPTY" \
    || no "sh-n-blindness[compared-nothing]: expected rc=0 with an announced pass and no operand-differs line, got rc=$BLIND_RUN_RC: $(cat "$TMPDIR_CENSUS/blind.out") / $(cat "$TMPDIR_CENSUS/blind.err")"

  # POSITIVE CONTROL. Without it the arm above is satisfiable by a fixture with
  # nothing to say: an honest pass and a vacuous one both exit 0. With a working
  # comparator the SAME file, the SAME operands, reds both comparisons — so the
  # exit 0 measured above was vacuous, not honest.
  CMP="comm" bash "$BLIND" "$TMPDIR_CENSUS/left" "$TMPDIR_CENSUS/right" \
    > "$TMPDIR_CENSUS/blind.ctl" 2>&1; BLIND_CTL_RC=$?
  { [ "$BLIND_CTL_RC" -ne 0 ] && grep -q "FAIL: left operand differs" "$TMPDIR_CENSUS/blind.ctl" \
      && grep -q "FAIL: right operand differs" "$TMPDIR_CENSUS/blind.ctl"; } \
    && ok "sh-n-blindness[control]: with a comparator that WORKS the same file EXITS $BLIND_CTL_RC and reds both comparisons — the 0 above was vacuous" \
    || no "sh-n-blindness[control]: the fixture must FAIL with a working comparator or it proves nothing, got rc=$BLIND_CTL_RC: $(cat "$TMPDIR_CENSUS/blind.ctl")"

  # --------------------------------- (b) the incident's trigger, PLATFORM-SHAPED
  #
  # The incident: `sh scripts/sunset-route-consumers.test.sh` on macOS exited 0
  # announcing 32 passes, having compared nothing, because bash 3.2 refuses a
  # process substitution in POSIX mode and parses a command substitution's body
  # LAZILY — so the refusal lands at EXPANSION time, long after `-n` answered 0.
  #
  # THAT IS NOT PORTABLE, AND THIS ARM USED TO ASSERT IT AS THOUGH IT WERE. It
  # reddened main on 2026-09-14. Measured 2026-09-15, same fixture:
  #   bash 3.2.57 (macOS /bin/bash, and what `sh` becomes there), `--posix`:
  #     rc 0, "FIXTURE TEST PASSED", `command substitution: syntax error` on
  #     stderr   <- THE VACUOUS VARIANT
  #   bash 5.2.21 (ubuntu 24.04, the CI runner), `--posix`: rc 2, both operands
  #     compared, both comparisons red   <- THE LOUD VARIANT. bash >= 5.1 allows
  #     process substitution in POSIX mode, so the fixture simply WORKS there.
  #   dash / `sh` on Linux: rc 2 at PARSE time — a third outcome, not this one.
  # No interpreter measured on Linux produces the vacuous variant.
  #
  # So the arm DETECTS which world it is in, ASSERTS the detection, and then
  # asserts the outcome that world owes. It never skips: a skip counted as a
  # pass is the exact vacuity this census exists to catch, and an unrecognised
  # probe answer is CANNOT READ (exit 2), not a shrug.
  #
  # `@PSUB@` is substituted rather than written, for the same reason PSUB exists
  # at the top of this file: a literal occurrence on a code line would enrol this
  # census in its own population.
  VAC="$TMPDIR_CENSUS/vacuous-fixture.sh"
  sed "s/@PSUB@/$PSUB/g" > "$VAC" <<'FIXTURE'
#!/usr/bin/env bash
# Shaped like the real harnesses: two `comm` comparisons whose operands are
# process substitutions, each wrapped in a command substitution.
fails=0
only_left=$(comm -13 @PSUB@printf 'a\n') @PSUB@printf 'b\n'))
only_right=$(comm -23 @PSUB@printf 'a\n') @PSUB@printf 'b\n'))
[ -z "$only_left" ]  || { echo "FAIL: left operand differs";  fails=$((fails + 1)); }
[ -z "$only_right" ] || { echo "FAIL: right operand differs"; fails=$((fails + 1)); }
echo "---- $fails failure(s), 2 pass(es)"
[ "$fails" -eq 0 ] && echo "FIXTURE TEST PASSED"
exit "$fails"
FIXTURE
  # The honest twin: identical operands, so it passes by AGREEING, not by
  # failing to look. It is the control for the LOUD branch.
  TWIN="$TMPDIR_CENSUS/honest-twin.sh"
  sed "s/@PSUB@/$PSUB/g" > "$TWIN" <<'FIXTURE'
#!/usr/bin/env bash
fails=0
only_left=$(comm -13 @PSUB@printf 'a\n') @PSUB@printf 'a\n'))
[ -z "$only_left" ] || { echo "FAIL: left operand differs"; fails=$((fails + 1)); }
echo "---- $fails failure(s), 1 pass(es)"
exit "$fails"
FIXTURE
  # The probe. It asks ONE question of ONE interpreter: does a process
  # substitution nested inside a command substitution yield its value here?
  DET="$TMPDIR_CENSUS/procsub-probe.sh"
  sed "s/@PSUB@/$PSUB/g" > "$DET" <<'PROBE'
#!/usr/bin/env bash
v=$(cat @PSUB@printf 'x\n'))
printf '[%s]' "$v"
PROBE

  # ONE PASS of the branched arms, against ONE invocation. Factored into a
  # function because the selftest runs it against the PLATFORM DEFAULT
  # unconditionally, and against an override only IN ADDITION.
  #
  # WHY ADDITIVE AND NOT A SWITCH. `CENSUS_SELFTEST_POSIX_SH` used to REPLACE the
  # invocation. That put a knob outside this file in a position to change what
  # the gate measures: anything exporting it in CI would have retired the
  # refusing branch, reddened nothing, and left the arm printing a confident
  # `ok`. That is this census's own failure mode installed in its configuration
  # surface. The override can now only ADD a measurement, never remove one, and
  # every pass says out loud which invocation it measured and whether it was the
  # default — so "which world did this run actually measure" is answered in the
  # verdict line rather than inferred from an environment nobody printed.
  procsub_arms() {
    local label="$1"; shift
    local inv="$*"
    local world ver det_out

    # The version is asked OF THE INTERPRETER THAT RAN, never taken from
    # $BASH_VERSION: that is a builtin of the shell running this census, and it
    # is only ever right about $inv by coincidence. Under an override to a
    # different bash it would name the wrong interpreter at exactly the moment a
    # reader consults the line to learn which world was measured.
    ver=$($inv -c 'printf "%s" "${BASH_VERSION:-not bash}"' 2>/dev/null)
    [ -n "$ver" ] || ver="unreadable"

    $inv "$DET" > "$TMPDIR_CENSUS/det.out" 2> "$TMPDIR_CENSUS/det.err"
    det_out=$(cat "$TMPDIR_CENSUS/det.out")
    if [ "$det_out" = "[x]" ]; then
      world=allows
    elif [ "$det_out" = "[]" ] && grep -q "command substitution" "$TMPDIR_CENSUS/det.err"; then
      world=refuses
    else
      echo "posix-vacuous-green-census --selftest: CANNOT READ — the procsub probe under '$inv' answered neither '[x]' (allows) nor '[]' + an expansion-time command-substitution error (refuses). It printed '$det_out' with stderr: $(cat "$TMPDIR_CENSUS/det.err"). This selftest cannot say which world it is in, so it asserts nothing rather than guessing." >&2
      exit 2
    fi
    ok "procsub-under-posix[$label/precondition]: '$inv' (bash $ver, asked of that interpreter) $world a process substitution nested in a command substitution — the branch below is chosen by this measurement, never by uname"

    $inv -n "$VAC" > "$TMPDIR_CENSUS/vac.parse" 2>&1;            VAC_PARSE_RC=$?
    $inv    "$VAC" > "$TMPDIR_CENSUS/vac.out" 2> "$TMPDIR_CENSUS/vac.err"; VAC_RUN_RC=$?
    bash    "$VAC" > "$TMPDIR_CENSUS/ctl.out" 2>&1;              VAC_CTL_RC=$?
    $inv    "$TWIN" > "$TMPDIR_CENSUS/twin.out" 2> "$TMPDIR_CENSUS/twin.err"; TWIN_RC=$?

    [ "$VAC_PARSE_RC" -eq 0 ] \
      && ok "procsub-under-posix[$label/parse]: \`$inv -n\` on the fixture EXITS $VAC_PARSE_RC — the static check answers 0 in BOTH worlds, which is why it is worth nothing in either" \
      || no "procsub-under-posix[$label/parse]: expected the parse check to exit 0, got rc=$VAC_PARSE_RC: $(cat "$TMPDIR_CENSUS/vac.parse")"

    if [ "$world" = refuses ]; then
      { [ "$VAC_RUN_RC" -eq 0 ] && grep -q "FIXTURE TEST PASSED" "$TMPDIR_CENSUS/vac.out"; } \
        && ok "procsub-under-posix[$label/run/vacuous]: the run EXITS $VAC_RUN_RC and prints \"$(grep -- '---- ' "$TMPDIR_CENSUS/vac.out")\" + FIXTURE TEST PASSED — this is the variant a macOS reader gets" \
        || no "procsub-under-posix[$label/run/vacuous]: this interpreter refuses the construct, so the run must exit 0 announcing a pass, got rc=$VAC_RUN_RC: $(cat "$TMPDIR_CENSUS/vac.out") / $(cat "$TMPDIR_CENSUS/vac.err")"

      { grep -q "syntax error near unexpected token" "$TMPDIR_CENSUS/vac.err" \
          && grep -q "command substitution" "$TMPDIR_CENSUS/vac.err"; } \
        && ok "procsub-under-posix[$label/compared-nothing]: stderr carries the EXPANSION-time \`command substitution: syntax error\` — both operands were empty, so the two checks compared nothing" \
        || no "procsub-under-posix[$label/compared-nothing]: expected an expansion-time command-substitution syntax error on stderr, got: $(cat "$TMPDIR_CENSUS/vac.err")"

      { [ "$VAC_CTL_RC" -ne 0 ] && grep -q "FAIL: left operand differs" "$TMPDIR_CENSUS/ctl.out"; } \
        && ok "procsub-under-posix[$label/control]: real bash on the SAME file EXITS $VAC_CTL_RC and reds both comparisons — the 0 above was vacuous, not honest" \
        || no "procsub-under-posix[$label/control]: the fixture must FAIL under real bash or it proves nothing, got rc=$VAC_CTL_RC: $(cat "$TMPDIR_CENSUS/ctl.out")"
    else
      { [ "$VAC_RUN_RC" -ne 0 ] && grep -q "FAIL: left operand differs" "$TMPDIR_CENSUS/vac.out" \
          && grep -q "FAIL: right operand differs" "$TMPDIR_CENSUS/vac.out"; } \
        && ok "procsub-under-posix[$label/run/loud]: the run EXITS $VAC_RUN_RC and reds BOTH comparisons — where the construct is allowed the same class arrives loudly, and there is nothing vacuous left to hide in" \
        || no "procsub-under-posix[$label/run/loud]: this interpreter allows the construct, so the run must red both comparisons, got rc=$VAC_RUN_RC: $(cat "$TMPDIR_CENSUS/vac.out") / $(cat "$TMPDIR_CENSUS/vac.err")"

      grep -q -- "---- 2 failure(s), 2 pass(es)" "$TMPDIR_CENSUS/vac.out" \
        && ok "procsub-under-posix[$label/compared-something]: the tally line says \"---- 2 failure(s), 2 pass(es)\" — both comparisons produced a verdict, the opposite of the vacuous branch" \
        || no "procsub-under-posix[$label/compared-something]: expected a 2-failure tally proving both comparisons ran, got: $(cat "$TMPDIR_CENSUS/vac.out")"

      # CONTROL for the loud branch: a twin with IDENTICAL operands. If the red
      # above came from the fixture always reding rather than from a measured
      # difference, this would red too.
      { [ "$TWIN_RC" -eq 0 ] && ! grep -q "operand differs" "$TMPDIR_CENSUS/twin.out"; } \
        && ok "procsub-under-posix[$label/control]: the honest twin — same construct, IDENTICAL operands — EXITS $TWIN_RC green, so the red above is a measured difference, not a fixture that always reds" \
        || no "procsub-under-posix[$label/control]: the identical-operand twin must pass or the loud arm proves nothing, got rc=$TWIN_RC: $(cat "$TMPDIR_CENSUS/twin.out") / $(cat "$TMPDIR_CENSUS/twin.err")"
    fi
  }

  # The DEFAULT pass, always. This is the invocation a reader gets when they type
  # `sh scripts/whatever.test.sh`: bash in POSIX mode. Nothing can switch it off.
  procsub_arms default bash --posix

  # The OVERRIDE pass, only when asked for, and only as an ADDITION. It exists so
  # a host that has just one of the two worlds can still exercise the other — a
  # macOS developer running `CENSUS_SELFTEST_POSIX_SH=bash` measures exactly what
  # CI will measure, which is how the platform-specific red this arm used to
  # carry would have been caught before it shipped.
  if [ -n "${CENSUS_SELFTEST_POSIX_SH:-}" ] && [ "$CENSUS_SELFTEST_POSIX_SH" != "bash --posix" ]; then
    procsub_arms override $CENSUS_SELFTEST_POSIX_SH
  fi
  echo
  echo "----"
  # DERIVED, never hand-counted: a tally typed as a literal survives the arm you
  # forgot to run. `passes` is incremented by ok(), and the floor makes a
  # selftest that silently executed fewer arms than it carries exit 2 rather than
  # print a smaller, clean-looking green. Floor = the arm count at the time this
  # was written (2026-09-15), raised deliberately whenever an arm is added.
  # It is BRANCH-INVARIANT on purpose: the procsub-under-posix branches emit the
  # same number of verdicts, so a host that takes the other one cannot come in
  # under the floor and read as a smaller, clean-looking green. It is a FLOOR and
  # not an equality, which is what lets the override pass ADD four arms (21) on a
  # host that asks for one (22) without loosening anything for a host that does not.
  ARMS_FLOOR=19
  reported=$((passes + fails))
  if [ "$reported" -lt "$ARMS_FLOOR" ]; then
    echo "posix-vacuous-green-census --selftest: CANNOT READ — only $reported arms reported a verdict, floor is $ARMS_FLOOR; this run measured LESS than the selftest carries" >&2
    exit 2
  fi
  if [ "$fails" -eq 0 ]; then echo "$passes passed, 0 failed"; exit 0; fi
  echo "$passes passed, $fails failed"; exit 1
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
