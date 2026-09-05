#!/usr/bin/env bash
# toolchain-skew-check.sh — the Elixir pin-agreement gate.
#
# WHAT THIS GUARDS, stated narrowly, because the row that asked for it
# (task-0c3081a2e534bdfc) was RESTATED on 2026-09-01 precisely because the
# original wording was wide enough to send someone to "fix" a CORRECT pin.
#
# The pins, as measured on origin/main 2026-09-05:
#
#   .tool-versions              elixir 1.18.4-otp-27   <- the Hetzner prod box (asdf)
#   .github/workflows elixir.yml mix-test              1.18.4
#   .github/workflows elixir.yml mix-prod-compile      1.18.4
#   api/Dockerfile FROM (build) elixir:1.19-alpine     <- self-host / compose image
#   .github/workflows elixir.yml format                1.19.5  (DELIBERATE, see below)
#   .github/workflows elixir.yml validation-perf       1.18.1  (same 1.18 minor)
#
# RULE 1 — HARD, and it is the row's title claim. The production toolchain
# (.tool-versions, which is what asdf resolves on the box) must be covered, to
# MAJOR.MINOR, by the two jobs whose green is supposed to mean "it works on the
# box": mix-test and mix-prod-compile. Today it is. This check exists so that a
# future edit to either side cannot silently break that.
#
# WHY MAJOR.MINOR AND NOT EXACT. Elixir's compatibility unit is the minor: a
# patch bump inside 1.18 is not a compiler major nobody ran. Demanding exact
# equality would red on `1.18.4` vs `1.18.1` — a difference the suite's own
# validation-perf job already carries on purpose — and a gate that reds on a
# non-defect gets waived, which is how a gate dies.
#
# WHAT IS DELIBERATELY *NOT* RULE 1. The `format` job runs 1.19.5 ON PURPOSE:
# `mix format` output is Elixir-version-contaminated and the fleet's local boxes
# run 1.19.5, so the formatter pin tracks the AUTHORING toolchain, not the box.
# elixir.yml says so at length above that matrix. Folding format into Rule 1
# would red a correct, documented decision — so it is out.
#
# RULE 2 — THE ACKNOWLEDGED DIVERGENCE. api/Dockerfile's build stage is
# elixir:1.19-alpine. That image is consumed by docker-compose.yml /
# compose-smoke.yml — the SELF-HOST distribution path — so the self-host image
# is built on an Elixir minor the unit suite never runs. It is smoke-booted, not
# suite-tested. That is a real gap and a SMALL one: smoke boot proves the
# release starts, it does not prove the semantics the suite pins.
#
# The two candidate remedies are one-line each and they are DIFFERENT decisions
# (pin the image down to 1.18.4, or add 1.19 to the test matrix so the
# distribution path is suite-covered). The row hands that call to the owner and
# says in terms: do not change the pins on the strength of it. So this check
# does not pick. It RECORDS the divergence, by value, with the task id — and
# reds the moment reality stops matching the record, in EITHER direction:
#
#   * the Dockerfile minor moves again      -> red, the record is stale
#   * the test matrix gains 1.19 (resolved) -> red, delete the record
#
# So the gap cannot change shape in silence, and whichever way the owner
# decides, the decision must come back through this file.
#
# EXIT CODES: 0 pins agree · 1 skew (both disagreeing values named) · 2 a pin
# could not be read (REFUSAL — never a pass; an unreadable pin is not agreement).
#
# bash 3.2 compatible (macOS runs it too): no associative arrays, no mapfile.
# No python, no yaml library, no network — it is three greps over three files.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TOOL_VERSIONS="${TOOLCHAIN_SKEW_TOOL_VERSIONS:-$REPO_ROOT/.tool-versions}"
DOCKERFILE="${TOOLCHAIN_SKEW_DOCKERFILE:-$REPO_ROOT/api/Dockerfile}"
WORKFLOW="${TOOLCHAIN_SKEW_WORKFLOW:-$REPO_ROOT/.github/workflows/elixir.yml}"

