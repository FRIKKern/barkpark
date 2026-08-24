#!/usr/bin/env bash
#
# reap-test-databases.sh — drop ORPHANED `barkpark_test*` databases.
#
# WHY THIS EXISTS
# ---------------
# Every lane runs `MIX_TEST_PARTITION=<lane> mix ecto.create` so it gets its own
# database and cannot collide with a peer. That was the right call: before it,
# lanes shared one `barkpark_test` and produced cross-lane failures that were
# mistaken for real reds. But NOTHING ever drops them, so the count is
# MONOTONIC. Measured on the dev host 2026-08-24: 314 databases, 6618 MB, and
# only 2 with a live connection. It went 313 → 314 during the hour it took to
# write this down.
#
# The ceiling is not disk, it is `max_connections` (100). Each running lane
# holds a pool, and when the pool is exhausted the failure is MISREAD BY
# DEFAULT:
#
#     ** (Mix) The database for Barkpark.Repo couldn't be created: killed
#     ** (Postgrex.Error) FATAL 53300 (too_many_connections) sorry, too many clients already
#
# Neither names the cause. The first reads exactly like a broken migration. A
# lane that records that abort as a red has invented a failure — the class this
# repo spends most of its effort eliminating.
#
# THE SAFETY RULE IS THE WHOLE DESIGN
# -----------------------------------
# A database is reaped only when BOTH hold:
#
#   1. it has NO backend in pg_stat_activity, AND
#   2. its on-disk directory ($PGDATA/base/<oid>) has not been touched for at
#      least --older-than-hours (default 48).
#
# The AND is load-bearing and the second half is the half people skip. "No
# connection right now" is NOT proof a lane is finished: a lane sitting between
# two `mix test` invocations holds zero connections. Reaping on absence alone
# would destroy a peer's migrated database mid-run and produce a failure that
# looks like a code fault — precisely the disease, re-introduced by the cure.
#
# pg_database carries no creation timestamp, so age comes from the directory
# mtime, which is readable and correct (it dated five databases on this host to
# 2026-08-19, five days stale). When $PGDATA is unreadable the script REFUSES to
# reap rather than falling back to the connection check alone — a reaper that
# silently degrades to its unsafe half is worse than no reaper.
#
# DRY RUN IS THE DEFAULT. `--apply` is required to drop anything.
#
#   scripts/reap-test-databases.sh                    # report, drop nothing
#   scripts/reap-test-databases.sh --apply            # drop, 48h threshold
#   scripts/reap-test-databases.sh --older-than-hours 24 --apply
#   scripts/reap-test-databases.sh --selftest         # prove the safety rule
#
# Filed as task-1a7e52b811dabc3c.
set -uo pipefail

PGHOST="${BARKPARK_TEST_DB_HOST:-localhost}"
PGUSER="${BARKPARK_TEST_DB_USER:-postgres}"
OLDER_THAN_HOURS=48
APPLY=0
SELFTEST=0
KEEP=()

die() { printf 'reap-test-databases: %s\n' "$*" >&2; exit 3; }

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)             APPLY=1 ;;
    --selftest)          SELFTEST=1 ;;
    --older-than-hours)  shift; OLDER_THAN_HOURS="${1:-}" ;;
    --keep)              shift; KEEP+=("${1:-}") ;;
    -h|--help)           sed -n '2,50p' "$0"; exit 0 ;;
    *)                   die "unrecognized argument: $1 (try --help)" ;;
  esac
  shift
done

case "$OLDER_THAN_HOURS" in
  ''|*[!0-9]*) die "--older-than-hours needs a non-negative integer, got '$OLDER_THAN_HOURS'" ;;
esac

psql_q() { psql -h "$PGHOST" -U "$PGUSER" -tAF'|' -c "$1" 2>/dev/null; }

command -v psql >/dev/null || die "psql is not on PATH"
psql_q "select 1" >/dev/null || die "cannot reach postgres at $PGHOST as $PGUSER"

