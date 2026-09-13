#!/usr/bin/env bash
# migration-version-collision-check.sh — a migration version that is already
# recorded must belong to the file that recorded it. Anything else is a SILENT
# NO-OP, and this script is the loud refusal that replaces it.
#
# ── THE DEFECT (task-ac34d17c2aba4458, GitHub #17494) ────────────────────────
#
# Measured 2026-09-10 by lead-deploy-r5/w3: a new cloud migration was minted as
# `20260910160000_*.exs`. A concurrent lane had ALREADY landed
# `20260910160000_add_serving_since_basis*.exs` (#17401), and the campaign's
# workers share ONE `barkpark_cloud_test` database. Ecto keys `schema_migrations`
# on the VERSION INTEGER ALONE — it stores no filename, no checksum — so the row
# `20260910160000` was already present. `mix ecto.migrate` printed
# `Migrations already up`, applied NOTHING, exited 0, and the worker's suite was
# one `mix test` away from running against a table missing its new columns. The
# collision was found only by hand-querying `information_schema`.
#
# Round-number, hand-typed timestamps minted by two lanes inside the same hour
# are the NORMAL case in this campaign, not an accident. The failure is silent in
# both directions: migrate says "up", the suite says green, and the schema the
# green was measured against is not the schema the PR describes.
#
#   THE INVARIANT: a migration version must identify exactly one migration FILE.
#   If two files claim one version, or the database holds a version no file
#   claims, or the database recorded a version BEFORE the file now bearing it
#   existed, the build must REFUSE — never no-op.
#
# ── THE THREE DETECTORS, and why there are three ─────────────────────────────
#
#   A  DUPLICATE FILES (no database, always runs). Two tracked migration files
#      in the SAME directory share a version. This is the shape the trap takes
#      once the OTHER lane merges: the losing branch then carries both files and
#      `mix ecto.migrate` will run exactly one of them, forever. Cheap, hermetic,
#      and the only detector that works on a runner with no database.
#
#   B  ORPHANED DB VERSION (needs a database). `schema_migrations` holds a
#      version that NO file in the directory claims. On a shared development
#      database this is the trap's fingerprint AFTER the other lane's file has
#      moved on or been renamed; on a disposable CI service container it is
#      expected to be empty, which is why B passing is worth little in CI and a
#      great deal locally.
#
#   C  RECORDED-BEFORE-ADDED (needs a database AND a resolvable base ref). A
#      version is present in `schema_migrations` and the file bearing it is ADDED
#      by this branch relative to the base ref. That is the 2026-09-10 incident
#      EXACTLY: the row predates the file, so `ecto.migrate` will skip the file.
#      C is the only detector that names the incident directly, and it is also
#      the one most often unavailable (a `fetch-depth: 1` checkout has no base),
#      which is why its absence is DISCLOSED rather than silently passed over.
#
# A DETECTOR THAT DID NOT RUN IS NOT A DETECTOR THAT PASSED. Every half that is
# skipped prints its own `NOT RUN:` line and that line is repeated in the closing
# summary. A green with no `NOT RUN:` lines is a green over all three detectors;
# a green with them is a green over the ones named. Both are exit 0 — the caller
# that wants B and C to be mandatory passes --require-db.
#
# Exit codes: 0 = no violation. 1 = at least one violation (printed). 2 = an
# input could not be read (`CANNOT READ:`) — never conflated with a clean run.
#
# Harness: scripts/migration-version-collision-check.test.sh (mutation matrix,
# including a real postgres fixture database when one is reachable).

set -euo pipefail

ROOT=""
DIR=""
DATABASE_URL_ARG=""
DB_VERSIONS_FILE=""
BASE_REF=""
REQUIRE_DB=0

usage() {
  cat <<'USAGE'
usage: migration-version-collision-check.sh [options]

  --root DIR            repository root to scan (default: git toplevel, else cwd)
  --dir PATH            migration directory the database half applies to
                        (repo-relative, e.g. cloud/priv/repo/migrations)
  --database-url URL    ecto:// or postgres:// URL for that directory's database
  --db-versions-file F  read schema_migrations versions from F (one per line)
                        instead of querying; for harnesses and for callers that
                        already have the list
  --base-ref REF        git ref the branch is measured against (detector C)
  --require-db          a database half that cannot run is a FAILURE, not a
                        disclosure (exit 2)
  -h, --help            this text

Detectors: A duplicate migration files sharing a version (always);
B a schema_migrations version no file claims (needs a database);
C a schema_migrations version whose file this branch ADDS (needs a database
and a base ref) — the silent `Migrations already up` no-op.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --dir) DIR="${2:-}"; shift 2 ;;
    --database-url) DATABASE_URL_ARG="${2:-}"; shift 2 ;;
    --db-versions-file) DB_VERSIONS_FILE="${2:-}"; shift 2 ;;
    --base-ref) BASE_REF="${2:-}"; shift 2 ;;
    --require-db) REQUIRE_DB=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'CANNOT READ: unknown argument %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$ROOT" ]; then
  if ROOT=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$ROOT" ]; then
    :
  else
    ROOT="$PWD"
  fi
