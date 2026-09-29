#!/usr/bin/env bash
#
# pds-idle-sampler.sh — the PAIRED IDLE CONTROL, ALONE (PDS-D237).
#
# WHAT THIS IS. scripts/pds-export-peak-measure.sh with its acquisition leg and
# its mutual-exclusion preflight removed. Nothing is fetched, nothing is
# authenticated, no mutex is taken. It observes: ssh + pgrep + ps + awk, twice a
# quantity, once a second, for a window you name. That is the whole program.
#
# WHY IT EXISTS. PDS-D104/PDS-D216 require the export-demand figure to carry a
# paired idle control. The obvious way to get one is to run the paired-control
# instrument — and beside a LIVE climb that instrument REFUSES. It takes
# `$PDS_FULL_EXPORT_DIR/lock` (default /tmp/pds-full-export/lock, byte-identically
# the path the frozen harness holds for the whole export) in its preflight,
# UNCONDITIONALLY, before its first window starts, and then evaluates the 2200 MiB
# headroom floor. Both are correct there: that instrument can FIRE a ~2.2 GiB
# full-fidelity export, and two of those against a 3.8 GB box OOM it (PDS-D31).
#
# Neither is correct HERE, and the distinction is the whole point of this file:
#
#   * Not passing --path does NOT dodge it. The mutex is taken in preflight
#     regardless of whether the acquisition window ever runs, so a caller who
#     wanted only the control still collides with the climb.
#   * Beside an active climb the collision does not degrade gracefully. It exits
#     2 with a PDS-D31 "is held by another run" message, which mid-wave reads as
#     unrelated infrastructure failure rather than as "the control declined to
#     race the thing it was measuring".
#   * Gating pure observation behind the export mutex is backwards. ssh + pgrep
#     + ps + awk allocate nothing on the source box. There is no OOM risk to
#     serialise, so there is nothing for the mutex to protect.
#
# So this file rides BESIDE a live climb at zero export cost. It takes no mutex,
# reads no headroom floor, and touches no state the climb owns.
#
# IT MUST NEVER GATE OR DELAY THE FIRE (PDS-D237). The climb is the wave's
# success condition; this is an instrument beside it. If this script is broken,
# unbuilt, or refusing, the climb fires WITHOUT it. A control is worth having and
# is worth nothing at the price of the transcript.
#
# WHAT IS REPRODUCED EXACTLY FROM THE PAIRED-CONTROL INSTRUMENT, AND WHY
#
#   1. UNITS. MiB is kB/1024. NEVER /1000. Mixing the two is precisely the slip
#      that once stated the export shortfall as 31 instead of 35.43 (PDS-D185).
#
#   2. BASELINE t=0 (PDS-D185). A ONE-SHOT `ps -o rss=` taken strictly BEFORE the
#      window opens, not the sampler's first logged tick — which lands at t≈+1 s
#      and already carries part of whatever is being measured.
#
#   3. PROCESS SELECTION (PDS-D135). `pgrep -o -x beam.smp` for the primary,
#      `pgrep -x beam.smp` for the set. NEVER `-f`: it matches ARGV, so an ssh
#      command line that merely mentions beam.smp SELF-MATCHES, and `head -1` is
#      a PID sort, not an age sort. One captured run under-read by ~342x — it
#      sampled a 1,852 kB monitoring shell instead of the 634,324 kB BEAM. The
#      box runs blue/green and legitimately has two slots alive, so EVERY
#      comm-anchored beam.smp is sampled and the peak is the MAX ACROSS THE SET.
#
#   4. RATE. 1 Hz, stated in the output. Per PDS-D114 a 1 Hz sampler reports a
#      LOWER BOUND — a transient between ticks is invisible. For a control that
#      is the CONSERVATIVE direction: it understates the drift, so it never
#      flatters a demand figure by inflating the noise beside it.
#
# TWO QUANTITIES, TWO INDEPENDENT LOOPS (PDS-D220b). BEAM RSS is the frozen
# procedure's quantity and stays the headline. /proc/meminfo MemAvailable is
# sampled beside it because PDS-D221 states its contamination-abort threshold
# (1048.16 MiB) on the RANGE of MemAvailable — a WHOLE-BOX figure. Attaching that
# threshold to a per-process RSS delta compares two different quantities: the
# same unit-class error PDS-D185 exists to correct, one level up.
#
# The MemAvailable leg is its OWN ssh loop, never extra columns in the RSS log.
# The RSS log's `<epoch> <pid> <rss_kb>` shape is the frozen arithmetic's
# contract, and a foreign line in that file would be read by peak_kb_of() as a
# colossal RSS reading and silently wreck the headline.
#
# THIS SCRIPT REPORTS THE RANGE AND DOES NOT JUDGE IT. Applying PDS-D221's
# 1048.16 MiB threshold is the derivation slice's call, against the emitted
# number. An instrument that both measures and rules on its own measurement
# gives a reader nothing to check.
#
# HONESTY NOTE ON THE MARGIN. Today's live 60-tick run measured an idle
# MemAvailable range of 1026.93 MiB against that 1048.16 MiB threshold — 98% of
# it. One clean run is NOT evidence the contamination risk has passed. It is
# evidence the box cleared the bar by 21 MiB on one occasion. Read any single
# green range accordingly.
#
# WHY A ZERO-SAMPLE WINDOW IS A REFUSAL, NOT A NUMBER (PDS-D220a). peak_kb_of()
# returns 0 for an empty log and the delta subtracts the baseline from it, so a
# sampler that lost its ssh session reports a large NEGATIVE drift and exits 0.
# Worse on the MemAvailable leg: an unsampled leg yields min 0 / max 0 / range
# 0.00 MiB, which reads to a threshold check as the quietest possible box and
# PASSES. A vacuous zero must never authorise a measurement. Both legs refuse.
#
# WHY --window HAS NO DEFAULT (pds-bl-sampler-window-default-retired-engine).
# This file used to default --window to 130 s, documented as "the canonical
# export's wall time, so a control taken with the default is length-paired with
# the canonical acquisition". That pairing claim is DEAD. The 130 s was measured
# in wave 7 against the IN-MEMORY export engine (send_resp materialising the
# whole tar as one BEAM binary), which wave 11 replaced with the streaming spill
# engine now deployed. The deployed engine has never completed the full
# canonical export, so its wall time is UNMEASURED — that is the open blocker
# pds-bl-w13-export-duration-unmeasured, and until it is paid nobody, including
# this script, knows whether the streaming engine is faster or slower than the
# retired one.
#
# An inherited 130 s is worse than no number. A window shorter than the
# acquisition it is paired with does not refuse: it closes early and reports an
# ordinary-looking, too-LOW control, which flatters whatever measurement it is
# placed beside. Nor does the launcher rescue the caller — scripts/pds-crown-
# launch.sh never invokes this sampler (the ride-along is manual by
# construction) and its own poll loop can wait hours before the export fires, so
# no default can be length-paired with an event whose start time is unknown.
#
# The honest move is therefore NOT to substitute a guessed replacement. It is to
# refuse to supply one: the caller must state the window, and owns the pairing
# claim. Same anti-vacuous rule as PDS-D220a — a figure nobody measured must
# never authorise a measurement. Until the blocker is paid, pass a generously
# large window and truncate at ANALYSIS time using the transcript's own
# idle_window_requested_s vs idle_window_s (both are on the machine line).
#
# USAGE
#
#   scripts/pds-idle-sampler.sh --window <seconds> [--label <text>]
#                               [--out <file>]
#   scripts/pds-idle-sampler.sh --selftest
#
#   --window   window length in seconds. REQUIRED — there is no default, and
#              omitting it is a misconfiguration (exit 3), not an inherited
#              number. See WHY --window HAS NO DEFAULT below.
#   --label    free text recorded in the output (e.g. "beside-climb-w13").
#   --out      also write the machine-readable line to this file.
#   --selftest run the built-in three-arm harness (below). Touches NO host: it
#              re-runs this script against a fake `ssh` on a shimmed PATH in a
#              mktemp work dir, so it is safe on any laptop and in CI.
#
#              WHERE IT RUNS. It is an arm of the `pds-harnesses` leg in
#              .github/shell-harness-legs.json, executed by the `harness`
#              matrix job of .github/workflows/shell-harnesses.yml through
#              scripts/shell-harness-run.sh. The leg is dispatched for this
#              file by the roster row `pds-harnesses scripts/pds-*.sh`, so an
#              edit HERE runs it. Before that wiring it ran in no job at all,
#              which is how a guard decays in silence.
#
# WHAT SURVIVES AN EARLY KILL (the defect this section documents)
#
# This instrument's ONLY product is the sample series in its work dir. It used
# to register `trap cleanup EXIT INT TERM` with a cleanup() that `rm -rf`'d that
# work dir UNCONDITIONALLY — so on an early TERM the logs were deleted BEFORE
# the main body's peak arithmetic read them, the run fell through to the
# PDS-D220a zero-sample refusal, and a window that had collected 34 real
# non-zero readings reported itself as `peak 0 kB (MAX over 0 readings)` and
# blamed a lost ssh session. That diagnosis was false twice over: the samples
# existed, and the killer was an operator. The failure was TOTAL — no operator
# could recover the partial series afterwards.
#
# So the three signals are no longer treated alike:
#
#   * EXIT (the run finished, refused, or died on its own terms) — the work dir
#     is REMOVED. A cleanup that never cleans up is not a fix either; the tidy
#     path still tidies, and the preflight prints the path it will remove.
#   * INT / TERM (somebody else ended this run) — the samplers are killed, the
#     partial series is READ and REPORTED, the work dir is PRESERVED at the path
#     printed on the way out, and a `PDS_IDLE_SAMPLE_PARTIAL` line is emitted.
#     The prefix differs from the complete run's `PDS_IDLE_SAMPLE` on purpose:
#     a partial control must not be ingestible as a measurement (PDS-D220a's
#     rule — a figure nobody finished must never authorise a measurement).
#     Exit is 130 (INT) / 143 (TERM), never 0 and never the 2 that would read as
#     "this instrument refused".
#
#   PDS_IDLE_KEEP_WORK_DIR=1 preserves the work dir on the clean path too, for
#   an operator who wants the raw series after a completed window.
#
# DETACHED LAUNCH — python3 fork+setsid+execvp, NEVER `& disown` (PDS-D243)
#
# A sampler riding beside a hours-long climb outlives the shell that started it,
# and `& disown` is the form PDS-D243 MEASURED as fragile: the child keeps the
# launcher's process group, survives a turn end and `kill -HUP -<pgid>`, and
# DIES to `kill -TERM -<pgid>` — which is what a closing tmux pane sends. It
# would vanish with `sampler_launched: yes` already recorded and nothing
# collected. `setsid(1)` does not exist on macOS either (PDS-D243 again), so the
# recipe is python3, exactly the form `cmd_arm` uses:
#
#   python3 - <<'PY'
#   import os, sys
#   if os.fork() == 0:
#       os.setsid()
#       fd = os.open('/tmp/pds-idle-sampler-w16.log',
#                    os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
#       os.dup2(fd, 1); os.dup2(fd, 2)
#       os.close(0)
#       os.execvp('scripts/pds-idle-sampler.sh',
#                 ['scripts/pds-idle-sampler.sh',
#                  '--window', '21600',
#                  '--label', 'beside-climb',
#                  '--out', '/tmp/pds-idle-sampler-w16.out'])
#   PY
#
# Then PROVE the detach rather than assuming it — the launched process must be
# its own session leader:
#
#   $ ps -p <pid> -o pid=,ppid=,pgid=,stat=,comm=
#   62913     1 62913 Ss   /usr/bin/env
#
# `pgid == pid` and `STAT` starting `Ss` is the session leader; `ppid=1` is the
# reparenting. Anything else (a pgid equal to the launching shell's) is the
# `& disown` shape and IS reaped by a pane close. The same recipe, with the same
# `ps -p` proof, is recorded live at docs/ledgers/pds-w15-fire-record.md.
#
# SELFTEST — three arms, no host touched
#
#   `--selftest` builds a fake `ssh` on a shimmed PATH and runs this script
#   three times in a mktemp work dir:
#     ARM 1 (RED when the preservation is reverted) — kill a running window with
#           TERM mid-flight; the run MUST report a non-zero sample count, MUST
#           NOT blame the ssh session, and its work dir MUST still hold the logs.
#     ARM 2 (RED if the cleanup stops cleaning) — let a window finish; the run
#           MUST exit 0, MUST print the complete `PDS_IDLE_SAMPLE` line, and its
#           work dir MUST be gone.
#     ARM 3 (the keep-flag control) — a finished window under
#           PDS_IDLE_KEEP_WORK_DIR=1 MUST exit 0 AND keep its work dir, so arm 2
#           is proving the cleanup ran rather than that the dir never existed.
#   PDS_IDLE_SELFTEST_TARGET=<path> points the harness at ANOTHER copy of this
#   script — that is how arm 1 is shown to red against the pre-fix version.
#
# ENV (all optional, mirroring the paired-control instrument's names)
#
#   PDS_SOURCE_BASE      default https://guerrilla.barkpark.cloud (recorded only)
#   PDS_SOURCE_WORKSPACE default default                          (recorded only)
#   PDS_SOURCE_SSH       default root@157.180.90.121
#   PDS_SOURCE_SSH_KEY   default $HOME/.ssh/barkpark_indx
#   PDS_RUN_ID           default a UTC stamp + pid
#   PDS_IDLE_KEEP_WORK_DIR  set to 1 to keep the work dir on the clean path too
#
#   No token is read and none is needed: nothing is fetched.
#
# EXIT: 0 measured · 2 refused (SSH unavailable, no comm-anchored BEAM, or a leg
#       that logged nothing — PDS-D220a) · 3 misconfigured (this includes a
#       MISSING --window: see WHY --window HAS NO DEFAULT above) ·
#       130 / 143 TERMINATED BY INT / TERM — NOT a refusal and NOT a failure of
#       this instrument: the partial series is preserved and reported on the way
#       out (see WHAT SURVIVES AN EARLY KILL above).

