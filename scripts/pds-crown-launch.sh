#!/usr/bin/env bash
#
# pds-crown-launch.sh — ARM THE CROWN CLIMB AND WALK AWAY.
#
#   scripts/pds-crown-launch.sh arm [--force] [--prewarm-now] [--max-draws N]
#   scripts/pds-crown-launch.sh collect [<run-tag>|--transcript P --pid-file F]
#   scripts/pds-crown-launch.sh selftest
#
# WHY THIS EXISTS
# ---------------
# Four waves (10, 11, 12, 13) failed to fire the crown climb. Wave 13 finally
# named the mechanism, and it is NOT instrument-recession: the builder's turn was
# cut short by the harness while the poll window was still open ("draw 3 of 30").
# THE WALL IS THE TURN. Every previous rig polled INSIDE the agent's own turn, so
# the rig died with the turn and the climb never fired.
#
# This script removes that wall by moving the poll loop INSIDE a detached child
# that outlives the turn which armed it. `arm` launches and RETURNS; a LATER
# actor runs `collect` to find out what happened.
#
# IT MEASURES NOTHING. It is plumbing, not an eighth instrument. The only remote
# reads here belong to the generated child's per-draw RECORDING, and they are a
# verbatim subset of what pds-window-sentinel.sh already samples. No new metric,
# no new floor, no new predicate is introduced by this file.
#
# THE FLOOR IT ARMS, AND TWO NON-ACTIONS — load-bearing, not decoration:
#   * It arms the DERIVED floor of 897 MiB (PDS-D276/D277), against the DEPLOYED
#     streaming spill engine, in all three floor knobs at once: the poll
#     predicate (:348), the arm-refusal guard (:412-414), and
#     PDS_FULL_EXPORT_MIN_MEM_MB exported to the harness (fire_detached). The old
#     2200 was a FOSSIL of the retired in-RAM engine; the streaming engine's real
#     BEAM RSS peak-minus-baseline demand is 98.16 MiB, and 98.16 + 798.81 margin
#     rounds up to 897 (D244's earlier refusal, with its NEGATIVE -7.55 MiB
#     delta, was derived against that retired engine and no longer applies). It
#     never LOWERS the floor below that derived law — the predicate tightens
#     only. Full arithmetic: scripts/pds-w20-floor-derivation.md.
#   * It never splits the climb. `--all`, unsplit, once. `--only` runs touching
#     rungs 2-6 are FORBIDDEN (W6-C).
#   * It never writes to the real attempts counter or the real export lock. It
#     READS the counter to compute a budget; that is all.
#
# ── DETACH FORM (PDS-D243) — FIXED BY EXECUTION, DO NOT SUBSTITUTE ───────────
#
#   * `setsid(1)` DOES NOT EXIST on this host (`which setsid` -> exit 1). Any
#     recipe built on it fires NOTHING and says so nowhere.
#   * `nohup CMD & disown` survives a turn ending and survives `kill -HUP
#     -<pgid>` — but DIES to `kill -TERM -<pgid>`, because the child keeps the
#     LAUNCHER's pgid and never becomes a session leader. Measured, side by side:
#         FORM_A nohup  4507: KILLED by killpg
#         FORM_B python 4516: SURVIVED
#     That is why `nohup` is never INVOKED in this file. The word survives only
#     in this rationale and in two diagnostics; selftest §8 asserts that no line
#     ever runs it, which is the claim that actually matters.
#   * The ONLY immune form is python3 os.fork() + os.setsid() + os.execvp(). The
#     child gets its OWN pgid and its OWN session (STAT `Ss`, ppid=1).
#
#   Two spellings inside that form are themselves load-bearing:
#     - ANSI-C `$'...'` quoting with REAL newlines. A literal `\n` inside a
#       double-quoted shell string stays a backslash-n; the whole program is then
#       a SyntaxError that launches nothing and leaves an EMPTY log — precisely
#       the silent-failure class this wave exists to kill.
#     - `os.closerange(3, 64)`. Without it the child inherits the harness's pipe
#       write-end, the reader never sees EOF, and the launching tool call appears
#       to HANG — defeating "returns immediately" even when detachment is
#       otherwise perfect. `pds-scratch-target.sh` TRAP 5 documents the same
#       hazard in-repo (a 9-minute hang ended only by SIGTERM).
#
# ── BUDGET (PDS-D249) — ONE SHELL, NEVER SPLIT ──────────────────────────────
#
# `FULL_BUDGET="${PDS_FULL_EXPORT_BUDGET:-1}"` (pds-pull-proof.sh:130) resolves
# ONCE at process start, and a child inherits its environment at fork/exec ONLY.
# Export in one tool call and launch in a later one and the child reads 1 — the
# silent default — then fails hours later with nothing visible at launch time.
# So read + compute + export + exec happen in ONE function, contiguously:
# see fire_detached() below, which is the only place this file forks.
#
# ── RUN_TAG (PDS-D233) ──────────────────────────────────────────────────────
#
# RUN_TAG is the only per-rung anchor the harness produces. Wave 9 pinned a
# literal path and the anchor went from 7 occurrences to 0. So PDS_RUN_ID is
# seeded here, RUN_TAG is derived with the SAME recipe as pds-pull-proof.sh:112,
# and it is embedded in all THREE exported path vars: BARKPARK_HOME,
# PDS_SCRATCH_POINTER, PDS_PROOF_ARTIFACTS. (NOT ART_DIR — that one is
# script-local and unexported inside the harness, and is SEEDED from
# PDS_PROOF_ARTIFACTS.)
#
# ── WHERE THE PRE-WARM RUNS, AND WHY IT MOVED (PDS-D241) ────────────────────
#
# D241 requires `cd api && CC=/usr/bin/clang MIX_ENV=prod mix compile` to be paid
# BEFORE the timed window opens (measured 155.72 s cold-prod on a real host). The
# `CC` override is LOAD-BEARING: bare `cc` resolves to the Claude CLI wrapper and
# argon2_elixir then FAILS to build ("unknown option '-g'") rather than merely
# running slow.
#
# That compile is paid by the CHILD, as its first act, before the first draw is
# taken. This is deliberate: paying it inside `arm` would blow the one constraint
# this whole slice exists to satisfy — that arming returns fast enough to survive
# an agent turn — while paying it in the child still satisfies D241, because the
# window does not open until polling begins. `--prewarm-now` forces the old
# synchronous behaviour for an operator who is watching and does not care how
# long arming takes. A failed pre-warm aborts the child WITHOUT firing.
#
# ── ARMED IS A READ-BACK, NOT A FORK RETURN (PDS-D317) ──────────────────────
#
# `arm` used to print ARMED on the strength of `is_int "$pid"` — proof that the
# FORK PARENT printed digits, nothing more. execvp ENOENT, a child-side syntax
# error, an instant `set -e` abort and an OOM kill all produced digits and all
# printed ARMED. So the claim is now backed by a post-condition READ of the
# state it claims to have produced: assert_child_up() settles, reads a marker
# THE CHILD ITSELF WROTE into the transcript, and then classifies.
#
# A bare liveness poke at t+0 would be a mirror-image lie: armed with a payload
# that is literally `exit 0`, one measured run returned rc=0 (LIVE) while
# classify microseconds later already said KILLED, and three re-runs returned
# rc=1. Hence SETTLE-then-CLASSIFY, never poke-and-tick.
#
# And the banner claims exactly what was read: "child is UP as of <t>" —
# necessary, not sufficient. It never claims the climb finishes.
#
# ── EXIT STATUS ─────────────────────────────────────────────────────────────
#   arm       0 armed (child proven up, or liveness UNPERFORMABLE and said so)
#             4 the child is NOT up (the named state is printed)
#             3 refused/usage/environment
#   collect   0 FINISHED or FINISHED-nosent · 2 STILL-RUNNING · 1 anything else
#   selftest  0 every check held · 1 a check failed
#
# bash 3.2 compatible (macOS system bash).

set -euo pipefail

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -P -- "$SCRIPT_DIR/.." && pwd)"
API_DIR="$REPO_ROOT/api"
HARNESS="${PDS_LAUNCH_HARNESS:-$SCRIPT_DIR/pds-pull-proof.sh}"

# THE BLIND-SPOT SENTENCE, BY REFERENCE (PDS-D633) — `$PDS_BLIND_SPOT` and
# `pds_blind_spot_note`. Sourced, never retyped; scripts/pds-blind-spot-check.sh
# reds if a copy drifts. Fail-closed: an instrument that cannot find the sentence
# it is obliged to print beside a duration must refuse, not print the duration.
# shellcheck source=scripts/pds-blind-spot.sh
. "$SCRIPT_DIR/pds-blind-spot.sh"

STATE_DIR="${PDS_LAUNCH_STATE_DIR:-/tmp/pds-crown-launch}"

# The full-export bookkeeping the harness owns. We READ the counter and we READ
# the lock. We never write either. PDS_FULL_EXPORT_DIR is honoured so selftest
# can point the whole mechanism at a scratch directory.
FULL_DIR="${PDS_FULL_EXPORT_DIR:-/tmp/pds-full-export}"
FULL_ATTEMPTS_FILE="$FULL_DIR/attempts"
FULL_LOCK="$FULL_DIR/lock"

# Poll cadence. The floor may be TIGHTENED, never loosened — a launcher whose
# floor can be dialled down is a rubber stamp with extra steps.
INTERVAL="${PDS_LAUNCH_INTERVAL:-10}"
MAX_DRAWS="${PDS_LAUNCH_MAX_DRAWS:-360}"
# PDS-D276/D277: the DERIVED floor is 897 MiB, against the deployed streaming
# spill engine (98.16 demand + 798.81 margin). Both the poll-predicate default
# and the tighten-only guard-law move off the fossil 2200 together — moving one
# without the other leaves the predicate defaulting to 2200 and the child
# standing down forever. scripts/pds-w20-floor-derivation.md.
MEM_FLOOR_MIB="${PDS_LAUNCH_MEM_FLOOR_MIB:-897}"
MEM_FLOOR_LAW=897

# How long `arm` settles before it reads the child's own transcript marker
# (PDS-D317). It is a DEADLINE, not a sleep: the loop breaks the moment the
# marker lands, so a healthy child costs ~1s. Raise it on a loaded host; the
# check never gets weaker, only more patient.
ARM_SETTLE_S="${PDS_LAUNCH_ARM_SETTLE_S:-5}"

SSH_HOST="${PDS_LAUNCH_SSH_HOST:-root@guerrilla.barkpark.cloud}"
SSH_KEY="${PDS_LAUNCH_SSH_KEY:-$HOME/.ssh/barkpark_indx}"

say()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
rule() { printf -- '─%.0s' $(seq 1 76); printf '\n'; }
die()  { printf '%s: %s\n' "$SELF" "$*" >&2; exit 3; }

