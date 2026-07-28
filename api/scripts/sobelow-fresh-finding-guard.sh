#!/usr/bin/env bash
#
# Proof that a NEW insecure pattern still reds the Sobelow gate.
#
# WHY. `mix sobelow --skip --exit Low` reads the api/.sobelow-skips baseline.
# A baseline is a promise about the PAST; the only thing that makes it safe is
# that a finding introduced TODAY is not in it and therefore still speaks. This
# script plants a `String.to_atom/1` (DOS.StringToAtom) probe, rescans, and
# proves the scanner named THAT probe.
#
# WHAT IT ASSERTS, and why it is not the exit status. The obvious assertion —
# "the scan exits 1" — is UNATTRIBUTABLE on a tree that is already red: main
# exits 1 for its own unbaselined findings, so that assertion is satisfied
# BEFORE the probe is planted and proves nothing about the probe. So the guard
# asserts a TRANSITION instead: a pre-plant scan that does NOT name the probe,
# then a post-plant scan that DOES (by detector name AND by filename). That
# holds whether main is green or red, and it is what `--selftest` mutates.
#
# EXIT CODES
#   0  transition observed: probe absent from the pre-plant scan, named by the
#      post-plant scan, and removed from the worktree again
#   1  no transition (scanner did not name the probe, or already named it
#      before it existed), or the probe survived cleanup
#   2  usage error, or a precondition that makes the run meaningless (probe
#      path already occupied, scan output missing)
#
# The probe is planted in the tracked tree for the duration of one scan and is
# removed on every exit path, including failure and interrupt.

set -euo pipefail

usage() {
  cat <<'USAGE'
usage: sobelow-fresh-finding-guard.sh [--probe PATH] [--scan-cmd CMD] [--selftest]

  --probe PATH   file to plant the String.to_atom probe at
                 (default: api/lib/barkpark/sobelow_fresh_finding_guard.ex)
  --scan-cmd CMD shell command whose stdout+stderr is the scan report
                 (default: mix sobelow --skip --exit Low, run in api/)
  --selftest     run the mutation fixtures that prove this guard can fail,
                 then exit; does not touch the tracked tree
USAGE
}

API_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROBE="$API_DIR/lib/barkpark/sobelow_fresh_finding_guard.ex"
SCAN_CMD=""
SELFTEST=0
DETECTOR='DOS.StringToAtom'

