#!/usr/bin/env bash
#
# pds-window-sentinel.sh — POLL guerrilla for a measured clearing draw, and say
# out loud whether the crown climb may fire right now.
#
# WHY THIS EXISTS, AND WHAT IT IS NOT
# -----------------------------------
# This is NOT an armed post-deploy rig. That mechanism is REFUTED (PDS-D190 /
# PDS-D191): a live 24-sample probe across BEAM ELAPSED 20:15–22:11 cleared the
# 2235.43 MiB demand in ALL 24 samples, MemAvailable oscillates ~550 MB on a
# ~20 s timescale ANTI-correlated with BEAM RSS, 79.0% of 1001 `sar` samples
# over seven days clear, and firing on a deploy's own signal aborts the harness
# on precondition (d) in 4 of 4 measured deploys. A deploy is a memory TROUGH
# first (PDS-D93), so waiting for one trades a gate the box passes most of the
# time for two gates it is guaranteed to fail.
#
# What this IS: PDS-D92 check-and-go, instrumented. Poll on a cadence; fire on
# the FIRST draw that satisfies the predicate. A closed gate costs ZERO export
# attempts (`pds-pull-proof.sh:1360-1362` returns BEFORE the counter increments
# at `:1366-1368`), so polling is free and refusals are cheap.
#
# THINGS THIS SCRIPT WILL NEVER DO — these are load-bearing, not decoration:
#   * It never restarts, deploys, or writes ANYTHING on the remote box. Every
#     remote command is a read (`/proc`, `ps`, `git rev-parse`, `systemctl
#     is-active`, `systemctl list-units`). The runbook forbids manufacturing a
#     restart and forbids requesting or waiting for a deploy.
#   * It never sets, exports or lowers PDS_FULL_EXPORT_MIN_MEM_MB. The floor
#     moves in ONE direction, and not from here.
#   * It never invokes the export. Exit status 0 means "the draw is clear" —
#     the fire is a separate, deliberate, human-owned act.
#
# THE FIRE PREDICATE (PDS-D193, as amended by PDS-D717) — THREE legs must hold:
#   (i)   MemAvailable_MiB >= 2300      [kB / 1024, NEVER / 1000]
#   (iii) the `bp-site-build-*` running-unit listing is EMPTY
#   (iv)  exactly ONE of barkpark-slot@blue / @green reads active
#
# LEG (ii) — beam VmSwap <= 100000 kB — IS RETIRED, and the leg numbering keeps
# its hole on purpose so every transcript that cites "leg (iii)" still means the
# build leg. PDS-D717 (charter, on main) rules that VmSwap was never a sound
# proxy for export-time OOM risk: the DEPLOYED streaming spill engine's export
# demand is 98.16 MiB (the RSS peak-minus-baseline delta measured by the frozen
# harness's own 1 Hz sampler during wave 16's real 1.4 GB export, PDS-D276),
# while a VmSwap ceiling gates how much of the BEAM's OWN address space is paged
# out — a residency fact about the resident process, which does not bound a
# ~98 MiB allocation by a DIFFERENT consumer. Measured: leg (ii) cleared 1 of
# 661 draws across two independent instruments (1/61 wave-10, 0/600 PDS-D229),
# and the crown fired and PASSED with no swap leg at all (run 5abf6afd, 11 PASS
# / 0 ABORT / 0 FAIL). VmSwap is still SAMPLED and still written to every TSV
# row — recorded, never gated, the same posture PDS-D246 set for BEAM warmth.
#
# Leg (iii) is new in wave 10 and it is the one leg (i) cannot see: a running
# site build depressed MemAvailable by 379 MiB and 496 MiB in two independent
# 90 s steps while VmSwap stayed FLAT and BEAM RSS actually FELL. A predicate
# built only on the BEAM's own numbers is blind to it — and PDS-D227 later
# measured the build channel as the dominant term (floor cleared 99.19% of
# build-idle draws against 9.3% build-busy), which is why leg (iii) survives
# the retirement of leg (ii) rather than falling with it.
#
# EVERY sample is appended to the TSV log — fire or stand-down. A predicate
# that has never refused is not a predicate; the refusals ARE the dataset.
#
# USAGE
#   scripts/pds-window-sentinel.sh sample                 # one draw, exit 0=FIRE
#   scripts/pds-window-sentinel.sh watch --max-samples 40 --interval 30
#   scripts/pds-window-sentinel.sh preflight [--pull]     # PDS-D192 legs
#
# EXIT STATUS
#   0  a draw satisfied the predicate (or preflight is clean) — GO
#   1  no draw satisfied it within the sample budget — STAND DOWN (reportable)
#   2  the probe itself failed (ssh/parse) — measured nothing, claim nothing
#
set -uo pipefail

