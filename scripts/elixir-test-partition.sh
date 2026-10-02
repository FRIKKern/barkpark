#!/usr/bin/env bash
# elixir-test-partition.sh — split the Elixir test files across the Test cells
# by MEASURED weight, not by hash (task-bc3ef53758b916a8).
#
# WHY. `--slowest` implies `--trace`, so every module runs serially and a
# cell's time is the sum of its files. `mix test --partitions` assigns files
# by hash, and the hash does not know that one file costs 120 s and another
# 0.05 s: the first three-cell run (PR #20999, run 36934928538) measured Test
# steps of 570 s / 552 s / 266 s for one suite. The same per-file times,
# packed greedily, give 462 s / 462 s / 462 s.
#
# HOW. Every cell runs this with the SAME candidate list and the SAME weights,
# so every cell computes the SAME assignment and takes its own share. The
# assignment is longest-weight-first onto the least-loaded cell (ties: lower
# cell; equal weights: path order), so it is a pure function of its inputs.
# A file the weights do not know gets the median known weight — a new test
# file is placed, never dropped. A weight the candidates do not name is
# ignored — a deleted file costs nothing.
#
# FAIL-CLOSED. A file in no cell is a silently smaller suite, and the gate's
# per-cell records cannot see it (they prove every CELL reported, not every
# FILE ran). So `--cell` refuses (exit 2) unless the cells it computed are
# DISJOINT and their union is EXACTLY the candidate list — checked on every
# call, in every cell, before a file is printed.
#
# usage:
#   elixir-test-partition.sh --cell K N [WEIGHTS] < candidates
#       print cell K's files (1-based, of N). candidates: one test path per
#       line, relative to api/ (e.g. test/barkpark/foo_test.exs).
#   elixir-test-partition.sh --plan N [WEIGHTS] < candidates
#       print `<cell>\t<seconds>\t<files>` per cell — what --cell would pick.
#   elixir-test-partition.sh --weights-from-logs LOG... > WEIGHTS
#       per-file seconds from `mix test --trace` CI logs (a module's time is
#       the gap from its `<Module> [test/…_test.exs]` header to the next
#       header or `Finished in`; modules run one at a time under --trace).
#
# WEIGHTS defaults to scripts/elixir-test-weights.tsv (`<path>\t<seconds>`).
# Regenerate it from the Test cells of one green full-suite run:
#   gh api repos/FRIKKern/barkpark/actions/jobs/<id>/logs > p<k>.log  (each cell)
#   bash scripts/elixir-test-partition.sh --weights-from-logs p*.log > scripts/elixir-test-weights.tsv
#
# P1_EXTRA: cell 1 also runs the one-time guard steps (measured ~40 s more
# job time than the other cells), so it starts that many seconds loaded.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_WEIGHTS="$HERE/elixir-test-weights.tsv"
P1_EXTRA="${ELIXIR_PARTITION_P1_EXTRA:-40}"

die() {
  echo "elixir-test-partition: $*" >&2
  exit 2
}

# stdin candidates + weights file -> `<cell>\t<weight>\t<path>` for every
# candidate, one line each, in assignment order.
assign() {
  local n="$1" weights="$2"
  [ -r "$weights" ] || die "weights file '$weights' is not readable"
  local tab cands weighed med
  tab="$(printf '\t')"
  cands="$(cat)"
  # Stage 1: `<weight|?>\t<path>` per distinct candidate (`?` = not in WEIGHTS).
  weighed="$(printf '%s\n' "$cands" | LC_ALL=C awk -F'\t' -v wf="$weights" '
    BEGIN {
      while ((getline line < wf) > 0) {
        split(line, a, "\t")
        if (a[1] != "" && a[2] ~ /^[0-9]+(\.[0-9]+)?$/) { w[a[1]] = a[2] + 0 }
      }
      close(wf)
    }
    {
      sub(/\r$/, "")
      if ($0 == "" || ($0 in seen)) next
      seen[$0] = 1
      if ($0 in w) printf "%.2f\t%s\n", w[$0], $0
      else printf "?\t%s\n", $0
    }')"
  # Stage 2: an unknown file weighs the MEDIAN known candidate weight (1 s when
  # none is known) — placed like a typical file, never dropped.
  med="$(printf '%s\n' "$weighed" | cut -f1 | grep -v '^?$' | LC_ALL=C sort -g |
    awk '{ v[NR] = $1 } END { if (NR == 0) print "1.00"; else print v[int((NR + 1) / 2)] }')"
  # Stage 3: weight desc, then path asc — a TOTAL order, so the answer does not
  # depend on the order the candidates arrived in. Stage 4: each file onto the
  # least-loaded cell (ties: the lower cell), cell 1 starting P1_EXTRA loaded.
  printf '%s\n' "$weighed" | sed '/^$/d' | LC_ALL=C awk -F'\t' -v med="$med" 'BEGIN { OFS = "\t" } { if ($1 == "?") $1 = med; print }' |
    LC_ALL=C sort -t "$tab" -k1,1gr -k2,2 |
    LC_ALL=C awk -F'\t' -v n="$n" -v p1="$P1_EXTRA" '
      BEGIN { for (c = 1; c <= n; c++) load[c] = 0; load[1] = p1 }
      {
        best = 1
        for (c = 2; c <= n; c++) if (load[c] < load[best]) best = c
        load[best] += $1
        printf "%d\t%s\t%s\n", best, $1, $2
      }'
}

