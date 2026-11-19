#!/usr/bin/env bash
#
# seat-stamp-dump-restore.test.sh — a plain pg_dump + pg_restore keeps every
# seat's `seat_change` stamp, so a pending role request is exactly as fresh or
# stale after the restore as before it (task-018e79d8734a1b08).
#
# The stamp is set by the trigger `workspace_memberships_seat_change` (ENABLE
# ALWAYS) on every write to a seat row. pg_dump creates triggers in post-data,
# after the rows load, so a restore does not re-stamp. This harness checks
# that rather than assuming it:
#
#   1. creates SRC with the schema of an already migrated database (read with
#      `pg_dump --schema-only`; that database's rows are never read or written);
#   2. seeds one workspace, two seated users, and two role requests that record
#      their seat's stamp; then moves the second seat viewer -> contributor ->
#      viewer, so its request is stale;
#   3. `pg_dump -Fc SRC`, creates DST, `pg_restore` into DST;
#   4. asserts in DST: both stamps equal SRC's, the fresh request is fresh and
#      the stale one stale (the AccessRequestStaleness rule in SQL), the
#      trigger is ENABLE ALWAYS ('A'), and a write after the restore gets a new
#      stamp, not the one it supplied.
#
# SRC and DST are named uniquely for this run and dropped on exit, pass or
# fail. Nothing else is created, and no other database is written.
#
# MANUAL PROOF — not wired: it needs a database already migrated to
# 20261119090000 and pg_dump/pg_restore of the server's major version. CI's
# Postgres is a postgres:15 service container; no workflow installs client
# tools pinned to it, and no job keeps a migrated database alive outside
# `mix test`'s sandbox, whose rows pg_dump cannot see. Run it by hand
# beside any change to the seat stamp, its trigger, or the bundle import's
# trigger switches:
#   SEAT_STAMP_SCHEMA_DB=barkpark_test<partition> scripts/seat-stamp-dump-restore.test.sh
#
# Connection: the libpq environment (PGHOST, PGPORT, PGUSER, PGPASSWORD);
# defaults PGHOST=localhost PGUSER=postgres.
#
# EXIT: 0 every assertion holds · 1 an assertion failed · 2 cannot measure.

set -uo pipefail

export PGHOST="${PGHOST:-localhost}" PGUSER="${PGUSER:-postgres}"
SCHEMA_DB="${SEAT_STAMP_SCHEMA_DB:-}"

refuse() { echo "seat-stamp-dump-restore: CANNOT MEASURE — $*" >&2; exit 2; }

for tool in psql pg_dump pg_restore createdb dropdb; do
  command -v "$tool" >/dev/null 2>&1 || refuse "$tool is not on PATH"
done
[ -n "$SCHEMA_DB" ] || refuse "set SEAT_STAMP_SCHEMA_DB to a database migrated to 20261119090000"

has_trigger="$(psql -X -d "$SCHEMA_DB" -Atc \
  "SELECT count(*) FROM pg_trigger WHERE tgname = 'workspace_memberships_seat_change'" 2>/dev/null)" \
  || refuse "cannot read $SCHEMA_DB"
[ "$has_trigger" = "1" ] || refuse "$SCHEMA_DB has no workspace_memberships_seat_change trigger (not migrated?)"

run_id="$$_$(date +%s)_${RANDOM}"
SRC="bp_seatstamp_${run_id}_src"
DST="bp_seatstamp_${run_id}_dst"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/seatstamp.XXXXXX")" || refuse "mktemp failed"
DUMP="$WORK/seatstamp.pgdump"

# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  dropdb --if-exists "$SRC" >/dev/null 2>&1
  dropdb --if-exists "$DST" >/dev/null 2>&1
  rm -f "$DUMP"
  rmdir "$WORK" 2>/dev/null
}
trap cleanup EXIT

q() { psql -X -q -v ON_ERROR_STOP=1 -d "$1" -Atc "$2"; }

fails=0
check() { # name, expected, actual
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: expected [$2], got [$3]"
    fails=$((fails + 1))
  fi
}

echo "pg_dump: $(pg_dump --version) · server: $(q "$SCHEMA_DB" 'SHOW server_version')"
echo "databases this run: $SRC, $DST"

createdb "$SRC" || refuse "createdb $SRC failed"
pg_dump --schema-only --no-owner "$SCHEMA_DB" 2>/dev/null \
  | psql -X -q -v ON_ERROR_STOP=1 -d "$SRC" >/dev/null 2>&1 \
  || refuse "could not copy the schema of $SCHEMA_DB into $SRC"