# ── knobs ────────────────────────────────────────────────────────────────────
SSH_HOST="${PDS_SENTINEL_HOST:-root@guerrilla.barkpark.cloud}"
SSH_KEY="${PDS_SENTINEL_SSH_KEY:-$HOME/.ssh/barkpark_indx}"
LOG="${PDS_SENTINEL_LOG:-/private/tmp/pds-window-sentinel.tsv}"
INTERVAL="${PDS_SENTINEL_INTERVAL:-30}"
MAX_SAMPLES="${PDS_SENTINEL_MAX_SAMPLES:-1}"

# The one numeric leg. It may be TIGHTENED, never loosened — the script refuses
# to run against a softened predicate rather than quietly measuring a weaker
# claim than the one the transcript will make. PDS_SENTINEL_SWAP_CEIL_KB is GONE
# with leg (ii) (PDS-D717); it is not read, and setting it does nothing.
MEM_FLOOR_MIB="${PDS_SENTINEL_MEM_FLOOR_MIB:-2300}"
MEM_FLOOR_LAW=2300

FREEZE_BLOB="${PDS_FREEZE_BLOB:-e219e97ccf7f33797c86a2b84d998d599b6bda31}"
HARNESS_PATH="scripts/pds-pull-proof.sh"

say()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
rule() { printf -- '─%.0s' $(seq 1 76); printf '\n'; }

die() { printf 'sentinel: %s\n' "$*" >&2; exit 2; }

# ── the guard on the guard ───────────────────────────────────────────────────
# A sentinel whose own floor can be dialled down is a rubber stamp with extra
# steps. Loosening the floor is a hard stop, not a warning.
#
# The floor is validated as an integer FIRST. `[ abc -lt 2300 ]` is a bash error
# that evaluates FALSE, so a non-numeric floor would slip past the comparison
# below and then silently disable leg (i) at the comparison in take_sample —
# the exact bypass this function exists to prevent. Same for the cadence knobs:
# a non-numeric --max-samples makes `[ 1 -le abc ]` error, the watch loop never
# executes, and the run reports a STAND-DOWN it never measured.
check_predicate_integrity() {
  is_int "$MEM_FLOOR_MIB" || die "PDS_SENTINEL_MEM_FLOOR_MIB='$MEM_FLOOR_MIB' is not an integer. The predicate is not evaluable."
  is_int "$INTERVAL"      || die "--interval / PDS_SENTINEL_INTERVAL='$INTERVAL' is not an integer."
  is_int "$MAX_SAMPLES"   || die "--max-samples / PDS_SENTINEL_MAX_SAMPLES='$MAX_SAMPLES' is not an integer."
  [ "$MAX_SAMPLES" -ge 1 ] || die "--max-samples must be >= 1; '$MAX_SAMPLES' would report a stand-down with zero draws taken."
  if [ "$MEM_FLOOR_MIB" -lt "$MEM_FLOOR_LAW" ]; then
    die "refusing to run: PDS_SENTINEL_MEM_FLOOR_MIB=$MEM_FLOOR_MIB is BELOW the D193 floor of $MEM_FLOOR_LAW MiB. The predicate tightens only."
  fi
}

# ── one sample = exactly ONE ssh round-trip ──────────────────────────────────
# Everything the predicate needs, plus the context a transcript reader will
# want (SwapFree, ELAPSED, served sha), comes back from a single connection.
# Sampling must not itself perturb what it measures.
remote_probe() {
  ssh -i "$SSH_KEY" \
      -o BatchMode=yes \
      -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new \
      "$SSH_HOST" 'bash -s' <<'REMOTE'
set -u
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mem=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
swf=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)