while [[ $# -gt 0 ]]; do
  case $1 in
    --probe)
      [[ $# -ge 2 ]] || { echo "error: --probe needs a value" >&2; exit 2; }
      PROBE=$2
      shift 2
      ;;
    --scan-cmd)
      [[ $# -ge 2 ]] || { echo "error: --scan-cmd needs a value" >&2; exit 2; }
      SCAN_CMD=$2
      shift 2
      ;;
    --selftest)
      SELFTEST=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      # An ignored unknown argument is how `--selftest` used to "pass" on a
      # script that had no selftest at all. Fail closed instead.
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

PROBE_MARKER=$(basename -- "$PROBE")

# `cc` on a developer machine can be shadowed by a non-compiler wrapper, which
# blows up the Erlang crypto NIF build that `mix sobelow`'s compile step needs.
# Respect an explicit CC (CI sets its own toolchain); otherwise discover a real
# compiler on PATH. Never pin an absolute path that may not exist on the runner
# image — the old `/usr/bin/clang` default was exactly that assumption.
if [[ -z ${CC:-} ]]; then
  for candidate in clang gcc cc; do
    if resolved=$(command -v -- "$candidate" 2>/dev/null); then
      CC=$resolved
      break
    fi
  done
fi
[[ -n ${CC:-} ]] && export CC

if [[ -z $SCAN_CMD ]]; then
  SCAN_CMD='mix sobelow --skip --exit Low'
fi

SCAN_STATUS=0
run_scan() { # $1 = output file; leaves the scanner's exit status in SCAN_STATUS
  local out=$1
  SCAN_STATUS=0
  ( cd -- "$API_DIR" && eval "$SCAN_CMD" ) >"$out" 2>&1 || SCAN_STATUS=$?
}

# --- the two load-bearing assertions (the --selftest mutation targets) -------

assert_probe_reported() {
  local out=$1
  if ! grep -q -- "$DETECTOR" "$out" || ! grep -qF -- "$PROBE_MARKER" "$out"; then
    echo "error: post-plant scan did not name the planted probe ($DETECTOR in $PROBE_MARKER)" >&2
    return 1
  fi
  echo "  ok  post-plant scan names $DETECTOR in $PROBE_MARKER"
}

assert_transition() {
  local out=$1
  if grep -qF -- "$PROBE_MARKER" "$out"; then
    echo "error: pre-plant scan ALREADY named $PROBE_MARKER — no transition to observe" >&2
    return 1
  fi
  echo "  ok  pre-plant scan does not name $PROBE_MARKER"
}

# --- the guard ---------------------------------------------------------------

QUARANTINE=""
cleanup() {
  if [[ -n $QUARANTINE ]]; then
    if [[ -e $PROBE ]]; then
      mv -f -- "$PROBE" "$QUARANTINE/probe.ex" 2>/dev/null || rm -f -- "$PROBE"
    fi
    # The old script leaked one mktemp -d per run. Scan output is echoed to
    # stdout above, so nothing here needs to outlive the run.
    rm -rf -- "$QUARANTINE"
    QUARANTINE=""
  fi
}

run_guard() {
  if [[ -e $PROBE ]]; then
    echo "error: refusing to overwrite existing probe path: $PROBE" >&2
    return 2
  fi

  QUARANTINE=$(mktemp -d "${TMPDIR:-/tmp}/sobelow-fresh-finding.XXXXXX")
  trap cleanup EXIT INT TERM

  local before="$QUARANTINE/before.out" after="$QUARANTINE/after.out"

  run_scan "$before"
  local before_status=$SCAN_STATUS
  echo "pre-plant scan exit=$before_status"
  assert_transition "$before" || return 1

  cat > "$PROBE" <<'PROBE'
defmodule Barkpark.SobelowFreshFindingGuard do
  def leak(key), do: String.to_atom(key)
end
PROBE

  run_scan "$after"
  local after_status=$SCAN_STATUS
  cat "$after"
  echo "post-plant scan exit=$after_status"

  assert_probe_reported "$after" || return 1

  if [[ $after_status -eq 0 ]]; then
    echo "error: post-plant scan named the probe but still exited 0 — --exit Low is not binding" >&2
    return 1
  fi

  cleanup
  trap - EXIT INT TERM
  if [[ -e $PROBE ]]; then
    echo "error: planted Sobelow probe was not removed from the worktree" >&2
    return 1
  fi
  printf 'PASS: fresh %s finding absent before the probe, reported after it (exit %d -> %d); probe restored absent\n' \
    "$DETECTOR" "$before_status" "$after_status"
}

# --- selftest: prove the guard can fail, on each assertion separately --------

# A fake scanner stands in for `mix sobelow` so the fixtures run in ~0s and can
# script the exact situations that matter: a red main, a green main, a scanner
# that never sees the probe, and a report that names the probe before it is
# planted.
write_fake_scanner() {
  cat > "$1" <<'SCANNER'
#!/usr/bin/env bash
# FAKE_MODE=honest   report the probe only when the probe file exists
# FAKE_MODE=blind    never report the probe (scanner is asleep)
# FAKE_MODE=poisoned report the probe always, even before it is planted
# MAIN_RED=1         emit an unrelated pre-existing finding (main already red)
set -u
found=0
if [[ ${MAIN_RED:-0} == 1 ]]; then
  echo 'Config.CSP: Missing Content-Security-Policy - lib/barkpark_web/router.ex:12'
  found=1
fi
case ${FAKE_MODE:-honest} in
  honest) [[ -e ${FAKE_PROBE:?} ]] && report=1 || report=0 ;;
  blind) report=0 ;;
  poisoned) report=1 ;;
  *) echo "fake scanner: bad FAKE_MODE" >&2; exit 3 ;;
esac
if [[ $report == 1 ]]; then
  echo "DOS.StringToAtom: Unsafe atom interpolation - $(basename -- "${FAKE_PROBE:?}"):2"
  found=1
fi
[[ $found == 1 ]] && exit 1
exit 0
SCANNER
  chmod +x "$1"
}

