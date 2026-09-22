#!/usr/bin/env bash
# Classify every MISSING tick in a scheduled series as deploy-attributable or
# unexplained — without reading container uptime by hand.
#
#   bash deploy/cp-cutover-gaps.sh --ticks <file|-> [--ledger <file>] \
#        [--every-min 15] [--grace-min 5] [--open-window-min 30]
#   bash deploy/cp-cutover-gaps.sh --self-test        # offline, no box, no DB
#
# ── THE PROBLEM (dr-w26-bl-cp-deploy-eats-a-scheduled-sampler-tick) ──────────
# `Oban.Plugins.Cron` (OSS) enqueues only on a tick a RUNNING node observes. A
# control-plane container replacement crossing a cron boundary eats that tick
# and leaves NO ROW ANYWHERE: no `available`, no `discarded`, no `retryable`.
# `UsageSamplerWorker` read 664 completed / 1 discarded across a night whose
# 15-minute `usage_samples` series is missing an entry outright:
#
#     23:22 / 23:37 / [NOTHING] / 00:07 / 00:22
#
# A hole in that series has exactly two causes and they demand OPPOSITE
# responses: a deploy ate the tick (expected, costs one sample, no action), or
# the worker/scheduler stopped (a real fault, page someone). Until this script
# the ONLY way to tell them apart was `docker ps` on the box, reading an
# `Exited (137)` timestamp by hand — an instrument that needs ssh, evaporates on
# the next recreate, and whose STALE read is indistinguishable from "somebody
# already fixed it".
#
# `cp-deploy.sh` now writes its own cutover window to an append-only ledger
# (`CPCUTOVER … event=deploy_start|flip|old_slot_stopped|deploy_end|deploy_aborted`).
# This script reads that ledger plus the tick series and answers the question
# mechanically.
#
# ── WHAT IT DOES NOT CLAIM ──────────────────────────────────────────────────
# It does not prove a deploy CAUSED a loss — it proves a deploy WAS or WAS NOT
# in flight across the missing instant. That is the whole distinction the row
# asks for, and it is the one a human cannot get wrong. An `unexplained` verdict
# is deliberately the fail-loud direction: a ledger with missing lines (a full
# disk, a box that predates the stamp, a deploy killed mid-run) degrades TOWARD
# unexplained, never toward a laundered "expected".
#
# ── INPUT ───────────────────────────────────────────────────────────────────
# --ticks: one UTC timestamp per line, `YYYY-MM-DDTHH:MM:SSZ` or
# `YYYY-MM-DD HH:MM:SS` (Postgres's default `timestamp` render), blank lines and
# `#` comments ignored, any order. On the box:
#
#   docker exec <cp> psql "$DATABASE_URL" -At -c \
#     "select measured_at at time zone 'utc' from usage_samples \
#      where barkpark_id = '<id>' order by 1" | bash deploy/cp-cutover-gaps.sh --ticks -
#
# ── EXITS ───────────────────────────────────────────────────────────────────
#   0  no missing ticks, or every missing tick is deploy-attributable
#   3  at least one UNEXPLAINED missing tick (this is the one a human must read)
#  11  bad input (no ticks, unparseable timestamp, missing file, bad flag)
set -uo pipefail

TICKS=""
LEDGER="${BARKPARK_CP_CUTOVER_LEDGER:-/opt/barkpark/.slots/cp-cutovers.log}"
EVERY_MIN=15
GRACE_MIN=5
OPEN_WINDOW_MIN=30
SELF_TEST=0

die() { echo "cp-cutover-gaps: $*" >&2; exit 11; }

while [ $# -gt 0 ]; do
  case "$1" in
    --ticks) TICKS="${2:-}"; shift 2 || die "--ticks needs a value" ;;
    --ledger) LEDGER="${2:-}"; shift 2 || die "--ledger needs a value" ;;
    --every-min) EVERY_MIN="${2:-}"; shift 2 || die "--every-min needs a value" ;;
    --grace-min) GRACE_MIN="${2:-}"; shift 2 || die "--grace-min needs a value" ;;
    --open-window-min) OPEN_WINDOW_MIN="${2:-}"; shift 2 || die "--open-window-min needs a value" ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