is_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# ── liveness (PDS-D135) ──────────────────────────────────────────────────────
#
# `ps -p`, NEVER `pgrep`. Wave 13 burned exactly this: pgrep printed two PIDs
# that `ps -p` proved were not live.
#
# And NEVER validate this predicate against an out-of-range pid: `ps -p 999999`
# fails ARGUMENT VALIDATION ("process id too large") rather than taking the
# not-found path — it looks like it proves the predicate while proving nothing.
# A pid outside the range is UNUSABLE, not dead, and pid_live says so by
# returning 2 rather than lying in either direction.
#
# WHERE THAT RANGE IS *NOT*: `kern.maxproc` is 4000 on this host and it is NOT a
# pid ceiling — it caps how many processes may exist AT ONCE, while pids keep
# climbing to PID_MAX and wrap. Bounding on it rejects the majority of LIVE pids
# (this selftest armed pid 87056 and a maxproc-bounded guard called it "unusable"
# and therefore KILLED, one line after `ps` had printed it alive). Measured here:
# `ps -p 99999` takes the clean not-found path, `ps -p 100000` says "too large".
#
# So the answer is DERIVED FROM ps ITSELF rather than from a guessed constant —
# the only bound that cannot drift out of step with the tool it is guarding.
#
# returns 0 = live · 1 = not live · 2 = pid unusable (liveness UNPROVEN)
pid_live() { # $1 = pid
  local pid="${1:-}" err rc
  is_int "$pid" || return 2
  [ "$pid" -ge 1 ] || return 2
  err="$(ps -p "$pid" 2>&1 >/dev/null)"
  rc=$?
  case "$err" in
    *'too large'*|*'process id'*) return 2 ;;
  esac
  [ "$rc" -eq 0 ] && return 0
  return 1
}

# ── identity (pds-bl-pid-live-identity-blind) ────────────────────────────────
#
# A pid number is a temporary slot. On this host the pid space was OBSERVED
# wrapping inside ~20 minutes, and collect's cadence is deliberately "hours
# later" — so `ps -p` alone can vouch for an unrelated process that inherited
# the recorded number. The fingerprint is comm + lstart: start time is fixed at
# fork, so the pair changes whenever the slot is reused. Captured at arm by
# write_run_meta, verified by pid_live_ours before anything says STILL-RUNNING.
#
# Whitespace is squeezed to single spaces because `ps` pads columns and both
# the capture and the comparison must normalise identically.
pid_fingerprint() { # $1 = pid  -> prints "comm lstart", empty if unevaluable
  ps -p "${1:-}" -o comm=,lstart= 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//' || true
}

# Identity-aware liveness. Same contract as pid_live, plus one more state:
#
#   returns 0 = live AND it is the process the meta recorded (or no fingerprint
#               was recorded — pre-fix run dirs degrade to plain pid_live)
#           1 = not live
#           2 = pid unusable (liveness UNPROVEN)
#           3 = the pid is LIVE but the identity DIFFERS — the slot was RECYCLED
#               by an unrelated process; the armed child is gone
#
# On every live path it leaves what it saw in PID_IDENT_RECORDED and
# PID_IDENT_SEEN so the caller can print EXACTLY what was compared — a mismatch
# must never be acted on without showing both strings.
PID_IDENT_RECORDED=""
PID_IDENT_SEEN=""
# Like pid_live, callers wrap this in set +e — nonzero returns are its grammar.
pid_live_ours() { # $1 = pid · $2 = meta file (may be absent)
  local pid="${1:-}" meta="${2:-}" rc
  PID_IDENT_RECORDED=""
  PID_IDENT_SEEN=""
  pid_live "$pid"
  rc=$?
  if [ "$rc" -ne 0 ]; then return "$rc"; fi
  if [ -n "$meta" ] && [ -f "$meta" ]; then
    PID_IDENT_RECORDED="$(grep '^pid_fingerprint=' "$meta" 2>/dev/null | head -1 | cut -d= -f2- || true)"
  fi
  PID_IDENT_SEEN="$(pid_fingerprint "$pid")"
  if [ -z "$PID_IDENT_RECORDED" ]; then return 0; fi
  if [ "$PID_IDENT_SEEN" = "$PID_IDENT_RECORDED" ]; then return 0; fi
  return 3
}

# ── THE FORK (PDS-D243 + PDS-D249) ───────────────────────────────────────────
#
# The ONE place this file detaches, and the ONE place the budget is resolved.
# Read, compute, export and exec are CONTIGUOUS on purpose: a child inherits env
# at fork/exec only, so any split between them silently hands the child the
# default budget of 1.
#
# $1 run_tag · $2 attempts_file · $3 log · $4 payload · $5 pid_file
fire_detached() {
  local run_tag="$1" attempts_file="$2" log="$3" payload="$4" pid_file="$5"
  local spent

  # ── D249: one shell, contiguous, no tool-call boundary anywhere in here ──
  spent="$(cat "$attempts_file" 2>/dev/null || echo 0)"
  is_int "$spent" || spent=0
  export PDS_FULL_EXPORT_BUDGET=$(( spent + 2 ))                    # PDS-D224
  # PDS-D276/D277: export the DERIVED 897 MiB floor to the frozen harness's own
  # cond_b (b) gate. This REVERSES D244's deliberate UNSET — that refusal was
  # taken against the retired in-RAM engine's NEGATIVE -7.55 MiB delta; the
  # deployed streaming engine's real demand is 98.16 MiB + 798.81 margin = 897.
  # It is set HERE, contiguous with the budget, so it crosses the fork/exec into
  # the child with everything else (D249) — a later export would silently hand
  # the child the harness default and revert the floor with nothing visible.
  export PDS_FULL_EXPORT_MIN_MEM_MB=897
  # The harness re-derives its OWN RUN_TAG as cksum(PDS_RUN_ID) (:112), but only
  # to build DEFAULT paths — and all three of those are overridden just below, so
  # that derivation reaches nothing. What PDS_RUN_ID DOES reach is the banner
  # (:485), SUMMARY (:2448) and sentinel_id (:2162). Seeding it with the run_tag
  # therefore makes the transcript print the SAME token that names this run's
  # state dir and its three paths — one string to cross-reference, instead of a
  # timestamp that appears nowhere else.
  export PDS_RUN_ID="$run_tag"
  export BARKPARK_HOME="/tmp/pds-w14.$run_tag"                      # PDS-D233
  export PDS_SCRATCH_POINTER="/tmp/pds-scratch.pds-w14.$run_tag.last"
  export PDS_PROOF_ARTIFACTS="/tmp/pds-proof-art.pds-w14.$run_tag"
  python3 -c $'import os,sys\nlog,payload=sys.argv[1],sys.argv[2]\npid=os.fork()\nif pid==0:\n os.setsid()\n f=os.open(log,os.O_WRONLY|os.O_CREAT|os.O_APPEND,0o644)\n d=os.open("/dev/null",os.O_RDONLY)\n os.dup2(d,0);os.dup2(f,1);os.dup2(f,2)\n os.closerange(3,64)\n os.execvp("/bin/bash",["bash","-lc",payload])\nelse:\n print(pid)' "$log" "$payload" > "$pid_file" \
    || die "the detach program itself failed to run. NOTHING was armed. This is the SyntaxError/ENOENT signature — read $log and the python error above it."
  # ── end D249 block ──────────────────────────────────────────────────────
}

# RUN_TAG derivation — the SAME recipe as pds-pull-proof.sh:112, verbatim.
derive_run_tag() { # $1 = run id
  printf '%s' "$1" | cksum | awk '{printf "%x", $1}'
}

