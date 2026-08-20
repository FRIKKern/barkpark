#!/usr/bin/env bash
# hermetic-proof — the byte-determinism proof for drive.sh's hermetic mode
# (charter D122, task ttw21-hermetic-drive).
#
# Runs DRIVE_MODE=hermetic drive.sh TWICE, back to back, normalizes exactly the
# legitimate per-run variance (wall-clock timestamps, pids, tempdir paths) out
# of each transcript, and diffs them. The proof holds only if BOTH runs exit 0
# AND the normalized transcripts are IDENTICAL — an empty diff. The report.md
# of each run is diffed the same way (its date line normalized).
#
# Everything else — assert order, assert text, located columns/lines, row
# titles, ratio values, pass/fail counts — must be byte-equal, or the mode is
# not hermetic and this script exits 1 with the diff on stdout.
#
# USAGE
#   bash scripts/taskboard-drive/hermetic-proof.sh
set -u -o pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Normalize ONLY genuine per-run variance:
#   - ISO-8601 UTC stamps (the report date line)          -> TS
#   - the per-run tmux socket suffix (tbdrive-<pid>)      -> tbdrive-PID
#   - mktemp paths (macOS /var/folders/…, linux /tmp/…)   -> TMPD
# Deliberately nothing else — titles, columns, counts and ratios must match.
norm() {
  perl -pe '
    s/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/TS/g;
    s/tbdrive-\d+/tbdrive-PID/g;
    s{/(?:private/)?(?:var/folders|tmp)/\S+}{TMPD}g;
  '
}

run() {
  local n=$1 rc
  echo "=== hermetic run $n ==="
  DRIVE_MODE=hermetic bash "$SCRIPT_DIR/drive.sh" >"$WORK/run$n.raw" 2>&1
  rc=$?
  cp "$SCRIPT_DIR/evidence-hermetic/report.md" "$WORK/report$n.raw" 2>/dev/null || true
  norm <"$WORK/run$n.raw" >"$WORK/run$n.txt"
  norm <"$WORK/report$n.raw" >"$WORK/report$n.txt" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: hermetic run $n exited $rc — transcript:"
    cat "$WORK/run$n.raw"
    exit 1
  fi
  tail -1 "$WORK/run$n.raw"
}

run 1
run 2

echo "=== transcript diff (normalized) ==="
if diff -u "$WORK/run1.txt" "$WORK/run2.txt"; then
  echo "(empty — transcripts identical)"
else
  echo "FAIL: hermetic transcripts differ"
  exit 1
fi

echo "=== report diff (normalized) ==="
if diff -u "$WORK/report1.txt" "$WORK/report2.txt"; then
  echo "(empty — reports identical)"
else
  echo "FAIL: hermetic reports differ"
  exit 1
fi

echo "hermetic-proof: PASS — two consecutive runs are byte-identical after timestamp/pid normalization"