# ── the acknowledged divergence (Rule 2). ONE record, by value, with the row. ─
# MUT: ack-record
ACK_TASK="task-0c3081a2e534bdfc"
ACK_DOCKERFILE_MM="1.19"
ACK_MATRIX_MM="1.18"

refuse() { echo "REFUSAL: $*" >&2; exit 2; }

# minor_of 1.18.4-otp-27 -> 1.18 ; 1.19-alpine -> 1.19
minor_of() {
  printf '%s' "$1" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*$/\1/p'
}

# The elixir version pinned in .tool-versions (what asdf resolves on the box).
read_tool_versions() {
  [ -f "$TOOL_VERSIONS" ] || refuse "cannot read the production pin: $TOOL_VERSIONS does not exist"
  local v
  v="$(sed -n 's/^[[:space:]]*elixir[[:space:]][[:space:]]*\([^[:space:]][^[:space:]]*\).*$/\1/p' "$TOOL_VERSIONS" | head -1)"
  [ -n "$v" ] || refuse "no \`elixir <version>\` line in $TOOL_VERSIONS"
  printf '%s' "$v"
}

# The elixir tag on the FIRST `FROM elixir:...` in the Dockerfile (the build
# stage — the runtime stage is a bare alpine and carries no compiler).
read_dockerfile() {
  [ -f "$DOCKERFILE" ] || refuse "cannot read the image pin: $DOCKERFILE does not exist"
  local v
  v="$(sed -n 's/^[[:space:]]*FROM[[:space:]][[:space:]]*elixir:\([^[:space:]]*\).*$/\1/p' "$DOCKERFILE" | head -1)"
  [ -n "$v" ] || refuse "no \`FROM elixir:<tag>\` line in $DOCKERFILE"
  printf '%s' "$v"
}

