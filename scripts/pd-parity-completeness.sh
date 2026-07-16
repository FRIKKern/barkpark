#!/usr/bin/env bash
#
# pd-parity-completeness.sh — the anti-drift lock for the PortableDoc render-parity
# kitchen-sink array (render-path unification Wave 1, charter D8).
#
# It greps compose.ex's dispatched block types — the `"type" => "X"` clause heads
# AND the `t in [...]` guard members — subtracts the 14 excluded schema-field/embed
# types (charter D7), and FAILS if any in-scope type lacks a committed golden
# fixture. That is the mechanism that keeps the hand-authored array complete: add a
# new blog-grammar type to compose.ex and forget to seed it here → this reds.
#
# MUST run under bash (its shebang). Under zsh an unquoted `$var` does NOT
# word-split, so the loop would iterate once over the whole blob and the coverage
# check would be vacuous — a distrust-vacuous-green trap. Invoke as:
#     bash scripts/pd-parity-completeness.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$ROOT/api/lib/barkpark/portable_doc/render/compose.ex"
FIXTURES="$ROOT/api/test/support/fixtures/pd-parity"
EXPECTED_COUNT=46

if [ ! -f "$COMPOSE" ]; then
  echo "FAIL: compose.ex not found at $COMPOSE" >&2
  exit 1
fi

# The 14 excluded types (charter D7). Space-padded so a `case` glob matches whole
# words only. This is the ONE lever a later wave edits to pull the field-* set in.
EXCLUDED=" field-string field-slug field-text field-boolean field-select field-datetime field-color field-reference field-image composite arrayOf codelist localizedText embed "

# Dispatched types = `"type" => "X"` clause heads ∪ `t in [...]` guard members.
DISPATCHED="$(
  {
    grep -oE '"type" => "[a-zA-Z-]+"' "$COMPOSE" | sed -E 's/.*"type" => "//; s/"$//'
    grep -oE 't in \[[^]]+\]' "$COMPOSE" | grep -oE '"[a-zA-Z-]+"' | tr -d '"'
  } | sort -u
)"

count=0
missing=""
inscope=""
for t in $DISPATCHED; do
  case "$EXCLUDED" in
    *" $t "*) continue ;;
  esac
  count=$((count + 1))
  inscope="$inscope $t"
  if [ ! -f "$FIXTURES/$t.golden.json" ]; then
    missing="$missing $t"
  fi
done

echo "in-scope types:$inscope"
echo "in-scope count: $count"

if [ -n "$missing" ]; then
  echo "FAIL: no golden fixture for in-scope type(s):$missing" >&2
  echo "  → add it to @inputs and run \`MIX_ENV=test mix barkpark.portable_doc.gen_pd_parity\`" >&2
  exit 1
fi

if [ "$count" -ne "$EXPECTED_COUNT" ]; then
  echo "FAIL: expected $EXPECTED_COUNT in-scope types, computed $count" >&2
  echo "  → compose.ex gained/lost a dispatched type; reconcile the array + EXPECTED_COUNT" >&2
  exit 1
fi

echo "OK: all $count in-scope PortableDoc types have a golden fixture in"
echo "    $FIXTURES"
