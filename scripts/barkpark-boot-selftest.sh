#!/usr/bin/env bash
#
# barkpark-boot-selftest.sh — a NARROW behavioural selftest for the two decisions
# bin/barkpark makes about a running server: does `up` claim one is already
# running, and does `stop` kill something.
#
# WHY NARROW. PDS wave 23 refused to ship a BROAD shell gate on the grounds that
# it would green vacuously, and that refusal was right. This script does not lint
# the launcher, does not grep it for phrases, and does not assert a
# classification string. It plants real processes and real pidfiles, runs the
# launcher's OWN start_server/stop_server, and asserts what happened: what was
# printed, what exit code came back, and — for stop — whether a process the
# harness spawned is still alive afterwards.
#
# THE PROOF THAT IT CAN FAIL. Every DIFFERENTIAL fixture below is run TWICE: once
# against the working tree's bin/barkpark and once against the PRE-FIX launcher.
# A differential fixture must PASS on the working tree and FAIL on the pre-fix
# one; if it passes on both, the fixture proves nothing and this script fails.
# The CONTROL fixtures are the mirror: they must pass on BOTH, so a fixture set
# that simply breaks everything cannot green either.
#
# The reference is PINNED to a revision, not to `origin/main`: origin/main was
# the pre-fix launcher when this was written, but the moment the fix merges
# there, a moving reference would make every differential fixture pass on both
# sides and this gate would go red for the wrong reason. REFERENCE_REV below is
# the last commit that touched bin/barkpark before the fix, and the script
# asserts that blob really is pre-fix before trusting it as a reference.
#
# HERMETIC. A temp BARKPARK_HOME, a non-default PORT probed free before use, a
# `curl` stub (the launcher's only definition of "answering", so the harness owns
# it) and a no-op `mix` stub on PATH. Postgres is never touched — the harness
# calls start_server/stop_server directly, never cmd_up/cmd_stop. Only pids this
# harness itself spawned are ever signalled, and they are tracked in one array.
#
# Run:  bash scripts/barkpark-boot-selftest.sh

set -uo pipefail

REPO_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd)"
LAUNCHER="$REPO_ROOT/bin/barkpark"
DISPATCH_LINE='case "${1:-up}" in'

# Last commit to touch bin/barkpark before this fix — origin/main at the time of
# writing. Its blob is the pre-fix launcher forever; see the header on why this
# is pinned rather than read from origin/main.
REFERENCE_REV="0bff57e4f500e9c9fc99424fa2635ca9988be725"
# The reference is only a reference if it is genuinely PRE-fix. Both markers
# below are the exact code this change removes, so if a future edit makes them
# vanish from that blob, the pin is wrong and the gate says so instead of
# quietly comparing the fix against itself.
REFERENCE_MARKERS=('server_running() {' 'pid="$(listener_pid)"')

TMP="$(mktemp -d "${TMPDIR:-/tmp}/barkpark-boot-selftest.XXXXXX")"
SPAWNED=()
FAILURES=0
CHECKS=0