valid_n() {
  case "$1" in '' | *[!0-9]*) die "cell count '$1' is not a positive integer" ;; esac
  [ "$1" -ge 1 ] || die "cell count must be >= 1"
}

mode="${1:-}"
case "$mode" in
  --cell)
    k="${2:-}"; n="${3:-}"; weights="${4:-$DEFAULT_WEIGHTS}"
    valid_n "$n"
    case "$k" in '' | *[!0-9]*) die "cell '$k' is not a positive integer" ;; esac
    { [ "$k" -ge 1 ] && [ "$k" -le "$n" ]; } || die "cell $k is outside 1..$n"
    cands="$(LC_ALL=C sort -u | sed '/^$/d')"
    [ -n "$cands" ] || die "no candidate files on stdin — refusing to answer an empty cell for an empty suite"
    plan="$(printf '%s\n' "$cands" | assign "$n" "$weights")"
    # the fail-closed proof: every candidate exactly once, every cell in 1..n
    got="$(printf '%s\n' "$plan" | cut -f3 | LC_ALL=C sort)"
    [ "$got" = "$cands" ] || die "the computed cells do not cover the candidates exactly once — refusing"
    # every out-of-range cell is printed (no truncating reader: house D37),
    # and the first is named.
    bad="$(awk -F'\t' -v n="$n" '$1 < 1 || $1 > n { print $1 }' <<<"$plan")"
    bad="${bad%%$'\n'*}"
    [ -z "$bad" ] || die "a file was assigned to cell $bad, outside 1..$n — refusing"
    printf '%s\n' "$plan" | awk -F'\t' -v k="$k" '$1 == k { print $3 }'
    ;;
  --plan)
    n="${2:-}"; weights="${3:-$DEFAULT_WEIGHTS}"
    valid_n "$n"
    LC_ALL=C sort -u | sed '/^$/d' | assign "$n" "$weights" |
      awk -F'\t' -v n="$n" -v p1="$P1_EXTRA" '
        { s[$1] += $2; c[$1]++ }
        END { for (i = 1; i <= n; i++) printf "%d\t%.1f\t%d\n", i, s[i] + (i == 1 ? p1 : 0), c[i] }'
    ;;
  --weights-from-logs)
    shift
    [ "$#" -ge 1 ] || die "--weights-from-logs needs at least one log"
    LC_ALL=C awk '
      function days(y, m, d,   era, yoe, doy, doe) {
        # days since 1970-01-01 (proleptic Gregorian), so a gap that crosses
        # midnight or a month end is still a gap.
        y -= (m <= 2)
        era = int(y / 400)
        yoe = y - era * 400
        doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
        doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
        return era * 146097 + doe - 719468
      }
      function ts(s,   d, a, b) {
        # 2026-10-01T22:26:15.1234567Z -> seconds since the epoch
        split(s, a, "T"); split(a[1], d, "-"); split(a[2], b, ":")
        sub(/Z$/, "", b[3])
        return days(d[1] + 0, d[2] + 0, d[3] + 0) * 86400 + b[1] * 3600 + b[2] * 60 + b[3]
      }
      FNR == 1 { if (cur != "") { cur = "" } }
      {
        line = $0
        stamp = $1
        rest = substr(line, length(stamp) + 2)
        if (rest ~ /^[A-Za-z0-9_.]+ \[test\/[^]]+_test\.exs\][ \t\r]*$/) {
          t = ts(stamp)
          if (cur != "") secs[cur] += t - t0
          f = rest; sub(/^[^[]*\[/, "", f); sub(/\].*$/, "", f)
          cur = f; t0 = t
          next
        }
        if (rest ~ /^Finished in / && cur != "") { secs[cur] += ts(stamp) - t0; cur = "" }
      }
      END { for (f in secs) printf "%s\t%.2f\n", f, secs[f] }' "$@" | LC_ALL=C sort
    ;;
  *)
    echo "usage: $0 --cell K N [WEIGHTS] | --plan N [WEIGHTS] | --weights-from-logs LOG..." >&2
    exit 2
    ;;
esac