# PDS-D135: `pgrep -o -x beam.smp`, NEVER `pgrep -f`. The -f form matches any
# process whose full cmdline merely CONTAINS the literal and can select a
# foreign low-pid process, which produced a captured ~342x RSS under-read.
# -x anchors on the exact process name; -o takes the oldest, i.e. the live VM.
pid=$(pgrep -o -x beam.smp 2>/dev/null || true)
rss=""; vsw=""; el=""
if [ -n "${pid:-}" ] && [ -r "/proc/$pid/status" ]; then
  rss=$(awk '/^VmRSS:/{print $2}'  "/proc/$pid/status")
  vsw=$(awk '/^VmSwap:/{print $2}' "/proc/$pid/status")
  el=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
fi

sha=$(git -C /opt/barkpark rev-parse HEAD 2>/dev/null || echo unresolved)

# Leg (iii). Comma-joined unit names, or empty. An empty listing is the pass.
builds=$(systemctl list-units 'bp-site-build-*' --state=running --no-legend --plain 2>/dev/null \
         | awk 'NF {print $1}' | paste -sd, - )
blue=$(systemctl  is-active barkpark-slot@blue  2>/dev/null || true)
green=$(systemctl is-active barkpark-slot@green 2>/dev/null || true)

printf 'ts=%s\n'          "$ts"
printf 'mem_kb=%s\n'      "${mem:-}"
printf 'swapfree_kb=%s\n' "${swf:-}"
printf 'beam_pid=%s\n'    "${pid:-}"
printf 'rss_kb=%s\n'      "${rss:-}"
printf 'vmswap_kb=%s\n'   "${vsw:-}"
printf 'elapsed=%s\n'     "${el:-}"
printf 'served_sha=%s\n'  "${sha:-unresolved}"
printf 'builds=%s\n'      "${builds:-}"
printf 'slot_blue=%s\n'   "${blue:-unknown}"
printf 'slot_green=%s\n'  "${green:-unknown}"
REMOTE
}

is_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

ensure_log() {
  local dir
  dir="$(dirname "$LOG")"
  [ -d "$dir" ] || mkdir -p "$dir" || die "cannot create log directory $dir"
  if [ ! -s "$LOG" ]; then
    printf 'ts_utc\tverdict\tmem_mib\tmem_kb\tswapfree_kb\tbeam_pid\trss_kb\tvmswap_kb\telapsed\tserved_sha\tsite_builds\tslot_blue\tslot_green\tfailing_legs\n' >"$LOG"
  fi
}

