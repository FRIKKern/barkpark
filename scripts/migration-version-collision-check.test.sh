#!/usr/bin/env bash
# migration-version-collision-check.test.sh — the mutation matrix behind
# scripts/migration-version-collision-check.sh.
#
# Every case PLANTS the defect, asserts the script REFUSES and names both sides
# of it, then removes the plant and asserts the same invocation goes green. A
# guard that has never been seen to fail is not a guard.
#
# Two tiers, and the split is deliberate:
#   HERMETIC (always): mktemp fixture trees, `--db-versions-file` standing in
#     for schema_migrations, `git init` repos for the base-ref detector. No
#     postgres, no network — so this half cannot rot into a skip on a runner.
#   LIVE POSTGRES (when reachable): a real `createdb` fixture database with a
#     real `schema_migrations` table, read through psql, for detector B red and
#     green. This is the only arm that proves the psql plumbing, so when no
#     server answers it prints its own NOT RUN line and the run says so in the
#     summary rather than counting silence as a pass.
#
# Exit: 0 all assertions held. 1 an assertion failed. 2 the harness itself could
# not set up (its own inputs unreadable).

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECK="$HERE/migration-version-collision-check.sh"
REPO=$(cd "$HERE/.." && pwd)

if [ ! -r "$CHECK" ]; then
  printf 'CANNOT READ: %s\n' "$CHECK" >&2
  exit 2
fi

pass=0
fail=0
skipped=()

ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }

# assert_rc <expected-rc> <label> -- <command...>
run_check() {
  CHECK_OUT=$(bash "$CHECK" "$@" 2>&1)
  CHECK_RC=$?
  return 0
}

expect_rc() {
  local want=$1 label=$2
  if [ "$CHECK_RC" -eq "$want" ]; then
    ok "$label (exit $CHECK_RC)"
  else
    bad "$label — expected exit $want, got $CHECK_RC"
    printf '%s\n' "$CHECK_OUT" | sed 's/^/      | /'
  fi
}

expect_out() {
  local label=$1 needle=$2
  if printf '%s' "$CHECK_OUT" | grep -qF -- "$needle"; then
    ok "$label — output names '$needle'"
  else
    bad "$label — output does NOT name '$needle'"
    printf '%s\n' "$CHECK_OUT" | sed 's/^/      | /'
  fi
}

