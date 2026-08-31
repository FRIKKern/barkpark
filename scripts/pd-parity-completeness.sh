#!/usr/bin/env bash
#
# pd-parity-completeness.sh — the anti-drift lock for the PortableDoc render-parity
# kitchen-sink array (render-path unification Wave 1, charter D8).
#
# It greps compose.ex's dispatched block types — the `"type" => "X"` clause heads
# AND the `when ... t in [...]` guard members — subtracts the 14 excluded
# schema-field/embed types (charter D7), and FAILS if any in-scope type lacks a
# committed golden fixture. That is the mechanism that keeps the hand-authored array
# complete: add a new blog-grammar type to compose.ex and forget to seed it here →
# this reds.
#
# The guard harvester is anchored on a literal `when ` / `and ` before `t in [` ON
# PURPOSE. A bare `t in \[` also matches the TAIL of any identifier ending in "t"
# — `layout in ["chapters", "timeline"]` contains the substring `t in [` — so the
# unanchored form harvested `paper-links` LAYOUT VARIANTS as if they were block
# types and demanded golden fixtures for block types that do not exist. Only the
# block-type dispatch guards bind the variable `t` (`compose_block(%{"type" => t}
# ...) when t in [...]`), so requiring the `when`/`and` keyword is exact, not lax.
# Anything genuinely new that this misses still reds via the EXPECTED_COUNT check
# below, which catches drift in BOTH directions.
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
# scaffy:add-block-type Diff MARK:parity-count-script-diff
# scaffy:add-block-type Filetree MARK:parity-count-script-filetree
# scaffy:add-block-type Blockquote MARK:parity-count-script-blockquote
# scaffy:add-block-type Toc MARK:parity-count-script-toc
# scaffy:add-block-type Steps MARK:parity-count-script-steps
# scaffy:add-block-type Footnote MARK:parity-count-script-footnote
# scaffy:add-block-type Expandable MARK:parity-count-script-expandable
# scaffy:add-block-type BarChart MARK:parity-count-script-bar-chart
# scaffy:add-block-type Equation MARK:parity-count-script-equation
# scaffy:add-block-type CriteriaProgress MARK:parity-count-script-criteria-progress
# scaffy:add-block-type Video MARK:parity-count-script-video
# scaffy:add-block-type ApiEndpoint MARK:parity-count-script-api-endpoint
# scaffy:add-block-type CodeTabs MARK:parity-count-script-code-tabs
# scaffy:add-block-type Tabs MARK:parity-count-script-tabs
# scaffy:add-block-type Route MARK:parity-count-script-route
EXPECTED_COUNT=64

if [ ! -f "$COMPOSE" ]; then
  echo "FAIL: compose.ex not found at $COMPOSE" >&2
  exit 1
fi

# The 14 excluded types (charter D7). Space-padded so a `case` glob matches whole
# words only. This is the ONE lever a later wave edits to pull the field-* set in.
EXCLUDED=" field-string field-slug field-text field-boolean field-select field-datetime field-color field-reference field-image field-number composite arrayOf codelist localizedText embed "

# Dispatched types = `"type" => "X"` clause heads ∪ `when|and t in [...]` guard
# members. See the header note on why the guard grep is keyword-anchored.
DISPATCHED="$(
  {
    grep -oE '"type" => "[a-zA-Z-]+"' "$COMPOSE" | sed -E 's/.*"type" => "//; s/"$//'
    grep -oE '(when|and) t in \[[^]]+\]' "$COMPOSE" | grep -oE '"[a-zA-Z-]+"' | tr -d '"'
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