# Evaluates the four legs, logs the row, prints the verdict.
# Returns 0 on FIRE, 1 on STAND-DOWN, 2 if the probe measured nothing.
take_sample() { # $1 = sample index (for display only)
  local idx="$1" raw line key val
  local ts="" mem_kb="" swapfree_kb="" beam_pid="" rss_kb="" vmswap_kb=""
  local elapsed="" served_sha="" builds="" slot_blue="" slot_green=""

  raw="$(remote_probe 2>&1)"
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'sentinel: probe #%s FAILED (ssh rc=%s) — measured nothing, claiming nothing:\n%s\n' \
      "$idx" "$rc" "$raw" >&2
    return 2
  fi

  # No eval: a remote value is untrusted input, and this loop keeps it inert.
  while IFS= read -r line; do
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      ts)          ts="$val" ;;
      mem_kb)      mem_kb="$val" ;;
      swapfree_kb) swapfree_kb="$val" ;;
      beam_pid)    beam_pid="$val" ;;
      rss_kb)      rss_kb="$val" ;;
      vmswap_kb)   vmswap_kb="$val" ;;
      elapsed)     elapsed="$val" ;;
      served_sha)  served_sha="$val" ;;
      builds)      builds="$val" ;;
      slot_blue)   slot_blue="$val" ;;
      slot_green)  slot_green="$val" ;;
      *)           : ;;
    esac
  done <<<"$raw"

  if ! is_int "$mem_kb"; then
    printf 'sentinel: probe #%s returned no readable MemAvailable — measured nothing:\n%s\n' "$idx" "$raw" >&2
    return 2
  fi

  # PDS-D193: MiB is kB/1024. NEVER kB/1000 — that inflates the reading by 2.4%
  # and would let a draw ~56 MiB short of the floor read as clear.
  local mem_mib=$(( mem_kb / 1024 ))

  local legs="" pass=1

  # (i) headroom
  if [ "$mem_mib" -lt "$MEM_FLOOR_MIB" ]; then
    pass=0; legs="${legs}i:mem(${mem_mib}<${MEM_FLOOR_MIB}MiB) "
  fi

  # (ii) RETIRED by PDS-D717. beam VmSwap is still sampled and still written to
  # the TSV — the refusals are the dataset — but it no longer gates. It was
  # never a sound proxy for export-time OOM risk, and it cleared 1 of 661 draws.
  # Do NOT re-add it here without overturning D717 in the charter first.

  # (iii) no site build running — the invisible depressor
  if [ -n "$builds" ]; then
    pass=0; legs="${legs}iii:site-build(${builds}) "
  fi

  # (iv) exactly one slot active
  local active=0
  [ "$slot_blue"  = "active" ] && active=$(( active + 1 ))
  [ "$slot_green" = "active" ] && active=$(( active + 1 ))
  if [ "$active" -ne 1 ]; then
    pass=0; legs="${legs}iv:slots(blue=${slot_blue},green=${slot_green}) "
  fi

  local verdict="STAND-DOWN"
  [ "$pass" -eq 1 ] && verdict="FIRE"
  [ -n "$legs" ] || legs="-"

  ensure_log
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "$verdict" "$mem_mib" "$mem_kb" "${swapfree_kb:--}" "${beam_pid:--}" \
    "${rss_kb:--}" "${vmswap_kb:--}" "${elapsed:--}" "$served_sha" \
    "${builds:--}" "$slot_blue" "$slot_green" "${legs% }" >>"$LOG"

  printf '#%-3s %s  %-10s mem=%s MiB  swapfree=%s kB  beam=%s rss=%s kB vmswap=%s kB elapsed=%s  sha=%s  builds=%s  slots=%s/%s\n' \
    "$idx" "$ts" "$verdict" "$mem_mib" "${swapfree_kb:--}" "${beam_pid:--}" \
    "${rss_kb:--}" "${vmswap_kb:--}" "${elapsed:--}" "${served_sha:0:9}" \
    "${builds:-none}" "$slot_blue" "$slot_green"
  [ "$verdict" = "FIRE" ] || printf '     failing legs: %s\n' "${legs% }"

  [ "$pass" -eq 1 ] && return 0
  return 1
}

cmd_sample() {
  check_predicate_integrity
  take_sample 1
}

cmd_watch() {
  check_predicate_integrity
  local i=1 rc probe_fails=0
  say "sentinel: polling $SSH_HOST every ${INTERVAL}s, up to ${MAX_SAMPLES} sample(s)"
  say "sentinel: predicate — mem >= ${MEM_FLOOR_MIB} MiB · no bp-site-build-* running · exactly one active slot"
  say "sentinel: vmswap is RECORDED, never gated (PDS-D717 retired leg (ii))"
  say "sentinel: log -> $LOG"
  rule
  while [ "$i" -le "$MAX_SAMPLES" ]; do
    take_sample "$i"; rc=$?
    if [ "$rc" -eq 0 ]; then
      rule
      say "sentinel: CLEARING DRAW on sample #$i — the predicate is satisfied. GO."
      return 0
    fi
    # Probe failures are tolerated but never silently: three consecutive dead
    # probes means the instrument is broken, and a broken instrument must not
    # keep producing rows that look like refusals.
    if [ "$rc" -eq 2 ]; then
      probe_fails=$(( probe_fails + 1 ))
      if [ "$probe_fails" -ge 3 ]; then
        rule
        say "sentinel: 3 consecutive probe failures — the instrument is down, not the window. Aborting."
        return 2
      fi
    else
      probe_fails=0
    fi
    i=$(( i + 1 ))
    [ "$i" -le "$MAX_SAMPLES" ] && sleep "$INTERVAL"
  done
  rule
  say "sentinel: NO clearing draw in $MAX_SAMPLES sample(s). Stand down — this is a REPORTABLE OUTCOME, not a failure."
  say "sentinel: the dataset behind that statement is $LOG"
  return 1
}

