#!/usr/bin/env bash
#
# pds-export-peak-measure.sh — the PAIRED-CONTROL peak instrument (PDS-D216).
#
# WHY THIS EXISTS. The canonical pre-fix export demand is
#
#     (2,483,304 − 194,228) kB / 1024 = 2235.43 MiB
#
# measured by the 1 Hz `ps -o rss=` sampler inside the FROZEN crown harness
# (scripts/pds-pull-proof.sh, blob e219e97ccf7f33797c86a2b84d998d599b6bda31).
# That sampler satisfies only the STATED-RATE half of PDS-D104: `grep -E
# 'idle|paired' scripts/pds-pull-proof.sh` returns ZERO hits. But the root
# task's criterion 2 requires the post-fix number carry a stated sampling rate
# AND a paired idle control. PDS-D104 exists because background BEAM drift
# alone swings 335.7–378 MiB over 100–135 s with ZERO requests issued — without
# a paired control that drift is indistinguishable from the export's own cost.
#
# So this script is the frozen sampler's procedure, reproduced EXACTLY, run
# TWICE: once over an idle window with zero requests issued, and once over the
# acquisition. Both peak-minus-baseline figures are reported, with the
# arithmetic printed. Nothing is silently subtracted — the idle drift is
# context for the reader, not a correction applied behind their back.
#
# THE HARNESS IS FROZEN AND STAYS FROZEN. This lives BESIDE it. It does not
# read, source, or edit scripts/pds-pull-proof.sh, and it does not move
# PDS_FULL_EXPORT_MIN_MEM_MB — it only READS that floor to gate itself.
#
# WHAT IS REPRODUCED EXACTLY, AND WHY EACH ONE MATTERS
#
#   1. UNITS. MiB is kB/1024. Never /1000. Mixing the two is precisely the slip
#      that once stated the shortfall as 31 instead of 35.43 (derivation §6b.1).
#
#   2. BASELINE t=0 (PDS-D185). A ONE-SHOT `ps -o rss=` taken strictly BEFORE
#      the request fires. NOT the sampler's first logged tick — that lands at
#      t≈+1 s and already contains part of the export's own allocation, which
#      subtracts the very thing being measured and errs in the direction that
#      flatters the floor (230,072 kB would have yielded 2200.42 MiB).
#
#   3. PROCESS SELECTION (PDS-D135). `pgrep -o -x beam.smp`. NEVER
#      `pgrep -f beam.smp | head -1`: `-f` matches ARGV, so an ssh command line
#      that merely mentions beam.smp SELF-MATCHES, and `head -1` is a PID sort,
#      not an age sort. One captured run under-read by ~342x — it sampled a
#      1,852 kB monitoring shell instead of the 634,324 kB BEAM. The box runs
#      blue/green and legitimately has two slots alive, so EVERY comm-anchored
#      beam.smp is sampled and the peak is the MAX ACROSS THE SET.
#
#   4. RATE. 1 Hz, stated in the output. Per PDS-D114 a 1 Hz sampler reports a
#      LOWER BOUND on the true peak — a transient between ticks is invisible.
#      That is the SAFE direction for a floor: it understates demand.
#
#   5. NO COMPRESSION. Bandit gzips `send_resp` bodies when the client offers
#      gzip (4,000,000 → 3,912 bytes, measured). The frozen harness's `curl_src`
#      sends no Accept-Encoding and `--compressed` appears nowhere in it, so
#      2235.43 MiB is uncontaminated. This script never passes `--compressed`
#      and refuses any override that would smuggle it in.
#
# WHAT THE CONTROL WINDOW ADDS BEYOND THE FROZEN PROCEDURE (PDS-D220b). The
# idle window samples TWO quantities, not one. BEAM RSS is the frozen
# procedure's quantity and stays the headline. `/proc/meminfo` MemAvailable is
# sampled beside it because PDS-D221 states its contamination-abort threshold
# (1048.16 MiB) on the RANGE of MemAvailable — a WHOLE-BOX figure. Attaching
# that threshold to a per-process RSS delta compares two different quantities:
# the same unit-class error PDS-D185 exists to correct, one level up. This
# script EMITS `idle_memavail_min_kb / _max_kb / _range_mib` and stops there —
# applying the threshold belongs to the measure slice, not the instrument.
#
# WHY A ZERO-SAMPLE WINDOW IS A REFUSAL, NOT A NUMBER (PDS-D220a). `peak_kb_of`
# returns 0 for an empty log and the delta subtracts the baseline from it. An
# acquisition that returns before the sampler's first ~1 s tick therefore once
# emitted `export_samples=0 export_delta_mib=-847.18` and EXITED 0 — a NEGATIVE
# demand, presented as a measurement, headed for the floor derivation. A window
# that was never sampled now refuses (exit 2) and names the cause.
#
# THE KNOWN ASYMMETRY, DISCLOSED RATHER THAN QUIETLY FIXED. The frozen
# procedure takes its BASELINE from the primary (oldest) slot alone but its
# PEAK from the MAX across all slots. On a single-slot box the two agree. On a
# two-slot box the baseline can under-read the set, which inflates the delta.
# This instrument reproduces the frozen arithmetic verbatim (that is the point
# — the numbers must be comparable) and ALSO prints the max-across-set baseline
# as a diagnostic so a reader can see the size of the asymmetry. The headline
# figure is the frozen one.
#
# SAFETY. An acquisition that is a FULL-fidelity export costs ~2.2 GiB on a
# 3.8 GB box. This script therefore takes the SAME lock directory the frozen
# harness uses (PDS-D31: two concurrent full exports OOM the box) and refuses a
# full acquisition when MemAvailable is under the harness's own floor. It reads
# that floor; it never changes it.
#
# USAGE
#
#   scripts/pds-export-peak-measure.sh [--path <api path>] [--window <seconds>]
#                                      [--label <text>] [--out <file>]
#
#   --path     acquisition path on the source, default the FULL workspace
#              export `/api/workspaces/$WS/export`. A path carrying
#              `profile=dev` is treated as a cheap acquisition and skips the
#              full-export headroom gate.
#   --window   idle-control window length in seconds (default 130 — the
#              canonical export's wall time). The export window's length is
#              whatever the export takes; both are reported and any mismatch is
#              named.
#   --label    free text recorded in the output (e.g. "post-spill").
#   --out      write the machine-readable line to this file as well as stdout.
#
# ENV (all optional, mirroring the frozen harness's names)
#
#   PDS_SOURCE_BASE      default https://guerrilla.barkpark.cloud
#   PDS_SOURCE_WORKSPACE default default
#   PDS_SOURCE_SSH       default root@157.180.90.121
#   PDS_SOURCE_SSH_KEY   default $HOME/.ssh/barkpark_indx
#   PDS_SOURCE_TOKEN     default: the `token` for PDS_SOURCE_BASE in
#                        ~/.config/barkpark/config.json. Never printed.
#   PDS_RUN_ID           default a UTC stamp + pid
#
# EXIT: 0 measured · 2 refused (a precondition, or a window that logged nothing
#       — see PDS-D220a) · 3 misconfigured.