fi
if [ ! -d "$ROOT" ]; then
  printf 'CANNOT READ: --root %s is not a directory\n' "$ROOT" >&2
  exit 2
fi

violations=0
notrun=()

note_not_run() {
  printf 'NOT RUN: %s\n' "$1"
  notrun+=("$1")
}

# ── The migration file corpus ────────────────────────────────────────────────
# Tracked files first (git ls-files: authoritative, ignores _build/deps/node
# copies by construction). A checkout that is not a git repository falls back to
# `find` with those trees pruned. A corpus that comes back EMPTY is a read
# failure, not a clean repo — this repository has had migrations since its first
# month, and an empty corpus is how every detector here false-greens at once.
corpus_source=""
files=""
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  corpus_source="git ls-files"
  files=$(git -C "$ROOT" ls-files -- '*/migrations/*.exs' 'migrations/*.exs' || true)
else
  corpus_source="find"
  files=$(cd "$ROOT" && find . \
    \( -name _build -o -name deps -o -name node_modules -o -name .git \) -prune -o \
    -type f -name '*.exs' -print 2>/dev/null | sed 's|^\./||' | grep '/migrations/' || true)
fi

# Keep only Ecto-shaped migration files: <8-or-more digits>_<name>.exs
files=$(printf '%s\n' "$files" | grep -E '(^|/)migrations/[0-9]{8,}_[^/]*\.exs$' || true)

if [ -z "$files" ]; then
  printf 'CANNOT READ: no migration files found under %s (corpus source: %s)\n' \
    "$ROOT" "$corpus_source" >&2
  exit 2
fi

file_count=$(printf '%s\n' "$files" | wc -l | tr -d ' ')
dir_count=$(printf '%s\n' "$files" | sed -E 's|/[^/]*$||' | sort -u | wc -l | tr -d ' ')
printf 'corpus: %s migration files in %s directories (source: %s, root: %s)\n' \
  "$file_count" "$dir_count" "$corpus_source" "$ROOT"

# ── Detector A: two files, one version, one directory ────────────────────────
# Keyed on (directory, version) — NOT on version alone. api/ and cloud/ are
# different repositories with different schema_migrations tables, and the test
# fixture tree under api/test is a third; a version shared ACROSS them collides
# with nothing and flagging it would be a false red that trains people to ignore
# this script.
dup_keys=$(printf '%s\n' "$files" \
  | awk '{ d=$0; sub(/\/[^\/]*$/, "", d); f=$0; sub(/.*\//, "", f); v=f; sub(/_.*/, "", v); print d "\t" v }' \
  | sort | uniq -d || true)

if [ -n "$dup_keys" ]; then
  while IFS=$'\t' read -r d v; do
    [ -n "$d" ] || continue
    violations=$((violations + 1))
    printf 'VIOLATION (A duplicate version): %s in %s is claimed by more than one file:\n' "$v" "$d"
    printf '%s\n' "$files" | grep -E "^${d}/${v}_[^/]*\.exs$" | sed 's/^/    /'
    printf '    `mix ecto.migrate` keys on the version integer alone: it will run ONE of these and silently skip the rest. Renumber the newer file.\n'
  done <<EOF
$dup_keys
EOF
fi

# ── The database half (detectors B and C) ────────────────────────────────────
db_reason=""
db_versions=""

if [ -z "$DIR" ]; then
  db_reason="no --dir given, so no directory is bound to a database"
elif [ ! -d "$ROOT/$DIR" ]; then
  printf 'CANNOT READ: --dir %s does not exist under %s\n' "$DIR" "$ROOT" >&2
  exit 2
elif [ -n "$DB_VERSIONS_FILE" ]; then
  if [ ! -r "$DB_VERSIONS_FILE" ]; then
    printf 'CANNOT READ: --db-versions-file %s is not readable\n' "$DB_VERSIONS_FILE" >&2
    exit 2
  fi
  db_versions=$(grep -E '^[0-9]+$' "$DB_VERSIONS_FILE" || true)