# ── the generated child ──────────────────────────────────────────────────────
#
# Written to disk rather than inlined so the armed payload is READABLE after the
# turn that armed it is gone. The config header is injected with printf %q; the
# body is a QUOTED heredoc, so nothing in it expands at write time.
write_child_script() { # $1 = dest · $2 = run_tag
  local dest="$1" run_tag="$2"
  {
    printf '#!/usr/bin/env bash\n#\n'
    printf '# GENERATED by %s arm — do not edit, re-arm instead.\n' "$SELF"
    printf '# run_tag=%s armed_at=%s\n#\n' "$run_tag" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'RUN_TAG=%q\n'        "$run_tag"
    printf 'HARNESS=%q\n'        "$HARNESS"
    printf 'API_DIR=%q\n'        "$API_DIR"
    printf 'INTERVAL=%q\n'       "$INTERVAL"
    printf 'MAX_DRAWS=%q\n'      "$MAX_DRAWS"
    printf 'MEM_FLOOR_MIB=%q\n'  "$MEM_FLOOR_MIB"
    printf 'SSH_HOST=%q\n'       "$SSH_HOST"
    printf 'SSH_KEY=%q\n'        "$SSH_KEY"
    printf 'DO_PREWARM=%q\n'     "${DO_PREWARM:-1}"
  } > "$dest"

  cat >> "$dest" <<'CHILD_BODY'

# NOT `set -e`: a failed draw probe must cost one draw, never the whole climb.
set -uo pipefail

stamp() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# PDS-D247: the LAST line is always the sentinel. A transcript without it is
# either still running or was killed, and `collect` must be able to tell the
# difference between those and a mid-rung abort.
sentinel() { printf 'EXIT: %s\n' "$1"; }

stamp "child up — pid=$$ pgid=$(ps -o pgid= -p $$ | tr -d ' ') sid_leader=$(ps -o stat= -p $$ | tr -d ' ')"
stamp "run_tag=$RUN_TAG"
stamp "budget PDS_FULL_EXPORT_BUDGET=${PDS_FULL_EXPORT_BUDGET:-<UNSET — the child did not inherit it>}"
stamp "poll   MEM_FLOOR_MIB=$MEM_FLOOR_MIB (the launcher's poll predicate — PDS-D276/D277 derived floor)"
stamp "floor  PDS_FULL_EXPORT_MIN_MEM_MB=${PDS_FULL_EXPORT_MIN_MEM_MB:-<UNSET — expected 897 per PDS-D276/D277; UNSET here means the export did NOT cross the fork>}"
stamp "home   BARKPARK_HOME=${BARKPARK_HOME:-<unset>}"
stamp "point  PDS_SCRATCH_POINTER=${PDS_SCRATCH_POINTER:-<unset>}"
stamp "art    PDS_PROOF_ARTIFACTS=${PDS_PROOF_ARTIFACTS:-<unset>}"

# ── PRE-WARM (PDS-D241) ──────────────────────────────────────────────────────
# CC=/usr/bin/clang is LOAD-BEARING: bare `cc` is the Claude CLI wrapper and
# argon2_elixir FAILS to build under it ("unknown option '-g'"). This is paid
# HERE, before the first draw, so the timed window never pays a cold compile.
if [ "$DO_PREWARM" = "1" ]; then
  stamp "prewarm: cd $API_DIR && CC=/usr/bin/clang MIX_ENV=prod mix compile"
  if ( cd "$API_DIR" && CC=/usr/bin/clang MIX_ENV=prod mix compile ); then
    stamp "prewarm: OK — the window will not pay a cold compile"
  else
    rc=$?
    stamp "prewarm: FAILED rc=$rc — NOT firing. A climb that pays 155 s of compile"
    stamp "         inside its own window is a measurement of the compile."
    sentinel "$rc"
    exit "$rc"
  fi
elif [ "$DO_PREWARM" = "0" ]; then
  stamp "prewarm: already paid synchronously in the arming shell (--prewarm-now)"
else
  stamp "prewarm: SKIPPED by --no-prewarm. If api/_build/prod is not already warm,"
  stamp "         the window below pays the compile and measures it (PDS-D241)."
fi

# ── the draw probe — ONE ssh round trip, every value a READ ──────────────────
# Nothing here writes on the remote box. This is the same read set
# pds-window-sentinel.sh already takes; no new instrument is introduced.
probe() {
  ssh -i "$SSH_KEY" \
      -o BatchMode=yes \
      -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new \
      "$SSH_HOST" 'bash -s' <<'REMOTE'
set -u
mem=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
# PDS-D135: `pgrep -o -x beam.smp`, NEVER `pgrep -f` — the -f form can select a
# foreign low-pid process and produced a captured ~342x RSS under-read.
pid=$(pgrep -o -x beam.smp 2>/dev/null || true)
rss=""; el=""
if [ -n "${pid:-}" ] && [ -r "/proc/$pid/status" ]; then
  rss=$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status")
  el=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
fi
builds=$(systemctl list-units 'bp-site-build-*' --state=running --no-legend --plain 2>/dev/null \
         | awk 'NF {print $1}' | paste -sd, - )
printf 'mem_kb=%s\n' "${mem:-}"
printf 'rss_kb=%s\n' "${rss:-}"
printf 'elapsed=%s\n' "${el:-}"
printf 'builds=%s\n' "${builds:-}"
REMOTE
}

draw=0
fired=0
while [ "$draw" -lt "$MAX_DRAWS" ]; do
  draw=$((draw + 1))

  raw="$(probe 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'DRAW\t%s\t%s\tverdict=PROBE-FAILED\trc=%s\n' \
      "$draw" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc"
    printf '%s\n' "$raw" | sed 's/^/      /'
    sleep "$INTERVAL"
    continue
  fi

  mem_kb=""; rss_kb=""; elapsed=""; builds=""
  while IFS= read -r line; do
    case "${line%%=*}" in
      mem_kb)  mem_kb="${line#*=}" ;;
      rss_kb)  rss_kb="${line#*=}" ;;
      elapsed) elapsed="${line#*=}" ;;
      builds)  builds="${line#*=}" ;;
      *)       : ;;
    esac
  done <<<"$raw"

  case "${mem_kb:-}" in
    ''|*[!0-9]*)
      printf 'DRAW\t%s\t%s\tverdict=UNPARSEABLE\tmem_kb=%s\n' \
        "$draw" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${mem_kb:-}"
      sleep "$INTERVAL"
      continue
      ;;
  esac

  mem_mib=$(( mem_kb / 1024 ))            # kB / 1024, NEVER / 1000

  # ── THE PREDICATE — TWO LEGS, AND ONLY TWO (PDS-D246) ─────────────────────
  # rss_kb and slot uptime are RECORDED on every draw and GATE ON NOTHING.
  # Idle MemAvailable is a near-deterministic function of beam RSS (r = -0.986),
  # so a long-running poller structurally PREFERS post-restart transients — the
  # exact draws D93/D190/D191 forbid. But D193's four-leg predicate went 0/61 by
  # ANDing one more condition, so warmth is recorded for the reviewer's ruling,
  # NOT wired into the gate.
  legs=""
  [ "$mem_mib" -ge "$MEM_FLOOR_MIB" ] || legs="$legs mem<floor"
  [ -z "$builds" ] || legs="$legs site-builds-running"

  if [ -z "$legs" ]; then verdict=FIRE; else verdict="STAND-DOWN:${legs# }"; fi

  printf 'DRAW\t%s\t%s\tmem_mib=%s\tfloor=%s\tbuilds=%s\trecorded_rss_kb=%s\trecorded_slot_uptime=%s\tverdict=%s\n' \
    "$draw" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$mem_mib" "$MEM_FLOOR_MIB" \
    "${builds:-<empty>}" "${rss_kb:-?}" "${elapsed:-?}" "$verdict"

  if [ "$verdict" = "FIRE" ]; then
    fired=1
    stamp "FIRE — draw $draw of $MAX_DRAWS qualified."
    stamp "  gated on: mem_mib=$mem_mib >= $MEM_FLOOR_MIB AND bp-site-build-* listing EMPTY"
    stamp "  recorded, NOT gated (PDS-D246): beam rss_kb=${rss_kb:-?} slot_uptime=${elapsed:-?}"
    stamp "  firing ONE unsplit --all (W6-C: --only across rungs 2-6 is forbidden)"
    "$HARNESS" --all
    rc=$?
    stamp "harness returned rc=$rc after $draw draw(s)"
    sentinel "$rc"
    exit "$rc"
  fi

  sleep "$INTERVAL"
done

if [ "$fired" -eq 0 ]; then
  stamp "STAND-DOWN — $MAX_DRAWS draws taken, none qualified. The climb NEVER FIRED;"
  stamp "  every draw above is a refusal, and the refusals are the dataset."
  stamp "  A closed gate costs ZERO export attempts, so re-arming is free."
  sentinel 5
  exit 5
fi
CHILD_BODY
  chmod +x "$dest"
}

# ── the floor record (PDS-D276/D277) ─────────────────────────────────────────
#
# ONE producer for the two floor knobs this arm carries, emitted as key=value
# lines. run_dir/meta, the arm banner, and the selftest ALL read this — so the
# recording can never silently drift from what is actually armed, and a revert
# of ANY of the three knobs moves one of these two numbers. This is what closes
# pds-bl-w16-arm-never-records-its-own-floor: the arm now records its own floor,
# and pds-bl-floor-env-silent-revert: a reverted PDS_FULL_EXPORT_MIN_MEM_MB
# prints <UNSET> here instead of vanishing unremarked.
#
#   mem_floor_mib           — the launcher's own poll predicate (:348)
#   full_export_min_mem_mb  — what fire_detached exported to the harness gate
arm_floor_record() {
  printf 'mem_floor_mib=%s\n'          "$MEM_FLOOR_MIB"
  printf 'full_export_min_mem_mb=%s\n' "${PDS_FULL_EXPORT_MIN_MEM_MB:-<UNSET>}"
}

# The human-facing rendering of the same two values for the arm banner.
arm_floor_summary() {
  info "poll floor  mem_floor_mib=$MEM_FLOOR_MIB — the launcher's poll predicate (:348)"
  info "harness flr full_export_min_mem_mb=${PDS_FULL_EXPORT_MIN_MEM_MB:-<UNSET>} — exported to the frozen harness's cond_b gate"
  if [ "$MEM_FLOOR_MIB" != 2200 ] || [ "${PDS_FULL_EXPORT_MIN_MEM_MB:-}" != 2200 ]; then
    info "            DERIVED floor (PDS-D276/D277) — the fossil 2200 of the retired in-RAM engine no longer applies; see scripts/pds-w20-floor-derivation.md"
  fi
}

# run_dir/meta writer, extracted so the selftest can exercise the SAME code the
# arm uses and prove — hermetically — that meta carries the derived floor.
# $1 run_dir · $2 run_tag · $3 run_id · $4 pid · $5 transcript
write_run_meta() {
  {
    printf 'run_tag=%s\n'    "$2"
    printf 'run_id=%s\n'     "$3"
    printf 'pid=%s\n'        "$4"
    printf 'armed_at=%s\n'   "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'budget=%s\n'     "${PDS_FULL_EXPORT_BUDGET:-}"
    arm_floor_record
    # comm+lstart of the child at arm time — the identity pid_live_ours checks
    # before anyone calls the recorded pid STILL-RUNNING. Empty when the child
    # died before this read; verification then degrades to plain pid_live.
    printf 'pid_fingerprint=%s\n' "$(pid_fingerprint "$4")"
    printf 'transcript=%s\n' "$5"
  } > "$1/meta"
}

# ── arm ──────────────────────────────────────────────────────────────────────

