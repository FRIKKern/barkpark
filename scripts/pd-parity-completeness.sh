#!/usr/bin/env bash
#
# pd-parity-completeness.sh — the anti-drift lock for the PortableDoc render-parity
# kitchen-sink array (render-path unification Wave 1, charter D8).
#
# It scans compose.ex's dispatched block types — the `"type" => "X"` clause heads
# AND the `when ... t in [...]` guard members — subtracts the 14 excluded
# schema-field/embed types (charter D7), and FAILS if any in-scope type lacks a
# committed golden fixture. That is the mechanism that keeps the hand-authored array
# complete: add a new blog-grammar type to compose.ex and forget to seed it here →
# this reds.
#
# Only compose_block function headers, ending before `do` / `do:`, contribute.
# Helpers, bodies and comments can contain identical type literals and guards.
# Literal-list aliases count; attribute/equality aliases still borrow their
# target golden. No Elixir runtime is needed in the doc-gates CI job.
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
# 2026-09-11 (gates/docgates-s27, task-bb00494a36b31342): 64 -> 65. #17199
# (c438d1215) added the reader-synthesised `pre-gate-badge` clause to compose.ex
# without its golden, which red this guard on main from 2026-09-09. Derivation:
# the DISPATCHED census below minus EXCLUDED, measured at 65 on this commit.
EXPECTED_COUNT=65

if [ ! -f "$COMPOSE" ]; then
  echo "FAIL: compose.ex not found at $COMPOSE" >&2
  exit 1
fi

# The 14 excluded types (charter D7). Space-padded so a `case` glob matches whole
# words only. This is the ONE lever a later wave edits to pull the field-* set in.
EXCLUDED=" field-string field-slug field-text field-boolean field-select field-datetime field-color field-reference field-image field-number composite arrayOf codelist localizedText embed "

# Join multiline headers before extracting literals. Track quoted strings and
# heredocs so comments and body/documentation text cannot open a fake header.
DISPATCHED="$(
  awk '
    function emit(header, rest, literal) {
      rest = header
      while (match(rest, /"type"[[:space:]]*=>[[:space:]]*"[a-zA-Z-]+"/)) {
        literal = substr(rest, RSTART, RLENGTH)
        sub(/^"type"[[:space:]]*=>[[:space:]]*"/, "", literal)
        sub(/"$/, "", literal)
        print literal
        rest = substr(rest, RSTART + RLENGTH)
      }
      if (header !~ /"type"[[:space:]]*=>[[:space:]]*t([^[:alnum:]_]|$)/) return
      rest = header
      while (match(rest, /(when|and)[[:space:]]+t[[:space:]]+in[[:space:]]*\[[^]]*\]/)) {
        literal = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        while (match(literal, /"[a-zA-Z-]+"/)) {
          print substr(literal, RSTART + 1, RLENGTH - 2)
          literal = substr(literal, RSTART + RLENGTH)
        }
      }
    }
    {
      if (!quote && !heredoc && /^[[:space:]]*defp?[[:space:]]+compose_block[[:space:]]*\(/) {
        active = 1
        header = ""
      }
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        triple = substr($0, i, 3)
        if (heredoc) {
          if (triple == heredoc) { heredoc = ""; i += 2 }
          continue
        }
        if (quote) {
          if (active) header = header c
          if (escaped) escaped = 0
          else if (c == "\\") escaped = 1
          else if (c == quote) quote = ""
          continue
        }
        if (c == "#") break
        if (c == "\"" || c == sprintf("%c", 39)) {
          if (triple == c c c) { heredoc = triple; i += 2; continue }
          quote = c
        }
        if (active && !quote && header ~ /[^[:alnum:]_!?]$/ &&
            substr($0, i) ~ /^do([[:space:]:,]|$)/) {
          emit(header)
          active = 0
        }
        if (active) header = header c
      }
      if (active) header = header " "
    }
  ' "$COMPOSE" | sort -u
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