set -eu

# A decimal COMMA is not a number this instrument may emit. Under a comma locale
# `awk 'printf "%.2f"'` renders 115.46 as "115,46", which silently corrupts every
# MiB figure in the machine-readable line. Caught by running it, not reading it.
LC_ALL=C
export LC_ALL

SELF="$(basename "$0")"

# THE BLIND-SPOT SENTENCE, BY REFERENCE (PDS-D633) — `$PDS_BLIND_SPOT` and
# `pds_blind_spot_note` come from ONE file, never a retyped copy;
# scripts/pds-blind-spot-check.sh reds if a copy drifts. Fail-closed on purpose:
# an instrument that cannot find the sentence it is obliged to print beside a
# duration must refuse, not print the duration bare.
# shellcheck source=scripts/pds-blind-spot.sh
PDS_SELF_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd)"
. "$PDS_SELF_DIR/pds-blind-spot.sh"

# ── source under observation (names mirror the paired-control instrument) ─────

SOURCE_BASE="${PDS_SOURCE_BASE:-https://guerrilla.barkpark.cloud}"
SOURCE_WS="${PDS_SOURCE_WORKSPACE:-default}"
SOURCE_SSH="${PDS_SOURCE_SSH-root@157.180.90.121}"
SOURCE_SSH_KEY="${PDS_SOURCE_SSH_KEY:-$HOME/.ssh/barkpark_indx}"

