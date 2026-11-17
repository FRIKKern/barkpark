#!/usr/bin/env bash
#
# ci-test-watchdog.sh — run the Elixir Test step's `mix test` under a watchdog
# (task-6d4727b7cff1f2bd).
#
# WHY. Partition 2 of the Test job has died ~1 run in 5 since 2026-11-12: output
# stops 1.5-2.5 min after "Running ExUnit", at a different test each time, and
# ~50 min later GitHub fails the job with "The hosted runner lost communication
# with the server" (19 of 19 such jobs, 11-12..11-16). No dump, no reason, and
# 50 runner-minutes gone each time. This script makes the next one say why:
#
#   * every --every seconds it prints ONE line of runner health (free memory,
#     swap, disk, load, the BEAM's RSS, OS process count, seconds since the last
#     test output). If the runner dies, the last lines show what ran out.
#   * if the test output is silent for --quiet seconds, or free memory or free
#     disk falls under its floor, it dumps the BEAM (SIGUSR1 -> erl_crash.dump:
#     every process, its queue, memory and stack), prints a summary, and FAILS.
#     A dead-silent hang then costs --quiet seconds, not 50 minutes.
#
# NEVER GREENS A RED. The exit code is the command's own; when the watchdog
# fires it is 124 whatever the command would have said.
#
# QUIET BUDGET. Before #26713 the longest silent gap was 149 s:
# PdsElixirCensusTest's setup_all, all arms at once. Its arms now run two at a
# time and print a line as each one finishes (PdsCensusMutantGate.run_arms/2).
# In the 18 Test jobs of the first 6 main pushes after it (44040815245 ..
# 44047577365) the longest gap was 91 s, between two arm lines. The default
# --quiet 600 is 6.6x that; a real hang still costs 10 min, not 50.
#
# MEMORY FLOOR. --min-mem-mb 700 is far under a healthy run's low point: on
# those pushes MemAvailable never fell below 4687 MB on the 16 GB runner
# (PdsCensusMutantGate's 1 s sampler), 6.7x the floor.
#
# usage: ci-test-watchdog.sh [--quiet S] [--every S] [--min-mem-mb N]
#                            [--min-disk-mb N] [--out DIR] -- CMD [ARG...]
#   writes into DIR: output.log (the command's output), erl_crash.dump and
#   watchdog.txt (the trigger, the summary, ps/df/free) when it fires.

set -uo pipefail

quiet=600 every=30 min_mem=700 min_disk=1024 out="${RUNNER_TEMP:-/tmp}/test-watchdog"
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) quiet="$2"; shift 2 ;;
    --every) every="$2"; shift 2 ;;
    --min-mem-mb) min_mem="$2"; shift 2 ;;
    --min-disk-mb) min_disk="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "ci-test-watchdog: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ $# -gt 0 ] || { echo "ci-test-watchdog: no command after --" >&2; exit 2; }

mkdir -p "$out" || exit 2
log="$out/output.log" report="$out/watchdog.txt" fifo="$out/.fifo.$$"
: >"$log"
rm -f "$fifo" && mkfifo "$fifo" || exit 2
# The dump is capped at 500 MB (it goes into a 14-day artifact). Child BEAMs
# (census arms, test subprocesses) inherit these too; a crashing child writes
# the same file, which is fine: any dump beats none.
export ERL_CRASH_DUMP="$out/erl_crash.dump" ERL_CRASH_DUMP_SECONDS=120 ERL_CRASH_DUMP_BYTES=500000000

say() { echo "[test-watchdog] $*"; }

# Output reaches the job log AND $log; $log's size is the quiet clock.
tee -a "$log" <"$fifo" &
teepid=$!
"$@" >"$fifo" 2>&1 &
pid=$!

mem_avail_mb() { awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null; }
swap_used_mb() { awk '/^SwapTotal:/ { t = $2 } /^SwapFree:/ { f = $2 } END { if (t != "") print int((t - f) / 1024) }' /proc/meminfo 2>/dev/null; }
disk_free_mb() { df -Pm "$out" 2>/dev/null | awk 'NR == 2 { print $4 }'; }