expect_no_out() {
  local label=$1 needle=$2
  if printf '%s' "$CHECK_OUT" | grep -qF -- "$needle"; then
    bad "$label — output unexpectedly names '$needle'"
    printf '%s\n' "$CHECK_OUT" | sed 's/^/      | /'
  else
    ok "$label — output does not name '$needle'"
  fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/migcheck.XXXXXX") || { printf 'CANNOT READ: mktemp failed\n' >&2; exit 2; }
cleanup() {
  if [ -n "${FIXTURE_DB:-}" ]; then
    dropdb --if-exists "$FIXTURE_DB" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# ── Fixture tree builder ─────────────────────────────────────────────────────
# A minimal repo shaped exactly like the real one: cloud/priv/repo/migrations
# with two ordinary migrations. Not a git repo unless the caller asks.
new_tree() {
  local d="$TMP/$1"
  mkdir -p "$d/cloud/priv/repo/migrations"
  printf 'defmodule R.M1 do\nend\n' > "$d/cloud/priv/repo/migrations/20260901120000_create_widgets.exs"
  printf 'defmodule R.M2 do\nend\n' > "$d/cloud/priv/repo/migrations/20260902120000_add_colour.exs"
  printf '%s' "$d"
}

git_init_tree() {
  local d=$1
  git -C "$d" init -q 2>/dev/null
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" -c user.email=h@x -c user.name=h commit -q -m base >/dev/null 2>&1
}

printf '== Detector A: two files, one version ==\n'

# --- A1: the CONTROL. A clean fixture tree is green.
T=$(new_tree a1); git_init_tree "$T"
run_check --root "$T"
expect_rc 0 "A1 control: clean fixture tree"
expect_out "A1 control" "OK: every migration version"

# --- A2: the PLANT. A second file claiming 20260902120000 must red, and the
# refusal must name BOTH files — a message that names one is not actionable.
cp "$T/cloud/priv/repo/migrations/20260902120000_add_colour.exs" \
   "$T/cloud/priv/repo/migrations/20260902120000_add_serving_since_basis.exs"
git -C "$T" add -A >/dev/null 2>&1
run_check --root "$T"
expect_rc 1 "A2 plant: duplicate version reds"
expect_out "A2 plant" "VIOLATION (A duplicate version): 20260902120000"
expect_out "A2 plant" "20260902120000_add_colour.exs"
expect_out "A2 plant" "20260902120000_add_serving_since_basis.exs"

# --- A3: the RESTORE. Removing the plant returns the same invocation to green.
rm "$T/cloud/priv/repo/migrations/20260902120000_add_serving_since_basis.exs"
git -C "$T" add -A >/dev/null 2>&1
run_check --root "$T"
expect_rc 0 "A3 restore: removing the plant greens"

# --- A4: same version in DIFFERENT directories is NOT a collision. api/ and
# cloud/ have separate schema_migrations tables; flagging this would be a false
# red that teaches people to ignore the script.
T=$(new_tree a4); mkdir -p "$T/api/priv/repo/migrations"
cp "$T/cloud/priv/repo/migrations/20260902120000_add_colour.exs" \
   "$T/api/priv/repo/migrations/20260902120000_add_colour.exs"
git_init_tree "$T"
run_check --root "$T"
expect_rc 0 "A4 cross-directory version reuse is not a collision"

# --- A5: an EMPTY corpus is a read failure, not a clean repo. This is the
# false-green every corpus-scanning gate dies of.
mkdir -p "$TMP/a5/nothing"
run_check --root "$TMP/a5"
expect_rc 2 "A5 empty corpus refuses instead of passing"
expect_out "A5 empty corpus" "CANNOT READ: no migration files found"

printf '== Detector B: schema_migrations holds a version no file claims ==\n'

T=$(new_tree b1); git_init_tree "$T"

# --- B1: CONTROL. The recorded set equals the file set → green.
printf '20260901120000\n20260902120000\n' > "$TMP/versions_clean.txt"
run_check --root "$T" --dir cloud/priv/repo/migrations --db-versions-file "$TMP/versions_clean.txt"
expect_rc 0 "B1 control: recorded set matches the files"
expect_out "B1 control" "database: 2 versions recorded"

# --- B2: PLANT. A stale version 20260910160000 recorded with no file — the
# exact residue the 2026-09-10 incident left in the shared test database.
printf '20260901120000\n20260902120000\n20260910160000\n' > "$TMP/versions_stale.txt"
run_check --root "$T" --dir cloud/priv/repo/migrations --db-versions-file "$TMP/versions_stale.txt"
expect_rc 1 "B2 plant: orphaned recorded version reds"
expect_out "B2 plant" "VIOLATION (B orphaned version): schema_migrations holds 20260910160000"
expect_out "B2 plant" "cloud/priv/repo/migrations"

# --- B3: RESTORE. Same invocation, clean version list → green.
run_check --root "$T" --dir cloud/priv/repo/migrations --db-versions-file "$TMP/versions_clean.txt"
expect_rc 0 "B3 restore: the clean list greens the same invocation"

printf '== Detector C: the version was recorded BEFORE the file existed ==\n'

# The incident shape. Base ref has no 20260910160000 file; the branch ADDS one;
# the database already holds that version (the other lane put it there).
T=$(new_tree c1); git_init_tree "$T"
git -C "$T" branch -q base
printf 'defmodule R.M3 do\nend\n' > "$T/cloud/priv/repo/migrations/20260910160000_add_ledger_slot.exs"
git -C "$T" add -A >/dev/null 2>&1
git -C "$T" -c user.email=h@x -c user.name=h commit -q -m "add colliding migration" >/dev/null 2>&1

# --- C1: PLANT. Version already recorded + file added on this branch → red.
printf '20260901120000\n20260902120000\n20260910160000\n' > "$TMP/versions_c.txt"
run_check --root "$T" --dir cloud/priv/repo/migrations --db-versions-file "$TMP/versions_c.txt" --base-ref base
expect_rc 1 "C1 plant: recorded-before-added reds"
expect_out "C1 plant" "VIOLATION (C recorded before added): 20260910160000"
expect_out "C1 plant" "20260910160000_add_ledger_slot.exs"
expect_out "C1 plant" "Migrations already up"

# --- C2: RESTORE. Drop the version from the recorded set: the same added file
# is now an ordinary new migration and the run is green. (This also proves C
# keys on the DATABASE, not merely on "a migration file was added".)
run_check --root "$T" --dir cloud/priv/repo/migrations --db-versions-file "$TMP/versions_clean.txt" --base-ref base
expect_rc 0 "C2 restore: an added migration nobody recorded is fine"

# --- C3: an unresolvable base ref DISCLOSES. A shallow CI checkout has no base;
# a skip that prints nothing there would be a false green.
run_check --root "$T" --dir cloud/priv/repo/migrations --db-versions-file "$TMP/versions_clean.txt" --base-ref refs/heads/no-such-ref
expect_rc 0 "C3 unresolvable base ref does not fail the run"
expect_out "C3 unresolvable base ref" "NOT RUN: detector C"
expect_out "C3 unresolvable base ref" "DISCLOSURE:"

printf '== Disclosure and --require-db ==\n'

# --- D1: no database at all → the A-only run is green but SAYS SO.
T=$(new_tree d1); git_init_tree "$T"
run_check --root "$T"
expect_rc 0 "D1 no database: A-only run is green"
expect_out "D1 no database" "NOT RUN: detectors B and C"

# --- D2: the caller that needs B and C says --require-db, and a missing
# database is then exit 2, never a green.
run_check --root "$T" --require-db
expect_rc 2 "D2 --require-db turns a missing database into a refusal"
expect_out "D2 --require-db" "CANNOT READ: the database half was required"

# --- D3: a clean run with all three detectors live prints NO disclosure.
run_check --root "$T" --dir cloud/priv/repo/migrations --db-versions-file "$TMP/versions_clean.txt" --base-ref HEAD --require-db
expect_rc 0 "D3 all detectors live: green"
expect_no_out "D3 all detectors live" "DISCLOSURE:"

printf '== The REAL repository corpus ==\n'
# Detector A over this repository as it stands. Not a fixture: if two lanes have
# already landed colliding versions on this branch, this is where it is said.
run_check --root "$REPO"
expect_rc 0 "R1 the real migration corpus has no duplicate versions"
expect_out "R1 real corpus" "corpus:"

printf '== LIVE POSTGRES arm (detector B through psql) ==\n'
FIXTURE_DB=""
pg_reason=""
if ! command -v psql >/dev/null 2>&1 || ! command -v createdb >/dev/null 2>&1; then
  pg_reason="psql/createdb not on PATH"
elif ! psql -X -q -A -t -c 'select 1' postgres >/dev/null 2>&1; then
  pg_reason="no postgres server answered on the default connection"
fi

if [ -n "$pg_reason" ]; then
  printf 'NOT RUN: live postgres arm (P1-P3) — %s\n' "$pg_reason"
  skipped+=("live postgres arm (P1-P3): $pg_reason")
else
  FIXTURE_DB="migcheck_fixture_$$"
  if ! createdb "$FIXTURE_DB" >/dev/null 2>&1; then
    printf 'NOT RUN: live postgres arm (P1-P3) — createdb %s failed\n' "$FIXTURE_DB"
    skipped+=("live postgres arm (P1-P3): createdb failed")
    FIXTURE_DB=""
  else
    PGURL="postgres:///$FIXTURE_DB"
    T=$(new_tree p1); git_init_tree "$T"

    # P0: a database with no schema_migrations table at all is "nothing
    # recorded", not a read failure — a fresh `ecto.create` is exactly this.
    run_check --root "$T" --dir cloud/priv/repo/migrations --database-url "$PGURL"
    expect_rc 0 "P0 un-migrated fixture database is not a read failure"
    expect_out "P0 un-migrated" "database: 0 versions recorded"

    psql -X -q "$PGURL" -c 'create table schema_migrations (version bigint primary key, inserted_at timestamp)' >/dev/null 2>&1
    psql -X -q "$PGURL" -c "insert into schema_migrations values (20260901120000, now()), (20260902120000, now())" >/dev/null 2>&1

    # P1: CONTROL on a clean fixture database, read through psql.
    run_check --root "$T" --dir cloud/priv/repo/migrations --database-url "$PGURL" --require-db
    expect_rc 0 "P1 clean fixture database greens (psql read)"
    expect_out "P1 clean fixture database" "database: 2 versions recorded"

    # P2: PLANT a stale version IN THE DATABASE and watch the same command red.
    psql -X -q "$PGURL" -c "insert into schema_migrations values (20260910160000, now())" >/dev/null 2>&1
    run_check --root "$T" --dir cloud/priv/repo/migrations --database-url "$PGURL" --require-db
    expect_rc 1 "P2 stale row in the fixture database reds (psql read)"
    expect_out "P2 stale row" "VIOLATION (B orphaned version): schema_migrations holds 20260910160000"

    # P3: RESTORE by deleting the row.
    psql -X -q "$PGURL" -c "delete from schema_migrations where version = 20260910160000" >/dev/null 2>&1
    run_check --root "$T" --dir cloud/priv/repo/migrations --database-url "$PGURL" --require-db
    expect_rc 0 "P3 deleting the stale row greens the same command"

    # P4: an ecto:// URL is accepted (that is the scheme cloud/ config uses).
    run_check --root "$T" --dir cloud/priv/repo/migrations --database-url "ecto:///$FIXTURE_DB" --require-db
    expect_rc 0 "P4 an ecto:// URL is read as postgres://"
  fi
fi

printf -- '----\n'
if [ "${#skipped[@]}" -gt 0 ]; then
  printf 'DISCLOSURE: %s arm(s) did not run:\n' "${#skipped[@]}"
  for s in "${skipped[@]}"; do printf '  - %s\n' "$s"; done
fi
printf '%s assertions passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