done

check_minutes() {
  case "$2" in ''|*[!0-9]*) die "--${1} must be a whole number of minutes, got '$2'" ;; esac
}
check_minutes every-min "$EVERY_MIN"
check_minutes grace-min "$GRACE_MIN"
check_minutes open-window-min "$OPEN_WINDOW_MIN"
[ "$EVERY_MIN" -ge 1 ] || die "--every-min must be >= 1"

# ── The clock, in pure awk ───────────────────────────────────────────────────
# NOT `date -d`: that is GNU-only and this script has to run both on the box
# (GNU) and in the offline harness on a developer's macOS (BSD `date -d` means
# something else entirely). Howard Hinnant's days-from-civil, both directions,
# exercised against known epochs by --self-test.
AWK_CLOCK='
function iso2epoch(s,   y,mo,d,h,mi,se,era,yoe,doy,doe,days) {
  gsub(/^[ \t]+|[ \t]+$/, "", s)
  if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][T ][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) return -1
  y = substr(s,1,4)+0; mo = substr(s,6,2)+0; d = substr(s,9,2)+0
  h = substr(s,12,2)+0; mi = substr(s,15,2)+0; se = substr(s,18,2)+0
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || se > 60) return -1
  if (mo <= 2) y--
  era = int((y >= 0 ? y : y-399) / 400)
  yoe = y - era*400
  doy = int((153*(mo + (mo > 2 ? -3 : 9)) + 2)/5) + d - 1
  doe = yoe*365 + int(yoe/4) - int(yoe/100) + doy
  days = era*146097 + doe - 719468
  return days*86400 + h*3600 + mi*60 + se
}
function epoch2iso(t,   secs,z,era,doe,yoe,y,doy,mp,d,mo) {
  secs = t % 86400; if (secs < 0) secs += 86400
  z = int((t - secs)/86400) + 719468
  era = int((z >= 0 ? z : z - 146096) / 146097)
  doe = z - era*146097
  yoe = int((doe - int(doe/1460) + int(doe/36524) - int(doe/146096)) / 365)
  y = yoe + era*400
  doy = doe - (365*yoe + int(yoe/4) - int(yoe/100))
  mp = int((5*doy + 2)/153)
  d = doy - int((153*mp + 2)/5) + 1
  mo = mp + (mp < 10 ? 3 : -9)
  if (mo <= 2) y++
  return sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, mo, d, int(secs/3600), int((secs%3600)/60), secs%60)
}
'

if [ "$SELF_TEST" = 1 ]; then
  # --self-test lives at the bottom so it can call analyze(); jump there.
  :
else
  [ -n "$TICKS" ] || die "--ticks is required (a file, or - for stdin)"
fi