# A process and every OS process under it, parents first (default: `pid`).
tree() {
  local p frontier="${1:-$pid}" kids
  while [ -n "${frontier// /}" ]; do
    kids=""
    for p in $frontier; do
      echo "$p"
      kids="$kids $(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')"
    done
    frontier="$kids"
  done
}

# The BEAM is `pid` itself (mix execs down to beam.smp) or a descendant of it.
beam_pid() {
  local p
  for p in $(tree); do
    case "$(ps -o comm= -p "$p" 2>/dev/null)" in *beam*) echo "$p"; return ;; esac
  done
}

# Top processes of an erl_crash.dump: by queue, by memory, and every one not waiting.
summarize_dump() {
  awk '
    function flush() { if (pid != "") print q "\t" m "\t" st "\t" pid "\t" nm "\t" sp "\t" pc; pid = "" }
    /^=proc:/ { flush(); pid = substr($0, 7); q = 0; m = 0; st = nm = sp = pc = "-"; next }
    /^=/ { flush(); next }
    pid != "" && /^State: / { st = substr($0, 8) }
    pid != "" && /^Name: / { nm = substr($0, 7) }
    pid != "" && /^Spawned as: / { sp = substr($0, 13) }
    pid != "" && /^Message queue length: / { q = substr($0, 23) + 0 }
    pid != "" && /^Memory: / { m = substr($0, 9) + 0 }
    pid != "" && /^Program counter: / { pc = $0; sub(/^Program counter: [^ ]* */, "", pc) }
    END { flush() }' "$1" >"$out/procs.tsv"
  echo "processes in the dump: $(wc -l <"$out/procs.tsv" | tr -d ' ')"
  sed -n '/^=memory/,/^=/p' "$1" | sed '$d' | head -20
  echo "-- top 15 by message queue (queue, bytes, state, pid, name, spawned as, current)"
  sort -t "$(printf '\t')" -k1,1nr "$out/procs.tsv" | head -15
  echo "-- top 15 by memory"
  sort -t "$(printf '\t')" -k2,2nr "$out/procs.tsv" | head -15
  echo "-- not waiting (running, runnable, garbing, exiting...)"
  awk -F'\t' '$3 != "Waiting"' "$out/procs.tsv" | head -40
}

# True once `$1` has exited: no such pid, or a zombie (on Linux `kill -0`
# still succeeds on a zombie whose parent has not reaped it yet).
gone() { case "$(ps -o stat= -p "$1" 2>/dev/null)" in "" | Z*) return 0 ;; esac; return 1; }

fire() {
  local reason="$1" beam pids p
  # Snapshot the tree NOW: once the BEAM exits, its port children are
  # reparented to init and `tree` can no longer find them.
  pids="$(tree)"
  beam="$(beam_pid)"
  # Freeze the BEAM's own children before the dump: a census arm VM (~3.8 GB)
  # must not keep growing while the BEAM writes, and the frozen state is the
  # state the dump describes. Never its parents: a frozen parent cannot reap
  # the dumped BEAM, which then lingers as a zombie.
  if [ -n "$beam" ]; then
    for p in $(tree "$beam"); do [ "$p" = "$beam" ] || kill -STOP "$p" 2>/dev/null; done
  fi
  {
    say "FIRED: $reason (at +$(($(date +%s) - start))s). Dumping the BEAM and failing this step."
    echo "-- free / df / load"
    free -m 2>/dev/null; df -h 2>/dev/null; uptime
    echo "-- OS processes under the test command (pid ppid rss etime command)"
    ps -o pid,ppid,rss,etime,args -p "$(echo "$pids" | paste -sd, -)" 2>/dev/null | cut -c1-220
    echo "-- top OS processes by RSS"
    ps -eo pid,ppid,rss,etime,args --sort=-rss 2>/dev/null | head -12 | cut -c1-220
  } >"$report" 2>&1
  if [ -n "$beam" ]; then
    kill -USR1 "$beam" 2>/dev/null
    # Done when the BEAM is gone or the dump is complete (its last line is =end).
    for _ in $(seq 1 150); do
      gone "$beam" && break
      tail -c 16 "$ERL_CRASH_DUMP" 2>/dev/null | grep -q '^=end' && break
      sleep 1
    done
  fi
  # The saved list, plus anything still under `pid` (nothing frozen can fork).
  # shellcheck disable=SC2046,SC2086 # one pid per word
  kill -9 $pids $(tree) 2>/dev/null
  if [ -s "$ERL_CRASH_DUMP" ]; then
    { echo "-- erl_crash.dump summary ($ERL_CRASH_DUMP)"; summarize_dump "$ERL_CRASH_DUMP"; } >>"$report" 2>&1
  else
    echo "-- no erl_crash.dump was written (beam pid: ${beam:-not found})" >>"$report"
  fi
  cat "$report"
}