cmd_arm() {
  local force=0 run_id run_tag run_dir log pid_file child payload pid t0 t1
  local child_state arc read_at prc
  DO_PREWARM=1

  while [ $# -gt 0 ]; do
    case "$1" in
      --force)       force=1 ;;
      --prewarm-now) DO_PREWARM=0 ;;
      # For a tree whose api/_build/prod is ALREADY warm, and for proving `arm`
      # itself against a dummy harness. Skipping it on a cold tree makes the
      # window pay a 155 s compile, which is why it is opt-in and never default.
      --no-prewarm)  DO_PREWARM=2 ;;
      # `shift` with nothing left returns 1, and under `set -e` that exits the
      # script with status 1 and NO message — a silent misfire in the exact
      # class this wave exists to kill. Demand the value before consuming it so
      # a malformed arm REFUSES OUT LOUD on the documented exit 3.
      --max-draws)   [ $# -ge 2 ] || die "--max-draws needs a value."; shift; MAX_DRAWS="$1" ;;
      --interval)    [ $# -ge 2 ] || die "--interval needs a value."; shift; INTERVAL="$1" ;;
      *)             die "arm: unknown argument '$1'" ;;
    esac
    shift
  done

  is_int "$MAX_DRAWS" || die "--max-draws must be an integer; '$MAX_DRAWS' would poll zero times and report a stand-down it never measured."
  is_int "$INTERVAL"  || die "--interval must be an integer; '$INTERVAL' is not evaluable."
  [ "$MAX_DRAWS" -ge 1 ] || die "--max-draws must be >= 1."
  is_int "$MEM_FLOOR_MIB" || die "PDS_LAUNCH_MEM_FLOOR_MIB='$MEM_FLOOR_MIB' is not an integer. The predicate is not evaluable."
  if [ "$MEM_FLOOR_MIB" -lt "$MEM_FLOOR_LAW" ]; then
    die "refusing to arm: PDS_LAUNCH_MEM_FLOOR_MIB=$MEM_FLOOR_MIB is BELOW the $MEM_FLOOR_LAW MiB floor. The predicate tightens only."
  fi

  [ -x "$HARNESS" ] || die "harness not executable at $HARNESS — nothing to arm."
  [ -d "$API_DIR" ] || die "api/ not found at $API_DIR — the pre-warm would fail inside the child."
  command -v python3 >/dev/null 2>&1 || die "python3 not found — and it is the ONLY detach form that survives (PDS-D243: setsid(1) does not exist here, nohup dies to killpg)."

  # Refuse to stack two live climbs on one box. Two concurrent full exports
  # would OOM the LIVE content API on a 3.8 GB host — the one thing PDS-D31
  # forbids outright.
  if [ "$force" -eq 0 ] && [ -f "$STATE_DIR/last" ]; then
    local prev prev_pid
    prev="$(cat "$STATE_DIR/last")"
    prev_pid="$(cat "$STATE_DIR/$prev/child.pid" 2>/dev/null || echo '')"
    set +e
    pid_live_ours "$prev_pid" "$STATE_DIR/$prev/meta"
    prc=$?
    set -e
    if [ "$prc" -eq 0 ]; then
      die "run $prev is STILL-RUNNING (pid $prev_pid). Two concurrent full exports would OOM the live box. Use \`collect\` first, or --force if you know that pid is not a climb."
    elif [ "$prc" -eq 3 ]; then
      # The number is alive but the process is not ours — the previous climb is
      # dead and its pid slot was reused. Refusing here would be the self-lock
      # this task exists to remove; say exactly what was compared and proceed.
      say "previous run $prev: pid $prev_pid is ALIVE but it is NOT the armed child — the pid was RECYCLED."
      info "recorded at arm: $PID_IDENT_RECORDED"
      info "seen now:        $PID_IDENT_SEEN"
      say "the previous climb is dead; arming proceeds. Do NOT kill pid $prev_pid — it is an unrelated process."
    fi
  fi

  # PDS-BLIND-SPOT-METER: `date +%s`, WALL CLOCK, around the arming sequence in
  # THIS shell. Placement is (a) of PDS-D633's law — an OS-level clock outside
  # every BEAM — but the UNIT is deliberately not a price: `armed in Ns` is a
  # LATENCY the operator is owed (did arming return promptly, or did it hang?),
  # never a CPU cost, and PDS-D605 forbids a wall-clock second standing in for
  # one. Wall swung 2.5x on an unchanged census where user CPU moved 9%, so this
  # figure grades the HOST as much as the code. A CPU price for this instrument
  # comes from `pds-door-census.sh --measure`, never from here; a regression
  # ratchet would need `Process.info(pid, :reductions)`, which a shell has not
  # got at all.
  t0="$(date +%s)"
  run_id="${PDS_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
  run_tag="$(derive_run_tag "$run_id")"
  run_dir="$STATE_DIR/$run_tag"
  mkdir -p "$run_dir"
  log="$run_dir/transcript.log"
  pid_file="$run_dir/child.pid"
  child="$run_dir/child.sh"

  if [ "$DO_PREWARM" -eq 0 ]; then
    say "pre-warming synchronously (--prewarm-now); arming will take as long as this compile."
    ( cd "$API_DIR" && CC=/usr/bin/clang MIX_ENV=prod mix compile ) \
      || die "pre-warm FAILED — refusing to arm a climb that would pay a cold compile inside its own window."
  fi

  write_child_script "$child" "$run_tag"
  payload="exec /bin/bash $(printf '%q' "$child")"

  fire_detached "$run_tag" "$FULL_ATTEMPTS_FILE" "$log" "$payload" "$pid_file"

  pid="$(cat "$pid_file" 2>/dev/null | tr -d ' \n')"
  is_int "$pid" || die "the fork did not report a pid (pid file holds '${pid:-}'). The child did NOT launch; check $log."
  printf '%s\n' "$pid" > "$pid_file"
  printf '%s\n' "$run_tag" > "$STATE_DIR/last"

  # meta records BOTH floor knobs distinctly (mem_floor_mib AND
  # full_export_min_mem_mb) via arm_floor_record, so a revert of either is
  # individually diagnosable from the run directory (PDS-D276/D277).
  write_run_meta "$run_dir" "$run_tag" "$run_id" "$pid" "$log"

  # ── the read-back behind the word ARMED (PDS-D317) ──────────────────────
  # `is_int "$pid"` above proves the FORK PARENT printed digits. It does not
  # prove a child exists. Settle, then read a marker the CHILD wrote, then
  # classify — and print whatever that read actually says.
  say "settling ${ARM_SETTLE_S}s, then reading the child's own transcript before claiming anything…"
  set +e
  child_state="$(assert_child_up "$log" "$pid_file" "$ARM_SETTLE_S")"
  arc=$?
  set -e
  read_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [ "$arc" -eq 1 ]; then
    rule
    say "NOT ARMED — the fork returned a pid, but the read-back says $child_state."
    rule
    info "run_tag     $run_tag"
    info "pid         $pid"
    info "transcript  $log"
    info "child       $child"
    info "read at     $read_at (after a ${ARM_SETTLE_S}s settle)"
    case "$child_state" in
      DEAD)          info "meaning     the child is gone and wrote no sentinel — the execvp-ENOENT / instant-abort / OOM-kill shape." ;;
      NO-MARKER)     info "meaning     a process is alive but never stamped 'child up' — the fork exec'd something that is not this climb." ;;
      CRASHED)       info "meaning     the child wrote a sentinel and stopped inside the settle window. Read the transcript." ;;
      EXITED-EARLY)  info "meaning     the child already finished inside ${ARM_SETTLE_S}s. A climb cannot; something else ran." ;;
      NO-TRANSCRIPT) info "meaning     the fork never created $log at all." ;;
    esac
    say "Nothing is polling. Read the transcript, fix the cause, arm again."
    rule
    exit 4
  fi

  t1="$(date +%s)"

  rule
  if [ "$arc" -eq 2 ]; then
    # pid_live rc=2 — `ps` refuses to evaluate this pid, so liveness is UNPROVEN
    # in BOTH directions. Saying "armed" bare here would be the same lie with a
    # different cause, so the caveat rides in the same breath as the claim.
    say "ARMED — but LIVENESS UNPERFORMABLE: pid $pid is outside the range ps evaluates."
    say "  Nothing here proves the child is up, and nothing here proves it is dead."
    say "  Read the outcome with \`collect\` before trusting this run."
  else
    say "ARMED — child is UP as of $read_at (it stamped its own arrival and is still running)."
    say "  That is NECESSARY, NOT SUFFICIENT: it is one read at one instant, not a"
    say "  promise about how the climb ends. Only \`collect\` answers that."
  fi
  rule
  info "run_tag     $run_tag"
  info "pid         $pid"
  info "transcript  $log"
  info "child       $child"
  info "budget      PDS_FULL_EXPORT_BUDGET=${PDS_FULL_EXPORT_BUDGET:-?} (attempts spent + 2)"
  arm_floor_summary
  info "poll        every ${INTERVAL}s, up to $MAX_DRAWS draws, inside the child"
  info "armed in    $(( t1 - t0 ))s"
  pds_blind_spot_note \
    "date +%s, WALL CLOCK around the arming sequence in this shell — an OS clock outside every BEAM (PDS-D633 placement (a)), and a LATENCY, not a price: PDS-D605 forbids a wall-clock second standing in for CPU" \
    "armed in"
  rule
  say "DO NOT POLL FROM HERE. This turn is done; the child is not."
  say "A later actor reads the outcome with:"
  say "    $0 collect $run_tag"
  rule
}

# ── collect ──────────────────────────────────────────────────────────────────
#
# SIX states (PDS-D247). Three is not enough: the harness runs under `set -euo
# pipefail` (:85) and emits `RESULT:` only from summary() (:2462-2487), so a
# mid-rung abort dies with NO `RESULT:` line — under a three-state grammar
# indistinguishable from an OOM-kill, and those are DIFFERENT diagnoses. A
# SIGKILLed transcript was proven BYTE-IDENTICAL to a still-running one, so
# content alone can NEVER separate those two; only the pid can.
#
# `grep -c` EXITS 1 on zero matches, so every grep here carries `|| true`.
classify() { # $1 = transcript · $2 = pid file  -> prints the state token
  local t="${1:-}" p="${2:-}" sent res pid rc

  [ -f "$t" ] || { printf 'NO-TRANSCRIPT\n'; return 0; }

  sent="$(grep -c '^EXIT: ' "$t" 2>/dev/null || true)"
  res="$(grep -c '^RESULT:' "$t" 2>/dev/null || true)"
  is_int "$sent" || sent=0
  is_int "$res"  || res=0

  if [ "$sent" -gt 0 ] && [ "$res" -gt 0 ]; then printf 'FINISHED\n';        return 0; fi
  if [ "$sent" -gt 0 ];                     then printf 'CRASHED\n';         return 0; fi
  if [ "$res"  -gt 0 ];                     then printf 'FINISHED-nosent\n'; return 0; fi

  pid="$(cat "$p" 2>/dev/null | tr -d ' \n' || true)"
  set +e
  pid_live_ours "$pid" "${p:+$(dirname "$p")/meta}"
  rc=$?
  set -e
  case "$rc" in
    0) printf 'STILL-RUNNING\n' ;;
    1) printf 'KILLED\n' ;;
    3) printf 'KILLED\n' ;;   # pid RECYCLED — the armed child is dead; collect names it
    *) printf 'KILLED\n' ;;   # pid unusable — caller prints the caveat
  esac
  return 0
}

# ── the arm-time read-back (PDS-D317) ────────────────────────────────────────
#
# THE POST-CONDITION READ BEHIND THE WORD "ARMED". Prints ONE state token and
# returns:
#
#   UP            0  the child wrote its own arrival stamp AND is still running
#   NO-MARKER     1  the pid is alive but the child never stamped — the fork
#                    exec'd something, but nothing that identifies as the climb
#   DEAD          1  no marker, no sentinel, pid gone — the instant-death shape
#   CRASHED       1  the child got far enough to write a sentinel and stopped
#   EXITED-EARLY  1  the child already FINISHED inside the settle window — a
#                    climb cannot; something else ran
#   NO-TRANSCRIPT 1  the fork never even created the log
#   UNPERFORMABLE 2  the pid is outside the range `ps` will evaluate, so
#                    liveness is UNPROVEN in either direction (pid_live rc=2 —
#                    kept DISTINCT from death, never collapsed into it)
#
# It is a FUNCTION, not four inline lines in cmd_arm, for one reason: the
# selftest reaches fire_detached directly and never runs cmd_arm, so anything
# inlined there ships untested by the harness that actually exists.
#
# THE SETTLE IS LOAD-BEARING. See the header: a t+0 poke is a measured coin
# flip. The marker is the child's FIRST act (write_child_script's `stamp "child
# up …"`), so waiting for it is waiting for the child to prove itself rather
# than for a clock to elapse.
#
# $1 transcript · $2 pid file · $3 settle seconds (default ARM_SETTLE_S)
assert_child_up() {
  local t="${1:-}" p="${2:-}" settle="${3:-$ARM_SETTLE_S}"
  local pid rc i marker state
  is_int "$settle" || settle=5

  pid="$(cat "$p" 2>/dev/null | tr -d ' \n' || true)"
  set +e
  pid_live "$pid"
  rc=$?
  set -e
  if [ "$rc" -eq 2 ]; then printf 'UNPERFORMABLE\n'; return 2; fi

  marker=0
  i=0
  while [ "$i" -lt "$settle" ]; do
    if [ -f "$t" ] && grep -qF 'child up' "$t" 2>/dev/null; then marker=1; break; fi
    sleep 1
    i=$(( i + 1 ))
  done

  state="$(classify "$t" "$p")"
  case "$state" in
    STILL-RUNNING)
      if [ "$marker" -eq 1 ]; then printf 'UP\n'; return 0; fi
      printf 'NO-MARKER\n'; return 1 ;;
    NO-TRANSCRIPT)          printf 'NO-TRANSCRIPT\n'; return 1 ;;
    KILLED)                 printf 'DEAD\n';          return 1 ;;
    CRASHED)                printf 'CRASHED\n';       return 1 ;;
    *)                      printf 'EXITED-EARLY\n';  return 1 ;;
  esac
}