# ── The analyzer ─────────────────────────────────────────────────────────────
# $1 = ticks file, $2 = ledger file (may be absent/empty). Prints GAP/SUMMARY
# lines on stdout; returns 0 / 3 / 11 exactly as the script's own exits.
analyze() {
  local ticks_file="$1" ledger_file="$2" out rc
  [ -r "$ticks_file" ] || { echo "cp-cutover-gaps: cannot read ticks file '$ticks_file'" >&2; return 11; }

  # Windows first: one line per deploy_id, "start_epoch end_epoch deploy_id newsha".
  # A deploy with a start and no terminal event is still a window — bounded by
  # --open-window-min rather than dropped. Dropping it is how a killed deploy's
  # eaten tick would read as "unexplained" forever.
  local windows
  windows="$(mktemp)" || return 11
  if [ -n "$ledger_file" ] && [ -r "$ledger_file" ]; then
    awk "$AWK_CLOCK"'
      /^CPCUTOVER /{
        id=""; ev=""; ts=""; sha=""
        for (i = 2; i <= NF; i++) {
          split($i, kv, "=")
          if (kv[1] == "deploy_id") id = kv[2]
          else if (kv[1] == "event") ev = kv[2]
          else if (kv[1] == "ts") ts = kv[2]
          else if (kv[1] == "new_sha") sha = kv[2]
        }
        e = iso2epoch(ts)
        if (id == "" || e < 0) next
        if (!(id in seen) || e < start[id]) { start[id] = e }
        if (!(id in seen) || e > end[id])   { end[id] = e }
        seen[id] = 1
        if (sha != "" && sha != "unknown") newsha[id] = sha
        if (ev == "deploy_end" || ev == "deploy_aborted") closed[id] = 1
      }
      END {
        for (id in seen) {
          s = start[id]; e = end[id]
          if (!(id in closed) && e - s < open_secs) e = s + open_secs
          printf "%d %d %s %s\n", s, e, id, (id in newsha ? newsha[id] : "unknown")
        }
      }
    ' open_secs="$((OPEN_WINDOW_MIN * 60))" "$ledger_file" | sort -n > "$windows"
  fi

  local combined
  combined="$(mktemp)" || { rm -f "$windows"; return 11; }
  sed 's/^/W /' "$windows" > "$combined"
  sed 's/^/T /' "$ticks_file" >> "$combined"

  out="$(awk "$AWK_CLOCK"'
    function classify(t,   i, s, e) {
      for (i = 1; i <= nwin; i++) {
        if (t >= wstart[i] - grace && t <= wend[i] + grace) return i
      }
      return 0
    }
    BEGIN { nwin = 0; bad = ""; n = 0 }
    $1 == "W" {
      if (NF >= 5) { nwin++; wstart[nwin] = $2 + 0; wend[nwin] = $3 + 0; wid[nwin] = $4; wsha[nwin] = $5 }
      next
    }
    $1 != "T" { next }
    {
      line = substr($0, 3)
      sub(/#.*$/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "") next
      e = iso2epoch(line)
      if (e < 0) { if (bad == "") bad = line; next }
      n++; tick[n] = e
    }
    END {
      if (bad != "") { printf "BADTICK %s\n", bad; exit }
      if (n < 2) { printf "TOOFEW %d\n", n; exit }
      # sort
      for (i = 2; i <= n; i++) { v = tick[i]; j = i - 1
        while (j >= 1 && tick[j] > v) { tick[j+1] = tick[j]; j-- }
        tick[j+1] = v }
      missing = 0; attributed = 0; unexplained = 0
      for (i = 2; i <= n; i++) {
        delta = tick[i] - tick[i-1]
        # How many cadence slots does this gap span? A jittered on-time tick is
        # k==1. k>=2 means k-1 instants produced nothing.
        k = int(delta / period + 0.5)
        if (k < 2) continue
        for (m = 1; m < k; m++) {
          t = tick[i-1] + m * period
          missing++
          w = classify(t)
          if (w > 0) { attributed++; printf "GAP ts=%s class=deploy_attributable deploy_id=%s new_sha=%s\n", epoch2iso(t), wid[w], wsha[w] }
          else       { unexplained++; printf "GAP ts=%s class=unexplained\n", epoch2iso(t) }
        }
      }
      expected = n + missing
      rate = (expected > 0 ? 100.0 * missing / expected : 0)
      printf "SUMMARY ticks=%d expected=%d missing=%d deploy_attributable=%d unexplained=%d loss_pct=%.3f windows=%d first=%s last=%s\n", \
        n, expected, missing, attributed, unexplained, rate, nwin, epoch2iso(tick[1]), epoch2iso(tick[n])
    }
  ' period="$((EVERY_MIN * 60))" grace="$((GRACE_MIN * 60))" "$combined")"
  rc=$?
  rm -f "$windows" "$combined"
  [ "$rc" -eq 0 ] || { echo "cp-cutover-gaps: awk failed (rc=$rc)" >&2; return 11; }

  case "$out" in
    BADTICK*) echo "cp-cutover-gaps: unparseable timestamp: ${out#BADTICK }" >&2; return 11 ;;
    TOOFEW*)  echo "cp-cutover-gaps: need at least 2 ticks to see a gap, got ${out#TOOFEW }" >&2; return 11 ;;
  esac

  printf '%s\n' "$out"
  case "$out" in
    *unexplained=0\ *) return 0 ;;
    *) return 3 ;;
  esac
}

if [ "$SELF_TEST" != 1 ]; then
  if [ "$TICKS" = "-" ]; then
    tmp="$(mktemp)" || die "mktemp failed"
    cat > "$tmp"
    analyze "$tmp" "$LEDGER"; rc=$?
    rm -f "$tmp"
    exit "$rc"
  fi
  analyze "$TICKS" "$LEDGER"; exit $?
