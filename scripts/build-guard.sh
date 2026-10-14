#!/usr/bin/env bash
#
# build-guard.sh <command> [args...] — run an on-box build so it cannot take
# the serving service down, and so a restart of that service cannot kill it.
#
# Why (task-15e2eb3aa36b240b). The self-update runner spawns the rebuild as a
# child of the serving BEAM, so the whole compile used to run inside
# barkpark.service's cgroup with no memory cap, default schedulers and normal
# priority. On a 2-core managed box (gyl) the compile and the serving BEAM
# shared one memory budget; when the service died (Restart=on-failure brings it
# back, and systemd stops the whole cgroup on the way down) the compile died
# with it, the deploy never landed, and every retry started a fresh compile
# that met the same end.
#
# What it does:
#
#   1. Moves the command into its own transient systemd scope
#      (`systemd-run --scope`), OUTSIDE barkpark.service's cgroup, with
#      MemoryMax/MemoryHigh, a low CPUWeight and IOWeight, and
#      OOMPolicy=continue where systemd supports it. An OOM inside the scope
#      kills the compile, which deploy-rebuild records as a failed build; the
#      serving BEAM keeps its memory. A service restart no longer reaches the
#      build, because systemd only stops processes inside the service's cgroup.
#      `systemd-run --scope` execs in place, so the pid the runner recorded is
#      still this process.
#   2. Runs the command under nice/ionice with ERL_FLAGS="+S 1:1" (one BEAM
#      scheduler per mix process) so the compile takes one core of two.
#   3. Writes the command's output to a log file ($BP_BUILD_LOG, default
#      <repo>/.bp-build.log) and follows that file to stdout. When the service
#      restarts, the runner's pipe closes and only the follower dies; the build
#      itself never writes to the pipe, so it never gets SIGPIPE.
#
# Without systemd-run (a dev machine, a container) it falls back to steps 2 and
# 3 and says so. The command sees BP_BUILD_GUARDED=1 so a script that guards
# itself (deploy-rebuild.sh) does not wrap twice, and BP_DEPLOY_RECORD_PID set
# to this process's pid, the pid the runner matches deploy-rebuild's flight
# record on.
#
# Tunables (all optional):
#   BP_BUILD_MEMORY_MAX      MemoryMax for the scope, e.g. 1500M. Default: half
#                            of MemTotal, at least 768M.
#   BP_BUILD_SCHEDULERS      BEAM schedulers per mix process. Default 1.
#   BP_BUILD_NICE            nice level. Default 10.
#   BP_BUILD_LOG             log file path.
#   BP_BUILD_GUARD_SCOPE     0 disables the scope (nice/ionice/log only).
#   BP_BUILD_SYSTEMD_DIR     where systemd's runtime dir lives (tests).
#   BP_BUILD_MEMINFO         meminfo path (tests).
#
# Exit code: the command's own exit code.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$REPO/scripts/build-guard.sh"

if [ "${1:-}" = "--inner" ]; then
  shift
  INNER=1
else
  INNER=0
fi

[ $# -gt 0 ] || { echo "usage: build-guard.sh <command> [args...]" >&2; exit 64; }

say() { echo "[build-guard] $*"; }

# MemoryMax for the scope, in bytes-with-suffix form systemd accepts.
memory_max() {
  if [ -n "${BP_BUILD_MEMORY_MAX:-}" ]; then
    echo "$BP_BUILD_MEMORY_MAX"
    return
  fi
  local meminfo="${BP_BUILD_MEMINFO:-/proc/meminfo}" total_kb half_kb
  total_kb="$(awk '/^MemTotal:/ {print $2}' "$meminfo" 2>/dev/null)"
  case "$total_kb" in
    '' | *[!0-9]*) echo "1536M"; return ;;
  esac
  half_kb=$((total_kb / 2))
  [ "$half_kb" -lt 786432 ] && half_kb=786432
  echo "$((half_kb / 1024))M"
}

# MemoryHigh at 85% of MemoryMax: the kernel throttles and reclaims before the
# hard cap kills anything.
memory_high() {
  local max="$1" n unit
  n="${max%[KMGkmg]}"
  unit="${max#"$n"}"
  case "$n" in '' | *[!0-9]*) echo ""; return ;; esac
  echo "$((n * 85 / 100))$unit"
}