PGDATA="$(psql_q "show data_directory;")"
[ -n "$PGDATA" ] && [ -d "$PGDATA" ] || die \
  "cannot read \$PGDATA ('$PGDATA') — REFUSING to reap. Age is half the safety
  rule; without it this would degrade to 'no connection right now', which reaps
  a lane that is merely between two test runs."

# ── selftest ────────────────────────────────────────────────────────────────
# PROVE THE SAFETY RULE, do not assert it. Three arms against a REAL planted
# database, driving this same script rather than a copy of its logic:
#
#   A. idle + threshold 0  -> REAPABLE   (it can select at all; without this the
#                                         other two arms pass vacuously)
#   B. HELD  + threshold 0 -> PROTECTED  (the connection guard)
#   C. idle  + threshold 48h -> PROTECTED (the age guard — the half that stops a
#                                         lane between two `mix test` runs being
#                                         reaped out from under itself)
#
# A reaper gated on absence-of-connection ALONE passes A and B and FAILS C.
if [ "$SELFTEST" = 1 ]; then
  FIX="barkpark_test_reapselftest_$$"
  fails=0
  arm() { # arm <name> <expect: reap|protect> <output>
    if [ "$2" = reap ]; then
      if printf '%s' "$3" | grep -q -- "- *$FIX"; then printf '  ok    %s\n' "$1"
      else printf '  FAIL  %s — expected %s in the reapable list\n' "$1" "$FIX"; fails=$((fails+1)); fi
    else
      if printf '%s' "$3" | grep -q -- "- *$FIX"; then
        printf '  FAIL  %s — %s was listed as reapable and MUST NOT be\n' "$1" "$FIX"; fails=$((fails+1))
      else printf '  ok    %s\n' "$1"; fi
    fi
  }

  printf 'reap-test-databases --selftest\n\n'
  psql -h "$PGHOST" -U "$PGUSER" -c "CREATE DATABASE \"$FIX\";" >/dev/null 2>&1 \
    || die "selftest could not create $FIX"
  # WITH (FORCE) terminates a lingering backend and drops anyway. It is correct
  # HERE and nowhere else: this database is the selftest's OWN fixture, and the
  # holder it opens can outlive `kill` by a moment. The reaper proper must NEVER
  # force — refusing to drop a busy database is the guarantee it exists to make.
  trap 'psql -h "$PGHOST" -U "$PGUSER" -c "DROP DATABASE IF EXISTS \"'"$FIX"'\" WITH (FORCE);" >/dev/null 2>&1' EXIT

  arm "A idle + 0h  -> reapable   (the arm that stops B and C being vacuous)" \
      reap "$(bash "$0" --older-than-hours 0 2>&1)"

  # Hold a real backend open, the way a running lane does. 120s, not 12:
  # the holder must outlive a FULL classification pass by a wide margin, or
  # arm B tests nothing and reports a guard failure that is really a timeout.
  psql -h "$PGHOST" -U "$PGUSER" -d "$FIX" -c "select pg_sleep(120);" >/dev/null 2>&1 &
  holder=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    c="$(psql_q "select count(*) from pg_stat_activity where datname = '$FIX';")"
    [ "${c:-0}" -gt 0 ] && break
    sleep 0.4
  done
  [ "${c:-0}" -gt 0 ] || { printf '  FAIL  could not open a holding connection — arm B is untested\n'; fails=$((fails+1)); }
  arm "B held + 0h  -> PROTECTED  (connection guard)" \
      protect "$(bash "$0" --older-than-hours 0 2>&1)"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

  arm "C idle + 48h -> PROTECTED  (age guard — a reaper without this FAILS here)" \
      protect "$(bash "$0" --older-than-hours 48 2>&1)"

  printf '\n'
  if [ "$fails" -gt 0 ]; then printf 'SELFTEST FAILED: %d of 3 arms failed\n' "$fails"; exit 1; fi
  printf 'SELFTEST PASSED: 3 of 3 arms\n'
  exit 0
fi

# ── classify ────────────────────────────────────────────────────────────────
NOW="$(date +%s)"
CUTOFF_SECS=$(( OLDER_THAN_HOURS * 3600 ))