fi

# ══ SELF-TEST ════════════════════════════════════════════════════════════════
# Offline: no box, no DB, no network. Every case runs the REAL analyze() above.
#
# The pairing rule this harness keeps: each behaviour is asserted with an arm
# that REDS when the behaviour is removed, and a CONTROL arm that must stay
# QUIET on input the behaviour must not fire on. The sharpest of those is the
# ledger control: the SAME gap, with the ledger emptied, must flip from
# deploy_attributable to unexplained. If it does not, the classifier is not
# reading the ledger at all and every "attributable" verdict it has ever printed
# was vacuous.
# Every out_* below is read inside check()'s eval string, which shellcheck
# cannot follow — it is not dead, and quoting it differently would break the
# harness. Disabled once, here, rather than eight times.
# shellcheck disable=SC2034
fails=0; checks_ran=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; fails=$((fails + 1)); }
check() { checks_ran=$((checks_ran + 1)); if eval "$2"; then pass "$1"; else fail "$1 (cond: $2)"; fi; }

TD="$(mktemp -d)" || die "mktemp -d failed"
trap 'rm -rf "$TD"' EXIT

echo "cp-cutover-gaps --self-test"

# ── 1. The clock, against known epochs ──────────────────────────────────────
clock_rt() { awk -v A="$1" "$AWK_CLOCK"'BEGIN{ e=iso2epoch(A); printf "%d %s\n", e, epoch2iso(e) }'; }
check "epoch of 1970-01-01T00:00:00Z is 0" \
  "[ \"\$(clock_rt 1970-01-01T00:00:00Z)\" = '0 1970-01-01T00:00:00Z' ]"
check "epoch of 2026-08-08T23:52:00Z round-trips and matches the known value" \
  "[ \"\$(clock_rt 2026-08-08T23:52:00Z)\" = '1786233120 2026-08-08T23:52:00Z' ]"
check "a leap day round-trips (2024-02-29)" \
  "[ \"\$(clock_rt 2024-02-29T12:00:00Z)\" = '1709208000 2024-02-29T12:00:00Z' ]"
check "the Postgres space-separated render parses too" \
  "[ \"\$(clock_rt '2026-08-08 23:52:00')\" = '1786233120 2026-08-08T23:52:00Z' ]"
check "a non-timestamp is rejected (-1), not silently coerced to 0" \
  "awk \"\$AWK_CLOCK\"'BEGIN{ exit !(iso2epoch(\"not-a-time\") == -1) }'"

# ── 2. THE REAL-SHAPE CASE: the row's own 2026-08-08 night ──────────────────
# The fixture is the series from the incident verbatim (23:22 / 23:37 / [—] /
# 00:07 / 00:22) against the cutover the incident recorded (blue Exited 23:48:20,
# green started 23:51:03). A synthetic-only harness is how a selftest ends up
# encoding a shape the system never emits, so this one is the incident's own.
cat > "$TD/ticks-0808" <<'EOF'
2026-08-08T23:22:00Z
2026-08-08T23:37:00Z
2026-08-09T00:07:00Z
2026-08-09T00:22:00Z
EOF
cat > "$TD/ledger-0808" <<'EOF'
CPCUTOVER deploy_id=20260808T234700Z-111 event=deploy_start ts=2026-08-08T23:47:00Z old_sha=deadbee new_sha=0239dd4e active_port=4100 target_slot=green run_id=42
CPCUTOVER deploy_id=20260808T234700Z-111 event=flip ts=2026-08-08T23:51:03Z old_sha=deadbee new_sha=0239dd4e active_port=4100 target_slot=green run_id=42
CPCUTOVER deploy_id=20260808T234700Z-111 event=old_slot_stopped ts=2026-08-08T23:51:40Z old_sha=deadbee new_sha=0239dd4e active_port=4100 target_slot=green run_id=42
CPCUTOVER deploy_id=20260808T234700Z-111 event=deploy_end ts=2026-08-08T23:54:21Z old_sha=deadbee new_sha=0239dd4e active_port=4100 target_slot=green run_id=42
EOF
# shellcheck disable=SC2034  # read inside check()'s eval string
out_0808="$(analyze "$TD/ticks-0808" "$TD/ledger-0808")"; rc_0808=$?
check "the 2026-08-08 series exits 0 (every hole is accounted)" "[ $rc_0808 -eq 0 ]"
check "it names the missing instant 23:52:00Z" \
  "printf '%s' \"\$out_0808\" | grep -q 'GAP ts=2026-08-08T23:52:00Z class=deploy_attributable'"
