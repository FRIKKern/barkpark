#!/usr/bin/env bash
# connectors-ddl-drift-check.sh — DB-free drift gate for the bridge-owned
# chat_bridge.connector_installs DDL (connectors D54).
#
# The bridge OWNS this table's DDL (charter D28: no Ecto migration may create
# `chat_bridge`), but Elixir READS the table through an `@schema_prefix` schema,
# so api/test/test_helper.exs has to TRANSCRIBE the SQL — a SECOND source of
# truth that has ALREADY DRIFTED once (ADD_CHAT_TOKEN_REF_SQL exists precisely
# because `CREATE TABLE IF NOT EXISTS` was a no-op against P2's four-column
# table). This gate reds when the two disagree on the connector_installs COLUMN
# SET, so the read path can't silently rot into a Studio 500 in production.
#
# Modeled on scripts/docs-anchors-check.sh: pure bash 3.2 + awk, NO database.
# It compares connector_installs ONLY (W6-1's separate pending_connect table is
# ignored by construction), extracting column names from:
#   · connectors/src/db/schema.ts  — CREATE_CONNECTOR_INSTALLS_SQL + ADD_CHAT_TOKEN_REF_SQL
#   · api/test/test_helper.exs      — CREATE TABLE chat_bridge.connector_installs + its ALTER TABLE ADD COLUMN
#
# `--selftest` proves the tripwire in temp files (plants nothing in the tree):
# identical DDL stays green, a one-column drift reds.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SCHEMA_TS="connectors/src/db/schema.ts"
TEST_HELPER="api/test/test_helper.exs"