REAP=(); HELD=(); YOUNG=(); KEPT=(); UNDATED=()

while IFS='|' read -r oid name conns; do
  [ -z "${oid:-}" ] && continue

  skip=0
  for k in ${KEEP+"${KEEP[@]}"}; do [ "$name" = "$k" ] && skip=1; done
  if [ "$skip" = 1 ]; then KEPT+=("$name"); continue; fi

  # GUARD 1 — a live backend means a lane is using it right now.
  if [ "${conns:-0}" -gt 0 ]; then HELD+=("$name ($conns conn)"); continue; fi

  # GUARD 2 — age. No directory means no age, and no age means no reap.
  dir="$PGDATA/base/$oid"
  if [ ! -d "$dir" ]; then UNDATED+=("$name"); continue; fi
  mtime="$(stat -f '%m' "$dir" 2>/dev/null || stat -c '%Y' "$dir" 2>/dev/null)"
  case "${mtime:-}" in ''|*[!0-9]*) UNDATED+=("$name"); continue ;; esac

  age=$(( NOW - mtime ))
  if [ "$age" -lt "$CUTOFF_SECS" ]; then
    YOUNG+=("$name ($(( age / 3600 ))h)")
  else
    REAP+=("$name|$(( age / 3600 ))")
  fi
done < <(psql_q "
  -- ONE round trip for the whole set. The first cut of this script ran a
  -- separate \`psql\` per database; at 314 databases that is 314 process spawns,
  -- and the run took long enough that the selftest's own holding connection
  -- EXPIRED before the classification reached it — arm B failed and the bug was
  -- mine, not the harness's. Batching is the fix and the selftest is why it was
  -- found before this shipped.
  select d.oid, d.datname, coalesce(a.n, 0)
    from pg_database d
    left join (select datname, count(*) as n
                 from pg_stat_activity
                where datname is not null
             group by datname) a on a.datname = d.datname
   where d.datname like 'barkpark\\_test%'
   order by d.datname;")

printf 'reap-test-databases — threshold %sh, host %s\n\n' "$OLDER_THAN_HOURS" "$PGHOST"
printf '  PROTECTED, live backend:     %d\n' "${#HELD[@]}"
printf '  PROTECTED, touched recently: %d\n' "${#YOUNG[@]}"
printf '  PROTECTED, --keep:           %d\n' "${#KEPT[@]}"
printf '  PROTECTED, no readable age:  %d\n' "${#UNDATED[@]}"
printf '  REAPABLE:                    %d\n\n' "${#REAP[@]}"

[ "${#HELD[@]}" -gt 0 ] && { printf '  held now:\n'; for h in "${HELD[@]}"; do printf '    · %s\n' "$h"; done; }
[ "${#UNDATED[@]}" -gt 0 ] && { printf '  UNDATED (never reaped — investigate):\n'; for u in "${UNDATED[@]}"; do printf '    ? %s\n' "$u"; done; }

if [ "${#REAP[@]}" -eq 0 ]; then
  printf '  nothing to reap.\n'
  exit 0
fi

if [ "$APPLY" != 1 ]; then
  printf '  would drop (DRY RUN — pass --apply to do it):\n'
  for r in "${REAP[@]}"; do printf '    - %-42s idle %sh\n' "${r%%|*}" "${r##*|}"; done
  printf '\n  %d database(s). Re-run with --apply to drop them.\n' "${#REAP[@]}"
  exit 0
fi

dropped=0; failed=0
for r in "${REAP[@]}"; do
  n="${r%%|*}"
  if psql -h "$PGHOST" -U "$PGUSER" -c "DROP DATABASE IF EXISTS \"$n\";" >/dev/null 2>&1; then
    printf '    dropped %s\n' "$n"; dropped=$((dropped+1))
  else
    # A lane that connected between the check and the drop: correct to fail.
    printf '    SKIPPED %s (drop refused — it became busy)\n' "$n"; failed=$((failed+1))
  fi
done
printf '\n  dropped %d, skipped %d\n' "$dropped" "$failed"
exit 0