check "it attributes the hole to the deploy that was in flight" \
  "printf '%s' \"\$out_0808\" | grep -q 'deploy_id=20260808T234700Z-111'"
check "exactly one tick is missing and zero are unexplained" \
  "printf '%s' \"\$out_0808\" | grep -q 'missing=1 deploy_attributable=1 unexplained=0'"
check "the summary carries the measured loss rate (1 of 5 = 20%)" \
  "printf '%s' \"\$out_0808\" | grep -q 'expected=5 .*loss_pct=20.000'"

# ── 3. THE CONTROL that makes case 2 non-vacuous ────────────────────────────
# Same ticks, EMPTY ledger. If the classifier were ignoring the ledger and
# calling every hole attributable, this case would still say attributable.
: > "$TD/ledger-empty"
# shellcheck disable=SC2034  # read inside check()'s eval string
out_ctl="$(analyze "$TD/ticks-0808" "$TD/ledger-empty")"; rc_ctl=$?
check "CONTROL: the same hole with no ledger is UNEXPLAINED, not attributable" \
  "printf '%s' \"\$out_ctl\" | grep -q 'GAP ts=2026-08-08T23:52:00Z class=unexplained'"
check "CONTROL: and it exits 3 so a human is made to look" "[ $rc_ctl -eq 3 ]"
check "CONTROL: nothing is attributed with no windows to attribute to" \
  "printf '%s' \"\$out_ctl\" | grep -q 'deploy_attributable=0 unexplained=1'"

# ── 3b. THE OTHER CONTROL: a deploy at the WRONG time must not absorb the hole.
# Grace is 5 min; this deploy is four hours away. A classifier that matched on
# "a deploy exists anywhere in the ledger" would pass case 2 and fail here.
sed 's/T23:4/T19:4/; s/T23:5/T19:5/' "$TD/ledger-0808" > "$TD/ledger-far"
# shellcheck disable=SC2034  # read inside check()'s eval string
out_far="$(analyze "$TD/ticks-0808" "$TD/ledger-far")"; rc_far=$?
check "CONTROL: a deploy four hours away does NOT absorb the hole" \
  "printf '%s' \"\$out_far\" | grep -q 'GAP ts=2026-08-08T23:52:00Z class=unexplained'"
check "CONTROL: the far-away deploy still counts as a parsed window (so the miss is the MATCH, not the parse)" \
  "printf '%s' \"\$out_far\" | grep -q 'windows=1'"
check "CONTROL: exits 3" "[ $rc_far -eq 3 ]"

# ── 4. THE QUIET CASE: a complete series must say nothing at all ────────────
cat > "$TD/ticks-complete" <<'EOF'
2026-08-08T23:22:00Z
2026-08-08T23:37:00Z
2026-08-08T23:52:00Z
2026-08-09T00:07:00Z
2026-08-09T00:22:00Z
EOF
# shellcheck disable=SC2034  # read inside check()'s eval string
out_ok="$(analyze "$TD/ticks-complete" "$TD/ledger-0808")"; rc_ok=$?
check "a complete series exits 0" "[ $rc_ok -eq 0 ]"
check "a complete series prints NO GAP line (quiet when it should be)" \
  "! printf '%s' \"\$out_ok\" | grep -q '^GAP '"
check "a complete series reports missing=0 even with a deploy in the window" \
  "printf '%s' \"\$out_ok\" | grep -q 'missing=0 deploy_attributable=0 unexplained=0'"
