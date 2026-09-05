#!/usr/bin/env bash
# ci-log-gap-census.sh — the meter behind "the Elixir Test job stalls".
#
# A GitHub Actions job log carries an RFC3339 timestamp on every line. A STALL is
# a gap between two CONSECUTIVE timestamps that is >= a threshold: the job printed
# nothing for that long. In a run with 0 failures every such gap is a WAIT that
# passes, so the sum of gaps is the reducible part of the job's wall time.
#
# This is the instrument task-18f209f185f5b3f1's criterion c1 is measured with
# ("the sum of timestamp gaps >= 10 s in a main run drops below 60 s"). It lives
# in the repo so the criterion is re-measurable by anyone, on any run, later.
#
# Usage:
#   scripts/ci-log-gap-census.sh <job.log> [--threshold SECONDS] [--all]
#   scripts/ci-log-gap-census.sh --selftest
#
# By default the census is WINDOWED to the `mix test` phase (from the line that
# announces the compile/test step through ExUnit's "Finished in" line), because
# runner provisioning and dependency fetching are not what the criterion governs.
# --all censuses the whole log.
#
# Output: one line per gap (seconds, the line BEFORE the gap, the line AFTER),
# then a TOTAL line. Exit 0 always — this is a meter, not a gate.
set -euo pipefail

THRESHOLD=10
ALL=0
LOG=""
SELFTEST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) SELFTEST=1; shift ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    --threshold=*) THRESHOLD="${1#*=}"; shift ;;
    --all) ALL=1; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    -*) echo "unknown argument: $1" >&2; exit 2 ;;
    *) LOG="$1"; shift ;;
  esac
done

census() {
  local log="$1" threshold="$2" all="$3"
  awk -v THRESHOLD="$threshold" -v ALL="$all" '
    function to_epoch(ts,   d, t, y, mo, da, h, mi, s, days, i, leap) {
      # ts is YYYY-MM-DDTHH:MM:SS(.fffffff)?Z
      split(ts, d, "T")
      split(d[1], da_p, "-")
      y = da_p[1] + 0; mo = da_p[2] + 0; da = da_p[3] + 0
      t = d[2]; sub(/Z$/, "", t)
      split(t, t_p, ":")
      h = t_p[1] + 0; mi = t_p[2] + 0; s = t_p[3] + 0.0
      # days since epoch (civil_from_days, Howard Hinnant)
      yy = y - (mo <= 2)
      era = int((yy >= 0 ? yy : yy - 399) / 400)
      yoe = yy - era * 400
      doy = int((153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5) + da - 1
      doe = yoe * 365 + int(yoe/4) - int(yoe/100) + doy
      days = era * 146097 + doe - 719468
      return days * 86400 + h * 3600 + mi * 60 + s
    }
    {
      # strip the "job<TAB>step<TAB>" prefix gh emits, if present
      line = $0
      n = split(line, parts, "\t")
      payload = parts[n]
      sub(/^\xef\xbb\xbf/, "", payload)
      if (payload !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}/) next
      ts = payload
      sub(/ .*$/, "", ts)
      rest = payload
      sub(/^[^ ]* ?/, "", rest)

      e = to_epoch(ts)

      if (!ALL) {
        if (!started) {
          if (rest ~ /mix (test|do compile)/ || rest ~ /Running ExUnit/ || rest ~ /^Compiling [0-9]+ files/) started = 1
          else { prev_e = e; prev_rest = rest; next }
        }
        if (started && rest ~ /^Finished in /) { finish = 1 }
      }

      if (have_prev) {
        gap = e - prev_e
        if (gap >= THRESHOLD) {
          total += gap
          count += 1
          printf "%8.1fs  BEFORE: %s\n", gap, substr(prev_rest, 1, 150)
          printf "           AFTER: %s\n", substr(rest, 1, 150)
        }
      }
      prev_e = e; prev_rest = rest; have_prev = 1
      if (finish) exit
    }
    END {
      printf "TOTAL: %d gaps >= %ss, summing %.1fs\n", count + 0, THRESHOLD, total + 0
    }
  ' "$log"
}