cmd_collect() {
  local tag="" t="" p="" state pid rc lines sd_stamp fire_stamp pw_stamp

  while [ $# -gt 0 ]; do
    case "$1" in
      --transcript) [ $# -ge 2 ] || die "--transcript needs a path."; shift; t="$1" ;;
      --pid-file)   [ $# -ge 2 ] || die "--pid-file needs a path."; shift; p="$1" ;;
      -*)           die "collect: unknown argument '$1'" ;;
      *)            tag="$1" ;;
    esac
    shift
  done

  if [ -z "$t" ]; then
    if [ -z "$tag" ]; then
      [ -f "$STATE_DIR/last" ] || die "no run recorded in $STATE_DIR — nothing has been armed on this host."
      tag="$(cat "$STATE_DIR/last")"
    fi
    t="$STATE_DIR/$tag/transcript.log"
    p="$STATE_DIR/$tag/child.pid"
  fi

  state="$(classify "$t" "$p")"
  pid="$(cat "$p" 2>/dev/null | tr -d ' \n' || true)"

  rule
  say "STATE: $state"
  rule
  info "transcript  $t"
  info "pid file    ${p:-<none>}    pid=${pid:-<none>}"
  [ -n "$tag" ] && info "run_tag     $tag"

  if [ -f "$t" ]; then
    lines="$(wc -l < "$t" | tr -d ' ')"
    info "lines       $lines"
    info "draws       $(grep -c '^DRAW' "$t" 2>/dev/null || true)"
  fi

  case "$state" in
    NO-TRANSCRIPT)
      info "The launcher itself failed — the child never opened its log."
      info "This is the empty-log signature of a SyntaxError in the detach"
      info "program (a literal backslash-n instead of a real newline)."
      ;;
    CRASHED)
      # A poll loop that exhausted its draws WITHOUT firing also lands here: it
      # appends the sentinel and never reaches the harness, so it has no RESULT.
      # That is a materially different diagnosis from a mid-rung abort, and the
      # grammar is fixed at six states (PDS-D247) — so rather than invent a
      # seventh, say which of the two this is, by name.
      #
      # PDS-D252: the discriminator MUST be anchored. The child prints
      # `verdict=STAND-DOWN:mem<floor` on EVERY refused DRAW line (:352), so a
      # bare `grep -c 'STAND-DOWN'` reads non-zero on a transcript that refused
      # once and then FIRED — i.e. it called a genuine mid-rung abort a free
      # stand-down and invited the reader to re-arm. Per D250 the floor clears
      # ~0 times in 862 build-idle draws, so a draw-1 fire is the improbable
      # case and that misread was the DEFAULT for a real crash.
      #
      # Only the terminal stamp (:373) is anchored `[<ts>] STAND-DOWN — `, and
      # it is printed ONLY on the never-fired path. The FIRE stamp (:358) is
      # its mutually-exclusive twin.
      #
      # REVIEW (PDS-D252, second leg): "not a stand-down" is NOT the same claim
      # as "an attempt was spent", and collapsing them re-commits D252's error
      # with the polarity flipped. The child writes the sentinel from THREE
      # places, not two: FIRE (:365), STAND-DOWN (:376), and a PRE-WARM FAILURE
      # (:264) that exits before the first draw. A prewarm abort therefore
      # carries NEITHER stamp — and it costs ZERO export attempts, exactly like
      # a stand-down. Asserting "re-arming is NOT free" there would make the
      # lead hoard a budget they still hold, on the D241 failure mode the
      # pre-warm exists to catch. So each claim is made only where its own
      # stamp proves it, and an unrecognised transcript is called UNDIAGNOSED
      # rather than assigned a cost that was never measured.
      sd_stamp="$(grep -cE '^\[[^]]+\] STAND-DOWN — ' "$t" 2>/dev/null || true)"
      fire_stamp="$(grep -cE '^\[[^]]+\] FIRE — draw ' "$t" 2>/dev/null || true)"
      pw_stamp="$(grep -cE '^\[[^]]+\] prewarm: FAILED rc=' "$t" 2>/dev/null || true)"
      is_int "$sd_stamp"   || sd_stamp=0
      is_int "$fire_stamp" || fire_stamp=0
      is_int "$pw_stamp"   || pw_stamp=0

      if [ "$fire_stamp" -gt 0 ]; then
        info "Sentinel present, no ^RESULT: — the harness died mid-rung under its"
        info "own \`set -euo pipefail\` (:85). This is NOT an OOM-kill (those keep"
        info "no sentinel at all) and the exit code below is the harness's own."
        info ""
        info "The FIRE stamp is present, so the harness RAN."
        info "An export attempt WAS SPENT — re-arming is NOT free, and any"
        info "refused DRAW lines above are draws, not the verdict. Re-read"
        info "$FULL_ATTEMPTS_FILE against the PDS-D224 budget of 5;"
        info "a second arm burns a second real attempt."
      elif [ "$sd_stamp" -gt 0 ]; then
        info "STAND-DOWN, not a crash. The poll loop exhausted its draws and the"
        info "harness was NEVER INVOKED — so there is no RESULT: line to find."
        info "A closed gate costs ZERO export attempts; re-arming is free."
      elif [ "$pw_stamp" -gt 0 ]; then
        info "PRE-WARM FAILURE, not a mid-rung abort. The child died at the"
        info "PDS-D241 pre-warm (:264), before its first draw — no FIRE stamp,"
        info "so the harness was NEVER INVOKED and ZERO export attempts were"
        info "spent. Re-arming is free, but it will fail identically until the"
        info "\`MIX_ENV=prod mix compile\` above builds; fix that first."
      else
        info "Sentinel present, no ^RESULT:, and NEITHER the FIRE (:358) nor the"
        info "STAND-DOWN (:373) nor the pre-warm-failure (:264) stamp is in the"
        info "bytes — so this transcript was not written by a run of this"
        info "launcher, or it was truncated. UNDIAGNOSED: do not assume either"
        info "way. Read $FULL_ATTEMPTS_FILE against the"
        info "PDS-D224 budget of 5 to learn whether an attempt was spent."
      fi
      ;;
    FINISHED)
      info "Sentinel AND ^RESULT: — the harness ran to its own summary()."
      info "Read the RESULT line: it can still say FAIL or BLOCKED."
      ;;
    FINISHED-nosent)
      info "^RESULT: but no sentinel — this is EVERY pre-w14 transcript, i.e. a"
      info "run that was not armed by this launcher. It is a real outcome, not"
      info "a defect."
      ;;
    STILL-RUNNING)
      info "Neither marker, and \`ps -p $pid\` shows the process. Come back later;"
      info "do NOT re-arm — two concurrent full exports would OOM the live box."
      ;;
    KILLED)
      set +e
      pid_live_ours "$pid" "${p:+$(dirname "$p")/meta}"
      rc=$?
      set -e
      if [ "$rc" -eq 3 ]; then
        info "PID RECYCLED — pid $pid is ALIVE, but it is NOT the process this"
        info "run armed. The fingerprint the arm recorded and the one ps sees"
        info "now DISAGREE:"
        info "  recorded at arm: $PID_IDENT_RECORDED"
        info "  seen now:        $PID_IDENT_SEEN"
        info "The armed child is gone; its pid number was reused by an"
        info "unrelated process. This reads KILLED because the CLIMB is dead —"
        info "do NOT kill pid $pid, it belongs to something else."
      elif [ "$rc" -eq 2 ]; then
        # NOT kern.maxproc — see pid_live's header: maxproc caps concurrent
        # processes, not pid VALUES, and bounding on it calls live pids dead.
        # This branch means the pid file held nothing usable, or `ps` itself
        # rejected the value ("process id too large").
        info "CAVEAT: '${pid:-<none>}' is not a pid \`ps\` will evaluate — either the"
        info "pid file is empty/absent, or ps rejected the value outright."
        info "Liveness here is UNPROVEN, not disproven. It reads KILLED because"
        info "the pid file cannot be trusted, NOT because a death was observed."
      else
        info "Neither marker, and the pid is gone. The process was killed"
        info "WITHOUT running its EXIT trap."
      fi
      # ── PDS-D248 ──────────────────────────────────────────────────────────
      # /tmp/pds-full-export/lock is a mkdir lock released ONLY by cleanup via
      # `trap cleanup EXIT` (pds-pull-proof.sh:193), and SIGKILL BYPASSES TRAPS.
      # Preflight takes the lock unconditionally, so a stranded lock blocks every
      # subsequent run INCLUDING THE RETRY. Say it by name.
      if [ -d "$FULL_LOCK" ]; then
        rule
        say "STRANDED EXPORT LOCK — PDS-D248"
        info "$FULL_LOCK exists and its owner is gone. SIGKILL bypasses the"
        info "EXIT trap that releases it, so every subsequent run — INCLUDING"
        info "THE RETRY — will block on it until it is removed by hand:"
        info ""
        info "    rmdir $FULL_LOCK"
      else
        info "Export lock $FULL_LOCK is clear — no recovery needed."
      fi
      ;;
  esac

  if [ -f "$t" ]; then
    rule
    say "last 12 lines"
    rule
    tail -12 "$t" | sed 's/^/  /'
  fi
  rule

  case "$state" in
    FINISHED|FINISHED-nosent) return 0 ;;
    STILL-RUNNING)            return 2 ;;
    *)                        return 1 ;;
  esac
}

# ── selftest ─────────────────────────────────────────────────────────────────
#
# Proves the LAUNCHER on a DUMMY payload. It must never touch the real climb,
# the real export lock, or the real attempts counter — so every path it uses is
# redirected into a scratch directory, and it asserts that redirection held.