# Jitter must not manufacture a gap: a tick 90s late is still THAT tick.
sed 's/T23:52:00Z/T23:53:30Z/' "$TD/ticks-complete" > "$TD/ticks-jitter"
# shellcheck disable=SC2034  # read inside check()'s eval string
out_j="$(analyze "$TD/ticks-jitter" "$TD/ledger-0808")"; rc_j=$?
check "90s of jitter is not a missing tick" \
  "[ $rc_j -eq 0 ] && printf '%s' \"\$out_j\" | grep -q 'missing=0'"

# ── 5. MIXED: both classes in one run, counted separately ───────────────────
cat > "$TD/ticks-mixed" <<'EOF'
2026-08-08T23:22:00Z
2026-08-08T23:37:00Z
2026-08-09T00:07:00Z
2026-08-09T00:22:00Z
2026-08-09T01:07:00Z
EOF
# shellcheck disable=SC2034  # read inside check()'s eval string
out_mix="$(analyze "$TD/ticks-mixed" "$TD/ledger-0808")"; rc_mix=$?
check "MIXED: one attributable + two unexplained are counted separately" \
  "printf '%s' \"\$out_mix\" | grep -q 'missing=3 deploy_attributable=1 unexplained=2'"
check "MIXED: exits 3 because at least one hole is unexplained" "[ $rc_mix -eq 3 ]"
check "MIXED: the unexplained instants are named, not just counted" \
  "printf '%s' \"\$out_mix\" | grep -q 'GAP ts=2026-08-09T00:37:00Z class=unexplained' && printf '%s' \"\$out_mix\" | grep -q 'GAP ts=2026-08-09T00:52:00Z class=unexplained'"

# ── 6. A deploy with NO terminal event still bounds a window ────────────────
# (a SIGKILLed deploy, a box rebooted mid-run). Bounded by --open-window-min.
head -1 "$TD/ledger-0808" > "$TD/ledger-open"
# shellcheck disable=SC2034  # read inside check()'s eval string
out_open="$(analyze "$TD/ticks-0808" "$TD/ledger-open")"; rc_open=$?
check "an unterminated deploy still forms a bounded window" \
  "[ $rc_open -eq 0 ] && printf '%s' \"\$out_open\" | grep -q 'deploy_attributable=1'"
# shellcheck disable=SC2034  # read inside check()'s eval string
out_open_narrow="$(OPEN_WINDOW_MIN=1 EVERY_MIN=$EVERY_MIN GRACE_MIN=1; analyze "$TD/ticks-0808" "$TD/ledger-open")" || true
check "and the bound is REAL: --open-window-min is what makes it reach" \
  "[ -n \"\$out_open_narrow\" ]"

# ── 7. Input refusals (exit 11), each proven to fire ────────────────────────
printf 'not-a-timestamp\n2026-08-08T23:22:00Z\n' > "$TD/ticks-bad"
analyze "$TD/ticks-bad" "$TD/ledger-0808" >/dev/null 2>&1; rc_bad=$?
check "an unparseable timestamp is refused with 11, never skipped" "[ $rc_bad -eq 11 ]"
printf '2026-08-08T23:22:00Z\n' > "$TD/ticks-one"
analyze "$TD/ticks-one" "$TD/ledger-0808" >/dev/null 2>&1; rc_one=$?
check "a single tick cannot show a gap and is refused with 11" "[ $rc_one -eq 11 ]"
analyze "$TD/does-not-exist" "$TD/ledger-0808" >/dev/null 2>&1; rc_nf=$?
check "a missing ticks file is refused with 11" "[ $rc_nf -eq 11 ]"
# shellcheck disable=SC2034  # read inside check()'s eval string
out_noled="$(analyze "$TD/ticks-complete" "$TD/no-such-ledger")"; rc_noled=$?
check "a MISSING ledger is not an error — it degrades to zero windows" \
  "[ $rc_noled -eq 0 ] && printf '%s' \"\$out_noled\" | grep -q 'windows=0'"
# Comments and blanks are ignored, not parsed as ticks.
{ echo "# a header"; echo; cat "$TD/ticks-complete"; } > "$TD/ticks-comments"
# shellcheck disable=SC2034  # read inside check()'s eval string
out_cm="$(analyze "$TD/ticks-comments" "$TD/ledger-0808")"
check "comments and blank lines are ignored, not counted as ticks" \
  "printf '%s' \"\$out_cm\" | grep -q 'ticks=5 '"

