#!/usr/bin/env bash
# Selftest for scripts/refute-on-absence-capture-log-check.sh.
#
# A detector that has never been shown to bite is not a detector — so arm (a)
# PLANTS a module carrying the unsound shape, proves the check reds naming it,
# and arm (f) removes the plant and proves the check goes green again.
#
# Arm (0) is the one that stops the rest passing vacuously in the OTHER
# direction: a check that flagged `capture_log` under `async: true` in general
# would satisfy "can it red" while implementing the WIDE rule the row rejects.
# Arms (b) and (c) drop one token each, so all three tokens are load-bearing.
#
# Every plant lives in a mktemp tree. Nothing is written under api/.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/refute-on-absence-capture-log-check.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/test"

fails=0
arm() { printf '  %-5s %s\n' "$1" "$2"; [ "$1" = "FAIL" ] && fails=$((fails + 1)); return 0; }

run() { REFUTE_CAPTURE_LOG_SCANDIR="$TMP/test" bash "$CHECK" "$@" 2>&1; }

echo "refute-on-absence-capture-log-check selftest"
echo

# --- (0) THE WIDE-RULE CONTROL ----------------------------------------------
# A concurrent module that uses capture_log and asserts PRESENCE is SOUND and
# must NOT be flagged. A foreign line cannot make a present line absent.
cat > "$TMP/test/presence_control_test.exs" <<'EX'
defmodule PresenceControlTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  test "a presence assert survives foreign lines" do
    log = capture_log(fn -> emit() end)
    assert log =~ "the line this test emitted"
  end
end
EX
out="$(run)"; rc=$?
if [ "$rc" = 0 ] && ! grep -q 'presence_control_test.exs' <<<"$out"; then
  arm "ok" "(0) async + capture_log + PRESENCE assert is NOT flagged — the wide rule is not implemented"
else
  arm "FAIL" "(0) the check flagged a sound presence assert — it is the WIDE rule, and every other arm is now meaningless"
  printf '%s\n' "$out" | sed 's/^/        /'
fi

# --- (b) TOKEN 2 DROPPED: synchronous module ---------------------------------
# The very fix this gate asks for. A refute over a capture in a SYNCHRONOUS
# module is sound: sync modules run alone, so the capture is theirs.
cat > "$TMP/test/sync_refute_test.exs" <<'EX'
defmodule SyncRefuteTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  test "an absence claim is sound when nothing else is running" do
    log = capture_log(fn -> quiet_path() end)
    refute log =~ "the signal that must not fire"
  end
end
EX
out="$(run)"; rc=$?
if [ "$rc" = 0 ] && ! grep -q 'sync_refute_test.exs' <<<"$out"; then
  arm "ok" "(b) a refute-on-log in a SYNCHRONOUS module is NOT flagged — that is the fix, not the defect"
else
  arm "FAIL" "(b) the check flagged the fix it recommends"
  printf '%s\n' "$out" | sed 's/^/        /'
fi

# --- (c) TOKEN 1 DROPPED: a refute-on-log with no capture at all --------------
cat > "$TMP/test/no_capture_test.exs" <<'EX'
defmodule NoCaptureTest do
  use ExUnit.Case, async: true

  test "refutes a field that happens to be called log" do
    refute changeset.changes[:log] == "x"
  end
end
EX
out="$(run)"; rc=$?
if [ "$rc" = 0 ] && ! grep -q 'no_capture_test.exs' <<<"$out"; then
  arm "ok" "(c) a refute mentioning 'log' with NO capture_log is NOT flagged — token 1 is load-bearing"
else
  arm "FAIL" "(c) the check flagged a module that captures nothing"
  printf '%s\n' "$out" | sed 's/^/        /'
fi

# --- (a) THE PLANT: all three tokens -----------------------------------------
cat > "$TMP/test/planted_unsound_test.exs" <<'EX'
defmodule PlantedUnsoundTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  test "an absence claim over a device-wide capture, under concurrency" do
    log = capture_log(fn -> quiet_path() end)
    refute log =~ "the signal that must not fire"
  end

  test "a second site in the same module" do
    log = capture_log(fn -> other_quiet_path() end)
    refute log =~ "also must not fire"
  end
end
EX
out="$(run)"; rc=$?
if [ "$rc" = 1 ] && grep -q 'planted_unsound_test.exs' <<<"$out"; then
  arm "ok" "(a) the planted unsound module REDS by name, exit 1"
else
  arm "FAIL" "(a) the plant did not red (exit $rc) — the gate is asleep"
  printf '%s\n' "$out" | sed 's/^/        /'
fi

# …and it counts BOTH sites in that file, not just the first.
if grep -qE 'planted_unsound_test\.exs — 2 refute-on-log site' <<<"$out"; then
  arm "ok" "(a2) both sites in the planted module are counted, not just the first"
else
  arm "FAIL" "(a2) the per-file count is wrong — a second site in the same file is invisible"
  printf '%s\n' "$out" | sed 's/^/        /'
fi

# --- (d) --list names the sites file:line ------------------------------------
out="$(run --list)"; rc=$?
if [ "$rc" = 0 ] && grep -qE 'planted_unsound_test\.exs:[0-9]+' <<<"$out"; then
  arm "ok" "(d) --list names every site file:line"
else
  arm "FAIL" "(d) --list did not name the planted sites"
  printf '%s\n' "$out" | sed 's/^/        /'
fi

# --- (e) AN UNREADABLE TREE REFUSES, distinctly from a RED --------------------
out="$(REFUTE_CAPTURE_LOG_SCANDIR="$TMP/does-not-exist" bash "$CHECK" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -q 'REFUSING' <<<"$out"; then
  arm "ok" "(e) a missing scan tree REFUSES with exit 3 — distinct from RED (1) and OK (0)"
else
  arm "FAIL" "(e) a missing tree returned $rc, not 3 — a clean report on a tree never opened"
  printf '%s\n' "$out" | sed 's/^/        /'
fi

# --- (f) REMOVE THE PLANT -----------------------------------------------------
rm -f "$TMP/test/planted_unsound_test.exs"
out="$(run)"; rc=$?
if [ "$rc" = 0 ] && grep -q 'OK — 0 site' <<<"$out"; then
  arm "ok" "(f) with the plant removed the tree is OK again — the red was the plant, not the fixtures"
else
  arm "FAIL" "(f) the tree still reds after removing the plant (exit $rc)"
  printf '%s\n' "$out" | sed 's/^/        /'
fi

# --- (g) THE REAL TREE IS UNTOUCHED AND GREEN --------------------------------
out="$(bash "$CHECK" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then
  arm "ok" "(g) the real api/test tree is at baseline 0: $(printf '%s' "$out" | tail -1)"
else
  arm "FAIL" "(g) the real tree reds"
  printf '%s\n' "$out" | sed 's/^/        /'
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "SELFTEST FAILED: $fails of 9 arms failed"
  exit 1
fi
echo "SELFTEST PASSED: 9 of 9 arms"
exit 0