set -eu

# A decimal COMMA is not a number this instrument may emit. Under a comma
# locale `awk 'printf "%.2f"'` renders 115.46 as "115,46", which silently
# corrupts every MiB figure in the machine-readable line and makes the headline
# uncomparable to 2235.43. Caught by running it, not by reading it.
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

# ── source under measurement (names mirror the frozen harness) ───────────────

SOURCE_BASE="${PDS_SOURCE_BASE:-https://guerrilla.barkpark.cloud}"
SOURCE_WS="${PDS_SOURCE_WORKSPACE:-default}"
SOURCE_SSH="${PDS_SOURCE_SSH-root@157.180.90.121}"
SOURCE_SSH_KEY="${PDS_SOURCE_SSH_KEY:-$HOME/.ssh/barkpark_indx}"

RUN_ID="${PDS_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"

# The floor is READ here and never written. Moving it is pds-w11-floor-rederivation.
FULL_MIN_MEM_MB="${PDS_FULL_EXPORT_MIN_MEM_MB:-2200}"
FULL_DIR="${PDS_FULL_EXPORT_DIR:-/tmp/pds-full-export}"
FULL_LOCK="$FULL_DIR/lock"
LOCK_OWNED=""

# The SHARED attempt ledger — the same file and the same budget name the frozen
# harness uses (pds-pull-proof.sh:128 / :1368). Both are read here; the ledger
# is written ONLY on the unscoped path, and only just before the fire. See the
# ATTEMPT LEDGER block below the ssh helpers for why.
FULL_ATTEMPTS_FILE="$FULL_DIR/attempts"
FULL_BUDGET="${PDS_FULL_EXPORT_BUDGET:-1}"
ATTEMPT_CHARGED=no                # did THIS run charge the ledger?
ATTEMPTS_AFTER=""                 # the counter's value once this run was done with it

SAMPLE_HZ=1                       # stated in the output; see PDS-D114
IDLE_SECONDS=130                  # the canonical export's wall time
ACQ_PATH=""
LABEL="unlabelled"
OUT_FILE=""

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pds-peak.XXXXXX")"
IDLE_LOG="$WORK_DIR/idle-rss.log"
IDLE_MEM_LOG="$WORK_DIR/idle-memavail.log"
EXPORT_LOG="$WORK_DIR/export-rss.log"
BODY_FILE="$WORK_DIR/acquired.bin"

say()  { printf '%s\n' "$*"; }
info() { printf '      %s\n' "$*"; }
rule() { printf -- '─%.0s' $(seq 1 78); printf '\n'; }
die()  { printf '%s: %s\n' "$SELF" "$*" >&2; exit 3; }
refuse() { printf '%s: REFUSED — %s\n' "$SELF" "$*" >&2; exit 2; }

IDLE_SAMPLER_PID=""
IDLE_MEM_SAMPLER_PID=""
EXPORT_SAMPLER_PID=""
cleanup() {
  [ -n "$IDLE_SAMPLER_PID" ] && kill "$IDLE_SAMPLER_PID" 2>/dev/null || true
  [ -n "$IDLE_MEM_SAMPLER_PID" ] && kill "$IDLE_MEM_SAMPLER_PID" 2>/dev/null || true
  [ -n "$EXPORT_SAMPLER_PID" ] && kill "$EXPORT_SAMPLER_PID" 2>/dev/null || true
  [ -n "$LOCK_OWNED" ] && rmdir "$FULL_LOCK" 2>/dev/null || true
  rm -rf "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── args ─────────────────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
  case "$1" in
    --path)   ACQ_PATH="${2:-}"; shift 2 || die "--path needs a value" ;;
    --window) IDLE_SECONDS="${2:-}"; shift 2 || die "--window needs a value" ;;
    --label)  LABEL="${2:-}"; shift 2 || die "--label needs a value" ;;
    --out)    OUT_FILE="${2:-}"; shift 2 || die "--out needs a value" ;;
    -h|--help) sed -n '1,80p' "$0"; exit 0 ;;
    *) die "unknown argument '$1' (try --help)" ;;
  esac
done