# Run the four fixtures against $1 (this script, or a mutant of it). Returns 0
# only if every fixture produced the expected exit status.
run_fixture_suite() {
  local script=$1 label=$2 scanner=$3 root=$4
  local failures=0 case_no=0

  fixture() { # <name> <expected exit> <FAKE_MODE> <MAIN_RED>
    local name=$1 want=$2 mode=$3 red=$4 got=0 out probe
    case_no=$((case_no + 1))
    probe="$root/case-$case_no/lib/barkpark/sobelow_fresh_finding_guard.ex"
    mkdir -p -- "$(dirname -- "$probe")"
    out=$(bash "$script" --probe "$probe" \
      --scan-cmd "FAKE_MODE=$mode MAIN_RED=$red FAKE_PROBE='$probe' '$scanner'" 2>&1) || got=$?
    if [[ $got -ne $want ]]; then
      printf '  FAIL  %-38s expected exit %d, got %d\n%s\n' "$name" "$want" "$got" "$out" >&2
      failures=1
      return 0
    fi
    if [[ -e $probe ]]; then
      printf '  FAIL  %-38s probe left behind at %s\n' "$name" "$probe" >&2
      failures=1
      return 0
    fi
    printf '  ok    %-38s exit %d\n' "$name" "$got"
  }

  echo "fixtures against $label:"
  fixture "honest scanner, main already red" 0 honest 1
  fixture "honest scanner, main green" 0 honest 0
  fixture "scanner never names the probe" 1 blind 1
  fixture "probe named BEFORE it is planted" 1 poisoned 1
  unset -f fixture
  return "$failures"
}

# Replace a shell function's body with `return 0`, i.e. delete the assertion.
mutate_out_function() {
  local fn=$1 src=$2 dst=$3
  awk -v fn="$fn" '
    !skip && $0 == fn"() {" { print fn"() { return 0; }"; skip = 1; next }
    skip && $0 == "}" { skip = 0; next }
    !skip { print }
  ' "$src" > "$dst"
  if cmp -s -- "$src" "$dst"; then
    echo "error: mutation '$fn' was a no-op — the selftest would prove nothing" >&2
    return 2
  fi
}

run_selftest() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/sobelow-fresh-selftest.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf -- '$tmp'" RETURN
  local scanner="$tmp/fake-sobelow.sh"
  write_fake_scanner "$scanner"

  local self="${BASH_SOURCE[0]}" failures=0

  mkdir -p "$tmp/real"
  run_fixture_suite "$self" "the guard as written" "$scanner" "$tmp/real" || failures=1

  # Mutation 1: neuter the probe-name grep. The blind-scanner fixture must stop
  # failing, which makes the suite red.
  local m1="$tmp/mutant-no-probe-grep.sh"
  mutate_out_function assert_probe_reported "$self" "$m1" || return 2
  mkdir -p "$tmp/m1"
  echo
  if run_fixture_suite "$m1" "MUTANT: probe-name grep neutered" "$scanner" "$tmp/m1" 2>/dev/null; then
    echo "SELFTEST FAIL: mutant with no probe-name grep still passed every fixture" >&2
    failures=1
  else
    echo "  ok    mutation caught: neutering the probe-name grep reds the fixtures"
  fi

  # Mutation 2: remove the transition assertion. The poisoned fixture (probe
  # reported before it exists) must stop failing, which makes the suite red.
  local m2="$tmp/mutant-no-transition.sh"
  mutate_out_function assert_transition "$self" "$m2" || return 2
  mkdir -p "$tmp/m2"
  echo
  if run_fixture_suite "$m2" "MUTANT: transition assertion removed" "$scanner" "$tmp/m2" 2>/dev/null; then
    echo "SELFTEST FAIL: mutant with no transition assertion still passed every fixture" >&2
    failures=1
  else
    echo "  ok    mutation caught: removing the transition assertion reds the fixtures"
  fi

  echo
  if [[ $failures -ne 0 ]]; then
    echo "SELFTEST FAILED" >&2
    return 1
  fi
  echo "SELFTEST PASS: the guard greens on a real transition (red or green main), reds when the scanner"
  echo "               never names the probe, reds when the probe is named before it exists, and each"
  echo "               of those two assertions is proven load-bearing by deleting it."
}

if [[ $SELFTEST -eq 1 ]]; then
  run_selftest
  exit $?
fi

run_guard