RUN_ID="${PDS_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"

SAMPLE_HZ=1                       # stated in the output; see PDS-D114
# NO DEFAULT. The empty string is the "caller said nothing" sentinel, refused
# below. The old value (130 s) was the RETIRED in-memory engine's wall time and
# the deployed streaming engine's is unmeasured — pds-bl-w13-export-duration-
# unmeasured. See WHY --window HAS NO DEFAULT in the header.
IDLE_SECONDS=""
LABEL="unlabelled"
OUT_FILE=""

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pds-idle.XXXXXX")"
IDLE_LOG="$WORK_DIR/idle-rss.log"
IDLE_MEM_LOG="$WORK_DIR/idle-memavail.log"

say()  { printf '%s\n' "$*"; }
info() { printf '      %s\n' "$*"; }
rule() { printf -- '─%.0s' $(seq 1 78); printf '\n'; }
die()  { printf '%s: %s\n' "$SELF" "$*" >&2; exit 3; }
refuse() { printf '%s: REFUSED — %s\n' "$SELF" "$*" >&2; exit 2; }

IDLE_SAMPLER_PID=""
IDLE_MEM_SAMPLER_PID=""

# THE THREE SIGNALS ARE NOT ALIKE. `trap cleanup EXIT INT TERM` with an
# unconditional `rm -rf "$WORK_DIR"` deleted the ONLY product this instrument
# has — idle-rss.log and idle-memavail.log — before the main body's arithmetic
# read them. On an early TERM the body then resumed after `wait`, found an empty
# (deleted) log, and fired the PDS-D220a zero-sample refusal: a run with 34 real
# readings printed `MAX over 0 readings` and blamed a lost ssh session. Both
# halves of that were false, and the loss was unrecoverable.
#
# EXIT keeps the tidy behaviour. INT and TERM get their own handler, which reads
# and reports the partial series and PRESERVES the dir. TERMINATED_BY is the
# one-way latch the EXIT handler reads to decide whether to remove anything; it
# is set BEFORE the report is printed so that a second signal arriving mid-report
# still lands on a preserving cleanup.
TERMINATED_BY=""

kill_samplers() {
  [ -n "$IDLE_SAMPLER_PID" ] && kill "$IDLE_SAMPLER_PID" 2>/dev/null || true
  [ -n "$IDLE_MEM_SAMPLER_PID" ] && kill "$IDLE_MEM_SAMPLER_PID" 2>/dev/null || true
}

cleanup() {
  kill_samplers
  # Preserve on a signal, and on an explicit operator request. Otherwise tidy —
  # a cleanup that never cleans up is its own defect.
  if [ -n "$TERMINATED_BY" ] || [ "${PDS_IDLE_KEEP_WORK_DIR:-0}" = 1 ]; then
    return 0
  fi
  rm -rf "$WORK_DIR" 2>/dev/null || true
}

# The partial report. Everything it quotes is read from the logs AFTER the
# samplers are killed and BEFORE anything is removed — that ordering is the
# whole fix. The helpers it calls (samples_in/peak_kb_of/min_f2_of/max_f2_of)
# are defined further down; a trap handler resolves its callees at FIRE time, so
# a signal arriving before they exist cannot reach this function either, because
# a signal before the window has nothing to preserve.
on_signal() { # <signal name> <exit code>
  sig="$1"; code="$2"
  TERMINATED_BY="$sig"
  trap '' INT TERM            # a second signal must not re-enter this report
  kill_samplers

  part_t1="$(date +%s)"
  part_wall=0
  [ -n "${IDLE_T0:-}" ] && part_wall=$((part_t1 - IDLE_T0))

  part_samples=0; part_peak=0; part_mem_samples=0; part_mem_min=0; part_mem_max=0
  if [ -f "$IDLE_LOG" ]; then
    part_samples="$(samples_in "$IDLE_LOG")"
    part_peak="$(peak_kb_of "$IDLE_LOG")"
  fi
  if [ -f "$IDLE_MEM_LOG" ]; then
    part_mem_samples="$(samples_in "$IDLE_MEM_LOG")"
    part_mem_min="$(min_f2_of "$IDLE_MEM_LOG")"
    part_mem_max="$(max_f2_of "$IDLE_MEM_LOG")"
  fi

  printf '\n%s: TERMINATED BY SIG%s after %s s of the %s s window.\n' \
    "$SELF" "$sig" "$part_wall" "${IDLE_SECONDS:-unset}" >&2
  printf '      This is an OPERATOR- OR SHELL-INITIATED STOP. It is NOT an ssh\n' >&2
  printf '      failure and NOT a refusal by this instrument, and the samples\n' >&2
  printf '      already collected are PRESERVED, not deleted.\n' >&2
  printf '      rss samples ........ %s (peak %s kB)\n' "$part_samples" "$part_peak" >&2
  printf '      memavail samples ... %s (min %s kB, max %s kB)\n' \
    "$part_mem_samples" "$part_mem_min" "$part_mem_max" >&2
  printf '      preserved at ....... %s\n' "$WORK_DIR" >&2
  printf '                           idle-rss.log, idle-memavail.log — the raw\n' >&2
  printf '                           series, readable now that nothing removed it.\n' >&2

  # A DIFFERENT PREFIX, deliberately. `PDS_IDLE_SAMPLE` means a window that
  # closed on its own terms; a consumer grepping that prefix must never ingest a
  # truncated control as a measurement (PDS-D220a). Partial lines announce
  # themselves in the key, not in a field a parser can drop.
  part_line="PDS_IDLE_SAMPLE_PARTIAL run_id=$RUN_ID label=$LABEL status=terminated_by_signal signal=$sig partial=yes sample_hz=$SAMPLE_HZ units=kB_div_1024 idle_peak_kb=$part_peak idle_samples=$part_samples idle_window_requested_s=${IDLE_SECONDS:-0} idle_window_s=$part_wall idle_memavail_samples=$part_mem_samples idle_memavail_min_kb=$part_mem_min idle_memavail_max_kb=$part_mem_max work_dir_preserved=$WORK_DIR threshold_applied=none"
  printf '%s\n' "$part_line"
  [ -n "$OUT_FILE" ] && printf '%s\n' "$part_line" >"$OUT_FILE" 2>/dev/null || true

  exit "$code"
}