ACQ_PATH="${ACQ_PATH:-/api/workspaces/$SOURCE_WS/export}"
case "$ACQ_PATH" in
  /*) ;;
  *) die "--path must start with / (got '$ACQ_PATH')" ;;
esac
case "$ACQ_PATH" in
  *--compressed*|*accept-encoding*|*Accept-Encoding*)
    die "the acquisition path smuggles compression. Bandit gzips send_resp bodies when the client offers gzip, and the frozen harness never asks for it — a compressed acquisition does not compare like with like (see the header, item 5)." ;;
esac
case "$IDLE_SECONDS" in
  ''|*[!0-9]*) die "--window must be a whole number of seconds (got '$IDLE_SECONDS')" ;;
esac
[ "$IDLE_SECONDS" -ge 5 ] || die "--window must be at least 5 s to produce a usable control"

# A full acquisition is one that does NOT narrow to the dev profile.
FULL_ACQ=yes
case "$ACQ_PATH" in *profile=dev*) FULL_ACQ=no ;; esac

# ── token: resolved, never printed (same resolution as the frozen harness) ───

SOURCE_TOKEN=""
resolve_source_token() {
  if [ -n "${PDS_SOURCE_TOKEN:-}" ]; then
    SOURCE_TOKEN="$PDS_SOURCE_TOKEN"
    return 0
  fi
  local cfg="$HOME/.config/barkpark/config.json"
  [ -r "$cfg" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  SOURCE_TOKEN="$(BASE="$SOURCE_BASE" python3 - "$cfg" <<'PY' || true
import json, os, sys
base = os.environ["BASE"].rstrip("/")
cfg = json.load(open(sys.argv[1]))
cands = [cfg] + list(cfg.get("known_servers") or [])
for c in cands:
    if str(c.get("server", "")).rstrip("/") == base and c.get("token"):
        print(c["token"])
        break
PY
)"
  [ -n "$SOURCE_TOKEN" ]
}

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
# that appears or dies mid-window is still covered. One `ps -o rss=` per slot
# per tick, `sleep 1` between ticks. Each line is `<epoch> <pid> <rss_kb>` —
# strictly richer than the harness's bare rss column, and the peak arithmetic
# over it is identical (max of the rss field across every reading).
#
# SAMPLER_PID is set as a GLOBAL, never echoed from a command substitution.
# `PID="$(start_sampler …)"` runs the function in a SUBSHELL, so `$!` is that
# subshell's job — not a child of this shell. `wait` on it returns instantly
# (so an idle window collapses to 0 s and logs nothing) and `kill` on it hits a
# pid that already exited, LEAVING THE REMOTE ssh LOOP ALIVE ON THE SOURCE BOX.
# Both failures were observed on the first live run.
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
# So the idle control window samples BOTH: RSS for continuity with the frozen
# procedure, MemAvailable so the threshold has a quantity of its own class to
# attach to. It runs as its OWN ssh loop rather than as extra lines inside the
# RSS loop, because the RSS log's `<epoch> <pid> <rss_kb>` shape is the frozen
# arithmetic's contract — a foreign line in that file would be read by
# peak_kb_of() as a colossal RSS reading and silently wreck the headline.
#
# This instrument only MAKES THE NUMBER EXIST. It does not abort on the
# threshold: applying 1048.16 MiB is the measure slice's job, against the
# emitted range.
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

# ── THE FULL-EXPORT ATTEMPT LEDGER (PDS-D244) ───────────────────────────────
#
# An UNSCOPED acquisition here IS the ~2.2 GiB full export — the same physical
# event the frozen harness charges an attempt for at pds-pull-proof.sh:1367-1368.
# This instrument used to fire it while touching no counter at all (`grep -c
# FULL_ATTEMPTS_FILE` returned 0), so the harness's cond_c ("attempts < budget")
# could not see an instrument-driven full export AT ALL: the cost was paid on
# the box and the ledger kept its old value, leaving a later climb free to fire
# on budget it had physically already consumed. An instrument whose cost the
# ledger cannot see is reporting a spend nobody observed.
#
# The ledger is therefore SHARED, exactly as $FULL_LOCK is shared, and the
# ordering is the harness's — for the harness's reasons:
#
#   * every failed precondition returns ABOVE the spend, so a closed gate costs
#     ZERO attempts (the harness's `return 1` at :1362 sits above its spend at
#     :1367-1368, and every `refuse` in this file sits above the call site);
#   * the spend is flushed with `sync` BEFORE the request, because a dead export
#     still paid its memory peak — a run killed mid-export must not come back to
#     a counter that never moved.
#
# A SCOPED acquisition (profile=dev → FULL_ACQ=no) is NOT that event and stays
# FREE: it never writes this file, and a scoped run leaves both its value and
# its mtime unchanged. That property is load-bearing; do not regress it.
#
# This instrument RECORDS the spend; it does not enforce the budget. cond_c in
# the frozen harness is the enforcement point, and it can only enforce what it
# can see — which is precisely what this block exists to give it.

full_attempts() { # -> integer (absent / empty / garbage counter file reads 0)
  local n=""
  if [ -f "$FULL_ATTEMPTS_FILE" ]; then
    n="$(tr -dc '0-9' <"$FULL_ATTEMPTS_FILE" | head -c 6)"
  fi
  printf '%s' "${n:-0}"
}

spend_full_attempt() { # unscoped path ONLY, called ONLY once every refusal is behind us
  local spent spent_now
  spent="$(full_attempts)"
  spent_now=$((spent + 1))
  mkdir -p "$FULL_DIR" 2>/dev/null || true
  printf '%s\n' "$spent_now" >"$FULL_ATTEMPTS_FILE"
  # Flushed BEFORE the request: a run killed mid-export must not come back to a
  # counter that never moved, because the box already paid the peak.
  ( command -v sync >/dev/null 2>&1 && sync ) 2>/dev/null || true
  ATTEMPT_CHARGED=yes
  ATTEMPTS_AFTER="$spent_now"
  info "attempt ledger  CHARGED $spent -> $spent_now (budget $FULL_BUDGET) — a FULL acquisition is"
  info "                about to fire, so the shared ledger is written and sync-flushed to"
  info "                $FULL_ATTEMPTS_FILE BEFORE the request. A dead export still paid its peak."
  info "                Recorded here, ENFORCED by the frozen harness's cond_c — the check that"
  info "                could not see this instrument at all before PDS-D244."
}

# ── preflight ────────────────────────────────────────────────────────────────

rule
say "PDS EXPORT PEAK — PAIRED-CONTROL INSTRUMENT (PDS-D104 / PDS-D216)"
rule
info "run id          $RUN_ID"
info "label           $LABEL"
info "source          $SOURCE_BASE  (workspace $SOURCE_WS)"
info "acquisition     GET $ACQ_PATH"
info "                full-fidelity? $FULL_ACQ · compression NOT requested (no --compressed, no Accept-Encoding)"
info "sampler         ${SAMPLE_HZ} Hz \`ps -o rss=\` over SSH across ALL comm-anchored beam.smp slots"
info "                selector \`pgrep -o -x beam.smp\` for the primary; peak = MAX over the SET (PDS-D135)"
info "                a 1 Hz grid is a LOWER BOUND on the true peak (PDS-D114) — the safe direction for a floor"
say ""

command -v curl >/dev/null 2>&1 || die "curl is not on PATH"
resolve_source_token || die "no source token. Set PDS_SOURCE_TOKEN, or add $SOURCE_BASE to ~/.config/barkpark/config.json. (It is never printed.)"
ssh_available || refuse "SSH to $SOURCE_SSH is not available (key $SOURCE_SSH_KEY). The BEAM's RSS lives on the source box; there is no local proxy for it, and this instrument quotes nothing it did not sample."

DEPLOYED_SHA="$(ssh_src 'cd /opt/barkpark && git rev-parse HEAD' | tr -d '[:space:]' || true)"
[ -n "$DEPLOYED_SHA" ] || DEPLOYED_SHA="unresolved"

MEM_AVAIL_KB="$(ssh_src "awk '/MemAvailable/{print \$2}' /proc/meminfo" | tr -d '[:space:]' || true)"
MEM_AVAIL_KB="${MEM_AVAIL_KB:-0}"
MEM_AVAIL_MB=$((MEM_AVAIL_KB / 1024))

info "deployed sha    $DEPLOYED_SHA"
info "MemAvailable    ${MEM_AVAIL_KB} kB = ${MEM_AVAIL_MB} MiB (floor read from PDS_FULL_EXPORT_MIN_MEM_MB=${FULL_MIN_MEM_MB}, never written here)"

# PDS-D31: two concurrent full exports OOM the box. The lock is the frozen
# harness's own, so this instrument and that harness are mutually exclusive.
mkdir -p "$FULL_DIR"
if mkdir "$FULL_LOCK" 2>/dev/null; then
  LOCK_OWNED=1
  info "lock            took $FULL_LOCK (shared with the frozen harness — PDS-D31)"
else
  refuse "$FULL_LOCK is held by another run. Two concurrent exports against this box OOM it (PDS-D31)."
fi

# READ-ONLY here. The ledger is not charged until window 2, below every refusal.
if [ "$FULL_ACQ" = yes ]; then
  info "attempt ledger  $(full_attempts) of $FULL_BUDGET spent so far · $FULL_ATTEMPTS_FILE (shared with the frozen harness)"
  info "                this acquisition is FULL-fidelity, so it will charge 1 attempt — written just before the request, never here"
  # This instrument RECORDS; the frozen harness's cond_c ENFORCES. That split is
  # deliberate (measuring must stay reachable), but "3 of 1 spent so far" said in
  # the same calm voice as "0 of 5" is the very defect the REFUSAL block below
  # exists to kill — an unusable number emitted as though it were usable. So the
  # over-budget case is stated OUT LOUD, at the last moment it can still be
  # cancelled by hand. Whether it should REFUSE is a policy call above this
  # script: pds-bl-peak-budget-enforcement.
  if [ "$(full_attempts)" -ge "$FULL_BUDGET" ]; then
    info ""
    info "                ⚠ OVER BUDGET — $(full_attempts) attempt(s) already spent against a budget of $FULL_BUDGET."
    info "                  The frozen harness's cond_c would REFUSE the crown climb in this state."
    info "                  This instrument does not enforce that gate, so it is ABOUT TO FIRE a"
    info "                  ~2.2 GiB export anyway and charge attempt $(( $(full_attempts) + 1 )). If that is not"
    info "                  what you want, interrupt now, or narrow the acquisition with"
    info "                  --path '/api/workspaces/$SOURCE_WS/export?profile=dev&dataset=production'."
    info "                  Raise the ceiling honestly with PDS_FULL_EXPORT_BUDGET; NEVER reset the"
    info "                  counter (PDS-D212)."
    info ""
  fi
else
  info "attempt ledger  $(full_attempts) of $FULL_BUDGET spent so far · $FULL_ATTEMPTS_FILE (read only)"
  info "                this acquisition is NARROWED, so it charges 0 attempts and leaves that file's value and mtime untouched"
fi

if [ "$FULL_ACQ" = yes ] && [ "$MEM_AVAIL_MB" -lt "$FULL_MIN_MEM_MB" ]; then
  refuse "a FULL-fidelity acquisition needs >= ${FULL_MIN_MEM_MB} MiB MemAvailable and the box has ${MEM_AVAIL_MB} MiB. Firing it anyway risks OOM-killing the LIVE content API. Re-run when the window opens, or narrow the acquisition with --path '/api/workspaces/$SOURCE_WS/export?profile=dev&dataset=production'."
fi

BEAM_PRIMARY="$(ssh_src 'pgrep -o -x beam.smp' | tr -d '[:space:]' || true)"
BEAM_ALL="$(ssh_src "pgrep -x beam.smp | tr '\n' ' '" | tr -s '[:space:]' ' ' || true)"
BEAM_N="$(printf '%s' "$BEAM_ALL" | wc -w | tr -d ' ')"
[ -n "$BEAM_PRIMARY" ] || refuse "no process on the source has comm == beam.smp. Nothing is quoted rather than sampling whatever a looser argv match happened to return (PDS-D135)."

info "beam slots      ${BEAM_N} comm-anchored: [${BEAM_ALL% }] · primary (oldest, \`pgrep -o -x\`) = $BEAM_PRIMARY"
say ""

# ── WINDOW 1 — THE IDLE CONTROL. Zero requests issued. ───────────────────────
#
# This is the half the frozen harness never had. Background BEAM drift alone
# swings hundreds of MiB with nothing asked of it; without this window a reader
# cannot tell the export's cost from the box's own weather.

rule
say "WINDOW 1 — IDLE CONTROL (${IDLE_SECONDS} s, ${SAMPLE_HZ} Hz, ZERO requests issued)"
rule

IDLE_BASELINE_KB="$(oneshot_rss_kb "$BEAM_PRIMARY")"
IDLE_BASELINE_KB="${IDLE_BASELINE_KB:-0}"
IDLE_BASELINE_SET_KB="$(oneshot_rss_set_kb)"
info "t=0 baseline    ${IDLE_BASELINE_KB} kB — one-shot \`ps -o rss= -p $BEAM_PRIMARY\` taken BEFORE the window (PDS-D185)"
info "                (diagnostic: max across all ${BEAM_N} slots at t=0 = ${IDLE_BASELINE_SET_KB} kB — see the header's asymmetry note)"

# PDS-BLIND-SPOT-METER: `date +%s`, WALL CLOCK around the sampling window in
# THIS shell. Placement is (a) of PDS-D633's law — an OS-level clock, outside
# every BEAM — and that is the ONLY placement available here, because the BEAM
# being measured is on ANOTHER HOST at the far end of an ssh. The unit is
# deliberately wall, not CPU: the figure exists to say how long the window that
# produced the peak actually ran, so a reader can pair the control window with
# the measured one. It is NOT a price and no CPU claim descends from it
# (PDS-D605 forbids a wall-clock second standing in for one; wall swung 2.5x on
# an unchanged census where user CPU moved 9%). Nothing here is a regression
# ratchet; if one is ever built the unit is `Process.info(pid, :reductions)`.
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
# on. Emitted, never enforced here — the measure slice applies the threshold.
IDLE_MEMAVAIL_SAMPLES="$(samples_in "$IDLE_MEM_LOG")"
IDLE_MEMAVAIL_MIN_KB="$(min_f2_of "$IDLE_MEM_LOG")"
IDLE_MEMAVAIL_MAX_KB="$(max_f2_of "$IDLE_MEM_LOG")"
IDLE_MEMAVAIL_RANGE_KB=$((IDLE_MEMAVAIL_MAX_KB - IDLE_MEMAVAIL_MIN_KB))
IDLE_MEMAVAIL_RANGE_MIB="$(mib "$IDLE_MEMAVAIL_RANGE_KB")"

info "peak            ${IDLE_PEAK_KB} kB (MAX over ${IDLE_SAMPLES} readings across ${BEAM_N} slot(s), ${IDLE_WALL} s wall)"

# ── PDS-D220a, APPLIED TO THE CONTROL WINDOW TOO ────────────────────────────
#
# The export window's zero-sample guard below was the defect this slice was
# chartered to fix. The IDLE window had the identical hole and the identical
# consequence: if its ssh sampler dies (dropped connection, remote loop killed)
# peak_kb_of() returns 0, the delta reads roughly −1142 MiB, and the run
# proceeds to the acquisition and EXITS 0 carrying a nonsense control.
#
# That is worse here than on the export leg, not better. This instrument exists
# to put a CONTROL beside the demand figure (PDS-D104, PDS-D216); a control the
# reader cannot distinguish from a failed sampler is the thing the instrument
# was built to prevent. Refuse before any figure is printed.
if [ "$IDLE_SAMPLES" -le 0 ]; then
  refuse "the IDLE CONTROL window logged ZERO samples over its ${IDLE_WALL} s, so there is no peak to subtract a baseline from. An empty log peaks at 0 kB, so the drift would have been reported as 0 − ${IDLE_BASELINE_KB} = ${IDLE_DELTA_KB} kB = $(mib "$IDLE_DELTA_KB") MiB. A NEGATIVE control is not a control (PDS-D220a — the same defect as the acquisition window's, on the leg that gives the demand figure its meaning). The RSS sampler almost certainly lost its ssh session; re-run."
fi

# The MemAvailable leg refuses on the same rule, for a sharper reason. Its
# range is what PDS-D221's 1048.16 MiB contamination-abort threshold is stated
# on, and a leg that logged nothing yields min 0 / max 0 / range 0.00 MiB —
# which reads to a threshold check as the QUIETEST POSSIBLE BOX and passes.
# A vacuous zero must never be able to authorise a measurement, so the sample
# count is enforced here rather than merely emitted for a downstream reader to
# remember to check.
if [ "$IDLE_MEMAVAIL_SAMPLES" -le 0 ]; then
  refuse "the idle window's MemAvailable leg logged ZERO samples, so its range is vacuously 0 kB = 0.00 MiB. PDS-D221 states its contamination-abort threshold (1048.16 MiB) on THIS range, and an unsampled leg would clear that threshold as though the box were perfectly quiet (PDS-D220a/PDS-D220b). A range that was never measured must not authorise a measurement; re-run."
fi

info "idle drift      ${IDLE_PEAK_KB} − ${IDLE_BASELINE_KB} = ${IDLE_DELTA_KB} kB = $(mib "$IDLE_DELTA_KB") MiB   [BEAM RSS]"
info "MemAvailable    min ${IDLE_MEMAVAIL_MIN_KB} kB · max ${IDLE_MEMAVAIL_MAX_KB} kB over ${IDLE_MEMAVAIL_SAMPLES} readings"
info "                range ${IDLE_MEMAVAIL_MAX_KB} − ${IDLE_MEMAVAIL_MIN_KB} = ${IDLE_MEMAVAIL_RANGE_KB} kB = ${IDLE_MEMAVAIL_RANGE_MIB} MiB   [WHOLE BOX]"
info "                this is the quantity PDS-D221's 1048.16 MiB threshold is stated on (PDS-D220b);"
info "                the BEAM-RSS drift above is a DIFFERENT unit class and the threshold does not attach to it."
info "                This instrument emits the range and does not abort on it — the measure slice applies it."
say ""

# ── WINDOW 2 — THE MEASURED ACQUISITION ──────────────────────────────────────

rule
say "WINDOW 2 — MEASURED ACQUISITION (${SAMPLE_HZ} Hz)"
rule

# PDS-D185: the baseline is re-taken HERE, strictly before the fire. Reusing
# window 1's baseline would fold the idle window's own drift into the export's
# delta — which is the very confound this instrument exists to separate.
EXPORT_BASELINE_KB="$(oneshot_rss_kb "$BEAM_PRIMARY")"
EXPORT_BASELINE_KB="${EXPORT_BASELINE_KB:-0}"
EXPORT_BASELINE_SET_KB="$(oneshot_rss_set_kb)"
info "t=0 baseline    ${EXPORT_BASELINE_KB} kB — one-shot \`ps -o rss= -p $BEAM_PRIMARY\` taken strictly BEFORE the request (PDS-D185)"
info "                NOT the sampler's first tick: that lands at t≈+1 s and already carries part of the export's own allocation"
info "                (diagnostic: max across all slots at t=0 = ${EXPORT_BASELINE_SET_KB} kB)"

# ── THE LEDGER IS CHARGED HERE: after every refusal, before the request ──────
#
# Everything that can refuse this run has already run and returned ABOVE this
# line — ssh reachability, the shared PDS-D31 lock, the MemAvailable floor, the
# beam.smp selector, and BOTH of window 1's PDS-D220a zero-sample guards. So a
# run that never fires never charges the ledger, which is the harness's
# discipline at pds-pull-proof.sh:1362 (return) vs :1367-1368 (spend), and the
# property criterion 4 proves by MUTATION rather than by a green.
#
# Below this line the box is about to be asked for ~2.2 GiB. From here the cost
# is paid whether or not the request completes, so from here the ledger says so.
if [ "$FULL_ACQ" = yes ]; then
  spend_full_attempt
else
  ATTEMPTS_AFTER="$(full_attempts)"
  info "attempt ledger  NOT charged — this acquisition is narrowed ($ACQ_PATH), not the full"
  info "                export the budget is stated on. Ledger stands at $ATTEMPTS_AFTER of $FULL_BUDGET, untouched."
fi

# Ticks are generous — the sampler is killed the moment the acquisition returns.
EXPORT_TICKS=$(( IDLE_SECONDS * 8 ))
if [ "$EXPORT_TICKS" -lt 120 ]; then EXPORT_TICKS=120; fi

EXPORT_T0="$(date +%s)"
start_sampler "$EXPORT_TICKS" "$EXPORT_LOG"
EXPORT_SAMPLER_PID="$SAMPLER_PID"
info "sampling        pid $EXPORT_SAMPLER_PID · firing GET $ACQ_PATH"

HTTP_CODE="$(curl -sS --max-time "${PDS_ACQ_TIMEOUT:-900}" \
  -H "Authorization: Bearer $SOURCE_TOKEN" \
  -o "$BODY_FILE" -w '%{http_code}' \
  "$SOURCE_BASE$ACQ_PATH" 2>/dev/null || true)"
# curl prints 000 AND exits non-zero on a connection failure; keep the last
# three digits so a doubled capture can never read as a valid code.
HTTP_CODE="$(printf '%s' "$HTTP_CODE" | tr -dc '0-9' | tail -c 3)"
HTTP_CODE="${HTTP_CODE:-000}"
EXPORT_T1="$(date +%s)"

kill "$EXPORT_SAMPLER_PID" 2>/dev/null || true
wait "$EXPORT_SAMPLER_PID" 2>/dev/null || true
EXPORT_SAMPLER_PID=""

EXPORT_PEAK_KB="$(peak_kb_of "$EXPORT_LOG")"
EXPORT_SAMPLES="$(samples_in "$EXPORT_LOG")"
EXPORT_WALL=$((EXPORT_T1 - EXPORT_T0))
EXPORT_DELTA_KB=$((EXPORT_PEAK_KB - EXPORT_BASELINE_KB))
BYTES="$(wc -c <"$BODY_FILE" 2>/dev/null | tr -d ' ' || echo 0)"

info "acquisition     HTTP $HTTP_CODE · ${BYTES} bytes · ${EXPORT_WALL} s"
pds_blind_spot_note \
  "date +%s, WALL CLOCK around each sampling window in this shell — an OS clock outside every BEAM (PDS-D633 placement (a)); the BEAM measured is on another host over ssh, so no in-BEAM meter exists here. A WINDOW LENGTH, never a price (PDS-D605)" \
  "the acquisition and control window lengths"

# ── PDS-D220a: a window with no samples has no peak to subtract from ─────────
#
# peak_kb_of() returns 0 for an empty log, and EXPORT_DELTA_KB subtracts the
# baseline from it unguarded. An acquisition that returns BEFORE the sampler's
# first ~1 s tick — a 404, a 500, a reset under memory pressure, which is
# exactly the regime this wave fires in — therefore produced
# `export_samples=0 export_peak_kb=0 export_delta_mib=-847.18` AND EXITED 0,
# feeding a NEGATIVE demand into the floor derivation as if it were a reading.
# Refuse instead. Nothing is quoted from a window that was never sampled.
if [ "$EXPORT_SAMPLES" -le 0 ]; then
  refuse "the acquisition window logged ZERO samples, so there is no peak to subtract a baseline from. GET $ACQ_PATH returned HTTP $HTTP_CODE after ${EXPORT_WALL} s — faster than the ${SAMPLE_HZ} Hz sampler's first tick — and an empty log peaks at 0 kB, so the delta would have been reported as 0 − ${EXPORT_BASELINE_KB} = ${EXPORT_DELTA_KB} kB = $(mib "$EXPORT_DELTA_KB") MiB. A NEGATIVE demand is not a measurement of anything (PDS-D220a). Re-run against an acquisition that lasts at least one sampler tick."
fi

info "peak            ${EXPORT_PEAK_KB} kB (MAX over ${EXPORT_SAMPLES} readings across ${BEAM_N} slot(s))"
info "export delta    ${EXPORT_PEAK_KB} − ${EXPORT_BASELINE_KB} = ${EXPORT_DELTA_KB} kB = $(mib "$EXPORT_DELTA_KB") MiB"
say ""

# ── how well paired are the two windows? ─────────────────────────────────────

if [ "$EXPORT_WALL" -eq "$IDLE_WALL" ]; then
  PAIRING="exact — both windows ran ${EXPORT_WALL} s at ${SAMPLE_HZ} Hz"
elif [ "$EXPORT_WALL" -gt "$IDLE_WALL" ]; then
  PAIRING="INEXACT — the measured window ran $((EXPORT_WALL - IDLE_WALL)) s LONGER than the control, so the control understates the drift the measured window could have accumulated"
else
  PAIRING="INEXACT — the control ran $((IDLE_WALL - EXPORT_WALL)) s LONGER than the measured window, so the control overstates the drift the measured window could have accumulated"
fi

if [ "$IDLE_WALL" -gt 0 ]; then
  IDLE_RATE="$(awk -v d="$IDLE_DELTA_KB" -v s="$IDLE_WALL" 'BEGIN { printf "%.2f", (d / 1024) / s }')"
else
  IDLE_RATE="0.00"
fi

# ── IS A FLOOR DERIVABLE FROM THIS RUN AT ALL? (PDS-D244) ───────────────────
#
# The instrument's whole job is to hand a floor derivation a number it can
# stand on. Two measured outcomes cannot do that, and BOTH were observed on the
# first real end-to-end run:
#
#   * a NON-POSITIVE delta. The scoped run measured 687904 − 695632 = −7728 kB
#     = −7.55 MiB. Memory did not go DOWN because of an export; the baseline
#     simply happened to be taken at a higher point than any sampler tick
#     reached. There is no demand in a negative number.
#
#   * a DRIFT-DOMINATED delta. That same −7.55 MiB sat beside a paired idle
#     control drifting +110.22 MiB — ~15x its magnitude, in the OPPOSITE
#     direction. When the box's own weather moves further than the thing being
#     measured, the measurement did not resolve the acquisition's cost, which
#     is exactly the confound PDS-D104 put the control there to expose.
#
# The report already explained how to read the pair. Explaining is not enough:
# `19.71 + 798.81` happened because an unusable number was emitted in the same
# voice as a usable one and someone downstream did the arithmetic anyway. So
# the run now states the verdict itself, in its own voice, and carries it in
# the machine line so a consumer can branch on it without re-deriving it.
#
# The EXIT CODE stays 0 deliberately. The measurement itself succeeded — these
# readings are real, and a run that refuses at the D220a guards (exit 2) sampled
# NOTHING, which is a different thing entirely. Conflating "I measured, and what
# I measured cannot bear a floor" with "I failed to measure" would throw away a
# valid control. The refusal is loud, machine-readable, and repeated at the tail.

EXPORT_DELTA_ABS_KB="$EXPORT_DELTA_KB"
if [ "$EXPORT_DELTA_ABS_KB" -lt 0 ]; then EXPORT_DELTA_ABS_KB=$(( 0 - EXPORT_DELTA_ABS_KB )); fi
IDLE_DELTA_ABS_KB="$IDLE_DELTA_KB"
if [ "$IDLE_DELTA_ABS_KB" -lt 0 ]; then IDLE_DELTA_ABS_KB=$(( 0 - IDLE_DELTA_ABS_KB )); fi

FLOOR_DERIVABLE=yes
FLOOR_REFUSAL_CODE=none
FLOOR_REFUSAL=""
if [ "$EXPORT_DELTA_KB" -le 0 ]; then
  FLOOR_DERIVABLE=no
  FLOOR_REFUSAL_CODE=non_positive_delta
  FLOOR_REFUSAL="the measured delta is ${EXPORT_DELTA_KB} kB = $(mib "$EXPORT_DELTA_KB") MiB, which is NOT POSITIVE, while the paired idle control drifted ${IDLE_DELTA_KB} kB = $(mib "$IDLE_DELTA_KB") MiB. An acquisition cannot demand a negative amount of memory: the peak simply never rose above the pre-fire baseline within the ${SAMPLE_HZ} Hz grid. There is no demand figure in this run to derive a floor from."
elif [ "$EXPORT_DELTA_ABS_KB" -le "$IDLE_DELTA_ABS_KB" ]; then
  FLOOR_DERIVABLE=no
  FLOOR_REFUSAL_CODE=drift_dominated
  FLOOR_REFUSAL="the measured delta is ${EXPORT_DELTA_KB} kB = $(mib "$EXPORT_DELTA_KB") MiB but the paired idle control — zero requests issued — drifted ${IDLE_DELTA_KB} kB = $(mib "$IDLE_DELTA_KB") MiB over its own window. The box's background weather moved at least as far as the thing being measured, so this run did NOT resolve the acquisition's own cost from the drift (PDS-D104). No floor may be derived from it."
fi

# ── verdict ──────────────────────────────────────────────────────────────────

rule
say "RESULT — both deltas, arithmetic stated, NOTHING silently subtracted"
rule
say ""
say "  MEASURED WINDOW (acquisition)"
say "    baseline t=0 ......... ${EXPORT_BASELINE_KB} kB   (one-shot ps, strictly pre-fire — PDS-D185)"
say "    peak ................. ${EXPORT_PEAK_KB} kB   (MAX across ${BEAM_N} slot(s), ${EXPORT_SAMPLES} readings)"
say "    delta ................ ${EXPORT_PEAK_KB} − ${EXPORT_BASELINE_KB} = ${EXPORT_DELTA_KB} kB / 1024 = $(mib "$EXPORT_DELTA_KB") MiB"
say "    window ............... ${EXPORT_WALL} s at ${SAMPLE_HZ} Hz · HTTP ${HTTP_CODE} · ${BYTES} bytes"
say ""
say "  PAIRED IDLE CONTROL (zero requests issued)"
say "    baseline t=0 ......... ${IDLE_BASELINE_KB} kB"
say "    peak ................. ${IDLE_PEAK_KB} kB   (MAX across ${BEAM_N} slot(s), ${IDLE_SAMPLES} readings)"
say "    drift [BEAM RSS] ..... ${IDLE_PEAK_KB} − ${IDLE_BASELINE_KB} = ${IDLE_DELTA_KB} kB / 1024 = $(mib "$IDLE_DELTA_KB") MiB"
say "    window ............... ${IDLE_WALL} s at ${SAMPLE_HZ} Hz · rate ${IDLE_RATE} MiB/s"
say "    pairing .............. ${PAIRING}"
say ""
say "    MemAvailable, WHOLE BOX (a different unit class — PDS-D220b)"
say "      min ................ ${IDLE_MEMAVAIL_MIN_KB} kB   over ${IDLE_MEMAVAIL_SAMPLES} readings"
say "      max ................ ${IDLE_MEMAVAIL_MAX_KB} kB"
say "      range .............. ${IDLE_MEMAVAIL_MAX_KB} − ${IDLE_MEMAVAIL_MIN_KB} = ${IDLE_MEMAVAIL_RANGE_KB} kB / 1024 = ${IDLE_MEMAVAIL_RANGE_MIB} MiB"
say "      PDS-D221 states its contamination-abort threshold (1048.16 MiB) on THIS"
say "      range, not on the BEAM-RSS drift above. This instrument emits the number"
say "      and stops there; applying the threshold is the measure slice's call."
say ""
say "  HOW TO READ THESE TWO NUMBERS"
say "    The reported demand is the MEASURED delta, $(mib "$EXPORT_DELTA_KB") MiB. The control is"
say "    printed BESIDE it, not subtracted from it: $(mib "$IDLE_DELTA_KB") MiB of the measured"
say "    delta could be background drift rather than the acquisition's own cost."
say "    A control that is a large fraction of the measured delta means the"
say "    measurement is drift-dominated and the acquisition's cost is not"
say "    resolved by this instrument. A control near zero means the measured"
say "    delta is the acquisition's."
say "    Both figures are kB/1024 (MiB), never /1000, and both are LOWER BOUNDS:"
say "    a spike between 1 Hz ticks is invisible (PDS-D114) — the safe direction."
say ""
say "  COMPARABILITY TO THE CANONICAL 2235.43 MiB"
say "    Canonical: (2,483,304 − 194,228) kB / 1024 = 2235.43 MiB, taken by the"
say "    FROZEN harness (blob e219e97ccf7f33797c86a2b84d998d599b6bda31) with this"
say "    same selector, same rate, same units, same one-shot pre-fire baseline,"
say "    and the same absence of compression. This run is comparable ONLY if its"
say "    acquisition is the same one: GET /api/workspaces/<ws>/export with no"
say "    profile narrowing. This run's acquisition was:"
say "      $ACQ_PATH   (full-fidelity? $FULL_ACQ)"
say ""
if [ "$FULL_ACQ" = no ]; then
  say "    This acquisition was NARROWED, so it is NOT comparable to 2235.43 MiB in any"
  say "    case: it measures a different, smaller export. Nothing here may be placed"
  say "    beside the canonical figure, and nothing may be subtracted from it."
  say ""
fi

# ── the derivability verdict, in the instrument's own voice ─────────────────
if [ "$FLOOR_DERIVABLE" = no ]; then
  say "  ┌──────────────────────────────────────────────────────────────────────────┐"
  say "  │ REFUSAL — NO FLOOR MAY BE DERIVED FROM THIS RUN                           │"
  say "  └──────────────────────────────────────────────────────────────────────────┘"
  say "    reason ($FLOOR_REFUSAL_CODE):"
  printf '      %s\n' "$FLOOR_REFUSAL" | fold -s -w 72 | sed 's/^/  /'
  say ""
  say "    The readings above are REAL and are reported in full — this run sampled"
  say "    ${EXPORT_SAMPLES} export readings and ${IDLE_SAMPLES} control readings, and it is not"
  say "    hiding them. What it refuses is the NEXT step: this pair of numbers may"
  say "    not be turned into a memory floor, quoted as an export's demand, or added"
  say "    to any other figure. Re-run when the control window is quiet relative to"
  say "    the acquisition, against an acquisition that actually moves the BEAM."
  say ""
  say "    Machine consumers: branch on floor_derivable=no in the line below rather"
  say "    than on the exit code — the measurement SUCCEEDED (exit 0); it is the"
  say "    derivation that is refused. Exit 2 means a window was never sampled at all."
else
  say "  FLOOR DERIVABILITY"
  say "    The measured delta $(mib "$EXPORT_DELTA_KB") MiB is positive and exceeds the paired"
  say "    control's drift of $(mib "$IDLE_DELTA_KB") MiB, so this run resolves an acquisition"
  say "    cost above the box's own weather. It is still a LOWER BOUND (PDS-D114),"
  say "    and the control is context beside it, never subtracted from it."
fi
say ""

MACHINE_LINE="PDS_PEAK_MEASURE run_id=$RUN_ID label=$LABEL deployed_sha=$DEPLOYED_SHA source=$SOURCE_BASE workspace=$SOURCE_WS acq_path=$ACQ_PATH full_acquisition=$FULL_ACQ http_code=$HTTP_CODE bytes=$BYTES sample_hz=$SAMPLE_HZ units=kB_div_1024 compression=none selector=pgrep_-o_-x_beam.smp peak_rule=max_across_slots beam_primary_pid=$BEAM_PRIMARY beam_slot_pids=${BEAM_ALL% } beam_slots=$BEAM_N mem_available_kb=$MEM_AVAIL_KB floor_mb=$FULL_MIN_MEM_MB export_baseline_kb=$EXPORT_BASELINE_KB export_peak_kb=$EXPORT_PEAK_KB export_delta_kb=$EXPORT_DELTA_KB export_delta_mib=$(mib "$EXPORT_DELTA_KB") export_samples=$EXPORT_SAMPLES export_window_s=$EXPORT_WALL export_baseline_set_kb=$EXPORT_BASELINE_SET_KB idle_baseline_kb=$IDLE_BASELINE_KB idle_peak_kb=$IDLE_PEAK_KB idle_delta_kb=$IDLE_DELTA_KB idle_delta_mib=$(mib "$IDLE_DELTA_KB") idle_samples=$IDLE_SAMPLES idle_window_s=$IDLE_WALL idle_drift_mib_per_s=$IDLE_RATE idle_baseline_set_kb=$IDLE_BASELINE_SET_KB idle_memavail_min_kb=$IDLE_MEMAVAIL_MIN_KB idle_memavail_max_kb=$IDLE_MEMAVAIL_MAX_KB idle_memavail_range_kb=$IDLE_MEMAVAIL_RANGE_KB idle_memavail_range_mib=$IDLE_MEMAVAIL_RANGE_MIB idle_memavail_samples=$IDLE_MEMAVAIL_SAMPLES canonical_reference_mib=2235.43 full_attempt_charged=$ATTEMPT_CHARGED attempts_after=${ATTEMPTS_AFTER:-unknown} attempts_budget=$FULL_BUDGET floor_derivable=$FLOOR_DERIVABLE floor_refusal=$FLOOR_REFUSAL_CODE"

say "$MACHINE_LINE"
say ""
if [ -n "$OUT_FILE" ]; then
  printf '%s\n' "$MACHINE_LINE" >"$OUT_FILE"
  info "machine line also written to $OUT_FILE"
fi

if [ "$HTTP_CODE" != "200" ]; then
  say ""
  say "  NOTE: the acquisition returned HTTP $HTTP_CODE, not 200. The RSS figures above"
  say "  are real readings, but they describe a FAILED acquisition — a dead export"
  say "  still pays its memory peak, and this instrument reports what it sampled"
  say "  rather than hiding a non-200 behind a plausible-looking number."
fi

if [ "$ATTEMPT_CHARGED" = yes ]; then
  say ""
  say "  LEDGER: this run charged 1 FULL-export attempt — $FULL_ATTEMPTS_FILE now reads"
  say "  $ATTEMPTS_AFTER of $FULL_BUDGET. That file is shared with the frozen harness, whose cond_c"
  say "  gate reads it before the crown climb fires. Resetting it is FORBIDDEN (PDS-D212)."
fi

# The last thing a reader or a `tail` sees must be the refusal, not a number.
if [ "$FLOOR_DERIVABLE" = no ]; then
  say ""
  say "  REFUSED ($FLOOR_REFUSAL_CODE): no floor may be derived from this run. See the"
  say "  REFUSAL block above for the delta, the control drift, and why. The exit code"
  say "  is 0 because the measurement itself succeeded."
fi

exit 0
