#!/usr/bin/env bash
#
# test-partition-cleanup.sh — drop a MIX_TEST_PARTITION lane's throwaway
# database after `mix test` finishes, so the leak task-1a7e52b811dabc3c
# documented (314 orphaned `barkpark_test*` databases on 2026-08-24, back up
# to 181 a week later despite an authorised bulk reap in between) stops
# growing at the SOURCE instead of only being swept up after the fact.
#
# scripts/reap-test-databases.sh (PR #13790) already builds the age-based
# sweep — the backstop for a lane that is killed outright (SIGKILL, OOM, a
# worktree ripped out mid-run) and never reaches any teardown. This script is
# the OTHER half that row's own description asked for and deliberately left
# unbuilt: "(A) DROP AT LANE END... (A) keeps the steady state small; (B) is
# the backstop." Both stay in place; this one shrinks the population (B) has
# to catch, it does not replace it.
#
# WHY A SEPARATE PROCESS, NOT A MIX ALIAS STEP.
#
# The first cut of this fix tried adding a drop step directly to mix.exs's
# `test:` alias, in the SAME BEAM VM as the test run. Two things about that
# were live-verified as unsafe, both on this exact host under its normal
# fleet load:
#
#   1. `DROP DATABASE` cannot run while the run's own Ecto sandbox pool still
#      holds connections to it, so the alias step first had to
#      `Application.stop(:barkpark)` — non-trivial with the app's background
#      workers (Indx.Recovery, Pulse.Metrics, the chat sweeper, ...) mid-flight.
#   2. Independent of that: DROP DATABASE on Postgres 14+ waits on an internal
#      `IPC/ProcSignalBarrier` that every OTHER backend on the cluster must
#      acknowledge. Verified live — dropping an IDLE, zero-connection scratch
#      database took over two minutes under this fleet's ordinary concurrent
#      load. That is inherent to Postgres under load, not a bug in either
#      approach, but it means a SYNCHRONOUS in-alias drop both (a) can raise
#      and turn a passing test run's exit code into a failure — the exact
#      "misread failure" class task-1a7e52b811dabc3c itself exists to stop —
#      and (b) makes every partitioned `mix test` invocation pay an
#      unpredictable multi-minute tail even when it works.
#
# So the drop here runs:
#   - in its OWN `mix` process, started only AFTER the test run's process has
#     fully exited (its connections are closed at the OS level, not merely
#     idle — no Application.stop juggling needed), and
#   - DETACHED and backgrounded, so this script returns as soon as `mix test`
#     does. The caller's exit code is ALWAYS the test run's, never the drop's;
#     the drop's own slowness or failure is invisible to it.
#
# USAGE (from anywhere; cd's into api/ itself):
#
#   MIX_TEST_PARTITION=<lane> scripts/test-partition-cleanup.sh [mix test args...]
#
# Without MIX_TEST_PARTITION set this is a plain `mix test` passthrough — it
# never touches the shared, unpartitioned `barkpark_test` a developer iterates
# against across many runs in one session; only a named partition is ever
# dropped, and only this script's own partition.
#
# See docs/setup/SETUP.md#test-database-partitioning for the recommended
# invocation and scripts/reap-test-databases.sh for the sweep this backstops.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_DIR="$SCRIPT_DIR/../api"

# ── selftest ────────────────────────────────────────────────────────────────
# Proves the two load-bearing properties without touching a real database or
# waiting on a real (possibly slow, under load) `mix test` run: a stubbed
# `mix` that fails still yields the TEST exit code, not the drop's; and the
# drop is only attempted (and only for the running partition) when
# MIX_TEST_PARTITION is set.
if [ "${1:-}" = "--selftest" ]; then
  fails=0
  arm() { # arm <name> <cond>
    if eval "$2"; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); fi
  }

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  # Stub `mix`: `mix test` exits 1 (a real failing suite) after recording
  # that it ran; `mix ecto.drop` records the partition it was asked to drop
  # and hangs briefly, standing in for the live ProcSignalBarrier stall.
  cat >"$tmp/mix" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  test) echo ran-test >> "$MIX_STUB_LOG"; exit 1 ;;
  ecto.drop) sleep 0.3; echo "dropped:${MIX_TEST_PARTITION:-}" >> "$MIX_STUB_LOG"; exit 0 ;;
esac
STUB
  chmod +x "$tmp/mix"

  log="$tmp/log"
  : >"$log"
  start="$(date +%s)"
  PATH="$tmp:$PATH" MIX_STUB_LOG="$log" MIX_TEST_PARTITION=_selftest \
    "$SCRIPT_DIR/test-partition-cleanup.sh" >/dev/null 2>&1
  status=$?
  elapsed=$(( $(date +%s) - start ))

  arm "forwards the TEST exit code (1), not the drop's" '[ "$status" = 1 ]'
  arm "returns before the drop finishes (did not block ~0.3s+)" '[ "$elapsed" -lt 1 ]'
  arm "ran mix test" 'grep -q "^ran-test$" "$log"'

  # Give the detached background drop a moment to land, then check it fired
  # for the RIGHT partition.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    grep -q "^dropped:" "$log" 2>/dev/null && break
    sleep 0.1
  done
  arm "dropped the running partition, not the default db" 'grep -q "^dropped:_selftest$" "$log"'

  # Unset MIX_TEST_PARTITION: must never attempt a drop.
  log2="$tmp/log2"
  : >"$log2"
  PATH="$tmp:$PATH" MIX_STUB_LOG="$log2" env -u MIX_TEST_PARTITION \
    "$SCRIPT_DIR/test-partition-cleanup.sh" >/dev/null 2>&1
  sleep 0.2
  arm "no MIX_TEST_PARTITION -> no drop attempted" '! grep -q "^dropped:" "$log2"'

  printf '\n'
  if [ "$fails" -gt 0 ]; then printf 'SELFTEST FAILED: %d arm(s) failed\n' "$fails"; exit 1; fi
  printf 'SELFTEST PASSED\n'
  exit 0
fi

cd "$API_DIR" || exit 3

if [ -z "${MIX_TEST_PARTITION:-}" ]; then
  # Nothing to clean up — this is the shared, unpartitioned barkpark_test db.
  exec mix test "$@"
fi

mix test "$@"
status=$?

partition="$MIX_TEST_PARTITION"
(
  cd "$API_DIR" || exit 0
  MIX_ENV=test MIX_TEST_PARTITION="$partition" mix ecto.drop --quiet >/dev/null 2>&1
) &
disown 2>/dev/null || true

exit "$status"