# Extract the sorted, de-duplicated connector_installs column-NAME set from a
# file. Column names are lowercase snake_case (the SQL keyword lines — PRIMARY
# KEY, CONSTRAINT — start uppercase and are skipped by the [a-z_] guard). The
# CREATE-TABLE body supplies the base columns; ALTER TABLE ... ADD COLUMN folds
# in any later-added column (chat_token_ref). Whitespace matched as [ \t] and
# char classes as explicit ranges for BSD-awk (macOS) / gawk (CI) parity.
extract_columns() {
  awk '
    # --- CREATE TABLE ... connector_installs ( ... ) ---
    /CREATE TABLE( IF NOT EXISTS)?[^(]*connector_installs[ \t]*\(/ { intable=1; next }
    intable && /^[ \t]*\)/ { intable=0; next }
    intable {
      if ($1 ~ /^[a-z_][a-z0-9_]*$/) print $1
      next
    }
    # --- ALTER TABLE ... connector_installs ... ADD COLUMN <name> ---
    /ALTER TABLE[^;]*connector_installs/ { inalter=1 }
    inalter && /ADD COLUMN/ {
      if (match($0, /ADD COLUMN( IF NOT EXISTS)? [a-z_][a-z0-9_]*/)) {
        frag = substr($0, RSTART, RLENGTH)
        n = split(frag, b, /[ \t]+/)
        print b[n]
        inalter = 0
      }
    }
  ' "$1" | sort -u
}

selftest() {
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  cat > "$tmp/schema.ts" <<'EOF'
export const CREATE_CONNECTOR_INSTALLS_SQL = `
CREATE TABLE IF NOT EXISTS ${CHAT_BRIDGE_SCHEMA}.connector_installs (
  provider       text NOT NULL,
  install_key    text NOT NULL,
  workspace_id   text NOT NULL,
  credential_ref text,
  PRIMARY KEY (provider, install_key)
)`;
export const ADD_CHAT_TOKEN_REF_SQL = `
ALTER TABLE ${CHAT_BRIDGE_SCHEMA}.connector_installs
  ADD COLUMN IF NOT EXISTS chat_token_ref text`;
EOF

  cat > "$tmp/agree.exs" <<'EOF'
Barkpark.Repo.query!("""
CREATE TABLE IF NOT EXISTS chat_bridge.connector_installs (
  provider       text NOT NULL,
  install_key    text NOT NULL,
  workspace_id   text NOT NULL,
  credential_ref text,
  PRIMARY KEY (provider, install_key)
)
""")
Barkpark.Repo.query!("""
ALTER TABLE chat_bridge.connector_installs
  ADD COLUMN IF NOT EXISTS chat_token_ref text
""")
EOF

  # dropped workspace_id from the exs side → a one-column drift
  cat > "$tmp/drift.exs" <<'EOF'
Barkpark.Repo.query!("""
CREATE TABLE IF NOT EXISTS chat_bridge.connector_installs (
  provider       text NOT NULL,
  install_key    text NOT NULL,
  credential_ref text,
  PRIMARY KEY (provider, install_key)
)
""")
Barkpark.Repo.query!("""
ALTER TABLE chat_bridge.connector_installs
  ADD COLUMN IF NOT EXISTS chat_token_ref text
""")
EOF

  local a b c
  a="$(extract_columns "$tmp/schema.ts")"
  b="$(extract_columns "$tmp/agree.exs")"
  c="$(extract_columns "$tmp/drift.exs")"

  if [ -z "$a" ] || [ -z "$b" ]; then
    echo "SELFTEST FAIL: extraction produced an empty column set"; return 1
  fi
  if [ "$a" != "$b" ]; then
    echo "SELFTEST FAIL: identical DDL was reported as drift"; return 1
  fi
  if [ "$a" = "$c" ]; then
    echo "SELFTEST FAIL: a one-column drift went undetected"; return 1
  fi
  echo "selftest OK: agree→green, one-column drift→red"
}

# Refuse an argument this gate does not understand. A swallowed flag — a
# `--selftest` typo, a future rename — would silently run the ordinary check
# and report green, fabricating the tripwire's own proof.
if [ -n "${1:-}" ] && [ "$1" != "--selftest" ]; then
  echo "connectors-ddl-drift-check: unknown argument '$1' (expected nothing or --selftest)" >&2
  exit 2
fi

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

cd "$REPO_ROOT"

for f in "$SCHEMA_TS" "$TEST_HELPER"; do
  [ -f "$f" ] || { echo "FAIL: DDL source not found: $f"; exit 1; }
done

SCHEMA_COLS="$(extract_columns "$SCHEMA_TS")"
TEST_COLS="$(extract_columns "$TEST_HELPER")"

# Guard against a silent parse break (anchors moved / block renamed): an empty
# set means the extractor found nothing, NOT that the tables agree.
if [ -z "$SCHEMA_COLS" ]; then
  echo "FAIL: no connector_installs columns parsed from $SCHEMA_TS (CREATE_CONNECTOR_INSTALLS_SQL moved or renamed?)"; exit 1
fi
if [ -z "$TEST_COLS" ]; then
  echo "FAIL: no connector_installs columns parsed from $TEST_HELPER (CREATE TABLE chat_bridge.connector_installs moved or renamed?)"; exit 1
fi

if [ "$SCHEMA_COLS" != "$TEST_COLS" ]; then
  s_flat="$(printf '%s\n' "$SCHEMA_COLS" | tr '\n' ' ' | sed 's/ *$//')"
  t_flat="$(printf '%s\n' "$TEST_COLS"  | tr '\n' ' ' | sed 's/ *$//')"
  only_schema="$(comm -23 <(printf '%s\n' "$SCHEMA_COLS") <(printf '%s\n' "$TEST_COLS") | tr '\n' ' ' | sed 's/ *$//')"
  only_test="$(comm -13 <(printf '%s\n' "$SCHEMA_COLS") <(printf '%s\n' "$TEST_COLS") | tr '\n' ' ' | sed 's/ *$//')"
  echo "FAIL: chat_bridge.connector_installs DDL DRIFT — schema.ts and test_helper.exs disagree (connectors D54)"
  echo "  $SCHEMA_TS declares [$s_flat]"
  echo "  but $TEST_HELPER declares [$t_flat]"
  [ -n "$only_schema" ] && echo "  only in schema.ts:      $only_schema"
  [ -n "$only_test" ]   && echo "  only in test_helper.exs: $only_test"
  echo "  → update BOTH $SCHEMA_TS and $TEST_HELPER (they are two sources of one truth)"
  exit 1
fi

echo "connectors-ddl-drift-check: PASS — connector_installs columns agree [$(printf '%s\n' "$SCHEMA_COLS" | tr '\n' ' ' | sed 's/ *$//')]"
