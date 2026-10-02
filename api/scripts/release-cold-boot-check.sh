#!/usr/bin/env bash
# Cold-boot check for the two release eval steps in api/entrypoint.sh.
#
# WHY A SCRIPT AND NOT A TEST: the property under test is RELEASE-ONLY. `mix
# test` has already started :barkpark, so every "nothing is started" assertion
# on the test node is vacuous, and the tree it boots is the dev/test tree, not
# the one `bin/barkpark eval` builds from config/runtime.exs. This repo has
# been burned by exactly that shape before (6 of 9 plugins dead in every
# release while the suite was green). So this drives a REAL assembled release
# against a REAL empty database — the docker-compose first-boot-on-an-empty-
# pgdata-volume sequence, minus docker.
#
# WHAT IT PROVES (task shb-bl-release-load-app):
#   1. `Barkpark.Release.migrate()` against a schema with ZERO tables logs no
#      undefined_table / Postgrex crash storm. It used to: load_app/0 was
#      Application.ensure_all_started/1, so the whole tree (Endpoint, Oban, the
#      plugin tier) came up and queried tables the migrations had not created
#      yet.
#   2. Neither eval step logs "Running BarkparkWeb.Endpoint" — the endpoint
#      binds only under `bin/barkpark start`.
#
# ANTI-VACUITY. An absence is never caught by inspection, so every absence
# assertion here is paired with something that must be PRESENT:
#   * the database is proven EMPTY before migrate (table count printed);
#   * `workspaces` and a non-zero schema_migrations must EXIST after migrate,
#     so an eval that died on line one cannot pass by logging nothing;
#   * each forbidden pattern is fired against a synthetic positive control, so
#     a typo'd regex cannot manufacture a clean log;
#   * the endpoint banner is proven to be the string the app ACTUALLY emits, by
#     booting `bin/barkpark start` at the end and requiring the banner to
#     appear there. Without that arm, "no endpoint line" would also pass with
#     the banner spelled wrong.
#
# MUTATION ARM (how you red it): revert `Release.load_app/0` to
# `Application.ensure_all_started(@app)`, or `Release.seed/0`'s `seed_boot!()`
# to `start_app()`, rebuild the release, re-run. Check 1 and check 2
# respectively must fail.
#
# USAGE:
#   api/scripts/release-cold-boot-check.sh [path/to/_build/prod/rel/barkpark]
# Default release path: api/_build/prod/rel/barkpark (build it with
# `MIX_ENV=prod mix release` from api/).
#
# Requires a reachable local Postgres superuser-ish role; the throwaway
# database is created and dropped by this script and its name MUST contain
# "coldboot" so it can never be pointed at anything real.

set -uo pipefail

API_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REL_DIR="${1:-$API_DIR/_build/prod/rel/barkpark}"
REL_BIN="$REL_DIR/bin/barkpark"

PGUSER_="${PGUSER_:-postgres}"
PGPASS_="${PGPASS_:-postgres}"
PGHOST_="${PGHOST_:-localhost}"
DB_NAME="${COLDBOOT_DB:-barkpark_coldboot_check}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/barkpark-coldboot.XXXXXX")"

case "$DB_NAME" in
  *coldboot*) ;;
  *) echo "REFUSED: COLDBOOT_DB ($DB_NAME) must contain 'coldboot'" >&2; exit 2 ;;
esac

if [ ! -x "$REL_BIN" ]; then
  echo "REFUSED: no assembled release at $REL_BIN" >&2
  echo "  build one: (cd $API_DIR && MIX_ENV=prod mix release)" >&2
  exit 2
fi

fails=0
note() { printf '%s\n' "$*"; }
ok()   { printf 'ok   %s\n' "$*"; }
bad()  { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }

psql_() { PGPASSWORD="$PGPASS_" psql -X -q -t -A -h "$PGHOST_" -U "$PGUSER_" "$@"; }