if [ "$SELFTEST" = "1" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  fail=0
  ok() { printf 'ok    %s\n' "$1"; }
  bad() { printf 'FAIL  %s\n' "$1"; fail=1; }

  # A synthetic log with KNOWN gaps: 12s, 3s, 30s inside the window, and a 99s
  # gap BEFORE the window that --all must see and the default must not.
  cat > "$tmp/log" <<'LOG'
job	step	2026-01-01T00:00:00.0000000Z Current runner version
job	step	2026-01-01T00:01:39.0000000Z mix test
job	step	2026-01-01T00:01:51.0000000Z Compiling barkpark
job	step	2026-01-01T00:01:54.0000000Z ....
job	step	2026-01-01T00:02:24.0000000Z ....
job	step	2026-01-01T00:02:25.0000000Z Finished in 145.0s
job	step	2026-01-01T00:05:00.0000000Z Post job cleanup
LOG

  out="$(census "$tmp/log" 10 0)"
  # windowed: gaps are 12 (mix test -> Compiling) and 30; the 3s is under
  # threshold, the 99s precedes the window, the 155s trails the Finished line.
  if printf '%s' "$out" | grep -q 'TOTAL: 2 gaps >= 10s, summing 42.0s'; then
    ok "windowed census finds exactly the two in-window gaps (42.0s)"
  else
    bad "windowed census; got: $out"
  fi
  if printf '%s' "$out" | grep -q '99'; then
    bad "windowed census leaked the pre-window 99s gap"
  else
    ok "windowed census excludes the pre-window gap"
  fi

  out_all="$(census "$tmp/log" 10 1)"
  if printf '%s' "$out_all" | grep -q 'TOTAL: 4 gaps >= 10s, summing 296.0s'; then
    ok "--all census finds all four gaps (296.0s)"
  else
    bad "--all census; got: $out_all"
  fi

  # threshold discriminates: at 40s only the 155s post-window gap and the 99s survive
  out_t="$(census "$tmp/log" 40 1)"
  if printf '%s' "$out_t" | grep -q 'TOTAL: 2 gaps >= 40s, summing 254.0s'; then
    ok "--threshold discriminates (40s keeps 99s + 155s = 254.0s)"
  else
    bad "--threshold; got: $out_t"
  fi

  # a log with no timestamps at all must report zero, not crash
  printf 'no timestamps here\nnor here\n' > "$tmp/plain"
  if census "$tmp/plain" 10 1 | grep -q 'TOTAL: 0 gaps'; then
    ok "a log with no timestamps reports 0 gaps"
  else
    bad "no-timestamp log did not report 0 gaps"
  fi

  # epoch conversion must survive a month/year boundary (Feb 28 -> Mar 1, leap year)
  cat > "$tmp/leap" <<'LOG'
2024-02-29T23:59:50.0000000Z a
2024-03-01T00:00:10.0000000Z b
LOG
  if census "$tmp/leap" 10 1 | grep -q 'TOTAL: 1 gaps >= 10s, summing 20.0s'; then
    ok "date arithmetic crosses a leap-day month boundary (20.0s)"
  else
    bad "leap-day boundary; got: $(census "$tmp/leap" 10 1)"
  fi

  if [ "$fail" = "0" ]; then echo "SELFTEST OK"; exit 0; else echo "SELFTEST FAILED"; exit 1; fi
fi

if [ -z "$LOG" ]; then echo "usage: $0 <job.log> [--threshold N] [--all] | --selftest" >&2; exit 2; fi
if [ ! -r "$LOG" ]; then echo "cannot read log: $LOG" >&2; exit 2; fi
census "$LOG" "$THRESHOLD" "$ALL"
