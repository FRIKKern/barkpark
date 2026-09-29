#!/usr/bin/env bash
#
# reap-test-databases.sh — drop ORPHANED `barkpark_test*` and
# `barkpark_cloud_test*` databases.
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
# A THIRD GUARD FOR PER-WORKTREE NAMES (task-3e7dbdd6620bd87e)
# -------------------------------------------------------------
# With MIX_TEST_PARTITION unset and CI unset, api/config/test.exs (#20107) and
# cloud/config/test.exs (#20349) BOTH name the database after the checkout:
#
#     barkpark_test_wt_<slug>_<hash>          (api)
#     barkpark_cloud_test_wt_<slug>_<hash>    (cloud)
#
# where <hash> = :erlang.phash2(<checkout root>) in lowercase base 36, and the
# suffix is byte-identical between the two apps for one checkout. So a `_wt_`
# name maps back to a worktree by DERIVATION, not by a list: every worktree
# `git worktree list` knows about is hashed with the same phash2 (one `erl` call
# for the whole set) and a `_wt_` database whose trailing <hash> belongs to a
# worktree whose directory still EXISTS is PROTECTED regardless of age or
# connections. The match is on <hash> alone: a slug mismatch could only ever
# lose protection, a hash collision could only ever add it.
#
# It is an ADDED guard, never a replacement: a `_wt_` database whose worktree is
# gone still has to pass guards 1 and 2 to be reaped. When the worktree set
# cannot be derived (no `git`, no `erl`), every `_wt_` name is PROTECTED as
# unmappable — the same fail-closed stance as an unreadable $PGDATA. It cannot
# see checkouts that are not worktrees of THIS repository (a separate clone);
# those keep exactly the protection they had before: guards 1 and 2.
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
# Filed as task-1a7e52b811dabc3c; cloud + worktree guard task-3e7dbdd6620bd87e.
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
    -h|--help)           sed -n '2,72p' "$0"; exit 0 ;;
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

# ── live worktrees, derived ─────────────────────────────────────────────────
# One line per worktree whose directory exists: its phash2 in the base-36
# lowercase form the two test.exs files use. Paths are read as raw bytes so a
# non-ASCII path hashes as the UTF-8 binary Elixir hashes, not as a charlist.
# WT_OK=0 means the set could not be derived and `_wt_` names are unmappable.
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
live_worktree_hashes() {
  command -v git >/dev/null && command -v erl >/dev/null || return 1
  local paths
  paths="$(git -C "$REPO_DIR" worktree list --porcelain 2>/dev/null)" || return 1
  printf '%s\n' "$paths" | sed -n 's/^worktree //p' | erl -noshell -eval '
    ok = io:setopts(standard_io, [binary]),
    L = fun Loop() ->
      case io:get_line("") of
        eof -> ok;
        {error, _} -> halt(1);
        Line ->
          P = string:trim(Line, trailing, "\n"),
          case filelib:is_dir(P) of
            true -> io:format("~s~n", [string:lowercase(integer_to_list(erlang:phash2(P), 36))]);
            false -> ok
          end,
          Loop()
      end
    end,
    L(), halt(0).'
}
WT_OK=0; LIVE_WT=" "
if wt="$(live_worktree_hashes)" && [ -n "$wt" ]; then
  WT_OK=1
  LIVE_WT=" $(printf '%s' "$wt" | tr '\n' ' ') "