ST_PASS=0
ST_FAIL=0
ok()   { ST_PASS=$((ST_PASS + 1)); printf '  ok    %s\n' "$*"; }
bad()  { ST_FAIL=$((ST_FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
check(){ if [ "$1" = "$2" ]; then ok "$3 ($1)"; else bad "$3 — expected '$2', got '$1'"; fi; }

# A genuinely dead, IN-RANGE pid. Never 999999: `ps -p 999999` fails argument
# validation ("process id too large"), which looks like it proves the predicate
# while proving nothing.
dead_pid_fixture() {
  local p i
  for i in 1 2 3 4 5; do
    /bin/sleep 0 &
    p=$!
    wait "$p" 2>/dev/null || true
    if ! ps -p "$p" >/dev/null 2>&1; then printf '%s\n' "$p"; return 0; fi
  done
  return 1
}

cmd_selftest() {
  local scratch real_attempts_before real_attempts_after
  local real_lock_before real_lock_after
  local t0 t1 elapsed pid line pgid ppid stat budget seeded expect
  local state live_pid dead_pid out i

  real_attempts_before="$(cat /tmp/pds-full-export/attempts 2>/dev/null || echo '<none>')"
  real_lock_before=absent; [ -d /tmp/pds-full-export/lock ] && real_lock_before=present

  scratch="$(mktemp -d "${TMPDIR:-/tmp}/pds-launch-selftest.XXXXXX")"
  trap '[ -n "${scratch:-}" ] && [ -d "$scratch" ] && rm -rf "$scratch"' EXIT

  rule
  say "pds-crown-launch selftest — DUMMY payload only, the real climb is never touched"
  rule
  info "scratch $scratch"
  say ""

  # ── 1. arm a dummy, detached, and time it ────────────────────────────────
  say "1 · the fork detaches, and arming returns fast"
  seeded=7
  mkdir -p "$scratch/full"
  printf '%s\n' "$seeded" > "$scratch/full/attempts"

  cat > "$scratch/dummy.sh" <<'DUMMY'
printf 'DUMMY-BUDGET=%s\n' "${PDS_FULL_EXPORT_BUDGET:-unset}"
printf 'DUMMY-HOME=%s\n'   "${BARKPARK_HOME:-unset}"
printf 'DUMMY-FLOOR=%s\n'  "${PDS_FULL_EXPORT_MIN_MEM_MB:-unset}"
sleep 6
printf 'RESULT: PASS (dummy)\n'
printf 'EXIT: 0\n'
DUMMY

  # PDS-BLIND-SPOT-METER: `date +%s`, WALL CLOCK around fire_detached in THIS
  # shell — placement (a), outside every BEAM. The arm asserts a 60 s CEILING on
  # arming latency, which is the one thing a wall figure is honestly good for; it
  # is NOT a price and no CPU claim descends from it (PDS-D605).
  t0="$(date +%s)"
  fire_detached "deadbeef" "$scratch/full/attempts" \
    "$scratch/dummy.log" "exec /bin/bash $(printf '%q' "$scratch/dummy.sh")" \
    "$scratch/dummy.pid"
  t1="$(date +%s)"
  elapsed=$(( t1 - t0 ))

  pid="$(cat "$scratch/dummy.pid" | tr -d ' \n')"
  if is_int "$pid"; then ok "pid file holds exactly one integer ($pid)"; else bad "pid file holds '$pid'"; fi
  if [ "$elapsed" -lt 60 ]; then ok "arming returned in ${elapsed}s (< 60s)"; else bad "arming took ${elapsed}s"; fi
  pds_blind_spot_note \
    "date +%s, WALL CLOCK around fire_detached in this shell — an OS clock outside every BEAM (PDS-D633 placement (a)); a LATENCY CEILING, never a price (PDS-D605)" \
    "arming returned in"

  # ── 2. own pgid, own session, reparented to init ─────────────────────────
  say ""
  say "2 · the child owns its pgid and its session (PDS-D243)"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ "${ppid:-0}" = "1" ] && break
    sleep 1
  done
  line="$(ps -o pid=,ppid=,pgid=,stat= -p "$pid" 2>/dev/null || true)"
  if [ -z "$line" ]; then
    bad "the child is already gone — cannot prove detachment"
  else
    info "ps -o pid=,ppid=,pgid=,stat= -p $pid"
    info "  $line"
    pgid="$(printf '%s\n' "$line" | awk '{print $3}')"
    ppid="$(printf '%s\n' "$line" | awk '{print $2}')"
    stat="$(printf '%s\n' "$line" | awk '{print $4}')"
    check "$pgid" "$pid" "pgid equals its own pid — the child leads its own process group"
    check "$ppid" "1"    "ppid is 1 — reparented to init, it no longer belongs to this turn"
    case "$stat" in
      *s*) ok "STAT '$stat' carries 's' — session leader, immune to killpg on the launcher's group" ;;
      *)   bad "STAT '$stat' lacks 's' — NOT a session leader; this is the nohup failure mode" ;;
    esac
  fi

  # ── 3. the budget crossed the fork (PDS-D249) ────────────────────────────
  say ""
  say "3 · the budget crossed the fork as spent+2, not the silent default of 1"
  budget=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    budget="$(grep '^DUMMY-BUDGET=' "$scratch/dummy.log" 2>/dev/null | head -1 | cut -d= -f2 || true)"
    [ -n "$budget" ] && break
    sleep 1
  done
  expect=$(( seeded + 2 ))
  check "${budget:-<none>}" "$expect" "child read PDS_FULL_EXPORT_BUDGET (seeded attempts=$seeded)"
  if [ "${budget:-1}" = "1" ]; then
    bad "the child read 1 — that is the silent default, i.e. the export never crossed the fork"
  fi
  # PDS-D276/D277: fire_detached exports the derived 897 floor, so the DUMMY
  # child MUST inherit it across the fork. Mutation-provable: remove the
  # `export PDS_FULL_EXPORT_MIN_MEM_MB=897` knob and the child prints `unset`
  # here and this check FAILS (this is the pds-bl-floor-env-silent-revert guard).
  out="$(grep '^DUMMY-FLOOR=' "$scratch/dummy.log" 2>/dev/null | head -1 | cut -d= -f2 || true)"
  check "${out:-unset}" "897" "PDS_FULL_EXPORT_MIN_MEM_MB=897 crosses the fork (PDS-D276/D277 — was UNSET under D244)"

  # …and the arm's OWN floor record carries the derived 897 in BOTH knobs. This
  # is the single producer that meta AND the banner read (arm_floor_record /
  # arm_floor_summary), proven here hermetically — no real climb, no network.
  # fire_detached above set PDS_FULL_EXPORT_MIN_MEM_MB in this shell; MEM_FLOOR_MIB
  # is the source default. A revert of knob 1/2 moves mem_floor_mib; a revert of
  # knob 3 makes full_export_min_mem_mb read <UNSET> — either FAILS a check.
  rec="$(arm_floor_record)"
  poll_floor="$(printf '%s\n' "$rec"    | grep '^mem_floor_mib='          | cut -d= -f2)"
  harness_floor="$(printf '%s\n' "$rec" | grep '^full_export_min_mem_mb=' | cut -d= -f2)"
  check "$poll_floor"    "897" "arm_floor_record: mem_floor_mib is the derived 897"
  check "$harness_floor" "897" "arm_floor_record: full_export_min_mem_mb is the derived 897"

  # The banner (arm_floor_summary) renders the SAME two values operators read.
  out="$(arm_floor_summary)"
  case "$out" in *mem_floor_mib=897*)          ok   "arm summary shows mem_floor_mib=897" ;;
                 *)                             bad  "arm summary lost mem_floor_mib=897" ;; esac
  case "$out" in *full_export_min_mem_mb=897*)  ok   "arm summary shows full_export_min_mem_mb=897" ;;
                 *)                              bad  "arm summary lost full_export_min_mem_mb=897" ;; esac

  # run_dir/meta must carry both, produced by the EXACT code cmd_arm runs
  # (write_run_meta), written to scratch here so the real climb is untouched.
  mkdir -p "$scratch/metarun"
  write_run_meta "$scratch/metarun" deadbeef selftest-id 1234 "$scratch/x.log"
  out="$(grep '^mem_floor_mib=' "$scratch/metarun/meta" | cut -d= -f2 || true)"
  check "${out:-<none>}" "897" "run_dir/meta records mem_floor_mib=897"
  out="$(grep '^full_export_min_mem_mb=' "$scratch/metarun/meta" | cut -d= -f2 || true)"
  check "${out:-<none>}" "897" "run_dir/meta records full_export_min_mem_mb=897"

  out="$(grep '^DUMMY-HOME=' "$scratch/dummy.log" 2>/dev/null | head -1 | cut -d= -f2 || true)"
  case "${out:-}" in
    *deadbeef*) ok "BARKPARK_HOME carries the run tag ($out)" ;;
    *)          bad "BARKPARK_HOME='$out' does not carry the run tag (PDS-D233)" ;;
  esac

  # ── 4. STILL-RUNNING, from the live dummy ────────────────────────────────
  say ""
  say "4 · the six states (PDS-D247), each from a fixture"
  # This one is also the regression test for the maxproc misread: the armed pid
  # is routinely > kern.maxproc (4000), and a guard bounded on that sysctl calls
  # a demonstrably live process "unusable" and reports KILLED.
  state="$(classify "$scratch/dummy.log" "$scratch/dummy.pid")"
  check "$state" "STILL-RUNNING" "live dummy classifies (pid $pid, above kern.maxproc)"

  # The liveness predicate's own boundary, pinned against ps's real behaviour.
  set +e
  pid_live 99999;  rc=$?
  set -e
  check "$rc" "1" "pid_live 99999 takes the not-found path — dead, not unusable"
  set +e
  pid_live 100000; rc=$?
  set -e
  check "$rc" "2" "pid_live 100000 is UNUSABLE — ps rejects it as 'too large', which is not proof of death"

  # ── identity: a recycled pid must NOT read STILL-RUNNING ─────────────────
  # (pds-bl-pid-live-identity-blind). The live pid here is this selftest shell
  # itself — guaranteed alive for the whole run — standing in for "an unrelated
  # process now holds the number the arm recorded".
  say ""
  say "4b · a live pid with the WRONG identity is a dead climb, not a running one"
  printf 'STEP 3 — the full export\n  ... mid-rung, no sentinel\n' > "$scratch/ident.log"

  # (a) meta fingerprint MATCHES the live process -> still STILL-RUNNING
  mkdir -p "$scratch/ident-match"
  printf '%s\n' "$$" > "$scratch/ident-match/child.pid"
  printf 'pid_fingerprint=%s\n' "$(pid_fingerprint "$$")" > "$scratch/ident-match/meta"
  state="$(classify "$scratch/ident.log" "$scratch/ident-match/child.pid")"
  check "$state" "STILL-RUNNING" "matching fingerprint keeps STILL-RUNNING (no false refusal)"

  # (b) meta fingerprint DIFFERS -> the armed child is gone; KILLED, not alive
  mkdir -p "$scratch/ident-recycled"
  printf '%s\n' "$$" > "$scratch/ident-recycled/child.pid"
  printf 'pid_fingerprint=%s\n' "someothercomm Mon Jan  1 00:00:00 2020" > "$scratch/ident-recycled/meta"
  state="$(classify "$scratch/ident.log" "$scratch/ident-recycled/child.pid")"
  check "$state" "KILLED" "mismatched fingerprint refuses STILL-RUNNING (recycled pid)"

  # (c) no fingerprint recorded (pre-fix run dir) -> degrade to plain pid_live
  mkdir -p "$scratch/ident-legacy"
  printf '%s\n' "$$" > "$scratch/ident-legacy/child.pid"
  state="$(classify "$scratch/ident.log" "$scratch/ident-legacy/child.pid")"
  check "$state" "STILL-RUNNING" "a run dir with no recorded fingerprint degrades to plain pid_live"

  # (d) collect NAMES the mismatch and prints BOTH strings it compared — a
  # refusal that does not say what it saw is banned by the task brief.
  set +e
  out="$(PDS_FULL_EXPORT_DIR="$scratch/full" "$0" collect \
          --transcript "$scratch/ident.log" --pid-file "$scratch/ident-recycled/child.pid" 2>&1)"
  set -e
  case "$out" in
    *"PID RECYCLED"*) ok "collect names the recycled pid by name" ;;
    *)                bad "collect does not name PID RECYCLED on an identity mismatch" ;;
  esac
  case "$out" in
    *"someothercomm Mon Jan  1 00:00:00 2020"*) ok "collect prints the fingerprint recorded at arm" ;;
    *)                                          bad "collect hides the recorded fingerprint" ;;
  esac
  case "$out" in
    *"seen now:"*) ok "collect prints the fingerprint it sees now" ;;
    *)             bad "collect hides the fingerprint it sees now" ;;
  esac
  case "$out" in
    *"do NOT re-arm"*) bad "a recycled pid still tells the operator not to re-arm (the self-lock)" ;;
    *)                 ok "a recycled pid no longer forbids re-arming" ;;
  esac

  # (e) write_run_meta captures the fingerprint of the pid it is given
  mkdir -p "$scratch/identmeta"
  write_run_meta "$scratch/identmeta" cafe0002 ident-id "$$" "$scratch/ident.log"
  out="$(grep '^pid_fingerprint=' "$scratch/identmeta/meta" | cut -d= -f2- || true)"
  check "$out" "$(pid_fingerprint "$$")" "write_run_meta records the arm-time comm+lstart fingerprint"

  # NO-TRANSCRIPT
  state="$(classify "$scratch/absent.log" "$scratch/dummy.pid")"
  check "$state" "NO-TRANSCRIPT" "absent transcript classifies"

  # CRASHED — sentinel, no RESULT
  printf 'STEP 3 — the full export\nEXIT: 1\n' > "$scratch/crashed.log"
  state="$(classify "$scratch/crashed.log" "$scratch/dummy.pid")"
  check "$state" "CRASHED" "sentinel without RESULT classifies"

  # CRASHED, sub-diagnosis — a refused draw must NOT buy a free stand-down.
  #
  # PDS-D252. Both fixtures below classify CRASHED; what is under test is which
  # of the two CRASHED messages collect prints. The old carve-out grepped the
  # bare substring 'STAND-DOWN', which the per-draw verdict field carries on
  # every refusal — so this first fixture (refuse once, then FIRE, then die
  # mid-rung) reported an attempt-spending crash as a free stand-down.
  {
    printf '[2026-07-21T07:00:00Z] child up — pid=1234\n'
    printf 'DRAW\t1\t2026-07-21T07:00:00Z\tmem_mib=1800\tfloor=2200\tbuilds=<empty>\trecorded_rss_kb=?\trecorded_slot_uptime=?\tverdict=STAND-DOWN:mem<floor\n'
    printf '[2026-07-21T07:05:00Z] FIRE — draw 2 of 240 qualified.\n'
    printf 'STEP 3 — the full export\n'
    printf '[2026-07-21T07:40:00Z] harness returned rc=1 after 2 draw(s)\n'
    printf 'EXIT: 1\n'
  } > "$scratch/crash-after-standdown.log"
  state="$(classify "$scratch/crash-after-standdown.log" "$scratch/dummy.pid")"
  check "$state" "CRASHED" "refused-draw-then-FIRE-then-abort classifies"
  set +e
  out="$(PDS_FULL_EXPORT_DIR="$scratch/full" "$0" collect \
          --transcript "$scratch/crash-after-standdown.log" \
          --pid-file "$scratch/dummy.pid" 2>&1)"
  set -e
  case "$out" in
    *"harness was NEVER INVOKED"*)
      bad "a spent attempt is reported as 'the harness was NEVER INVOKED' (PDS-D252 regression)" ;;
    *) ok "a refused draw ahead of the FIRE does NOT claim the harness was never invoked" ;;
  esac
  case "$out" in
    *"re-arming is free"*)
      bad "a spent attempt is reported as free to re-arm (PDS-D252 regression)" ;;
    *) ok "a refused draw ahead of the FIRE does NOT call re-arming free" ;;
  esac
  case "$out" in
    *"An export attempt WAS SPENT"*) ok "the crash branch says the attempt was SPENT" ;;
    *)                               bad "the crash branch does not say the attempt was spent" ;;
  esac
  case "$out" in
    *"re-arming is NOT"*) ok "the crash branch says re-arming is NOT free" ;;
    *)                    bad "the crash branch does not deny that re-arming is free" ;;
  esac

  # …and the true never-fired stand-down must still read as one, verbatim.
  {
    printf 'DRAW\t1\t2026-07-21T07:00:00Z\tmem_mib=1800\tfloor=2200\tbuilds=<empty>\trecorded_rss_kb=?\trecorded_slot_uptime=?\tverdict=STAND-DOWN:mem<floor\n'
    printf '[2026-07-21T15:00:00Z] STAND-DOWN — 240 draws taken, none qualified. The climb NEVER FIRED;\n'
    printf '[2026-07-21T15:00:00Z]   A closed gate costs ZERO export attempts, so re-arming is free.\n'
    printf 'EXIT: 5\n'
  } > "$scratch/standdown.log"
  state="$(classify "$scratch/standdown.log" "$scratch/dummy.pid")"
  check "$state" "CRASHED" "a draws-exhausted stand-down still classifies CRASHED (six states, no seventh)"
  set +e
  out="$(PDS_FULL_EXPORT_DIR="$scratch/full" "$0" collect \
          --transcript "$scratch/standdown.log" --pid-file "$scratch/dummy.pid" 2>&1)"
  set -e
  case "$out" in
    *"harness was NEVER INVOKED"*) ok "the true stand-down still names the harness as never invoked" ;;
    *)                             bad "the true stand-down lost its never-invoked wording" ;;
  esac
  case "$out" in
    *"re-arming is free"*) ok "the true stand-down still says re-arming is free" ;;
    *)                     bad "the true stand-down lost its re-arming-is-free guidance" ;;
  esac

  # …and a PRE-WARM FAILURE is the third sentinel writer (:264). It carries
  # NEITHER stamp and spends ZERO attempts, so telling its reader that an
  # attempt was spent is D252's own error with the polarity flipped.
  {
    printf '[2026-07-21T07:00:00Z] child up — pid=1234\n'
    printf '[2026-07-21T07:00:01Z] prewarm: cd /x && CC=/usr/bin/clang MIX_ENV=prod mix compile\n'
    printf '[2026-07-21T07:02:00Z] prewarm: FAILED rc=1 — NOT firing. A climb that pays 155 s of compile\n'
    printf 'EXIT: 1\n'
  } > "$scratch/prewarm-fail.log"
  state="$(classify "$scratch/prewarm-fail.log" "$scratch/dummy.pid")"
  check "$state" "CRASHED" "a pre-warm abort classifies CRASHED (still no seventh state)"
  set +e
  out="$(PDS_FULL_EXPORT_DIR="$scratch/full" "$0" collect \
          --transcript "$scratch/prewarm-fail.log" --pid-file "$scratch/dummy.pid" 2>&1)"
  set -e
  case "$out" in
    *"An export attempt WAS SPENT"*)
      bad "a pre-warm abort is reported as having spent an attempt (it spends none)" ;;
    *) ok "a pre-warm abort does NOT claim an export attempt was spent" ;;
  esac
  case "$out" in
    *"PRE-WARM FAILURE"*) ok "a pre-warm abort is named as a pre-warm failure" ;;
    *)                    bad "a pre-warm abort is not named as one" ;;
  esac
  case "$out" in
    *"ZERO export attempts"*) ok "the pre-warm branch says zero attempts were spent" ;;
    *)                        bad "the pre-warm branch does not say the attempt count is zero" ;;
  esac

  # …and a transcript carrying none of the three stamps gets a cost ASSIGNED to
  # neither side. `crashed.log` above is exactly that shape.
  set +e
  out="$(PDS_FULL_EXPORT_DIR="$scratch/full" "$0" collect \
          --transcript "$scratch/crashed.log" --pid-file "$scratch/dummy.pid" 2>&1)"
  set -e
  case "$out" in
    *"UNDIAGNOSED"*) ok "a stampless transcript is called UNDIAGNOSED, not costed" ;;
    *)               bad "a stampless transcript is assigned a cost it never proved" ;;
  esac
  case "$out" in
    *"An export attempt WAS SPENT"*|*"re-arming is free"*)
      bad "a stampless transcript is told an attempt was/was not spent without proof" ;;
    *) ok "a stampless transcript claims neither that an attempt was nor was not spent" ;;
  esac

  # FINISHED — both
  printf 'RESULT: PASS — the whole ladder ran and held.\nEXIT: 0\n' > "$scratch/finished.log"
  state="$(classify "$scratch/finished.log" "$scratch/dummy.pid")"
  check "$state" "FINISHED" "sentinel with RESULT classifies"

  # FINISHED-nosent — every pre-w14 transcript
  printf 'RESULT: BLOCKED — named the merge it waits on.\n' > "$scratch/nosent.log"
  state="$(classify "$scratch/nosent.log" "$scratch/dummy.pid")"
  check "$state" "FINISHED-nosent" "RESULT without sentinel classifies (pre-w14 shape)"

  # KILLED — neither marker, pid genuinely dead and IN RANGE
  printf 'STEP 3 — the full export\n  ... mid-rung, no sentinel\n' > "$scratch/killed.log"
  dead_pid="$(dead_pid_fixture || true)"
  if is_int "$dead_pid"; then
    printf '%s\n' "$dead_pid" > "$scratch/killed.pid"
    info "dead pid fixture: $dead_pid (reaped, in-range — never 999999, which fails ps argument validation)"
    state="$(classify "$scratch/killed.log" "$scratch/killed.pid")"
    check "$state" "KILLED" "no marker + dead pid classifies"
  else
    bad "could not obtain a reaped in-range pid for the KILLED fixture"
  fi

  # ── 5. KILLED names the stranded lock (PDS-D248) ─────────────────────────
  say ""
  say "5 · KILLED reports the stranded export lock and its recovery line"
  mkdir -p "$scratch/full/lock"
  set +e
  out="$(PDS_FULL_EXPORT_DIR="$scratch/full" "$0" collect \
          --transcript "$scratch/killed.log" --pid-file "$scratch/killed.pid" 2>&1)"
  set -e
  case "$out" in
    *"STATE: KILLED"*) ok "collect returns KILLED for the fixture" ;;
    *)                 bad "collect did not return KILLED" ;;
  esac
  case "$out" in
    *"STRANDED EXPORT LOCK"*) ok "the stranded lock is named" ;;
    *)                        bad "the stranded lock was not reported" ;;
  esac
  case "$out" in
    *"rmdir $scratch/full/lock"*) ok "the rmdir recovery line names the dummy lock, not the real one" ;;
    *)                            bad "the rmdir recovery line is missing or points elsewhere" ;;
  esac
  rmdir "$scratch/full/lock"
  set +e
  out="$(PDS_FULL_EXPORT_DIR="$scratch/full" "$0" collect \
          --transcript "$scratch/killed.log" --pid-file "$scratch/killed.pid" 2>&1)"
  set -e
  case "$out" in
    *"is clear — no recovery needed"*) ok "with the lock cleared, collect says so instead of crying wolf" ;;
    *)                                 bad "collect reported a lock that does not exist" ;;
  esac

  # ── 6. the dummy finishes, and FINISHED is reached for real ──────────────
  say ""
  say "6 · the detached child outlives its launcher and finishes on its own"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    state="$(classify "$scratch/dummy.log" "$scratch/dummy.pid")"
    [ "$state" = "FINISHED" ] && break
    sleep 1
  done
  check "$state" "FINISHED" "the dummy ran to completion after its launcher returned"

  # ── 7. the real climb's bookkeeping is untouched ─────────────────────────
  say ""
  say "7 · the real attempts counter and the real export lock are untouched"
  real_attempts_after="$(cat /tmp/pds-full-export/attempts 2>/dev/null || echo '<none>')"
  check "$real_attempts_after" "$real_attempts_before" "/tmp/pds-full-export/attempts unchanged"
  # UNCHANGED, not ABSENT. A lock that was ALREADY held when the selftest started
  # is the PDS-D248 stranded lock — the precise hazard this wave braces for — and
  # a selftest that fails there accuses ITSELF of a strand it did not cause, then
  # blocks the retry with a false diagnosis. What this check owns is the
  # DIFFERENCE it made, which is required to be none.
  real_lock_after=absent; [ -d /tmp/pds-full-export/lock ] && real_lock_after=present
  check "$real_lock_after" "$real_lock_before" "/tmp/pds-full-export/lock unchanged (was $real_lock_before)"
  if [ "$real_lock_before" = present ]; then
    info "NOTE: the real export lock was ALREADY held before this selftest ran."
    info "If no climb is running, that is the PDS-D248 strand — recover with:"
    info "    rmdir /tmp/pds-full-export/lock"
  fi

  # ── 8. the forbidden mechanisms are absent from the CODE, not just the prose ──
  #
  # Both bans are about what the script RUNS. Grepping the whole file conflates a
  # ban with the paragraph explaining it, so these two checks strip comments and
  # look for command-position invocations — the only form that could hurt.
  say ""
  say "8 · the refuted mechanisms are never invoked (PDS-D243, PDS-D135)"
  out="$(sed 's/[[:space:]]*#.*$//' "$SCRIPT_DIR/$SELF" 2>/dev/null \
         | grep -nE '(^|[|;&(]|&&|\|\|)[[:space:]]*nohup[[:space:]]' || true)"
  if [ -z "$out" ]; then
    ok "no line INVOKES nohup (the word survives only in rationale + diagnostics)"
  else
    bad "nohup is invoked: $out"
  fi

  # pgrep is legal for discovering beam.smp on the REMOTE box (PDS-D135 blesses
  # `-o -x` and forbids `-f`); it is ILLEGAL for deciding whether OUR child is
  # alive, which is what wave 13 burned. Assert exactly that split.
  # Command-position only. A substring match would flag this very check's own
  # source lines — the assertion would fail on itself and prove nothing.
  out="$(sed 's/[[:space:]]*#.*$//' "$SCRIPT_DIR/$SELF" 2>/dev/null \
         | grep -nE '(^|[|;&(=]|&&|\|\||\$\()[[:space:]]*pgrep[[:space:]]' || true)"
  case "$out" in
    *'pgrep -o -x beam.smp'*) : ;;
    *) bad "unexpected pgrep invocation: ${out:-<none>}" ;;
  esac
  if [ "$(printf '%s' "$out" | grep -c . || true)" = "1" ]; then
    ok "the only pgrep INVOCATION is the remote 'pgrep -o -x beam.smp' (D135's endorsed form, on the box we do not own)"
  else
    bad "expected exactly one pgrep invocation, got: ${out:-<none>}"
  fi
  if grep -qE 'pgrep' <<<"$(sed -n '/^pid_live()/,/^}/p' "$SCRIPT_DIR/$SELF")"; then
    bad "pid_live uses pgrep — this is exactly what wave 13 burned"
  else
    ok "pid_live contains no pgrep; liveness is ps -p only"
  fi

  # ── 9. ARMED is a read-back, not a fork return (PDS-D317) ────────────────
  #
  # Four live fixtures through assert_child_up — the SAME function cmd_arm
  # calls — plus two source guards so deleting the call, or softening the
  # banner back into a promise, turns this section RED.
  say ""
  say "9 · ARMED is gated on a marker the CHILD wrote, not on the fork's pid"

  # (a) a child that stamps its own arrival and stays up -> UP
  cat > "$scratch/live-child.sh" <<'LIVECHILD'