trap cleanup EXIT
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

# ── the built-in selftest — THREE ARMS, NO HOST TOUCHED ──────────────────────
#
# This instrument's product is a file it deletes on the way out, which is
# precisely why the deletion policy needs a check that RUNS. The harness shims a
# fake `ssh` onto PATH (so nothing is contacted, nothing is authenticated and no
# real work dir is ever named) and drives THIS script to each of the three exits
# that matter: killed mid-window, finished, and finished under the keep flag.
#
# ARM 1 is the RED arm for this row's fix: point PDS_IDLE_SELFTEST_TARGET at a
# pre-fix copy of the script and it fails, because that copy exits 2 with the
# "lost its ssh session" refusal instead of 143 with a preserved series.
# ARM 2 is the quiet arm: a cleanup that stopped cleaning up would red it.
# ARM 3 is ARM 2's control — it proves the work dir EXISTS to be removed, so a
# green ARM 2 cannot be bought by never creating one.
selftest_ssh_shim() { # <path to write>
  cat >"$1" <<'SHIM'
#!/usr/bin/env bash
# fake ssh — answers exactly the commands pds-idle-sampler.sh issues.
cmd=""
for a in "$@"; do cmd="$a"; done
case "$cmd" in
  true) exit 0 ;;
  *"for i in "*)
    ticks="$(printf '%s' "$cmd" | sed -n 's/.*seq 1 \([0-9][0-9]*\).*/\1/p')"
    [ -n "$ticks" ] || ticks=5
    i=0
    while [ "$i" -lt "$ticks" ]; do
      case "$cmd" in
        *"rss="*) printf '%s %s %s\n' "$(date +%s)" 4242 $((123456 + i)) ;;
        *)        printf '%s %s\n'    "$(date +%s)" $((4000000 - i * 10)) ;;
      esac
      i=$((i + 1))
      sleep 1
    done ;;
  *rev-parse*)                 printf 'selftestshaselftestsha\n' ;;
  *"pgrep -o -x"*)             printf '4242\n' ;;
  *"pgrep -x beam.smp | tr"*)  printf '4242 \n' ;;
  *"pgrep -x beam.smp"*)       printf '123456\n' ;;
  *"ps -o rss= -p"*)           printf '  123456\n' ;;
  *MemAvailable*)              printf '4000000\n' ;;
  *) exit 0 ;;
esac
SHIM
  chmod +x "$1"
}

selftest_fail() { printf '  ARM %s FAILED: %s\n' "$1" "$2" >&2; SELFTEST_RC=1; }

run_selftest() {
  SELFTEST_RC=0
  target="${PDS_IDLE_SELFTEST_TARGET:-$PDS_SELF_DIR/$SELF}"
  t="$(mktemp -d "${TMPDIR:-/tmp}/pds-idle-selftest.XXXXXX")"
  mkdir -p "$t/bin"
  selftest_ssh_shim "$t/bin/ssh"
  : >"$t/fake.key"

  say "pds-idle-sampler selftest — target $target"
  say "  harness $t (fake ssh on PATH; no host is contacted)"

  # ARM 1 — killed mid-window. The samples must survive and be reported.
  (
    PATH="$t/bin:$PATH" PDS_SOURCE_SSH="selftest@fake" PDS_SOURCE_SSH_KEY="$t/fake.key" \
    PDS_RUN_ID="selftest-arm1" bash "$target" --window 30 --label selftest-kill
  ) >"$t/arm1.out" 2>&1 &
  arm1_pid=$!
  sleep 6
  kill -TERM "$arm1_pid" 2>/dev/null || true
  arm1_rc=0; wait "$arm1_pid" || arm1_rc=$?

  [ "$arm1_rc" = 143 ] || selftest_fail 1 "expected exit 143 (TERM), got $arm1_rc — see $t/arm1.out"
  grep -q 'TERMINATED BY SIGTERM' "$t/arm1.out" \
    || selftest_fail 1 "no TERMINATED BY SIGTERM line — see $t/arm1.out"
  grep -q 'lost its ssh session' "$t/arm1.out" \
    && selftest_fail 1 "a kill was blamed on the ssh session — see $t/arm1.out"
  arm1_samples="$(sed -n 's/.*PDS_IDLE_SAMPLE_PARTIAL .*idle_samples=\([0-9]*\).*/\1/p' "$t/arm1.out" | head -1)"
  [ -n "$arm1_samples" ] && [ "$arm1_samples" -gt 0 ] 2>/dev/null \
    || selftest_fail 1 "killed run reported '${arm1_samples:-no}' samples, not a positive count — see $t/arm1.out"
  arm1_dir="$(sed -n 's/.*work_dir_preserved=\([^ ]*\).*/\1/p' "$t/arm1.out" | head -1)"
  if [ -n "$arm1_dir" ] && [ -s "$arm1_dir/idle-rss.log" ]; then
    arm1_lines="$(awk 'NF{n++} END{print n+0}' "$arm1_dir/idle-rss.log")"
    say "  ARM 1 ok — exit $arm1_rc, reported $arm1_samples samples, $arm1_lines lines survive in $arm1_dir"
    rm -rf "$arm1_dir" 2>/dev/null || true
  else
    selftest_fail 1 "the work dir was not preserved (${arm1_dir:-none named}) — see $t/arm1.out"
  fi

  # ARM 2 — a finished window still tidies up after itself.
  arm2_rc=0
  PATH="$t/bin:$PATH" PDS_SOURCE_SSH="selftest@fake" PDS_SOURCE_SSH_KEY="$t/fake.key" \
    PDS_RUN_ID="selftest-arm2" bash "$target" --window 5 --label selftest-clean \
    >"$t/arm2.out" 2>&1 || arm2_rc=$?
  arm2_dir="$(sed -n 's/^ *work dir  *\([^ ]*\).*/\1/p' "$t/arm2.out" | head -1)"
  [ "$arm2_rc" = 0 ] || selftest_fail 2 "expected exit 0, got $arm2_rc — see $t/arm2.out"
  grep -q '^PDS_IDLE_SAMPLE ' "$t/arm2.out" \
    || selftest_fail 2 "no complete PDS_IDLE_SAMPLE line — see $t/arm2.out"
  if [ -z "$arm2_dir" ]; then
    selftest_fail 2 "the run never printed its work dir — see $t/arm2.out"
  elif [ -d "$arm2_dir" ]; then
    selftest_fail 2 "the work dir $arm2_dir SURVIVED a clean exit — cleanup stopped cleaning up"
  else
    say "  ARM 2 ok — exit 0, complete machine line, $arm2_dir removed"
  fi

  # ARM 3 — ARM 2's control: the dir exists unless something removes it.
  arm3_rc=0
  PATH="$t/bin:$PATH" PDS_SOURCE_SSH="selftest@fake" PDS_SOURCE_SSH_KEY="$t/fake.key" \
    PDS_RUN_ID="selftest-arm3" PDS_IDLE_KEEP_WORK_DIR=1 \
    bash "$target" --window 5 --label selftest-keep >"$t/arm3.out" 2>&1 || arm3_rc=$?
  arm3_dir="$(sed -n 's/^ *work dir  *\([^ ]*\).*/\1/p' "$t/arm3.out" | head -1)"
  [ "$arm3_rc" = 0 ] || selftest_fail 3 "expected exit 0, got $arm3_rc — see $t/arm3.out"
  if [ -n "$arm3_dir" ] && [ -s "$arm3_dir/idle-rss.log" ]; then
    say "  ARM 3 ok — exit 0, PDS_IDLE_KEEP_WORK_DIR=1 kept $arm3_dir with its series"
    rm -rf "$arm3_dir" 2>/dev/null || true
  else
    selftest_fail 3 "PDS_IDLE_KEEP_WORK_DIR=1 did not keep a populated work dir (${arm3_dir:-none named})"
  fi

  if [ "$SELFTEST_RC" = 0 ]; then
    say "SELFTEST PASS — 3 arms"
    rm -rf "$t" 2>/dev/null || true
  else
    say "SELFTEST FAIL — transcripts kept in $t"
  fi
  exit "$SELFTEST_RC"
}

