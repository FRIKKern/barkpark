#!/usr/bin/env bash
# Paper-excellence render gate — hermetic: no server, no database, no network.
#
#   bash tooling/paper-excellence/rig/gate.sh [fixture.json] [out-dir]
#   bash tooling/paper-excellence/rig/gate.sh --panel [out-dir]
#   bash tooling/paper-excellence/rig/gate.sh --check [fixture.json] [out-dir]
#   bash tooling/paper-excellence/rig/gate.sh --panel --check
#
# Renders a COMMITTED fixture through the real PortableDoc renderer + the real
# bulldocs layout, photographs it at 8 (2 schemes x 4 widths) cells, and exits
# NONZERO the moment a content assertion fails. Every assertion is on DOM
# content, never on an HTTP status.
#
#   --panel   run EVERY committed fixture (fixtures/*.json) in one command
#   --check   also diff this run's MEASUREMENTS against the committed
#             baselines/<slug>.report.json — see §Report check below
#
# Paths are resolved to ABSOLUTE before the `cd api` below. A repo-relative
# fixture path used to die inside render.exs, which `File.read!`s the path
# verbatim from api/ (`bash …/gate.sh tooling/paper-excellence/rig/fixtures/
# design-probe.json` → File.Error, found 2026-08-17). Both the fixture and the
# out-dir go through abspath now, so any path the caller's shell accepts works.
#
# The PASS line counts THIS RUN's shots, read from the report.json this run
# wrote — not `find`ing the out-dir, which is shared and cumulative (a 4-fixture
# loop over one out-dir printed 8/16/24/32 while each fixture wrote 8).
#
# Red-before proof (2026-08-12, worktree wf_b6bfe6c9-2b7-34): mutating the
# LiveView wrapper class list in api/lib/barkpark_web/live/bulldocs_live.ex
# from "bp-paper-shell" to "bp-paper-shellX" made this gate exit 1 with
# `rig/render: FAIL — wrapper drift: … now renders ["bp-paper-shellX", …]`;
# reverting the mutation made it exit 0 again.
#
# §Report check — red-before proof (2026-08-17, worktree wf_b92073cc-802-31):
# `--check` re-captures under the baseline env (SHOT_FORMAT=jpeg
# SHOT_QUALITY=72 SHOT_WIDTHS=1280,1920) and diffs the fresh report against the
# committed one, IGNORING image byte counts only (a JPEG byte count differed
# 1.5% across hosts while every measurement matched; the README already refuses
# bytes as an oracle). Mutation proof, run three ways against
# baselines/design-probe.report.json:
#
#   unperturbed copy       exit 0 — "247 measured values compared, 0 differences
#                                    (4 image byte counts ignored)"
#   shots[0].columnWidth   exit 1 — "1 measurement(s) drifted …
#     660 → 661                       shots[0].columnWidth: 660 → 661"
#   shots[0].bytes +99999  exit 0 — encoder noise is not a layout fact
#
# So the check CAN lose, loses on what it is for, and does not lose on the one
# value this rig has measured to be host noise.
set -euo pipefail

RIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$RIG_DIR/../../.." && pwd)"

die() {
  echo "rig/gate: $*" >&2
  exit 2
}

# Absolute, without requiring realpath/GNU coreutils.
abspath() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")" ;;
  esac
}

PANEL=0
CHECK=0
FIXTURE_ARG=""
OUT_DIR_ARG=""
POSITIONAL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --panel | --all) PANEL=1 ;;
    --check) CHECK=1 ;;
    -h | --help)
      sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) die "unknown flag $1 (see --help)" ;;
    *)
      POSITIONAL=$((POSITIONAL + 1))
      case $POSITIONAL in
        1) FIXTURE_ARG="$1" ;;
        2) OUT_DIR_ARG="$1" ;;
        *) die "too many arguments (fixture, out-dir)" ;;
      esac
      ;;
  esac
  shift
done