printf '[fixture] child up — pid=%s\n' "$$"
sleep 20
LIVECHILD
  fire_detached "cafe0001" "$scratch/full/attempts" \
    "$scratch/live.log" "exec /bin/bash $(printf '%q' "$scratch/live-child.sh")" \
    "$scratch/live.pid"
  set +e
  out="$(assert_child_up "$scratch/live.log" "$scratch/live.pid" 5)"; rc=$?
  set -e
  check "$out" "UP" "a stamped, still-running child reads UP"
  check "$rc"  "0"  "…and returns 0"

  # (b) THE FLAGSHIP LIE: a payload that is literally `exit 0`. Pre-fix this
  # printed ARMED and returned 0. It must now be a NAMED non-zero outcome.
  cat > "$scratch/dead-child.sh" <<'DEADCHILD'
exit 0
DEADCHILD
  fire_detached "cafe0002" "$scratch/full/attempts" \
    "$scratch/dead.log" "exec /bin/bash $(printf '%q' "$scratch/dead-child.sh")" \
    "$scratch/dead.pid"
  set +e
  out="$(assert_child_up "$scratch/dead.log" "$scratch/dead.pid" 4)"; rc=$?
  set -e
  check "$rc" "1" "an instant-exit payload is a NON-ZERO outcome, not ARMED"
  case "$out" in
    UP) bad "an instant-exit payload read UP — this is the success-lie itself" ;;
    "") bad "an instant-exit payload produced no state token at all" ;;
    *)  ok  "…and it is NAMED, not a bare failure ($out)" ;;
  esac

  # (c) a live process that never identifies itself. Alive is not enough: the
  # marker is what separates "the climb is up" from "SOMETHING is up".
  cat > "$scratch/mute-child.sh" <<'MUTECHILD'