# OOMPolicy= on scope units needs systemd 253 or newer. Older systemd rejects
# the property and the scope would not start, so it is added only when known.
systemd_major() {
  systemctl --version 2>/dev/null | awk 'NR == 1 {print $2}' | sed 's/[^0-9].*//'
}

scope_available() {
  [ "${BP_BUILD_GUARD_SCOPE:-1}" != 0 ] || return 1
  command -v systemd-run > /dev/null 2>&1 || return 1
  [ -d "${BP_BUILD_SYSTEMD_DIR:-/run/systemd/system}" ] || return 1
  return 0
}

# ── stage 1: move into a capped scope, then run stage 2 there ─────────────────
if [ "$INNER" = 0 ]; then
  export BP_DEPLOY_RECORD_PID="${BP_DEPLOY_RECORD_PID:-$$}"

  if scope_available; then
    max="$(memory_max)"
    high="$(memory_high "$max")"
    props=(-p "MemoryMax=$max" -p "CPUWeight=20" -p "IOWeight=20")
    [ -n "$high" ] && props+=(-p "MemoryHigh=$high")
    major="$(systemd_major)"
    case "$major" in
      '' | *[!0-9]*) ;;
      *) [ "$major" -ge 253 ] && props+=(-p "OOMPolicy=continue") ;;
    esac
    unit="barkpark-build-$$"

    # Probe first: a scope that cannot be created (no privilege, an unknown
    # property) must not fail the deploy. The probe costs one short-lived unit.
    if systemd-run --scope --quiet --collect "${props[@]}" -- true > /dev/null 2>&1; then
      say "build runs in scope $unit (MemoryMax=$max${high:+ MemoryHigh=$high}, CPUWeight=20, IOWeight=20), outside barkpark.service"
      exec systemd-run --scope --quiet --collect --unit="$unit" "${props[@]}" -- \
        bash "$SELF" --inner "$@"
    fi
    say "WARN: systemd-run could not create a scope; the build stays in the caller's cgroup without a memory cap"
  else
    say "WARN: no systemd-run here; the build stays in the caller's cgroup without a memory cap"
  fi
fi

# ── stage 2: low priority, one scheduler, output via a log file ───────────────
# The runner's pipe closes when barkpark.service restarts. Ignore SIGPIPE and
# SIGHUP so nothing in the build dies of that; the follower below is the only
# writer to the pipe and the only thing that may die with it.
trap '' PIPE HUP

LOG="${BP_BUILD_LOG:-$REPO/.bp-build.log}"
: > "$LOG" 2> /dev/null || LOG="$(mktemp)"

SCHED="${BP_BUILD_SCHEDULERS:-1}"
NICE="${BP_BUILD_NICE:-10}"

prio=()
command -v nice > /dev/null 2>&1 && prio+=(nice -n "$NICE")
command -v ionice > /dev/null 2>&1 && prio+=(ionice -c 2 -n 7)

say "nice=$NICE ionice=best-effort/7 ERL_FLAGS=+S $SCHED:$SCHED log=$LOG"

(
  export BP_BUILD_GUARDED=1
  export ERL_FLAGS="${ERL_FLAGS:+$ERL_FLAGS }+S $SCHED:$SCHED"
  # Elixir 1.19+ reads this; on older Elixir it is inert. 1 = one deps
  # compile at a time, the same bound as the scheduler flag above.
  export MIX_OS_DEPS_COMPILE_PARTITION_COUNT=1
  exec ${prio[@]+"${prio[@]}"} "$@"
) >> "$LOG" 2>&1 < /dev/null &
child=$!

# Follow the log to stdout until the child exits. GNU tail stops on its own
# once --pid exits and has printed everything; elsewhere we stop it ourselves.
if tail --version > /dev/null 2>&1; then
  tail -n +1 -f --pid="$child" "$LOG" 2> /dev/null || true
  wait "$child"
  rc=$?
else
  tail -n +1 -f "$LOG" 2> /dev/null &
  follower=$!
  wait "$child"
  rc=$?
  sleep 1
  kill "$follower" 2> /dev/null
  wait "$follower" 2> /dev/null
fi

exit "$rc"