elif [ -n "$DATABASE_URL_ARG" ]; then
  if ! command -v psql >/dev/null 2>&1; then
    db_reason="psql is not on PATH, so schema_migrations cannot be read"
  else
    # ecto://user:pass@host/db is postgres://user:pass@host/db with a different
    # scheme word; psql understands the latter only.
    pg_url=${DATABASE_URL_ARG/#ecto:\/\//postgres://}
    psql_out=""
    psql_rc=0
    psql_out=$(psql "$pg_url" -X -q -A -t \
      -c "select version from schema_migrations order by version" 2>&1) || psql_rc=$?
    if [ "$psql_rc" -ne 0 ]; then
      # A database that exists but has never been migrated has no
      # schema_migrations table; that is "nothing recorded", not a read failure.
      case "$psql_out" in
        *'relation "schema_migrations" does not exist'*) db_versions="" ;;
        *) db_reason="psql could not read schema_migrations (exit $psql_rc): $(printf '%s' "$psql_out" | tr '\n' ' ')" ;;
      esac
    else
      db_versions=$(printf '%s\n' "$psql_out" | grep -E '^[0-9]+$' || true)
    fi
  fi
else
  db_reason="neither --database-url nor --db-versions-file was given"
fi

if [ -n "$db_reason" ]; then
  if [ "$REQUIRE_DB" -eq 1 ]; then
    printf 'CANNOT READ: the database half was required but did not run: %s\n' "$db_reason" >&2
    exit 2
  fi
  note_not_run "detectors B and C (schema_migrations vs files) — $db_reason"
else
  dir_versions=$(printf '%s\n' "$files" \
    | grep -E "^${DIR}/[0-9]{8,}_[^/]*\.exs$" \
    | sed -E 's|.*/([0-9]+)_.*|\1|' | sort -u || true)
  recorded=$(printf '%s\n' "$db_versions" | grep -E '^[0-9]+$' | sort -u || true)
  recorded_count=0
  [ -n "$recorded" ] && recorded_count=$(printf '%s\n' "$recorded" | wc -l | tr -d ' ')
  printf 'database: %s versions recorded in schema_migrations for %s\n' "$recorded_count" "$DIR"

  # Detector B: recorded, but no file claims it.
  while read -r v; do
    [ -n "$v" ] || continue
    if ! printf '%s\n' "$dir_versions" | grep -qx "$v"; then
      violations=$((violations + 1))
      printf 'VIOLATION (B orphaned version): schema_migrations holds %s but NO file in %s claims it.\n' "$v" "$DIR"
      printf '    expected a file named %s/%s_<name>.exs; the directory holds none.\n' "$DIR" "$v"
      printf '    `mix ecto.migrate` will report this version as already up. If a file is later minted with it, that file will NEVER run.\n'
    fi
  done <<EOF
$recorded
EOF

  # Detector C: recorded AND the file bearing it is added by this branch.
  if [ -z "$BASE_REF" ]; then
    note_not_run "detector C (recorded-before-added) — no --base-ref given"
  elif ! git -C "$ROOT" rev-parse --verify --quiet "$BASE_REF" >/dev/null 2>&1; then
    note_not_run "detector C (recorded-before-added) — base ref '$BASE_REF' does not resolve in this checkout (a shallow clone has no merge base)"
  else
    added=""
    added_rc=0
    added=$(git -C "$ROOT" diff --name-only --diff-filter=A "$BASE_REF"...HEAD -- "$DIR" 2>/dev/null) || added_rc=$?
    if [ "$added_rc" -ne 0 ]; then
      note_not_run "detector C (recorded-before-added) — git diff against '$BASE_REF' failed (exit $added_rc)"
    else
      while read -r f; do
        [ -n "$f" ] || continue
        case "$f" in
          "$DIR"/*) : ;;
          *) continue ;;
        esac
        base=${f##*/}
        v=${base%%_*}
        printf '%s' "$v" | grep -qE '^[0-9]{8,}$' || continue
        if printf '%s\n' "$recorded" | grep -qx "$v"; then
          violations=$((violations + 1))
          printf 'VIOLATION (C recorded before added): %s is ALREADY in schema_migrations, but %s is added by this branch relative to %s.\n' "$v" "$f" "$BASE_REF"
          printf '    The row predates the file. `mix ecto.migrate` will print `Migrations already up` and apply NOTHING from it; the suite then runs against a schema this migration never touched.\n'
          printf '    Renumber %s to a version no other lane has taken.\n' "$f"
        fi
      done <<EOF
$added
EOF
    fi
  fi
fi

printf -- '----\n'
if [ "${#notrun[@]}" -gt 0 ]; then
  printf 'DISCLOSURE: %s detector(s) did not run and therefore say NOTHING:\n' "${#notrun[@]}"
  for n in "${notrun[@]}"; do
    printf '  - %s\n' "$n"
  done
fi

if [ "$violations" -gt 0 ]; then
  printf 'REFUSED: %s migration version violation(s).\n' "$violations"
  exit 1
fi

printf 'OK: every migration version identifies exactly one file across the detectors that ran.\n'
exit 0