sleep 20
MUTECHILD
  fire_detached "cafe0003" "$scratch/full/attempts" \
    "$scratch/mute.log" "exec /bin/bash $(printf '%q' "$scratch/mute-child.sh")" \
    "$scratch/mute.pid"
  set +e
  out="$(assert_child_up "$scratch/mute.log" "$scratch/mute.pid" 3)"; rc=$?
  set -e
  check "$out" "NO-MARKER" "a live process that never stamped is NO-MARKER, not UP"
  check "$rc"  "1"         "…and returns non-zero"

  # (d) the tri-state survives: an unusable pid is UNPERFORMABLE, never DEAD.
  # 100000 is the measured boundary — `ps` rejects it as "too large", which is
  # not proof of death in either direction (see pid_live's own checks in §4).
  printf '100000\n' > "$scratch/unusable.pid"
  set +e
  out="$(assert_child_up "$scratch/live.log" "$scratch/unusable.pid" 1)"; rc=$?
  set -e
  check "$out" "UNPERFORMABLE" "an unusable pid is UNPERFORMABLE, not collapsed into DEAD"
  check "$rc"  "2"             "…and keeps rc=2 distinct from rc=1"

  # (e) MUTATION GUARD — the call itself. cmd_arm must run the read-back
  # between the fork and the banner; delete it and this FAILS.
  out="$(sed -n '/^cmd_arm()/,/^}/p' "$SCRIPT_DIR/$SELF" | grep -c 'assert_child_up' || true)"
  if [ "${out:-0}" -ge 1 ]; then
    ok "cmd_arm calls assert_child_up (the read-back is wired, not merely defined)"
  else
    bad "cmd_arm no longer calls assert_child_up — ARMED is back to trusting the fork's pid"
  fi

  # (f) MUTATION GUARD — the wording. The banner may claim a read at an
  # instant; it may never claim an outcome it cannot know.
  out="$(sed -n '/^cmd_arm()/,/^}/p' "$SCRIPT_DIR/$SELF" | grep -c 'child is UP as of' || true)"
  if [ "${out:-0}" -ge 1 ]; then
    ok "the ARMED banner claims 'child is UP as of <t>'"
  else
    bad "the ARMED banner lost its 'child is UP as of <t>' wording"
  fi
  out="$(sed -n '/^cmd_arm()/,/^}/p' "$SCRIPT_DIR/$SELF" | grep -cE 'climb will complete|climb now outlives' || true)"
  if [ "${out:-0}" -eq 0 ]; then
    ok "the banner promises nothing about how the climb ends"
  else
    bad "the banner makes a promise about the climb's outcome that one read cannot back"
  fi

  say ""
  rule
  printf '  %d ok · %d FAIL\n' "$ST_PASS" "$ST_FAIL"
  rule
  if [ "$ST_FAIL" -gt 0 ]; then
    say "SELFTEST FAILED — do not arm the real climb."
    return 1
  fi
  say "SELFTEST PASSED — the launcher detaches, carries its budget across the fork,"
  say "classifies all six states, and backs the word ARMED with a read of the"
  say "child's own transcript. It has fired nothing."
  return 0
}

# ── dispatch ─────────────────────────────────────────────────────────────────

usage() {
  cat <<USAGE
usage: $SELF <command>

  arm [--force] [--prewarm-now|--no-prewarm] [--max-draws N] [--interval S]
        Launch the climb DETACHED and return. Does not poll; the poll loop
        lives in the child, which outlives this turn. By default the child
        pays the MIX_ENV=prod pre-warm before its first draw (PDS-D241).

  collect [<run-tag>] [--transcript P --pid-file F]
        Classify a transcript into one of six states (PDS-D247):
        NO-TRANSCRIPT · CRASHED · FINISHED · FINISHED-nosent ·
        STILL-RUNNING · KILLED. On KILLED, reports the stranded export lock.

  selftest
        Prove the launcher on a DUMMY payload. Touches neither the real
        climb, nor the export lock, nor the attempts counter.
USAGE
}

main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    arm)      cmd_arm "$@" ;;
    collect)  cmd_collect "$@" ;;
    selftest) cmd_selftest "$@" ;;
    -h|--help|help) usage ;;
    '')       usage >&2; exit 3 ;;
    *)        printf '%s: unknown command %s\n' "$SELF" "$cmd" >&2; usage >&2; exit 3 ;;
  esac
}

main "$@"