if [ "$PANEL" = 1 ] && [ -n "$FIXTURE_ARG" ]; then
  # --panel IS the fixture list, so its FIRST positional is the out-dir.
  # A `.json` there is a caller who meant one fixture and would otherwise have
  # their argument silently ignored.
  case "$FIXTURE_ARG" in
    *.json) die "--panel runs every committed fixture — drop --panel to shoot just $FIXTURE_ARG" ;;
  esac
  [ -z "$OUT_DIR_ARG" ] || die "--panel takes one argument (the out-dir)"
  OUT_DIR_ARG="$FIXTURE_ARG"
  FIXTURE_ARG=""
fi

OUT_DIR="${OUT_DIR_ARG:-${TMPDIR:-/tmp}/bp-paper-rig}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
SHOTS_DIR="$OUT_DIR/shots"

FIXTURES=()
if [ "$PANEL" = 1 ]; then
  for f in "$RIG_DIR"/fixtures/*.json; do
    [ -f "$f" ] || die "no fixtures in $RIG_DIR/fixtures"
    FIXTURES+=("$f")
  done
  echo "rig/gate: panel — ${#FIXTURES[@]} committed fixtures"
else
  FIXTURES+=("$(abspath "${FIXTURE_ARG:-$RIG_DIR/fixtures/heggemsnes-act.json}")")
fi

for FIXTURE in "${FIXTURES[@]}"; do
  [ -f "$FIXTURE" ] || die "no fixture at $FIXTURE"
done

TOTAL_SHOTS=0

for FIXTURE in "${FIXTURES[@]}"; do
  LABEL="$(basename "$FIXTURE" .json)"
  RENDERED="$OUT_DIR/$LABEL.html"
  REPORT="$SHOTS_DIR/$LABEL.report.json"

  echo "rig/gate: fixture $FIXTURE"

  # 1. Hermetic render. MIX_ENV=test + --no-start: the Repo never starts and the
  #    Endpoint never opens a socket (config/test.exs sets server: false).
  #    CC=clang because a `cc` shell alias can shadow the C compiler here.
  ( cd "$REPO_ROOT/api" && CC=clang MIX_ENV=test mix run --no-start \
      "$RIG_DIR/render.exs" "$FIXTURE" "$RENDERED" )

  # 2. Screenshot + DOM-content assertions. --check pins the capture to the
  #    baseline env so the fresh report is comparable to the committed one.
  if [ "$CHECK" = 1 ]; then
    SHOT_FORMAT=jpeg SHOT_QUALITY=72 SHOT_WIDTHS=1280,1920 \
      node "$RIG_DIR/shoot.mjs" "$RENDERED" "$SHOTS_DIR" "$LABEL"
  else
    node "$RIG_DIR/shoot.mjs" "$RENDERED" "$SHOTS_DIR" "$LABEL"
  fi

  # 3. This run's shot count, from the report this run wrote.
  RUN_SHOTS="$(node -e 'const fs=require("fs");process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).shots.length))' "$REPORT")"
  TOTAL_SHOTS=$((TOTAL_SHOTS + RUN_SHOTS))

  # 4. Optional: the committed measurements are the oracle.
  if [ "$CHECK" = 1 ]; then
    BASELINE="$RIG_DIR/baselines/$LABEL.report.json"
    if [ ! -f "$BASELINE" ]; then
      echo "rig/gate: FAIL — $LABEL has no committed baseline report at $BASELINE" >&2
      echo "rig/gate:        run \`bash tooling/paper-excellence/rig/baseline.sh $LABEL\` first" >&2
      exit 1
    fi
    node "$RIG_DIR/shoot.mjs" --report-diff "$BASELINE" "$REPORT"
  fi

  echo "rig/gate: PASS — $RENDERED + $RUN_SHOTS shots in $SHOTS_DIR"
done

if [ "${#FIXTURES[@]}" -gt 1 ]; then
  echo "rig/gate: PASS — ${#FIXTURES[@]} fixtures, $TOTAL_SHOTS shots in $SHOTS_DIR"
fi