cleanup() {
  local p
  for p in "${SPAWNED[@]:-}"; do
    [ -n "$p" ] || continue
    kill -9 "$p" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

say()  { printf '%s\n' "$*"; }
fail() { printf '  FAIL: %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

# ── preflight ────────────────────────────────────────────────────────────────
#
# A missing tool must HARD FAIL, never skip: a skipped fixture is a vacuous
# green, which is the exact failure mode this gate exists to refuse.
need() { command -v "$1" >/dev/null 2>&1 || { say "barkpark-boot-selftest: required tool '$1' not found — refusing to report a pass it did not earn"; exit 2; }; }
need lsof
need git
LISTENER_KIND=""
if command -v python3 >/dev/null 2>&1; then LISTENER_KIND=python3
elif command -v nc >/dev/null 2>&1; then LISTENER_KIND=nc
else
  say "barkpark-boot-selftest: need python3 or nc to hold a port — refusing to skip"
  exit 2
fi

# ── the two launchers under test ─────────────────────────────────────────────
#
# Both trees get IDENTICAL treatment: take everything above the final `case`
# dispatch, so the file can be sourced for its functions without running a
# subcommand. Nothing inside the functions is rewritten. If the dispatch line
# ever moves, this bails rather than silently sourcing a truncated (or entire)
# script.
extract_lib() { # <src-file> <dest>
  grep -q -F "$DISPATCH_LINE" "$1" || {
    say "barkpark-boot-selftest: dispatch line not found in $1 — cannot isolate the functions"
    exit 2
  }
  awk -v marker="$DISPATCH_LINE" 'index($0, marker) == 1 { exit } { print }' "$1" >"$2"
}

git -C "$REPO_ROOT" show "$REFERENCE_REV:bin/barkpark" >"$TMP/prefix-barkpark" 2>/dev/null || {
  say "barkpark-boot-selftest: could not read $REFERENCE_REV:bin/barkpark — the pre-fix half of every proof is unavailable."
  say "  (a shallow clone will not have it: git fetch --depth=... origin $REFERENCE_REV, or clone with full history)"
  exit 2
}
for marker in "${REFERENCE_MARKERS[@]}"; do
  grep -q -F "$marker" "$TMP/prefix-barkpark" || {
    say "barkpark-boot-selftest: reference $REFERENCE_REV does not contain the pre-fix marker '$marker' — it is NOT the pre-fix launcher, so it cannot prove these fixtures discriminate. Re-pin REFERENCE_REV."
    exit 2
  }
done
extract_lib "$LAUNCHER" "$TMP/fixed.sh"
extract_lib "$TMP/prefix-barkpark" "$TMP/prefix.sh"

# ── harness stubs ────────────────────────────────────────────────────────────
#
# `curl` IS the launcher's definition of "the server answers", so the harness
# decides that answer explicitly per fixture via HARNESS_CURL_RC. `mix` is a
# no-op so the boot path can be entered without an Elixir build; wait_server is
# stubbed out inside each run (see run_fn) so nothing waits 60s on a real boot.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/curl" <<'STUB'
#!/bin/sh
exit "${HARNESS_CURL_RC:-1}"
STUB
cat >"$TMP/bin/mix" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$TMP/bin/curl" "$TMP/bin/mix"

# ── fixture plumbing ─────────────────────────────────────────────────────────

pick_free_port() {
  local p i
  for i in $(seq 1 40); do
    p=$((4400 + RANDOM % 400))
    if [ -z "$(lsof -nP -tiTCP:"$p" -sTCP:LISTEN 2>/dev/null)" ]; then
      printf '%s' "$p"
      return 0
    fi
  done
  say "barkpark-boot-selftest: could not find a free test port"
  exit 2
}

# NOTE on redirection: every spawned helper detaches its stdout/stderr to
# /dev/null. A background process that inherits the harness's stdout keeps the
# write end of any capturing pipe open, and a `$(...)` around it would then block
# until the helper exits — a 120s "hang" that looks like a broken launcher.
spawn_sleep() { # a live pid that is NOT a server — the classic stale-pidfile occupant
  sleep 120 >/dev/null 2>&1 &
  local p=$!
  SPAWNED+=("$p")
  printf '%s' "$p"
}

spawn_listener() { # hold $1 in LISTEN, serving nothing
  local port="$1" p i lp
  if [ "$LISTENER_KIND" = python3 ]; then
    python3 -c 'import socket,sys,time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(8)
time.sleep(300)' "$port" >/dev/null 2>&1 &
  else
    nc -l 127.0.0.1 "$port" >/dev/null 2>&1 &
  fi
  p=$!
  SPAWNED+=("$p")
  for i in $(seq 1 50); do
    lp="$(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -1)"
    [ -n "$lp" ] && { printf '%s' "$lp"; return 0; }
    sleep 0.1
  done
  say "barkpark-boot-selftest: helper never took port $port"
  exit 2
}

alive() { kill -0 "$1" 2>/dev/null; }

# Run ONE launcher function against one of the two trees, in a subshell.
# wait_server is replaced AFTER sourcing so "the boot path was entered" is
# observable without booting anything; nothing else is overridden.
run_fn() { # <lib> <fn>   (BARKPARK_HOME/PORT/HARNESS_CURL_RC come from the env)
  (
    PATH="$TMP/bin:$PATH"
    export PATH
    # shellcheck disable=SC1090
    . "$1"
    wait_server() { printf 'HARNESS: boot path entered\n'; exit 43; }
    "$2"
  ) 2>&1
}

new_home() {
  HOME_DIR="$TMP/home.$RANDOM.$RANDOM"
  mkdir -p "$HOME_DIR"
  PIDFILE="$HOME_DIR/server.pid"
}

# assertion helpers — every one of them prints WHAT it saw when it fails
has()    { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
expect_contains()     { CHECKS=$((CHECKS+1)); has "$2" "$1" || { fail "expected output to contain '$2'; got: $(printf '%s' "$1" | tr '\n' '|')"; return 1; }; }
expect_not_contains() { CHECKS=$((CHECKS+1)); has "$2" "$1" && { fail "expected output NOT to contain '$2'; got: $(printf '%s' "$1" | tr '\n' '|')"; return 1; }; return 0; }
expect_rc()           { CHECKS=$((CHECKS+1)); [ "$1" = "$2" ] || { fail "expected exit $2, got $1"; return 1; }; }
expect_rc_nonzero()   { CHECKS=$((CHECKS+1)); [ "$1" != "0" ] || { fail "expected a non-zero exit, got 0"; return 1; }; }
expect_alive()        { CHECKS=$((CHECKS+1)); alive "$1" || { fail "expected pid $1 to still be alive — it was killed"; return 1; }; }
expect_dead()         { CHECKS=$((CHECKS+1)); alive "$1" && { fail "expected pid $1 to have been killed — it is still alive"; return 1; }; return 0; }
expect_file_is()      { CHECKS=$((CHECKS+1)); [ "$(cat "$1" 2>/dev/null || true)" = "$2" ] || { fail "expected $1 to contain '$2', got '$(cat "$1" 2>/dev/null || true)'"; return 1; }; }
expect_no_file()      { CHECKS=$((CHECKS+1)); [ ! -e "$1" ] || { fail "expected $1 to be gone; it still holds '$(cat "$1" 2>/dev/null || true)'"; return 1; }; }

# ── DIFFERENTIAL fixtures — must PASS on the fix, FAIL on the pre-fix ref ────

# D1  `up` with a stale pidfile naming a live unrelated process and NOTHING on
#     the port. Pre-fix: "server already running", exit 0 — the lie.
fx_up_stale_pidfile() { # <lib>
  local lib="$1" sleeper out rc
  new_home
  export BARKPARK_HOME="$HOME_DIR" PORT HARNESS_CURL_RC=1
  sleeper="$(spawn_sleep)"
  printf '%s\n' "$sleeper" >"$PIDFILE"
  out="$(run_fn "$lib" start_server)"; rc=$?
  expect_not_contains "$out" "server already running"
  expect_contains "$out" "HARNESS: boot path entered"
  expect_alive "$sleeper"
}

# D2  `up` when a listener is present and ANSWERING but no pidfile exists.
#     Pre-fix: dies "something is already listening", never adopting the server
#     it can plainly see. Post-fix: says ANSWERING and records the real pid.
fx_up_adopts_answering_listener() {
  local lib="$1" lpid out rc
  new_home
  export BARKPARK_HOME="$HOME_DIR" PORT HARNESS_CURL_RC=0
  lpid="$(spawn_listener "$PORT")"
  out="$(run_fn "$lib" start_server)"; rc=$?
  expect_rc "$rc" 0
  expect_contains "$out" "server already running (pid $lpid)"
  expect_contains "$out" "ANSWERING"
  expect_file_is "$PIDFILE" "$lpid"
}

# D3  `up` with a stale pidfile AND a listener that does not answer. Pre-fix:
#     "server already running", exit 0, naming a pid that holds nothing.
fx_up_listener_not_answering() {
  local lib="$1" sleeper lpid out rc
  new_home
  export BARKPARK_HOME="$HOME_DIR" PORT HARNESS_CURL_RC=1
  sleeper="$(spawn_sleep)"
  lpid="$(spawn_listener "$PORT")"
  printf '%s\n' "$sleeper" >"$PIDFILE"
  out="$(run_fn "$lib" start_server)"; rc=$?
  expect_rc_nonzero "$rc"
  expect_not_contains "$out" "server already running"
  expect_contains "$out" "does not answer"
  expect_alive "$lpid"
}

# D4  `stop` with a pidfile naming a live unrelated process and nothing on the
#     port. Pre-fix: kills it — a stranger, on the strength of a stale file.
fx_stop_refuses_uncorroborated_pidfile() {
  local lib="$1" sleeper out rc
  new_home
  export BARKPARK_HOME="$HOME_DIR" PORT HARNESS_CURL_RC=1
  sleeper="$(spawn_sleep)"
  printf '%s\n' "$sleeper" >"$PIDFILE"
  out="$(run_fn "$lib" stop_server)"; rc=$?
  expect_rc "$rc" 0
  expect_alive "$sleeper"
  expect_contains "$out" "not stopping pid $sleeper"
  expect_no_file "$PIDFILE"
}

# D5  `stop` with NO pidfile and an unrelated process holding the port. Pre-fix:
#     falls back to listener_pid on $PORT (default 4000) and kills it.
fx_stop_refuses_unidentified_port_holder() {
  local lib="$1" lpid out rc
  new_home
  export BARKPARK_HOME="$HOME_DIR" PORT HARNESS_CURL_RC=1
  lpid="$(spawn_listener "$PORT")"
  out="$(run_fn "$lib" stop_server)"; rc=$?
  expect_rc "$rc" 0
  expect_alive "$lpid"
  expect_contains "$out" "refusing to stop pid $lpid"
}

# ── CONTROL fixtures — must PASS on BOTH trees ───────────────────────────────
# These pin the behaviour the fix must NOT break, and they are the reason the
# differential set cannot green by simply breaking the launcher.

# C1  `up` is still a no-op when the recorded pid IS the answering listener.
fx_ctl_up_noop_when_running() {
  local lib="$1" lpid out rc
  new_home
  export BARKPARK_HOME="$HOME_DIR" PORT HARNESS_CURL_RC=0
  lpid="$(spawn_listener "$PORT")"
  printf '%s\n' "$lpid" >"$PIDFILE"
  out="$(run_fn "$lib" start_server)"; rc=$?
  expect_rc "$rc" 0
  expect_contains "$out" "server already running (pid $lpid)"
  expect_alive "$lpid"
}

# C2  `stop` still stops the real thing: pidfile names the pid holding the port.
fx_ctl_stop_kills_corroborated() {
  local lib="$1" lpid out rc
  new_home
  export BARKPARK_HOME="$HOME_DIR" PORT HARNESS_CURL_RC=0
  lpid="$(spawn_listener "$PORT")"
  printf '%s\n' "$lpid" >"$PIDFILE"
  out="$(run_fn "$lib" stop_server)"; rc=$?
  expect_rc "$rc" 0
  expect_contains "$out" "stopping server (pid $lpid"
  expect_dead "$lpid"
  expect_no_file "$PIDFILE"
}

# D6  `stop` on a clean slate says so and kills nothing. This was written as a
#     control and the harness caught it out: pre-fix, `stop` with nothing running
#     dies SILENTLY at exit 1 — `pid="$(listener_pid)"` assigns from a pipeline
#     that lsof fails, and under `set -euo pipefail` that aborts the function
#     before it can print anything. So it is a differential fixture, and the
#     honest place for it is here.
fx_stop_clean_slate_says_so() {
  local lib="$1" out rc
  new_home
  export BARKPARK_HOME="$HOME_DIR" PORT HARNESS_CURL_RC=1
  out="$(run_fn "$lib" stop_server)"; rc=$?
  expect_rc "$rc" 0
  expect_contains "$out" "server not running"
}

DIFFERENTIAL="fx_up_stale_pidfile fx_up_adopts_answering_listener fx_up_listener_not_answering fx_stop_refuses_uncorroborated_pidfile fx_stop_refuses_unidentified_port_holder fx_stop_clean_slate_says_so"
CONTROL="fx_ctl_up_noop_when_running fx_ctl_stop_kills_corroborated"

# Run one fixture against one tree in isolation and report only whether all its
# assertions held — failures inside a probe run are EXPECTED, so they must not
# pollute the harness's own tally.
# The fixture runs in THIS shell (output to a file, never `$(...)`): a fixture
# run inside a command substitution is a subshell, so its FAILURES increments
# would be discarded and every probe would report a pass it did not earn.
probe() { # <fixture> <lib>
  local before_f=$FAILURES log delta
  log="$TMP/probe.$RANDOM.$RANDOM.log"
  "$1" "$2" >"$log" 2>&1
  delta=$((FAILURES - before_f))
  # Assertion failures INSIDE a probe are the probe's verdict, not the harness's
  # — the harness's own tally is set by the pass/fail expectations below.
  FAILURES=$before_f
  PROBE_OUTPUT="$(cat "$log")"
  [ "$delta" -eq 0 ]
}

say "barkpark boot selftest — bin/barkpark start/stop decisions"
say "  tree under test : $LAUNCHER"
say "  reference tree  : git show $REFERENCE_REV:bin/barkpark (pre-fix, pinned)"
say "  listener helper : $LISTENER_KIND"
say ""

for fx in $DIFFERENTIAL; do
  PORT="$(pick_free_port)"
  say "DIFFERENTIAL $fx (port $PORT)"

  if probe "$fx" "$TMP/fixed.sh"; then
    say "  fixed tree      : PASS"
  else
    fail "$fx does not hold on the working tree"
    printf '%s\n' "$PROBE_OUTPUT" | sed 's/^/    /'
  fi

  PORT="$(pick_free_port)"
  if probe "$fx" "$TMP/prefix.sh"; then
    fail "$fx ALSO passes against the pre-fix reference — it does not discriminate, so it proves nothing"
  else
    say "  pre-fix ref     : FAILS as required —"
    printf '%s\n' "$PROBE_OUTPUT" | sed 's/^/    /'
  fi
  say ""
done

for fx in $CONTROL; do
  PORT="$(pick_free_port)"
  say "CONTROL $fx (port $PORT)"
  if probe "$fx" "$TMP/fixed.sh"; then
    say "  fixed tree      : PASS"
  else
    fail "control $fx broke on the working tree"
    printf '%s\n' "$PROBE_OUTPUT" | sed 's/^/    /'
  fi
  PORT="$(pick_free_port)"
  if probe "$fx" "$TMP/prefix.sh"; then
    say "  pre-fix ref     : PASS (as expected — this behaviour was never broken)"
  else
    fail "control $fx does not hold on the pre-fix reference either — it is a differential fixture in disguise, not a control"
    printf '%s\n' "$PROBE_OUTPUT" | sed 's/^/    /'
  fi
  say ""
done

if [ "$FAILURES" -eq 0 ]; then
  say "barkpark-boot-selftest: OK — 6 differential fixtures pass on the fix and fail on the pinned pre-fix launcher, 2 controls pass on both."
  exit 0
fi
say "barkpark-boot-selftest: $FAILURES failure(s)."
exit 1