# ── args ─────────────────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
  case "$1" in
    --window) IDLE_SECONDS="${2:-}"; shift 2 || die "--window needs a value" ;;
    --label)  LABEL="${2:-}"; shift 2 || die "--label needs a value" ;;
    --out)    OUT_FILE="${2:-}"; shift 2 || die "--out needs a value" ;;
    --selftest) RUN_SELFTEST=1; shift ;;
    # 1,231p — through the EXIT legend. The parent instrument stops at 80 and
    # drops its own exit codes; an operator whose sampler REFUSED mid-climb needs
    # to read "2 = refused" without opening the file.
    -h|--help) sed -n '1,231p' "$0"; exit 0 ;;
    *) die "unknown argument '$1' (try --help). This instrument takes no --path: it fetches nothing." ;;
  esac
done

if [ "${RUN_SELFTEST:-0}" = 1 ]; then
  run_selftest
fi

# The MISSING case is split out from the MALFORMED case on purpose: they are
# different operator errors and the missing one needs to say what it is refusing
# to guess. Refused here, before the first ssh, so a caller who forgot the flag
# learns it in under a second rather than after a window has already run.
if [ -z "$IDLE_SECONDS" ]; then
  die "--window is REQUIRED and has no default. This instrument used to default to 130 s, described as the canonical export's wall time — that figure was measured on the RETIRED in-memory export engine (wave 7), not on the streaming spill engine deployed since wave 11, whose full-export duration is UNMEASURED (open blocker: pds-bl-w13-export-duration-unmeasured). A window shorter than the acquisition it is paired with does not refuse; it closes early and reports a real-looking, too-LOW control. Rather than guess a replacement, this instrument makes you state the window and own the pairing claim. Until that blocker is paid: pass a generously large window and truncate at ANALYSIS time using idle_window_requested_s vs idle_window_s on the machine line."
fi

case "$IDLE_SECONDS" in
  *[!0-9]*) die "--window must be a whole number of seconds (got '$IDLE_SECONDS')" ;;
esac
[ "$IDLE_SECONDS" -ge 5 ] || die "--window must be at least 5 s to produce a usable control"

# ── ssh: read-only. The BEAM lives on the source box, not here. ──────────────

ssh_src() { # command string, run on the source box
  ssh -i "$SOURCE_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=20 \
    -o StrictHostKeyChecking=accept-new "$SOURCE_SSH" "$1" 2>/dev/null
}

ssh_available() {
  [ -n "$SOURCE_SSH" ] && [ -r "$SOURCE_SSH_KEY" ] && command -v ssh >/dev/null 2>&1 || return 1
  ssh -i "$SOURCE_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=accept-new "$SOURCE_SSH" true >/dev/null 2>&1
}

