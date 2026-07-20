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
# EXIT: 0 measured · 2 refused by a precondition · 3 misconfigured.

set -eu

# A decimal COMMA is not a number this instrument may emit. Under a comma
# locale `awk 'printf "%.2f"'` renders 115.46 as "115,46", which silently
# corrupts every MiB figure in the machine-readable line and makes the headline
# uncomparable to 2235.43. Caught by running it, not by reading it.
LC_ALL=C
export LC_ALL

SELF="$(basename "$0")"

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

SAMPLE_HZ=1                       # stated in the output; see PDS-D114
IDLE_SECONDS=130                  # the canonical export's wall time
ACQ_PATH=""
LABEL="unlabelled"
OUT_FILE=""

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pds-peak.XXXXXX")"
IDLE_LOG="$WORK_DIR/idle-rss.log"
EXPORT_LOG="$WORK_DIR/export-rss.log"
BODY_FILE="$WORK_DIR/acquired.bin"

say()  { printf '%s\n' "$*"; }
info() { printf '      %s\n' "$*"; }
rule() { printf -- '─%.0s' $(seq 1 78); printf '\n'; }
die()  { printf '%s: %s\n' "$SELF" "$*" >&2; exit 3; }
refuse() { printf '%s: REFUSED — %s\n' "$SELF" "$*" >&2; exit 2; }

IDLE_SAMPLER_PID=""
EXPORT_SAMPLER_PID=""
cleanup() {
  [ -n "$IDLE_SAMPLER_PID" ] && kill "$IDLE_SAMPLER_PID" 2>/dev/null || true
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

peak_kb_of()    { awk '{ if ($3+0 > m) m = $3+0 } END { print m+0 }' "$1" 2>/dev/null || echo 0; }
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

IDLE_T0="$(date +%s)"
start_sampler "$IDLE_SECONDS" "$IDLE_LOG"
IDLE_SAMPLER_PID="$SAMPLER_PID"
info "sampling        pid $IDLE_SAMPLER_PID · issuing NOTHING for ${IDLE_SECONDS} s"
wait "$IDLE_SAMPLER_PID" 2>/dev/null || true
IDLE_SAMPLER_PID=""
IDLE_T1="$(date +%s)"

IDLE_PEAK_KB="$(peak_kb_of "$IDLE_LOG")"
IDLE_SAMPLES="$(samples_in "$IDLE_LOG")"
IDLE_WALL=$((IDLE_T1 - IDLE_T0))
IDLE_DELTA_KB=$((IDLE_PEAK_KB - IDLE_BASELINE_KB))

info "peak            ${IDLE_PEAK_KB} kB (MAX over ${IDLE_SAMPLES} readings across ${BEAM_N} slot(s), ${IDLE_WALL} s wall)"
info "idle drift      ${IDLE_PEAK_KB} − ${IDLE_BASELINE_KB} = ${IDLE_DELTA_KB} kB = $(mib "$IDLE_DELTA_KB") MiB"
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
say "    drift ................ ${IDLE_PEAK_KB} − ${IDLE_BASELINE_KB} = ${IDLE_DELTA_KB} kB / 1024 = $(mib "$IDLE_DELTA_KB") MiB"
say "    window ............... ${IDLE_WALL} s at ${SAMPLE_HZ} Hz · rate ${IDLE_RATE} MiB/s"
say "    pairing .............. ${PAIRING}"
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

MACHINE_LINE="PDS_PEAK_MEASURE run_id=$RUN_ID label=$LABEL deployed_sha=$DEPLOYED_SHA source=$SOURCE_BASE workspace=$SOURCE_WS acq_path=$ACQ_PATH full_acquisition=$FULL_ACQ http_code=$HTTP_CODE bytes=$BYTES sample_hz=$SAMPLE_HZ units=kB_div_1024 compression=none selector=pgrep_-o_-x_beam.smp peak_rule=max_across_slots beam_primary_pid=$BEAM_PRIMARY beam_slot_pids=${BEAM_ALL% } beam_slots=$BEAM_N mem_available_kb=$MEM_AVAIL_KB floor_mb=$FULL_MIN_MEM_MB export_baseline_kb=$EXPORT_BASELINE_KB export_peak_kb=$EXPORT_PEAK_KB export_delta_kb=$EXPORT_DELTA_KB export_delta_mib=$(mib "$EXPORT_DELTA_KB") export_samples=$EXPORT_SAMPLES export_window_s=$EXPORT_WALL export_baseline_set_kb=$EXPORT_BASELINE_SET_KB idle_baseline_kb=$IDLE_BASELINE_KB idle_peak_kb=$IDLE_PEAK_KB idle_delta_kb=$IDLE_DELTA_KB idle_delta_mib=$(mib "$IDLE_DELTA_KB") idle_samples=$IDLE_SAMPLES idle_window_s=$IDLE_WALL idle_drift_mib_per_s=$IDLE_RATE idle_baseline_set_kb=$IDLE_BASELINE_SET_KB canonical_reference_mib=2235.43"

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

exit 0
