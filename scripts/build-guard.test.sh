#!/usr/bin/env bash
# build-guard.test.sh — hermetic matrix for scripts/build-guard.sh
# (task-15e2eb3aa36b240b). No real systemd, mix or service runs: systemd-run
# and systemctl are fakes on PATH, and the "build" is a small bash script.
#
# Arms:
#   1. scope: the command runs under `systemd-run --scope` with MemoryMax,
#      MemoryHigh, CPUWeight, IOWeight and OOMPolicy=continue (systemd >= 253),
#      a unit named after the guard's pid, ERL_FLAGS "+S 1:1", nice 10, and
#      BP_DEPLOY_RECORD_PID equal to the guard's own pid (the pid the runner
#      recorded, kept through every exec).
#   2. systemd 252: no OOMPolicy (older systemd rejects it on a scope).
#   3. a scope that cannot be created: a warning, then the build still runs.
#   4. no systemd: a warning, then the build still runs.
#   5. the reader of stdout goes away mid-build (the runner's pipe closing on a
#      service restart): the build runs to its end, writes everything to the
#      log, and the guard returns the build's own exit code.
#   6. the build's exit code passes through.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1 (cond: $2)"; fi; }

TMP="$(mktemp -d)"
cleanup() { find "$TMP" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT

REPO="$TMP/repo"
mkdir -p "$REPO/scripts"
cp -f "$HERE/build-guard.sh" "$REPO/scripts/"

FAKE="$TMP/fakebin"
mkdir -p "$FAKE"
SYSD="$TMP/run-systemd-system"
mkdir -p "$SYSD"
MEMINFO="$TMP/meminfo"
printf 'MemTotal:        3900000 kB\nMemFree:          100000 kB\n' > "$MEMINFO"

# Fake systemd-run: log the argv, refuse the probe when FAKE_SCOPE_FAIL=1, and
# otherwise exec whatever follows `--`, in place, as the real --scope mode does.
cat > "$FAKE/systemd-run" <<'EOF'
#!/usr/bin/env bash
echo "systemd-run $*" >> "$CALL_LOG"
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
if [ "${1:-}" = true ] && [ "${FAKE_SCOPE_FAIL:-0}" = 1 ]; then
  echo "Failed to start transient scope unit: Access denied" >&2
  exit 1
fi
exec "$@"
EOF
cat > "$FAKE/systemctl" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then echo "systemd ${FAKE_SYSTEMD_VERSION:-255} (255.4-1ubuntu8)"; exit 0; fi
echo "systemctl $*" >> "$CALL_LOG"
exit 0
EOF
chmod +x "$FAKE"/*

# The "build": report what it was handed, then exit FAKE_RC.
cat > "$TMP/build.sh" <<'EOF'
#!/usr/bin/env bash
{
  echo "erl_flags=${ERL_FLAGS:-}"
  echo "guarded=${BP_BUILD_GUARDED:-}"
  echo "record_pid=${BP_DEPLOY_RECORD_PID:-}"
  echo "nice=$(ps -o nice= -p $$ | tr -d ' ')"
} > "$REPORT"
echo "build line one"
echo "build line two"
exit "${FAKE_RC:-0}"
EOF
chmod +x "$TMP/build.sh"

CALL_LOG="$TMP/calls.log"
REPORT="$TMP/report.txt"

# run_guard OUT ENV... : run the guard in the background so its pid is known,
# with the fake systemd dir and meminfo, then wait for it.
run_guard() {
  local out="$1"
  shift
  : > "$CALL_LOG"
  : > "$REPORT"
  env PATH="$FAKE:/usr/bin:/bin" CALL_LOG="$CALL_LOG" REPORT="$REPORT" \
    BP_BUILD_SYSTEMD_DIR="$SYSD" BP_BUILD_MEMINFO="$MEMINFO" BP_BUILD_LOG="$TMP/build.log" \
    "$@" bash "$REPO/scripts/build-guard.sh" bash "$TMP/build.sh" > "$out" 2>&1 &
  GUARD_PID=$!
  wait "$GUARD_PID"
  RC=$?
}

echo "== scope: capped, outside the caller's cgroup, one scheduler, low priority =="
run_guard "$TMP/scope.out"
check "exit 0" "[ '$RC' = 0 ]"
check "probe then real scope (two systemd-run calls)" "[ \"\$(grep -c '^systemd-run --scope' '$CALL_LOG')\" = 2 ]"
check "unit named after the guard pid" "grep -q -- '--unit=barkpark-build-$GUARD_PID ' '$CALL_LOG'"
check "MemoryMax is half of MemTotal (3900000 kB -> 1904M)" "grep -q 'MemoryMax=1904M' '$CALL_LOG'"
check "MemoryHigh is 85% of MemoryMax" "grep -q 'MemoryHigh=1618M' '$CALL_LOG'"
check "CPUWeight lowered" "grep -q 'CPUWeight=20' '$CALL_LOG'"
check "IOWeight lowered" "grep -q 'IOWeight=20' '$CALL_LOG'"
check "OOMPolicy=continue on systemd 255" "grep -q 'OOMPolicy=continue' '$CALL_LOG'"
check "build saw ERL_FLAGS +S 1:1" "grep -qx 'erl_flags=+S 1:1' '$REPORT'"
check "build saw BP_BUILD_GUARDED=1" "grep -qx 'guarded=1' '$REPORT'"
check "record pid is the guard's own pid (kept through every exec)" "grep -qx 'record_pid=$GUARD_PID' '$REPORT'"
check "build ran at nice 10" "grep -qx 'nice=10' '$REPORT'"
check "build output streamed to stdout" "grep -qx 'build line two' '$TMP/scope.out'"
check "build output also in the log file" "grep -qx 'build line two' '$TMP/build.log'"

echo "== explicit memory cap wins =="
run_guard "$TMP/cap.out" BP_BUILD_MEMORY_MAX=1500M
check "MemoryMax=1500M" "grep -q 'MemoryMax=1500M' '$CALL_LOG'"
check "MemoryHigh=1275M" "grep -q 'MemoryHigh=1275M' '$CALL_LOG'"

echo "== systemd 252: no OOMPolicy =="
run_guard "$TMP/old.out" FAKE_SYSTEMD_VERSION=252
check "exit 0" "[ '$RC' = 0 ]"
check "no OOMPolicy property" "! grep -q 'OOMPolicy' '$CALL_LOG'"
check "still a scope" "grep -q -- '--unit=barkpark-build-' '$CALL_LOG'"

echo "== a scope that cannot be created: warn, then build anyway =="
run_guard "$TMP/nopriv.out" FAKE_SCOPE_FAIL=1
check "exit 0" "[ '$RC' = 0 ]"
check "only the probe was attempted" "[ \"\$(grep -c '^systemd-run' '$CALL_LOG')\" = 1 ]"
check "says the build is uncapped" "grep -qF 'could not create a scope' '$TMP/nopriv.out'"
check "build still ran with one scheduler" "grep -qx 'erl_flags=+S 1:1' '$REPORT'"

echo "== no systemd: warn, then build anyway =="
run_guard "$TMP/nosysd.out" BP_BUILD_SYSTEMD_DIR="$TMP/absent"
check "exit 0" "[ '$RC' = 0 ]"
check "systemd-run never called" "[ ! -s '$CALL_LOG' ]"
check "says there is no systemd-run" "grep -qF 'no systemd-run here' '$TMP/nosysd.out'"
check "build output streamed" "grep -qx 'build line one' '$TMP/nosysd.out'"

echo "== exit code passes through =="
run_guard "$TMP/rc.out" FAKE_RC=13
check "exit 13" "[ '$RC' = 13 ]"

echo "== the stdout reader goes away mid-build: the build still finishes =="
# The reader stops at the build's first line and exits, as the runner's port does when the
# service restarts. The build keeps writing after that, then leaves a marker.
cat > "$TMP/long.sh" <<'EOF'
#!/usr/bin/env bash
echo "first"
sleep 1
for i in 1 2 3 4 5 6 7 8 9 10; do echo "after-reader-gone $i"; done
sleep 0.5
echo "last"
echo done > "$MARKER"
exit 0
EOF
chmod +x "$TMP/long.sh"
MARKER="$TMP/marker"
rm -f "$MARKER"
env PATH="$FAKE:/usr/bin:/bin" CALL_LOG="$CALL_LOG" MARKER="$MARKER" \
  BP_BUILD_SYSTEMD_DIR="$SYSD" BP_BUILD_MEMINFO="$MEMINFO" BP_BUILD_LOG="$TMP/long.log" \
  bash "$REPO/scripts/build-guard.sh" bash "$TMP/long.sh" 2>/dev/null | sed -n '/^first$/{p;q;}' > "$TMP/long.out"
guard_rc="${PIPESTATUS[0]}"
# The guard may return before the marker is written only if it lost track of
# the build; give a slow machine a moment before calling it.
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$MARKER" ] && break; sleep 0.3; done
check "the reader got the first line" "grep -qx 'first' '$TMP/long.out'"
check "the build ran to its end" "[ -f '$MARKER' ]"
check "every line after the reader left is in the log" "grep -qx 'after-reader-gone 10' '$TMP/long.log' && grep -qx 'last' '$TMP/long.log'"
check "the guard returned the build's exit code, not a pipe error" "[ '$guard_rc' = 0 ]"

if [ "$fails" -ne 0 ]; then
  echo "build-guard tests: $fails failure(s)" >&2
  exit 1
fi
echo "build-guard tests: PASS"