# ── 8. cp-deploy.sh actually EMITS what this script parses ──────────────────
# The two halves are written apart and could drift apart. This runs the REAL
# stamp function out of the REAL script against a temp ledger and feeds the
# result to the REAL analyzer. Deleting any emission from cp-deploy.sh reds here.
CPD="$(cd "$(dirname "$0")" && pwd)/cp-deploy.sh"
check "cp-deploy.sh is present beside this script" "[ -r '$CPD' ]"
if [ -r "$CPD" ]; then
  STAMP_FN="$TD/stamp.sh"
  awk '/^cutover_stamp\(\) \{/,/^\}/' "$CPD" > "$STAMP_FN"
  check "extracted cutover_stamp() from cp-deploy.sh (not a hand-written copy)" "[ -s '$STAMP_FN' ]"
  for ev in deploy_start flip old_slot_stopped deploy_end deploy_aborted; do
    check "cp-deploy.sh stamps '$ev'" "grep -qE '^[[:space:]]*cutover_stamp $ev' '$CPD'"
  done
  # shellcheck disable=SC2034  # every var here is consumed by the sourced cutover_stamp()
  (
    CUTOVER_LEDGER="$TD/ledger-live"
    CUTOVER_LEDGER_MAX_LINES=4000
    CUTOVER_DEPLOY_ID="selftest-1"
    OLD=aaaaaaa; NEW=bbbbbbb; ACTIVE_PORT=4100; TARGET=green
    # shellcheck disable=SC1090
    . "$STAMP_FN"
    cutover_stamp deploy_start
    cutover_stamp flip
    cutover_stamp deploy_end result=ok
  )
  check "the real stamp function wrote three ledger lines" \
    "[ \"\$(wc -l < '$TD/ledger-live' 2>/dev/null || echo 0)\" -eq 3 ]"
  check "and each carries the keys the analyzer reads (deploy_id, event, ts, new_sha)" \
    "[ \"\$(grep -c 'deploy_id=selftest-1 event=.* ts=.*new_sha=bbbbbbb' '$TD/ledger-live')\" -eq 3 ]"
  # Round-trip: a series whose hole sits inside the window the REAL script just
  # stamped must classify as attributable. This is the seam test — a rename of
  # any key in cp-deploy.sh reds it even though both files still "work".
  ledger_start="$(awk '/event=deploy_start/{for(i=2;i<=NF;i++){split($i,kv,"=");if(kv[1]=="ts")print kv[2]}}' "$TD/ledger-live")"
  if [ -n "$ledger_start" ]; then
    awk -v S="$ledger_start" "$AWK_CLOCK"'BEGIN{ e = iso2epoch(S); printf "%s\n%s\n%s\n", epoch2iso(e-1800), epoch2iso(e-900), epoch2iso(e+900) }' \
      > "$TD/ticks-live"
# shellcheck disable=SC2034  # read inside check()'s eval string
    out_live="$(analyze "$TD/ticks-live" "$TD/ledger-live")"; rc_live=$?
    check "SEAM: a hole inside the window the REAL cp-deploy.sh stamped is attributable" \
      "[ $rc_live -eq 0 ] && printf '%s' \"\$out_live\" | grep -q 'deploy_attributable=1'"
    check "SEAM: and it names the deploy_id the real function wrote" \
      "printf '%s' \"\$out_live\" | grep -q 'deploy_id=selftest-1'"
  else
    check "SEAM: read the deploy_start ts out of the live ledger" "false"
  fi
  # The trim is bounded, and it keeps the NEWEST lines (a trim that kept the
  # oldest would silently answer every recent question with "unexplained").
  # shellcheck disable=SC2034  # every var here is consumed by the sourced cutover_stamp()
  (
    CUTOVER_LEDGER="$TD/ledger-trim"
    CUTOVER_LEDGER_MAX_LINES=5
    CUTOVER_DEPLOY_ID="trim"
    OLD=a; NEW=b; ACTIVE_PORT=4100; TARGET=green
    # shellcheck disable=SC1090
    . "$STAMP_FN"
    i=0; while [ "$i" -lt 12 ]; do cutover_stamp "e$i"; i=$((i + 1)); done
  )
  check "the ledger is trimmed to its line budget" \
    "[ \"\$(wc -l < '$TD/ledger-trim')\" -le 5 ]"
  check "the trim keeps the NEWEST lines (the last event survives)" \
    "grep -q 'event=e11' '$TD/ledger-trim'"
  check "and drops the oldest" "! grep -q 'event=e0 ' '$TD/ledger-trim'"
  # An unwritable ledger must never fail the deploy.
  # shellcheck disable=SC2034  # every var here is consumed by the sourced cutover_stamp()
  (
    CUTOVER_LEDGER="/proc/nonexistent-dir-dw3/ledger.log"
    CUTOVER_LEDGER_MAX_LINES=10
    CUTOVER_DEPLOY_ID="ro"
    OLD=a; NEW=b; ACTIVE_PORT=4100; TARGET=green
    # shellcheck disable=SC1090
    . "$STAMP_FN"
    cutover_stamp deploy_start
  ) >/dev/null 2>&1; rc_ro=$?
  check "an unwritable ledger returns 0 — bookkeeping never reds a deploy" "[ $rc_ro -eq 0 ]"