# The `elixir: [...]` matrix of one job id in the workflow. Scans from the job's
# own `  <id>:` line to the next top-level job key, so a matrix belonging to a
# DIFFERENT job can never be read as this one's — the failure mode that makes a
# by-position parser guess permissively.
read_matrix() {
  local job="$1" v
  [ -f "$WORKFLOW" ] || refuse "cannot read the CI matrix: $WORKFLOW does not exist"
  v="$(awk -v job="$job" '
    $0 == "  " job ":" { injob = 1; next }
    injob && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { injob = 0 }
    injob && /^[[:space:]]*elixir:[[:space:]]*\[/ { print; exit }
  ' "$WORKFLOW" | sed -n 's/.*\[\(.*\)\].*/\1/p' | tr -d '" ' )"
  [ -n "$v" ] || refuse "no \`elixir: [...]\` matrix under job \`${job}\` in $WORKFLOW"
  printf '%s' "$v"
}

# Does MAJOR.MINOR $2 appear among the comma-separated versions in $1?
matrix_covers() {
  local list="$1" want="$2" one
  local IFS=,
  for one in $list; do
    [ "$(minor_of "$one")" = "$want" ] && return 0
  done
  return 1
}

run_check() {
  local tv docker test_m prod_m tv_mm docker_mm test_mm rc=0
  tv="$(read_tool_versions)"   || exit 2
  docker="$(read_dockerfile)"  || exit 2
  test_m="$(read_matrix mix-test)"          || exit 2
  prod_m="$(read_matrix mix-prod-compile)"  || exit 2

  tv_mm="$(minor_of "$tv")"
  docker_mm="$(minor_of "$docker")"
  test_mm="$(minor_of "$test_m")"
  [ -n "$tv_mm" ]     || refuse ".tool-versions elixir pin is not a version: '${tv}'"
  [ -n "$docker_mm" ] || refuse "Dockerfile elixir tag is not a version: '${docker}'"

  # POSITIVE CONTROL — always print what was actually read, so a green can be
  # told apart from a check that read nothing.
  echo "PINS READ"
  echo "  .tool-versions        elixir ${tv}            (MAJOR.MINOR ${tv_mm})  <- production box, via asdf"
  echo "  api/Dockerfile FROM   elixir:${docker}        (MAJOR.MINOR ${docker_mm})  <- self-host image"
  echo "  elixir.yml mix-test          elixir [${test_m}]"
  echo "  elixir.yml mix-prod-compile  elixir [${prod_m}]"
  echo

  # ── RULE 1 ────────────────────────────────────────────────────────────────
  if matrix_covers "$test_m" "$tv_mm"; then
    echo "ok   - RULE 1a: .tool-versions ${tv} is covered by mix-test [${test_m}] (both ${tv_mm})"
  else
    echo "FAIL - RULE 1a: the production Elixir is not suite-tested."
    echo "       .tool-versions says ${tv} (${tv_mm}); elixir.yml job \`mix-test\` runs [${test_m}]."
    echo "       Fix the pin the box does NOT use, or add ${tv_mm} to the mix-test matrix."
    rc=1
  fi
  if matrix_covers "$prod_m" "$tv_mm"; then
    echo "ok   - RULE 1b: .tool-versions ${tv} is covered by mix-prod-compile [${prod_m}] (both ${tv_mm})"
  else
    echo "FAIL - RULE 1b: the production Elixir has no prod-compile gate."
    echo "       .tool-versions says ${tv} (${tv_mm}); elixir.yml job \`mix-prod-compile\` runs [${prod_m}]."
    rc=1
  fi

  # ── RULE 2 ────────────────────────────────────────────────────────────────
  if [ "$docker_mm" = "$test_mm" ]; then
    echo "FAIL - RULE 2: the acknowledged divergence is RESOLVED — delete the record."
    echo "       api/Dockerfile is now elixir:${docker} (${docker_mm}) and mix-test runs [${test_m}]."
    echo "       ${ACK_TASK} recorded ${ACK_DOCKERFILE_MM} vs ${ACK_MATRIX_MM}. Remove the ACK_* block"
    echo "       in $(basename "${BASH_SOURCE[0]}") and fold the Dockerfile into RULE 1."
    rc=1
  elif [ "$docker_mm" = "$ACK_DOCKERFILE_MM" ] && [ "$test_mm" = "$ACK_MATRIX_MM" ]; then
    echo "ok   - RULE 2: divergence unchanged and acknowledged by ${ACK_TASK}:"
    echo "       self-host image elixir:${docker} (${docker_mm}) vs suite matrix [${test_m}] (${test_mm})."
    echo "       Smoke-booted, not suite-tested. Owner's call: pin the image down, or widen the matrix."
  else
    echo "FAIL - RULE 2: the divergence CHANGED SHAPE and nobody said so."
    echo "       recorded by ${ACK_TASK}: Dockerfile ${ACK_DOCKERFILE_MM} vs mix-test ${ACK_MATRIX_MM}"
    echo "       measured now:            Dockerfile ${docker_mm} vs mix-test ${test_mm}"
    echo "       Update the ACK_* record with the new values, or restore the pins."
    rc=1
  fi

  return $rc
}

# ── selftest: planted pin files, three outcomes ─────────────────────────────
# TSKEW_TMP is deliberately GLOBAL: an EXIT trap fires after the function's
# locals are gone, and `rm -rf "$tmp"` on an unset local dies under `set -u`.
TSKEW_TMP=""
selftest() {
  local pass=0 fail=0 tmp out rc
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/tskew.XXXXXX")" || { echo "HARNESS-UNAVAILABLE: mktemp failed" >&2; exit 2; }
  TSKEW_TMP="$tmp"
  trap 'rm -rf "$TSKEW_TMP"' EXIT

  plant() { # plant <dir> <tool-versions elixir> <dockerfile elixir tag> <test matrix> <prod matrix>
    mkdir -p "$1"
    printf 'erlang 27.3.4\nelixir %s\nnodejs 26.5.0\n' "$2" > "$1/tv"
    printf 'FROM elixir:%s AS build\nFROM alpine:3.23\n' "$3" > "$1/Dockerfile"
    cat > "$1/wf.yml" <<PLANT
jobs:
  format:
    strategy:
      matrix:
        elixir: ["9.99.9"]
  mix-test:
    strategy:
      matrix:
        elixir: [$4]
  mix-prod-compile:
    strategy:
      matrix:
        elixir: [$5]
PLANT
  }

  probe() { # probe <dir>  -> prints output, returns exit code
    TOOLCHAIN_SKEW_TOOL_VERSIONS="$1/tv" \
    TOOLCHAIN_SKEW_DOCKERFILE="$1/Dockerfile" \
    TOOLCHAIN_SKEW_WORKFLOW="$1/wf.yml" \
    bash "${BASH_SOURCE[0]}" --check 2>&1
  }

  ok()  { pass=$((pass + 1)); echo "ok   - $*"; }
  bad() { fail=$((fail + 1)); echo "FAIL - $*"; }

  # A — AGREE: prod pin covered, divergence exactly as acknowledged -> green
  plant "$tmp/a" "1.18.4-otp-27" "1.19-alpine" '"1.18.4"' '"1.18.4"'
  out="$(probe "$tmp/a")"; rc=$?
  [ $rc -eq 0 ] && ok "A agree -> exit 0" || bad "A agree -> exit $rc (want 0)"
  case "$out" in *"1.18.4"*) ok "A prints the versions it read (positive control)";; *) bad "A printed no versions";; esac

  # B — DISAGREE on RULE 1: the box runs 1.18, the suite runs 1.20 -> red, both named
  plant "$tmp/b" "1.18.4-otp-27" "1.19-alpine" '"1.20.0"' '"1.20.0"'
  out="$(probe "$tmp/b")"; rc=$?
  [ $rc -eq 1 ] && ok "B rule-1 skew -> exit 1" || bad "B rule-1 skew -> exit $rc (want 1)"
  case "$out" in *"1.18.4"*) ok "B names the production value";; *) bad "B did not name 1.18.4";; esac
  case "$out" in *"1.20.0"*) ok "B names the matrix value";;     *) bad "B did not name 1.20.0";; esac
  case "$out" in *"RULE 1a"*) ok "B names the specific rule";;    *) bad "B did not name RULE 1a";; esac

  # B2 — RULE 1b alone: mix-test covers the box, mix-prod-compile does not
  plant "$tmp/b2" "1.18.4-otp-27" "1.19-alpine" '"1.18.4"' '"1.20.0"'
  out="$(probe "$tmp/b2")"; rc=$?
  [ $rc -eq 1 ] && ok "B2 prod-compile skew -> exit 1" || bad "B2 prod-compile skew -> exit $rc (want 1)"
  case "$out" in *"RULE 1b"*) ok "B2 names RULE 1b";; *) bad "B2 did not name RULE 1b";; esac

  # C — RULE 2, shape changed: the image moved to a third minor -> red, both named
  plant "$tmp/c" "1.18.4-otp-27" "1.21-alpine" '"1.18.4"' '"1.18.4"'
  out="$(probe "$tmp/c")"; rc=$?
  [ $rc -eq 1 ] && ok "C divergence changed shape -> exit 1" || bad "C changed shape -> exit $rc (want 1)"
  case "$out" in *"1.21"*) ok "C names the new image value";;  *) bad "C did not name 1.21";; esac
  case "$out" in *"RULE 2"*) ok "C names RULE 2";;             *) bad "C did not name RULE 2";; esac

  # D — RULE 2, resolved: the matrix caught up -> red, telling you to delete the record
  plant "$tmp/d" "1.19.0-otp-27" "1.19-alpine" '"1.19.0"' '"1.19.0"'
  out="$(probe "$tmp/d")"; rc=$?
  [ $rc -eq 1 ] && ok "D divergence resolved -> exit 1 (stale record)" || bad "D resolved -> exit $rc (want 1)"
  case "$out" in *"delete the record"*) ok "D says to delete the record";; *) bad "D did not say delete";; esac

  # E — patch-level difference inside one minor is NOT skew (the tolerance)
  plant "$tmp/e" "1.18.4-otp-27" "1.19-alpine" '"1.18.1"' '"1.18.9"'
  out="$(probe "$tmp/e")"; rc=$?
  [ $rc -eq 0 ] && ok "E same minor, different patch -> exit 0 (MAJOR.MINOR tolerance)" || bad "E patch skew -> exit $rc (want 0)"

  # F — UNREADABLE pins must REFUSE (exit 2), never green
  mkdir -p "$tmp/f"; plant "$tmp/f" "1.18.4-otp-27" "1.19-alpine" '"1.18.4"' '"1.18.4"'
  rm -f "$tmp/f/tv"
  out="$(probe "$tmp/f")"; rc=$?
  [ $rc -eq 2 ] && ok "F missing .tool-versions -> exit 2 refusal" || bad "F missing tool-versions -> exit $rc (want 2)"

  plant "$tmp/g" "1.18.4-otp-27" "1.19-alpine" '"1.18.4"' '"1.18.4"'
  printf 'erlang 27.3.4\nnodejs 26.5.0\n' > "$tmp/g/tv"   # no elixir line at all
  out="$(probe "$tmp/g")"; rc=$?
  [ $rc -eq 2 ] && ok "G .tool-versions without an elixir line -> exit 2 refusal" || bad "G no elixir line -> exit $rc (want 2)"
  case "$out" in *REFUSAL*) ok "G says REFUSAL";; *) bad "G did not say REFUSAL";; esac

  plant "$tmp/h" "1.18.4-otp-27" "1.19-alpine" '"1.18.4"' '"1.18.4"'
  printf 'FROM alpine:3.23\n' > "$tmp/h/Dockerfile"       # no FROM elixir: at all
  out="$(probe "$tmp/h")"; rc=$?
  [ $rc -eq 2 ] && ok "H Dockerfile without FROM elixir -> exit 2 refusal" || bad "H no FROM elixir -> exit $rc (want 2)"

  plant "$tmp/i" "1.18.4-otp-27" "1.19-alpine" '"1.18.4"' '"1.18.4"'
  printf 'jobs:\n  format:\n    strategy:\n      matrix:\n        elixir: ["9.9.9"]\n' > "$tmp/i/wf.yml"
  out="$(probe "$tmp/i")"; rc=$?
  [ $rc -eq 2 ] && ok "I workflow without a mix-test matrix -> exit 2 refusal" || bad "I no mix-test -> exit $rc (want 2)"
  # and the refusal must name mix-test, not silently read the format matrix
  case "$out" in *mix-test*) ok "I refusal names the missing job";; *) bad "I refusal did not name mix-test";; esac

  # J — the scanner must not read a NEIGHBOURING job's matrix as mix-test's
  plant "$tmp/j" "1.18.4-otp-27" "1.19-alpine" '"1.20.0"' '"1.20.0"'
  out="$(probe "$tmp/j")"; rc=$?
  case "$out" in *"9.99.9"*) bad "J read the format job's matrix as mix-test's";; *) ok "J does not bleed the format matrix into mix-test";; esac

  echo
  echo "selftest: ${pass} passed, ${fail} failed"
  [ "$fail" -eq 0 ] || return 1
  return 0
}

case "${1:---check}" in
  --selftest) selftest ;;
  --check)    run_check ;;
  *) echo "usage: $(basename "${BASH_SOURCE[0]}") [--check|--selftest]" >&2; exit 2 ;;
esac