# A SIGTERM or SIGINT to the watchdog alone must not leave the test command
# running unsupervised (a bash child ignores SIGINT under `&`): pass TERM to
# the whole tree, give it 10 s, then SIGKILL what is left. `last_tree` (at
# most 1 s old) covers a BEAM that a group SIGINT has already ended: its port
# children run in their own session, so the group signal never reached them.
# shellcheck disable=SC2329 # invoked by the traps below
on_signal() {
  local pids p q
  pids="$(tree) $last_tree"
  # shellcheck disable=SC2086 # one pid per word
  kill -TERM $pids 2>/dev/null
  for _ in $(seq 1 10); do
    p=""; for q in $pids; do kill -0 "$q" 2>/dev/null && p=1; done
    [ -n "$p" ] || break
    sleep 1
  done
  # shellcheck disable=SC2086 # one pid per word
  kill -9 $pids "$teepid" 2>/dev/null
  rm -f "$fifo"
  say "got SIG$1; stopped the test command's tree"
  exit "$2"
}
trap 'on_signal TERM 143' TERM
trap 'on_signal INT 130' INT

start=$(date +%s) last_size=0 last_change=$start next_line=$((start + every)) fired="" last_tree=""
while kill -0 "$pid" 2>/dev/null; do
  last_tree="$(tree)"
  sleep 1
  now=$(date +%s)
  size=$(wc -c <"$log" | tr -d ' ')
  if [ "$size" != "$last_size" ]; then last_size=$size; last_change=$now; fi
  mem=$(mem_avail_mb) disk=$(disk_free_mb)
  if [ "$now" -ge "$next_line" ]; then
    next_line=$((now + every))
    b="$(beam_pid)"
    brss=$([ -n "$b" ] && ps -o rss= -p "$b" 2>/dev/null | awk '{ print int($1 / 1024) }')
    say "+$((now - start))s mem_avail=${mem:-?}MB swap_used=$(swap_used_mb)MB disk_free=${disk:-?}MB load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null) beam_rss=${brss:-?}MB os_procs=$(ps -e 2>/dev/null | wc -l | tr -d ' ') quiet=$((now - last_change))s"
  fi
  [ -n "$disk" ] && [ "$disk" -lt "$min_disk" ] && fired="free disk ${disk}MB is under ${min_disk}MB"
  [ -n "$mem" ] && [ "$mem" -lt "$min_mem" ] && fired="free memory ${mem}MB is under ${min_mem}MB"
  [ $((now - last_change)) -ge "$quiet" ] && fired="no test output for ${quiet}s"
  if [ -n "$fired" ]; then fire "$fired"; break; fi
done

wait "$pid"
rc=$?
# A grandchild that inherited the pipe can hold tee open; it gets 10 s.
for _ in $(seq 1 10); do kill -0 "$teepid" 2>/dev/null || break; sleep 1; done
kill "$teepid" 2>/dev/null
rm -f "$fifo"
if [ -n "$fired" ]; then
  echo "::error::test watchdog: $fired. The BEAM dump summary is above; erl_crash.dump is in the test-watchdog artifact."
  exit 124
fi
exit "$rc"