# ── The forbidden patterns, in one place: the checks and the grep control
# both read this list, so a pattern can never be proven-live in one and
# silently different in the other.
# Each alternative is listed separately so the control below can prove EVERY
# one of them fires; an alternation checked as a whole passes on one arm while
# another is silently typo'd.
#
# `relation .* does not exist` is deliberately pinned to `[error]`: Postgres
# emits that phrase as a benign NOTICE from inside migrations themselves
# (`trigger "oban_notify" for relation "public.oban_jobs" does not exist,
# skipping`), and an unpinned pattern reds a perfectly clean cold boot.
CRASH_ALTERNATIVES=(
  'undefined_table'
  '\(Postgrex\.Error\)'
  'DrainWorker.*terminating'
  '\[error\].*relation .* does not exist'
)
CRASH_PATTERNS="$(IFS='|'; echo "${CRASH_ALTERNATIVES[*]}")"
ENDPOINT_PATTERN='Running BarkparkWeb\.Endpoint'

# Grep control: prove every pattern FIRES. An absence verdict from a regex that
# matches nothing is not evidence of anything.
control_log="$WORK_DIR/control.log"
cat > "$control_log" <<'CTL'
[error] Postgrex.Protocol (#PID<0.1.0>) disconnected: ** (Postgrex.Error) ERROR 42P01 (undefined_table)
[error] GenServer #PID<0.2.0> terminating: relation "plugin_settings" does not exist
[error] Oban.Plugins.DrainWorker terminating
[info] Running BarkparkWeb.Endpoint with Bandit 1.5.0 at 0.0.0.0:4000 (http)
CTL
for alt in "${CRASH_ALTERNATIVES[@]}"; do
  if grep -Eq "$alt" "$control_log"; then
    ok "control: crash pattern /$alt/ fires on a known-bad log"
  else
    bad "control: crash pattern /$alt/ matched NOTHING - a clean verdict from it would be meaningless"
  fi
done
# Negative control for the pinned one: the benign migration NOTICE must NOT red
# a clean boot.
benign_log="$WORK_DIR/benign.log"
printf '%s\n' '14:16:01.889 [info] trigger "oban_notify" for relation "public.oban_jobs" does not exist, skipping' > "$benign_log"
if grep -Eq "$CRASH_PATTERNS" "$benign_log"; then
  bad "control: the crash patterns red on a BENIGN migration notice - check 1 would be a false alarm"
else
  ok "control: the benign migration notice does NOT trip the crash patterns"
fi
if grep -Eq "$ENDPOINT_PATTERN" "$control_log"; then
  ok "control: the endpoint-banner pattern matches a known endpoint banner"
else
  bad "control: ENDPOINT_PATTERN matched nothing - 'no endpoint line' would be meaningless"
fi

# ── A database with no tables at all: the empty pgdata volume.
psql_ -d postgres -c "DROP DATABASE IF EXISTS \"$DB_NAME\" WITH (FORCE)" >/dev/null 2>&1
if ! psql_ -d postgres -c "CREATE DATABASE \"$DB_NAME\"" >/dev/null 2>"$WORK_DIR/createdb.err"; then
  echo "REFUSED: could not create $DB_NAME" >&2; cat "$WORK_DIR/createdb.err" >&2; exit 2
fi

tables_before="$(psql_ -d "$DB_NAME" -c "select count(*) from information_schema.tables where table_schema='public'")"
note "precondition: public schema holds $tables_before tables before migrate"
if [ "$tables_before" = "0" ]; then
  ok "precondition: the database is EMPTY (first-ever boot)"
else
  bad "precondition: $DB_NAME already holds $tables_before tables — this is not a cold boot"
fi

export DATABASE_URL="ecto://$PGUSER_:$PGPASS_@$PGHOST_/$DB_NAME"
export PHX_HOST=localhost
export PORT="${COLDBOOT_PORT:-4321}"
export SECRET_KEY_BASE="coldboot-throwaway-secret-key-base-0000000000000000000000000000000000000000"
export BARKPARK_CLOAK_KEY="Y29sZGJvb3QtdGhyb3dhd2F5LWNsb2FrLWtleS0wMDAwMDA="
export BARKPARK_KEK="$(head -c 32 /dev/zero | base64)"
export PREVIEW_JWT_SECRET="coldboot-throwaway-preview-jwt-secret-000000"
export BARKPARK_RELEASE_CAPTURE_HMAC_SECRET="coldboot-throwaway-release-capture-secret-0000"
export BARKPARK_SEED_PROFILE="${BARKPARK_SEED_PROFILE:-clean}"

migrate_log="$WORK_DIR/migrate.log"
seed_log="$WORK_DIR/seed.log"
start_log="$WORK_DIR/start.log"

note ""
note "== step 1/3: bin/barkpark eval \"Barkpark.Release.migrate()\""
"$REL_BIN" eval "Barkpark.Release.migrate()" >"$migrate_log" 2>&1
migrate_rc=$?
note "   rc=$migrate_rc, $(wc -l <"$migrate_log" | tr -d ' ') log lines -> $migrate_log"
[ "$migrate_rc" -eq 0 ] || bad "the migrate eval exited $migrate_rc"

# CHECK 1 — the crash storm.
if grep -Eq "$CRASH_PATTERNS" "$migrate_log"; then
  bad "check 1: the migrate eval logged a crash storm before migrations ran:"
  grep -En "$CRASH_PATTERNS" "$migrate_log" | head -20 | sed 's/^/     /'
else
  ok "check 1: zero undefined_table / Postgrex crashes in the migrate eval"
fi

# Positive control for check 1: migrate must have actually built the schema.
tables_after="$(psql_ -d "$DB_NAME" -c "select count(*) from information_schema.tables where table_schema='public'" 2>/dev/null)"
applied="$(psql_ -d "$DB_NAME" -c "select count(*) from schema_migrations" 2>/dev/null)"
note "   after migrate: $tables_after tables, $applied applied migrations"
if [ "${applied:-0}" -gt 0 ] 2>/dev/null; then
  ok "control: the migrate eval applied $applied migrations (a no-op eval could not pass check 1)"
else
  bad "control: schema_migrations is empty — the migrate eval did nothing, so check 1 is vacuous"
fi
if psql_ -d "$DB_NAME" -c "select to_regclass('public.workspaces')" 2>/dev/null | grep -q workspaces; then
  ok "control: the 'workspaces' table the crash storm used to query now exists"
else
  bad "control: no 'workspaces' table after migrate"
fi

note ""
note "== step 2/3: bin/barkpark eval \"Barkpark.Release.seed()\""
"$REL_BIN" eval "Barkpark.Release.seed()" >"$seed_log" 2>&1
seed_rc=$?
note "   rc=$seed_rc, $(wc -l <"$seed_log" | tr -d ' ') log lines -> $seed_log"
[ "$seed_rc" -eq 0 ] || bad "the seed eval exited $seed_rc"

# CHECK 2 — no endpoint bind from either eval step.
if grep -Eq "$ENDPOINT_PATTERN" "$migrate_log" "$seed_log"; then
  bad "check 2: an eval step started the endpoint:"
  grep -En "$ENDPOINT_PATTERN" "$migrate_log" "$seed_log" | head -10 | sed 's/^/     /'
else
  ok "check 2: neither eval step logged '$ENDPOINT_PATTERN'"
fi

note ""
note "== step 3/3: bin/barkpark start (control: the banner this release DOES emit)"
"$REL_BIN" start >"$start_log" 2>&1 &
start_pid=$!
banner=0
for _ in $(seq 1 60); do
  if grep -Eq "$ENDPOINT_PATTERN" "$start_log"; then banner=1; break; fi
  kill -0 "$start_pid" 2>/dev/null || break
  sleep 1
done
kill "$start_pid" 2>/dev/null
wait "$start_pid" 2>/dev/null
if [ "$banner" -eq 1 ]; then
  ok "control: the serving boot DOES log the banner — check 2's absence is a real absence"
  grep -E "$ENDPOINT_PATTERN" "$start_log" | head -2 | sed 's/^/     /'
else
  bad "control: 'bin/barkpark start' never logged the banner in 60s, so check 2 proves nothing (start log: $start_log)"
  tail -20 "$start_log" | sed 's/^/     /'
fi

note ""
note "logs kept in $WORK_DIR"
psql_ -d postgres -c "DROP DATABASE IF EXISTS \"$DB_NAME\" WITH (FORCE)" >/dev/null 2>&1

if [ "$fails" -eq 0 ]; then
  note "COLD BOOT CLEAN: both checks and all controls passed."
  exit 0
fi
note "COLD BOOT FAILED: $fails check(s)."
exit 1