WS=11111111-1111-1111-1111-111111111111
FRESH=22222222-2222-2222-2222-222222222222
STALE=33333333-3333-3333-3333-333333333333

psql -X -q -v ON_ERROR_STOP=1 -d "$SRC" >/dev/null <<SQL || refuse "seeding $SRC failed"
INSERT INTO workspaces (id, name, slug, inserted_at, updated_at)
  VALUES ('$WS', 'Seat stamp', 'seat-stamp', now(), now());
INSERT INTO users (id, email, hashed_password, inserted_at, updated_at) VALUES
  ('$FRESH', 'fresh@example.com', 'x', now(), now()),
  ('$STALE', 'stale@example.com', 'x', now(), now());
INSERT INTO workspace_memberships (id, workspace_id, principal_type, principal_id, role, inserted_at, updated_at) VALUES
  (gen_random_uuid(), '$WS', 'user', '$FRESH', 'viewer', now(), now()),
  (gen_random_uuid(), '$WS', 'user', '$STALE', 'viewer', now(), now());
-- Each asks for admin, recording its seat's stamp, as AccessRequests.request/4 does.
INSERT INTO workspace_access_requests
  (id, user_id, workspace_slug, workspace_id, status, requested_role, from_role, seat_change, inserted_at, updated_at)
  SELECT gen_random_uuid(), m.principal_id, 'seat-stamp', m.workspace_id, 'pending', 'admin', m.role, m.seat_change, now(), now()
  FROM workspace_memberships m WHERE m.workspace_id = '$WS';
-- The stale one: its seat moves viewer -> contributor -> viewer after the ask.
UPDATE workspace_memberships SET role = 'contributor' WHERE principal_id = '$STALE';
UPDATE workspace_memberships SET role = 'viewer' WHERE principal_id = '$STALE';
SQL

# The AccessRequestStaleness rule for a role request: fresh only while the
# seat's stamp is the one the request recorded.
verdict() {
  q "$1" "SELECT CASE WHEN r.seat_change = m.seat_change THEN 'fresh' ELSE 'stale' END
          FROM workspace_access_requests r
          LEFT JOIN workspace_memberships m
            ON m.workspace_id = r.workspace_id AND m.principal_type = 'user' AND m.principal_id = r.user_id
          WHERE r.user_id = '$2'"
}
stamp() { q "$1" "SELECT seat_change FROM workspace_memberships WHERE principal_id = '$2'"; }

check "before: the untouched seat's request is fresh" fresh "$(verdict "$SRC" "$FRESH")"
check "before: the bounced seat's request is stale" stale "$(verdict "$SRC" "$STALE")"
src_fresh="$(stamp "$SRC" "$FRESH")"
src_stale="$(stamp "$SRC" "$STALE")"

pg_dump -Fc --no-owner -f "$DUMP" "$SRC" || refuse "pg_dump $SRC failed"
createdb "$DST" || refuse "createdb $DST failed"
pg_restore --no-owner -d "$DST" "$DUMP" || refuse "pg_restore into $DST failed"

check "restore keeps the untouched seat's stamp" "$src_fresh" "$(stamp "$DST" "$FRESH")"
check "restore keeps the bounced seat's stamp" "$src_stale" "$(stamp "$DST" "$STALE")"
check "after: the fresh request is still fresh" fresh "$(verdict "$DST" "$FRESH")"
check "after: the stale request is still stale" stale "$(verdict "$DST" "$STALE")"
check "after: the trigger is ENABLE ALWAYS" A \
  "$(q "$DST" "SELECT tgenabled FROM pg_trigger WHERE tgname = 'workspace_memberships_seat_change'")"

supplied=00000000-0000-0000-0000-000000000001
written="$(q "$DST" "UPDATE workspace_memberships SET seat_change = '$supplied'
                     WHERE principal_id = '$FRESH' RETURNING seat_change")"
check "after: a write gets a new stamp, not the supplied one" new \
  "$([ -n "$written" ] && [ "$written" != "$supplied" ] && [ "$written" != "$src_fresh" ] && echo new || echo "$written")"

if [ "$fails" -eq 0 ]; then
  echo "seat-stamp-dump-restore: OK — a dump and restore keeps fresh fresh and stale stale"
  exit 0
fi
echo "seat-stamp-dump-restore: RED — $fails assertion(s) failed" >&2
exit 1