fi

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
#
# Three more arms for the cloud prefix and the worktree guard, all idle + 0h so
# ONLY the worktree guard can separate them:
#
#   D. barkpark_cloud_test_wt_*, worktree GONE   -> REAPABLE  (the cloud prefix
#                                         is selected at all; without it E and F
#                                         pass vacuously)
#   E. barkpark_cloud_test_wt_*, worktree EXISTS -> PROTECTED (<hash> derived
#                                         from THIS checkout, not typed in)
#   F. barkpark_test_wt_*,       worktree EXISTS -> PROTECTED (the guard is the
#                                         same rule for api's names)
#
# A reaper that only widened its LIKE passes D and FAILS E and F.
if [ "$SELFTEST" = 1 ]; then
  [ "$WT_OK" = 1 ] || die "selftest needs the live worktree set (git + erl) — cannot derive it"
  # THIS checkout's hash, by the reaper's own derivation. The script lives in
  # <root>/scripts, and the checkout root is what test.exs hashes.
  SELF_ROOT="$(git -C "$REPO_DIR" rev-parse --show-toplevel)" || die "selftest: not in a git checkout"
  SELF_HASH="$(printf '%s\n' "$SELF_ROOT" | erl -noshell -eval '
    ok = io:setopts(standard_io, [binary]),
    P = string:trim(io:get_line(""), trailing, "\n"),
    io:format("~s~n", [string:lowercase(integer_to_list(erlang:phash2(P), 36))]), halt(0).')"
  case "$LIVE_WT" in *" $SELF_HASH "*) ;; *) die "selftest: this checkout's hash $SELF_HASH is not in the derived live set" ;; esac

  FIX="barkpark_test_reapselftest_$$"
  FIX_GONE="barkpark_cloud_test_wt_reapselftest_gone$$"      # no worktree hashes to 'gone<pid>'
  FIX_LIVE="barkpark_cloud_test_wt_reapselftest_$SELF_HASH"
  FIX_API_LIVE="barkpark_test_wt_reapselftest_$SELF_HASH"
  FIXTURES="$FIX $FIX_GONE $FIX_LIVE $FIX_API_LIVE"
  fails=0
  # Membership by `case`, never `printf | grep -q`: under pipefail a long report
  # can SIGPIPE the printf and turn a TRUE match into a FAIL.
  listed() { # listed <fixture> <output>
    case "$2" in *"- $1 "*|*"- $1"$'\n'*) return 0 ;; *) return 1 ;; esac
  }
  arm() { # arm <name> <expect: reap|protect> <fixture> <output>
    if [ "$2" = reap ]; then
      if listed "$3" "$4"; then printf '  ok    %s\n' "$1"
      else printf '  FAIL  %s — expected %s in the reapable list\n' "$1" "$3"; fails=$((fails+1)); fi
    else
      if listed "$3" "$4"; then
        printf '  FAIL  %s — %s was listed as reapable and MUST NOT be\n' "$1" "$3"; fails=$((fails+1))
      else printf '  ok    %s\n' "$1"; fi
    fi
  }

  printf 'reap-test-databases --selftest\n\n'
  # WITH (FORCE) terminates a lingering backend and drops anyway. It is correct
  # HERE and nowhere else: these databases are the selftest's OWN fixtures, and
  # the holder it opens can outlive `kill` by a moment. The reaper proper must
  # NEVER force — refusing to drop a busy database is the guarantee it exists to
  # make.
  cleanup() {
    for f in $FIXTURES; do
      psql -h "$PGHOST" -U "$PGUSER" -c "DROP DATABASE IF EXISTS \"$f\" WITH (FORCE);" >/dev/null 2>&1
    done
  }
  trap cleanup EXIT
  for f in $FIXTURES; do
    psql -h "$PGHOST" -U "$PGUSER" -c "CREATE DATABASE \"$f\";" >/dev/null 2>&1 \
      || die "selftest could not create $f"
  done

  out="$(bash "$0" --older-than-hours 0 2>&1)"
  arm "A idle + 0h  -> reapable   (the arm that stops B and C being vacuous)" reap "$FIX" "$out"
  arm "D cloud _wt_, worktree gone   + 0h -> reapable  (cloud prefix is selected)" reap "$FIX_GONE" "$out"
  arm "E cloud _wt_, worktree exists + 0h -> PROTECTED (worktree guard, derived hash)" protect "$FIX_LIVE" "$out"
  arm "F api   _wt_, worktree exists + 0h -> PROTECTED (same guard for api's names)" protect "$FIX_API_LIVE" "$out"

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
      protect "$FIX" "$(bash "$0" --older-than-hours 0 2>&1)"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

  arm "C idle + 48h -> PROTECTED  (age guard — a reaper without this FAILS here)" \
      protect "$FIX" "$(bash "$0" --older-than-hours 48 2>&1)"

  printf '\n'
  if [ "$fails" -gt 0 ]; then printf 'SELFTEST FAILED: %d of 6 arms failed\n' "$fails"; exit 1; fi
  printf 'SELFTEST PASSED: 6 of 6 arms\n'
  exit 0
fi

# ── classify ────────────────────────────────────────────────────────────────
NOW="$(date +%s)"
CUTOFF_SECS=$(( OLDER_THAN_HOURS * 3600 ))

REAP=(); HELD=(); YOUNG=(); KEPT=(); UNDATED=(); WTLIVE=(); UNMAPPED=()

while IFS='|' read -r oid name conns; do
  [ -z "${oid:-}" ] && continue

  skip=0
  for k in ${KEEP+"${KEEP[@]}"}; do [ "$name" = "$k" ] && skip=1; done
  if [ "$skip" = 1 ]; then KEPT+=("$name"); continue; fi

  # GUARD 1 — a live backend means a lane is using it right now.
  if [ "${conns:-0}" -gt 0 ]; then HELD+=("$name ($conns conn)"); continue; fi

  # GUARD 3 — a per-worktree name whose worktree still exists (see header).
  case "$name" in
    barkpark_test_wt_*|barkpark_cloud_test_wt_*)
      if [ "$WT_OK" != 1 ]; then UNMAPPED+=("$name"); continue; fi
      case "$LIVE_WT" in *" ${name##*_} "*) WTLIVE+=("$name"); continue ;; esac
      ;;
  esac

  # GUARD 2 — age. No directory means no age, and no age means no reap.
  dir="$PGDATA/base/$oid"
  if [ ! -d "$dir" ]; then UNDATED+=("$name"); continue; fi
  # GNU FIRST, BSD second — never the reverse. On GNU coreutils `-f` means
  # FILESYSTEM status, so `stat -f %s` SUCCEEDS on Linux with a block-count
  # report instead of failing, and a BSD-first `||` chain never reaches the
  # GNU form. BSD stat rejects `-c` outright, so GNU-first fails loudly on
  # the wrong platform instead of quietly.
  mtime="$(stat -c '%Y' "$dir" 2>/dev/null || stat -f '%m' "$dir" 2>/dev/null)"
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
      or d.datname like 'barkpark\\_cloud\\_test%'
   order by d.datname;")

printf 'reap-test-databases — threshold %sh, host %s\n\n' "$OLDER_THAN_HOURS" "$PGHOST"
printf '  PROTECTED, live backend:     %d\n' "${#HELD[@]}"
printf '  PROTECTED, touched recently: %d\n' "${#YOUNG[@]}"
printf '  PROTECTED, worktree exists:  %d\n' "${#WTLIVE[@]}"
[ "$WT_OK" = 1 ] || printf '  PROTECTED, worktree unknown: %d  (git/erl could not derive the live set)\n' "${#UNMAPPED[@]}"
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