# ── the sampler, reproduced from the frozen harness ──────────────────────────
#
# `pgrep -x` (comm-anchored, NOT -f) enumerated fresh on EVERY tick, so a slot
# that appears or dies mid-window is still covered. One `ps -o rss=` per slot per
# tick, `sleep 1` between ticks. Each line is `<epoch> <pid> <rss_kb>` — strictly
# richer than the harness's bare rss column, and the peak arithmetic over it is
# identical (max of the rss field across every reading).
#
# SAMPLER_PID is set as a GLOBAL, never echoed from a command substitution.
# `PID="$(start_sampler …)"` runs the function in a SUBSHELL, so `$!` is that
# subshell's job — not a child of this shell. `wait` on it returns instantly (so
# a window collapses to 0 s and logs nothing) and `kill` on it hits a pid that
# already exited, LEAVING THE REMOTE ssh LOOP ALIVE ON THE SOURCE BOX. Both
# failures were observed on the paired-control instrument's first live run.
SAMPLER_PID=""
start_sampler() { # <ticks> <logfile> — sets SAMPLER_PID
  local ticks="$1" log="$2"
  : >"$log"
  ssh -i "$SOURCE_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=20 \
    -o StrictHostKeyChecking=accept-new "$SOURCE_SSH" \
    "for i in \$(seq 1 $ticks); do t=\$(date +%s); pgrep -x beam.smp | while read -r p; do r=\$(ps -o rss= -p \$p 2>/dev/null | tr -d ' '); [ -n \"\$r\" ] && printf '%s %s %s\\n' \"\$t\" \"\$p\" \"\$r\"; done; sleep 1; done" \
    >"$log" 2>/dev/null &
  SAMPLER_PID="$!"
}

# ── the MemAvailable sampler — the CONTROL'S OWN QUANTITY (PDS-D220b) ────────
#
# The RSS sampler above answers "how much did the BEAM grow?". PDS-D221's
# contamination-abort threshold (1048.16 MiB) is stated on the RANGE of
# /proc/meminfo MemAvailable — a WHOLE-BOX figure, not a per-process one.
# Attaching a BEAM-RSS delta to a MemAvailable threshold compares two different
# quantities and is the exact unit-class error PDS-D185 exists to correct.
#
# It runs as its OWN ssh loop rather than as extra lines inside the RSS loop,
# because the RSS log's `<epoch> <pid> <rss_kb>` shape is the frozen arithmetic's
# contract — a foreign line in that file would be read by peak_kb_of() as a
# colossal RSS reading and silently wreck the headline.
#
# This instrument only MAKES THE NUMBER EXIST. It does not abort on the
# threshold: applying 1048.16 MiB is the derivation slice's job.
start_memavail_sampler() { # <ticks> <logfile> — sets MEMAVAIL_SAMPLER_PID
  local ticks="$1" log="$2"
  : >"$log"
  ssh -i "$SOURCE_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=20 \
    -o StrictHostKeyChecking=accept-new "$SOURCE_SSH" \
    "for i in \$(seq 1 $ticks); do t=\$(date +%s); m=\$(awk '/^MemAvailable:/{print \$2}' /proc/meminfo); [ -n \"\$m\" ] && printf '%s %s\\n' \"\$t\" \"\$m\"; sleep 1; done" \
    >"$log" 2>/dev/null &
  MEMAVAIL_SAMPLER_PID="$!"
}
MEMAVAIL_SAMPLER_PID=""

peak_kb_of()    { awk '{ if ($3+0 > m) m = $3+0 } END { print m+0 }' "$1" 2>/dev/null || echo 0; }
# field 2 of the MemAvailable log. An EMPTY log yields 0/0 — reported alongside
# idle_memavail_samples=0 so a reader can see the range is vacuous rather than
# reading a suspiciously perfect zero as a rock-steady box.
min_f2_of()     { awk 'NF { v = $2+0; if (m == "" || v < m) m = v } END { print (m == "" ? 0 : m) }' "$1" 2>/dev/null || echo 0; }
max_f2_of()     { awk 'NF { v = $2+0; if (v > m) m = v } END { print m+0 }' "$1" 2>/dev/null || echo 0; }
# NOT `grep -c . || echo 0`: on an empty file grep PRINTS 0 and EXITS 1, so the
# fallback fires too and the count reads "0\n0". Observed on the first live run.
samples_in()    { awk 'NF { n++ } END { print n+0 }' "$1" 2>/dev/null || echo 0; }
mib()           { awk -v k="$1" 'BEGIN { printf "%.2f", k / 1024 }'; }   # kB/1024. NEVER /1000.

# one-shot `ps -o rss=` on ONE pid — the PDS-D185 t=0 reading
oneshot_rss_kb() { ssh_src "ps -o rss= -p ${1:-0}" | tr -d '[:space:]'; }

# one-shot max across EVERY comm-anchored slot — the disclosed diagnostic
oneshot_rss_set_kb() {
  ssh_src "pgrep -x beam.smp | while read -r p; do ps -o rss= -p \$p 2>/dev/null; done" \
    | awk '{ if ($1+0 > m) m = $1+0 } END { print m+0 }'
}

# ── preflight — OBSERVATION ONLY ─────────────────────────────────────────────
#
# No mutex is taken and no headroom floor is read. Both belong to an instrument
# that can FIRE an export; this one cannot, so serialising it against the climb
# would buy nothing and cost the ride-along (PDS-D237).

rule
say "PDS IDLE SAMPLER — PAIRED CONTROL ONLY, RIDES BESIDE A LIVE CLIMB (PDS-D237)"
rule
info "run id          $RUN_ID"
info "label           $LABEL"
info "work dir        $WORK_DIR"
info "                REMOVED on a clean exit (PDS_IDLE_KEEP_WORK_DIR=1 keeps it), PRESERVED if this"
info "                run is interrupted — the samples are this instrument's only product and an"
info "                early kill used to delete them before the arithmetic read them"
info "source          $SOURCE_BASE  (workspace $SOURCE_WS) — recorded for provenance; NOTHING is fetched"
info "acquisition     none. No HTTP request is issued and no token is read."
info "exclusion       none taken. This observes over ssh (pgrep/ps/awk) and allocates nothing on"
info "                the box, so there is no OOM risk for the export mutex to serialise. Safe to"
info "                run WHILE the frozen harness holds it — that is this file's whole reason."
info "sampler         ${SAMPLE_HZ} Hz \`ps -o rss=\` over SSH across ALL comm-anchored beam.smp slots"
info "                selector \`pgrep -o -x beam.smp\` for the primary; peak = MAX over the SET (PDS-D135)"
info "                a 1 Hz grid is a LOWER BOUND on the true peak (PDS-D114) — it understates drift"
say ""

ssh_available || refuse "SSH to $SOURCE_SSH is not available (key $SOURCE_SSH_KEY). The BEAM's RSS lives on the source box; there is no local proxy for it, and this instrument quotes nothing it did not sample. Per PDS-D237 this refusal must NOT stop a climb: fire without the control and say so."

DEPLOYED_SHA="$(ssh_src 'cd /opt/barkpark && git rev-parse HEAD' | tr -d '[:space:]' || true)"
[ -n "$DEPLOYED_SHA" ] || DEPLOYED_SHA="unresolved"

MEM_AVAIL_KB="$(ssh_src "awk '/MemAvailable/{print \$2}' /proc/meminfo" | tr -d '[:space:]' || true)"
MEM_AVAIL_KB="${MEM_AVAIL_KB:-0}"
MEM_AVAIL_MB=$((MEM_AVAIL_KB / 1024))

info "deployed sha    $DEPLOYED_SHA"
info "MemAvailable    ${MEM_AVAIL_KB} kB = ${MEM_AVAIL_MB} MiB at t=0 — CONTEXT ONLY. No floor is read and"
info "                none is enforced: a low box is a fact about the window, not a reason to refuse"
info "                to observe it. Refusing to sample a busy box loses exactly the data worth having."

BEAM_PRIMARY="$(ssh_src 'pgrep -o -x beam.smp' | tr -d '[:space:]' || true)"
BEAM_ALL="$(ssh_src "pgrep -x beam.smp | tr '\n' ' '" | tr -s '[:space:]' ' ' || true)"
BEAM_N="$(printf '%s' "$BEAM_ALL" | wc -w | tr -d ' ')"
[ -n "$BEAM_PRIMARY" ] || refuse "no process on the source has comm == beam.smp. Nothing is quoted rather than sampling whatever a looser argv match happened to return (PDS-D135)."

info "beam slots      ${BEAM_N} comm-anchored: [${BEAM_ALL% }] · primary (oldest, \`pgrep -o -x\`) = $BEAM_PRIMARY"
say ""

# ── THE WINDOW — ZERO REQUESTS ISSUED ────────────────────────────────────────

rule
say "IDLE CONTROL WINDOW (${IDLE_SECONDS} s, ${SAMPLE_HZ} Hz, ZERO requests issued)"
rule

IDLE_BASELINE_KB="$(oneshot_rss_kb "$BEAM_PRIMARY")"
IDLE_BASELINE_KB="${IDLE_BASELINE_KB:-0}"
IDLE_BASELINE_SET_KB="$(oneshot_rss_set_kb)"
info "t=0 baseline    ${IDLE_BASELINE_KB} kB — one-shot \`ps -o rss= -p $BEAM_PRIMARY\` taken BEFORE the window (PDS-D185)"
info "                (diagnostic: max across all ${BEAM_N} slots at t=0 = ${IDLE_BASELINE_SET_KB} kB)"

# PDS-BLIND-SPOT-METER: `date +%s`, WALL CLOCK around the sampling window in
# THIS shell. Placement is (a) of PDS-D633's law — an OS-level clock, outside
# every BEAM — and that is the ONLY placement available here, because the BEAM
# being sampled is on ANOTHER HOST at the far end of an ssh. The unit is
# deliberately wall, not CPU: the figure exists to say how long the window that
# produced the peak actually ran, so a reader can pair the two windows and see
# whether the control covers the measured one. It is NOT a price and no CPU
# claim descends from it (PDS-D605 forbids a wall-clock second standing in for
# one; wall swung 2.5x on an unchanged census where user CPU moved 9%). Nothing
# in this instrument is a regression ratchet; if one is ever built the unit is
# `Process.info(pid, :reductions)`, not seconds.
IDLE_T0="$(date +%s)"
start_sampler "$IDLE_SECONDS" "$IDLE_LOG"
IDLE_SAMPLER_PID="$SAMPLER_PID"
start_memavail_sampler "$IDLE_SECONDS" "$IDLE_MEM_LOG"
IDLE_MEM_SAMPLER_PID="$MEMAVAIL_SAMPLER_PID"
info "sampling        rss pid $IDLE_SAMPLER_PID · MemAvailable pid $IDLE_MEM_SAMPLER_PID · issuing NOTHING for ${IDLE_SECONDS} s"
wait "$IDLE_SAMPLER_PID" 2>/dev/null || true
IDLE_SAMPLER_PID=""
wait "$IDLE_MEM_SAMPLER_PID" 2>/dev/null || true
IDLE_MEM_SAMPLER_PID=""
IDLE_T1="$(date +%s)"

IDLE_PEAK_KB="$(peak_kb_of "$IDLE_LOG")"
IDLE_SAMPLES="$(samples_in "$IDLE_LOG")"
IDLE_WALL=$((IDLE_T1 - IDLE_T0))
IDLE_DELTA_KB=$((IDLE_PEAK_KB - IDLE_BASELINE_KB))

# PDS-D220b: the whole-box quantity PDS-D221's 1048.16 MiB threshold is stated
# on. Emitted, never enforced here — the derivation slice applies the threshold.
IDLE_MEMAVAIL_SAMPLES="$(samples_in "$IDLE_MEM_LOG")"
IDLE_MEMAVAIL_MIN_KB="$(min_f2_of "$IDLE_MEM_LOG")"
IDLE_MEMAVAIL_MAX_KB="$(max_f2_of "$IDLE_MEM_LOG")"
IDLE_MEMAVAIL_RANGE_KB=$((IDLE_MEMAVAIL_MAX_KB - IDLE_MEMAVAIL_MIN_KB))
IDLE_MEMAVAIL_RANGE_MIB="$(mib "$IDLE_MEMAVAIL_RANGE_KB")"

info "peak            ${IDLE_PEAK_KB} kB (MAX over ${IDLE_SAMPLES} readings across ${BEAM_N} slot(s), ${IDLE_WALL} s wall)"
pds_blind_spot_note \
  "date +%s, WALL CLOCK around the sampling window in this shell — an OS clock outside every BEAM (PDS-D633 placement (a)); the BEAM sampled is on another host over ssh, so no in-BEAM meter exists here. A WINDOW LENGTH, never a price (PDS-D605)" \
  "the idle control window length"

# ── PDS-D220a, BOTH LEGS ─────────────────────────────────────────────────────
#
# If the ssh sampler dies (dropped connection, remote loop killed) peak_kb_of()
# returns 0, the delta reads as a large NEGATIVE, and the run would otherwise
# EXIT 0 carrying a nonsense control. A control the reader cannot distinguish
# from a failed sampler is the thing the instrument was built to prevent. Refuse
# before any figure is printed.
if [ "$IDLE_SAMPLES" -le 0 ]; then
  refuse "the IDLE CONTROL window logged ZERO samples over its ${IDLE_WALL} s, so there is no peak to subtract a baseline from. An empty log peaks at 0 kB, so the drift would have been reported as 0 − ${IDLE_BASELINE_KB} = ${IDLE_DELTA_KB} kB = $(mib "$IDLE_DELTA_KB") MiB. A NEGATIVE control is not a control (PDS-D220a — the same defect as the acquisition window's, on the leg that gives the demand figure its meaning). The RSS sampler almost certainly lost its ssh session; re-run."
fi

# PDS-D220a KEYED ON THE QUANTITY, NOT ON A PROXY FOR IT (review, wave 13).
# The refusal above tests SAMPLE COUNT, but the wreck its own text describes is a
# VACUOUS PEAK. Those come apart: a log of well-formed-looking lines whose rss
# field is absent or zero (a session torn mid-write, a `ps` that returned nothing)
# counts as samples > 0 and still peaks at 0 kB. Reproduced in review — 1 sample,
# peak 0 kB, drift −191.63 MiB, EXIT 0. A zero peak is vacuous however many lines
# produced it, and no new threshold is invented to say so.
if [ "$IDLE_PEAK_KB" -le 0 ]; then
  refuse "the IDLE CONTROL window logged ${IDLE_SAMPLES} sample(s) but its PEAK is ${IDLE_PEAK_KB} kB, so the drift would have been reported as ${IDLE_PEAK_KB} − ${IDLE_BASELINE_KB} = ${IDLE_DELTA_KB} kB = $(mib "$IDLE_DELTA_KB") MiB. A NEGATIVE control is not a control (PDS-D220a). A non-empty log with a zero peak means the rss field never arrived — the remote loop's \`ps\` returned nothing, or the session tore mid-write. Re-run."
fi

# The MemAvailable leg refuses on the same rule, for a sharper reason. Its range
# is what PDS-D221's 1048.16 MiB contamination-abort threshold is stated on, and
# a leg that logged nothing yields min 0 / max 0 / range 0.00 MiB — which reads
# to a threshold check as the QUIETEST POSSIBLE BOX and passes. A vacuous zero
# must never be able to authorise a measurement, so the sample count is enforced
# here rather than merely emitted for a downstream reader to remember to check.
if [ "$IDLE_MEMAVAIL_SAMPLES" -le 0 ]; then
  refuse "the idle window's MemAvailable leg logged ZERO samples, so its range is vacuously 0 kB = 0.00 MiB. PDS-D221 states its contamination-abort threshold (1048.16 MiB) on THIS range, and an unsampled leg would clear that threshold as though the box were perfectly quiet (PDS-D220a/PDS-D220b). A range that was never measured must not authorise a measurement; re-run."
fi

# A negative drift that survives the vacuous-peak refusal is REPORTED, never
# refused. It is legitimately reachable on a healthy box: the baseline is a
# one-shot on the PRIMARY slot, the peak is the MAX ACROSS THE SET, and this box
# runs blue/green — so a primary that is retired mid-window leaves a successor
# whose RSS is honestly lower. GC on a quiet slot does the same, smaller. Refusing
# would invent a magnitude threshold this charter has not licensed (PDS-D232), and
# per PDS-D237 an instrument beside the climb must never fail loud on a fact about
# the box. So the reader is told the sign is suspect and why, and it rides the
# machine line so a downstream consumer cannot miss it.
IDLE_DRIFT_SIGN=ok
if [ "$IDLE_DELTA_KB" -lt 0 ]; then
  IDLE_DRIFT_SIGN=negative_suspect
fi

if [ "$IDLE_WALL" -gt 0 ]; then
  IDLE_RATE="$(awk -v d="$IDLE_DELTA_KB" -v s="$IDLE_WALL" 'BEGIN { printf "%.2f", (d / 1024) / s }')"
else
  IDLE_RATE="0.00"
fi

say ""

# ── verdict — reported, not judged ───────────────────────────────────────────

rule
say "RESULT — the idle control alone. Arithmetic stated, no threshold applied."
rule
say ""
say "  BEAM RSS DRIFT (per process — the frozen procedure's quantity)"
say "    baseline t=0 ......... ${IDLE_BASELINE_KB} kB   (one-shot ps, strictly pre-window — PDS-D185)"
say "    peak ................. ${IDLE_PEAK_KB} kB   (MAX across ${BEAM_N} slot(s), ${IDLE_SAMPLES} readings)"
say "    drift ................ ${IDLE_PEAK_KB} − ${IDLE_BASELINE_KB} = ${IDLE_DELTA_KB} kB / 1024 = $(mib "$IDLE_DELTA_KB") MiB"
say "    window ............... ${IDLE_WALL} s measured of ${IDLE_SECONDS} s requested, at ${SAMPLE_HZ} Hz · rate ${IDLE_RATE} MiB/s"
say "                           (a measured window SHORTER than the requested one means"
say "                            the sampler closed early; pair the two before quoting this)"
say "    diagnostic ........... max across all slots at t=0 = ${IDLE_BASELINE_SET_KB} kB"
if [ "$IDLE_DRIFT_SIGN" = negative_suspect ]; then
say "    SIGN ................. NEGATIVE. The baseline is a one-shot on the PRIMARY"
say "                           slot; the peak is the MAX ACROSS THE SET. On a"
say "                           blue/green box a primary retired mid-window leaves"
say "                           a successor with honestly lower RSS, and GC on a"
say "                           quiet slot does the same, smaller. Not refused —"
say "                           no magnitude threshold is licensed here (PDS-D232)."
say "                           Treat this control as SUSPECT, not as a drift of 0."
fi
say ""
say "  MemAvailable, WHOLE BOX (a DIFFERENT unit class — PDS-D220b)"
say "    min .................. ${IDLE_MEMAVAIL_MIN_KB} kB   over ${IDLE_MEMAVAIL_SAMPLES} readings"
say "    max .................. ${IDLE_MEMAVAIL_MAX_KB} kB"
say "    range ................ ${IDLE_MEMAVAIL_MAX_KB} − ${IDLE_MEMAVAIL_MIN_KB} = ${IDLE_MEMAVAIL_RANGE_KB} kB / 1024 = ${IDLE_MEMAVAIL_RANGE_MIB} MiB"
say ""
say "  HOW TO READ THIS"
say "    This is a CONTROL, not a demand. It says how much the box moves on its"
say "    own over ${IDLE_WALL} s with nothing asked of it. Place it BESIDE a measured"
say "    delta; never subtract it from one. A control that is a large fraction of"
say "    a measured delta means that measurement is drift-dominated."
say "    PDS-D221 states its 1048.16 MiB contamination-abort threshold on the"
say "    MemAvailable RANGE above — NOT on the BEAM-RSS drift, which is a"
say "    different unit class. This script does NOT apply that threshold: it"
say "    reports the range and leaves the ruling to the derivation slice."
say "    For scale: a live 60-tick run measured 1026.93 MiB of range — 98% of the"
say "    threshold. One clean range is not proof the contamination risk is gone."
say "    Both figures are kB/1024 (MiB), never /1000, and both are LOWER BOUNDS:"
say "    a spike between 1 Hz ticks is invisible (PDS-D114)."
say ""

MACHINE_LINE="PDS_IDLE_SAMPLE run_id=$RUN_ID label=$LABEL deployed_sha=$DEPLOYED_SHA source=$SOURCE_BASE workspace=$SOURCE_WS acquisition=none sample_hz=$SAMPLE_HZ units=kB_div_1024 selector=pgrep_-o_-x_beam.smp peak_rule=max_across_slots beam_primary_pid=$BEAM_PRIMARY beam_slot_pids=${BEAM_ALL% } beam_slots=$BEAM_N mem_available_t0_kb=$MEM_AVAIL_KB idle_baseline_kb=$IDLE_BASELINE_KB idle_baseline_set_kb=$IDLE_BASELINE_SET_KB idle_peak_kb=$IDLE_PEAK_KB idle_delta_kb=$IDLE_DELTA_KB idle_delta_mib=$(mib "$IDLE_DELTA_KB") idle_samples=$IDLE_SAMPLES idle_window_requested_s=$IDLE_SECONDS idle_window_s=$IDLE_WALL idle_drift_mib_per_s=$IDLE_RATE idle_drift_sign=$IDLE_DRIFT_SIGN idle_memavail_min_kb=$IDLE_MEMAVAIL_MIN_KB idle_memavail_max_kb=$IDLE_MEMAVAIL_MAX_KB idle_memavail_range_kb=$IDLE_MEMAVAIL_RANGE_KB idle_memavail_range_mib=$IDLE_MEMAVAIL_RANGE_MIB idle_memavail_samples=$IDLE_MEMAVAIL_SAMPLES threshold_applied=none"

say "$MACHINE_LINE"
say ""
if [ -n "$OUT_FILE" ]; then
  printf '%s\n' "$MACHINE_LINE" >"$OUT_FILE"
  info "machine line also written to $OUT_FILE"
fi

exit 0