# ── PDS-D192 preflight ───────────────────────────────────────────────────────
# Three legs, all free, all live blockers. They are checked in the SAME shell
# that will fire, seconds before it fires: this checkout is shared and volatile
# and HEAD has moved under a running verifier mid-session.
cmd_preflight() {
  local do_pull=0
  [ "${1:-}" = "--pull" ] && do_pull=1
  local rc=0

  say "PDS-D192 PREFLIGHT"
  rule

  # (a) the worktree must not be behind origin/main. Step 0b of the harness
  # hard-fails when the served sha is not an ancestor of the worktree — and
  # fail() only increments a counter, so a run fired in that state BURNS the
  # export, greens rungs 3/4 and STILL exits RESULT: FAIL. The crown cannot be
  # stamped off that.
  git fetch origin --quiet || { info "(a) FAILED — git fetch origin errored"; return 1; }
  if [ "$do_pull" -eq 1 ]; then
    if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
      git pull --rebase || { info "(a) FAILED — git pull --rebase errored"; return 1; }
    else
      info "(a) NOTE — this branch has no upstream (worktree branch); falling back to an ancestry check against origin/main"
    fi
  fi
  local behind
  behind="$(git rev-list --count HEAD..origin/main)"
  if [ "$behind" -ne 0 ]; then
    info "(a) FAILED — HEAD is $behind commit(s) behind origin/main. Step 0b will hard-fail."
    rc=1
  else
    info "(a) OK — HEAD is 0 commits behind origin/main"
  fi

  # (b) the instrument is FROZEN. PDS-D154: verify the GIT BLOB with
  # `git rev-parse`, never `shasum` — the two disagree, and the blob OID is
  # the value the freeze was recorded as.
  local blob
  blob="$(git rev-parse "HEAD:$HARNESS_PATH" 2>/dev/null || echo unresolved)"
  if [ "$blob" = "$FREEZE_BLOB" ]; then
    info "(b) OK — $HARNESS_PATH blob $blob == freeze"
  else
    info "(b) FAILED — $HARNESS_PATH blob $blob != freeze $FREEZE_BLOB"
    rc=1
  fi

  # (c) the live served sha must be an ancestor of HEAD, checked NOW.
  local live
  live="$(ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new "$SSH_HOST" \
            'git -C /opt/barkpark rev-parse HEAD' 2>/dev/null || echo '')"
  if [ -z "$live" ]; then
    info "(c) FAILED — could not read the live served sha over ssh"
    rc=1
  elif git merge-base --is-ancestor "$live" HEAD 2>/dev/null; then
    info "(c) OK — live served sha $live is an ancestor of HEAD ($(git rev-parse HEAD))"
  else
    info "(c) FAILED — live served sha $live is NOT an ancestor of HEAD"
    rc=1
  fi

  rule
  if [ "$rc" -eq 0 ]; then
    say "PREFLIGHT CLEAN — all three legs hold."
  else
    say "PREFLIGHT BLOCKED — do not fire. A run fired in this state burns the export and still exits FAIL."
  fi
  return "$rc"
}

usage() {
  sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  local cmd="${1:-sample}" pull_flag=""
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval)     INTERVAL="${2:?--interval needs a value}"; shift 2 ;;
      --max-samples)  MAX_SAMPLES="${2:?--max-samples needs a value}"; shift 2 ;;
      --log)          LOG="${2:?--log needs a value}"; shift 2 ;;
      --pull)         pull_flag="--pull"; shift ;;
      -h|--help)      usage; exit 0 ;;
      *)              die "unknown option: $1" ;;
    esac
  done
  case "$cmd" in
    sample)    cmd_sample ;;
    watch)     cmd_watch ;;
    preflight) cmd_preflight "$pull_flag" ;;
    -h|--help|help) usage ;;
    *)         die "unknown command: $cmd (want: sample | watch | preflight)" ;;
  esac
}

main "$@"