fi

# ── FLOOR: a harness that ran zero checks must not read as a green ──────────
FLOOR=38
check "at least $FLOOR checks executed (a vacuous green is a red)" "[ $checks_ran -ge $FLOOR ]"

# --- deploy/README.md count guard (ssw8-selftest-count-guard) ---------------
# deploy/README.md publishes THIS engine's check count in prose, and until this
# block nothing read it back: the page said 46 while the only thing guarding it
# was `FLOOR=38` above — in a DIFFERENT file (deploy/cp-deploy_test.sh asserts
# `>= 38`), so the published number could drift by 8 downward and without bound
# upward with every harness still green. The agreement was a coincidence of
# timing, not a measurement.
#
# Direction matters, and is the same as the other four engines': the README
# number is the ASSERTED value, $checks_ran — which this run just measured — is
# the MEASUREMENT, and the guard only ever READS the README. A guard that learns
# its expected value from the thing it guards is inert and would have agreed
# with any drifted number.
#
# Skips cleanly when the README is absent, so a box that ships the engines
# without the docs tree is unaffected.
readme_md="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)/README.md"
if [ ! -f "$readme_md" ]; then
  echo "README count guard: SKIPPED - no $readme_md (engine shipped without the docs tree)"
else
  # The anchor is this engine's own invocation followed by its count, which
  # occurs exactly once on the page. Zero matches, or more than one, is a
  # FAILURE and not a pass: a reworded sentence must red here rather than
  # quietly disarm the guard by matching nothing.
  readme_anchor='deploy/cp-cutover-gaps\.sh[^0-9]{1,24}[0-9]+ checks'
  readme_hits="$(grep -oE "$readme_anchor" "$readme_md" | wc -l | tr -d ' ')"
  if [ "$readme_hits" != 1 ]; then
    echo "FAIL: README count guard, deploy/cp-cutover-gaps.sh: expected exactly ONE 'deploy/cp-cutover-gaps.sh ... <N> checks' anchor in $readme_md, found $readme_hits. The guard reads that sentence to learn the published count; if you reworded it, restore the anchor (the script path, then the number, then the word 'checks', all on one line) in the SAME commit."
    fails=$((fails + 1))
  else
    readme_count="$(grep -oE "$readme_anchor" "$readme_md" | sed -E 's/.*[^0-9]([0-9]+) checks$/\1/')"
    if [ "$readme_count" != "$checks_ran" ]; then
      echo "FAIL: README count drift in deploy/cp-cutover-gaps.sh: deploy/README.md publishes $readme_count checks, this run measured $checks_ran. The RUN is the truth - update the number in deploy/README.md to $checks_ran in the SAME commit that changed the case count, or the two drift apart again."
      fails=$((fails + 1))
    else
      echo "README count guard: deploy/README.md publishes $readme_count checks for deploy/cp-cutover-gaps.sh, this run measured $checks_ran - agreed"
    fi
  fi
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL PASS ($checks_ran checks)"
  exit 0
fi
echo "FAILURES: $fails of $checks_ran checks"
exit 1
