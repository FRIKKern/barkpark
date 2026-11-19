#!/usr/bin/env bash
#
# seat-stamp-dump-restore-drop-guard.test.sh — scripts/seat-stamp-dump-restore.test.sh
# drops only the databases it created in the same run (task-018e79d8734a1b08).
#
# Runs that script with stand-ins for psql, pg_dump, pg_restore, createdb and
# dropdb first on PATH. No database is touched. Two cases:
#
#   1. createdb refuses the first name (a database already holds it): the run
#      stops (exit 2) and dropdb is never called.
#   2. createdb makes the first name and refuses the second: the run stops
#      (exit 2) and dropdb is called for the first name only.
#
# MANUAL PROOF — not wired: it guards the manual seat-stamp-dump-restore.test.sh and runs beside it, by hand:
#   scripts/seat-stamp-dump-restore-drop-guard.test.sh
#
# EXIT: 0 both cases hold · 1 a case failed.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HERE/seat-stamp-dump-restore.test.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/seatstamp-guard.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

fails=0
check() { # name, expected, actual
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected [$2], got [$3]"
    fails=$((fails + 1))
  fi
}

# Stand-ins. createdb succeeds for the first $CREATEDB_OK calls, then refuses
# as if the name were taken; every call is logged.
make_bin() {
  local bin="$1"
  mkdir -p "$bin"
  cat >"$bin/psql" <<'SH'
#!/usr/bin/env bash
case "$*" in *"FROM pg_trigger WHERE tgname"*) echo 1 ;; esac
[ -t 0 ] || cat >/dev/null
exit 0
SH
  cat >"$bin/pg_dump" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && echo "pg_dump (stand-in)"
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/pg_restore"
  cat >"$bin/createdb" <<'SH'
#!/usr/bin/env bash
n=$(wc -l <"$GUARD_LOG_DIR/createdb.log" 2>/dev/null || echo 0)
echo "$1" >>"$GUARD_LOG_DIR/createdb.log"
if [ "$n" -lt "$CREATEDB_OK" ]; then exit 0; fi
echo "createdb: error: database \"$1\" already exists" >&2
exit 1
SH
  cat >"$bin/dropdb" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in -*) ;; *) echo "$a" >>"$GUARD_LOG_DIR/dropdb.log" ;; esac; done
exit 0
SH
  chmod +x "$bin"/*
}

run_case() { # dir, createdb_ok
  local dir="$1"
  mkdir -p "$dir/tmp"
  make_bin "$dir/bin"
  : >"$dir/createdb.log"
  : >"$dir/dropdb.log"
  PATH="$dir/bin:$PATH" GUARD_LOG_DIR="$dir" CREATEDB_OK="$2" TMPDIR="$dir/tmp/" \
    SEAT_STAMP_SCHEMA_DB=stand_in_schema bash "$TARGET" </dev/null >"$dir/out.log" 2>&1
  echo $?
}

c1="$WORK/c1"
rc="$(run_case "$c1" 0)"
check "1: a taken first name stops the run" 2 "$rc"
check "1: createdb was asked once" 1 "$(wc -l <"$c1/createdb.log" | tr -d ' ')"
check "1: nothing is dropped" "" "$(cat "$c1/dropdb.log")"

c2="$WORK/c2"
rc="$(run_case "$c2" 1)"
first="$(sed -n 1p "$c2/createdb.log")"
second="$(sed -n 2p "$c2/createdb.log")"
check "2: a taken second name stops the run" 2 "$rc"
check "2: createdb was asked twice" 2 "$(wc -l <"$c2/createdb.log" | tr -d ' ')"
check "2: only the database this run made is dropped" "$first" "$(cat "$c2/dropdb.log")"
check "2: the taken name is not dropped" no "$(grep -qx "$second" "$c2/dropdb.log" && echo yes || echo no)"

if [ "$fails" -eq 0 ]; then
  echo "seat-stamp-dump-restore-drop-guard: OK — the script drops only what it created"
  exit 0
fi
echo "seat-stamp-dump-restore-drop-guard: RED — $fails check(s) failed" >&2
exit 1
