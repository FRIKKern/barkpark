#!/usr/bin/env bash
#
# ci-test-watchdog.test.sh — the harness for scripts/ci-test-watchdog.sh
# (task-6d4727b7cff1f2bd). The watchdog wraps the Test step's `mix test`, so the
# cases that matter are the two it must never get wrong:
#
#   * it never turns a red into a green, nor a green into a red      (1, 2)
#   * a silent command is stopped, named and failed fast               (3)
#   * a silent BEAM leaves an erl_crash.dump and a summary naming it   (4)
#   * the memory floor can fire (Linux only: it reads /proc/meminfo)   (5)
#   * a copy with the quiet check cut out must NOT fire               (6)
#
# Case 6 stops case 3 passing vacuously. Runs in ~20 s, in a temp dir.

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DOG="$HERE/ci-test-watchdog.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  ok   — $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL — $1"; }

run() { # run <case> <args...>: output in $tmp/<case>.out, exit code in $rc
  local c="$1"; shift
  bash "$@" >"$tmp/$c.out" 2>&1
  rc=$?
}

echo "ci-test-watchdog.test.sh"

# 1. A healthy command: its output passes through, its 0 stays 0, nothing fires.
run 1 "$DOG" --out "$tmp/d1" -- bash -c 'echo hello; echo world'
if [ "$rc" -eq 0 ] && grep -qx world "$tmp/1.out" && ! grep -q FIRED "$tmp/1.out"; then
  ok "a green command stays green and its output passes through"
else bad "case 1: rc=$rc"; sed 's/^/       /' "$tmp/1.out"; fi

# 2. A red command stays red, with its own exit code.
run 2 "$DOG" --out "$tmp/d2" -- bash -c 'echo failing; exit 3'
if [ "$rc" -eq 3 ] && ! grep -q FIRED "$tmp/2.out"; then ok "a red command keeps its own exit code (3)"
else bad "case 2: rc=$rc (want 3)"; fi

# 3. A command that goes silent is stopped after --quiet seconds, and fails 124.
t0=$(date +%s)
run 3 "$DOG" --quiet 2 --out "$tmp/d3" -- bash -c 'echo started; sleep 60'
dt=$(($(date +%s) - t0))
if [ "$rc" -eq 124 ] && grep -q "FIRED: no test output for 2s" "$tmp/3.out" && [ "$dt" -lt 20 ]; then
  ok "a silent command is failed in ${dt}s, named 'no test output'"
else bad "case 3: rc=$rc after ${dt}s"; sed 's/^/       /' "$tmp/3.out"; fi

# 4. A silent BEAM is dumped: erl_crash.dump exists and the summary names the process.
if command -v elixir >/dev/null 2>&1; then
  # bash keeps the output alive until the BEAM has queued its messages (a cold
  # BEAM on a loaded box can take seconds to boot); THEN the silence starts. The
  # BEAM is a child of bash here, so this also proves the watchdog finds it.
  probe='Process.register(self(), :watchdog_hang_probe); for _ <- 1..5000, do: send(self(), :stuck); File.write!(System.fetch_env!("READY"), ""); Process.sleep(:infinity)'
  # shellcheck disable=SC2016 # $0 and $READY expand in the inner bash
  run 4 "$DOG" --quiet 3 --out "$tmp/d4" -- env READY="$tmp/ready4" bash -c \
    'elixir -e "$0" & until [ -f "$READY" ]; do echo booting; sleep 0.5; done; wait' "$probe"
  # The probe holds 5000 unread messages: it must top the by-queue list.
  if [ "$rc" -eq 124 ] && [ -s "$tmp/d4/erl_crash.dump" ] &&
    grep -A1 -- "-- top 15 by message queue" "$tmp/4.out" | grep -q "^5000.*watchdog_hang_probe"; then
    ok "a silent BEAM leaves erl_crash.dump; the summary puts :watchdog_hang_probe (5000 queued) on top"
  else bad "case 4: rc=$rc"; sed 's/^/       /' "$tmp/4.out" | tail -30; fi
elif [ -n "${CI:-}" ]; then bad "case 4: no elixir on PATH in CI"
else echo "  skip — case 4 (no elixir on PATH)"; fi

# 5. The memory floor fires (an absurd floor is always crossed).
if [ -r /proc/meminfo ]; then
  run 5 "$DOG" --min-mem-mb 999999999 --out "$tmp/d5" -- bash -c 'echo up; sleep 30'
  if [ "$rc" -eq 124 ] && grep -q "FIRED: free memory" "$tmp/5.out"; then ok "the free-memory floor fires"
  else bad "case 5: rc=$rc"; sed 's/^/       /' "$tmp/5.out"; fi
elif [ -n "${CI:-}" ]; then bad "case 5: no /proc/meminfo in CI"
else echo "  skip — case 5 (no /proc/meminfo here)"; fi

# 6. Cut the quiet check out: case 3's command must then run on (no fire, no 124).
sed '/fired="no test output/d' "$DOG" >"$tmp/gutted.sh"
if cmp -s "$DOG" "$tmp/gutted.sh"; then bad "case 6: the quiet check was not found to cut"
else
  run 6 "$tmp/gutted.sh" --quiet 2 --out "$tmp/d6" -- bash -c 'echo started; sleep 6; exit 0'
  if [ "$rc" -eq 0 ] && ! grep -q FIRED "$tmp/6.out"; then ok "with the quiet check cut out, case 3 no longer fires (the check is what fires)"
  else bad "case 6: the gutted copy still fired (rc=$rc)"; fi
fi

echo "ci-test-watchdog.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
