#!/usr/bin/env bash
#
# pd-parity-completeness.sh — the anti-drift lock for the PortableDoc render-parity
# kitchen-sink array (render-path unification Wave 1, charter D8).
#
# It derives compose.ex's dispatched block types, subtracts the excluded
# schema-field/embed types (charter D7), and FAILS if any in-scope type lacks a
# committed golden fixture. That is the mechanism that keeps the hand-authored array
# complete: add a new blog-grammar type to compose.ex and forget to seed it here →
# this reds.
#
# ── THE CENSUS IS ANCHORED ON `def compose_block/2,3` CLAUSE HEADS ────────────
# It used to be a FILE-WIDE grep pair over compose.ex — `"type" => "X"` anywhere
# in the file, plus `when|and t in [...]` anywhere in the file. Both halves read
# text that is not a block-type dispatch:
#
#   #17811 (abe58a4d2) added the private `table_col_types/2` helper, whose
#   anonymous-fn clauses name TABLE COLUMN types — `num`, `delta`, `spark`. The
#   file-wide `"type" => "X"` half harvested all three as block types, the census
#   went 65 → 68, and this guard has RED on main ever since, demanding golden
#   fixtures for three types that are not blocks and can never have one.
#
# The same over-match hit tiers_test.exs's sibling census, and #18166 (e671915ea)
# fixed it there by re-anchoring on `def compose_block/2,3` clause heads read off
# the AST. This is the port of that extractor into shell — the SECOND of the two
# consumers. The naming semantics are #18166's, unchanged: a type is named either
# by a literal `"type" => "x"` in the first-argument map pattern, or by a literal
# `t in ["x","y"]` guard over the variable that pattern binds. `t == "x"` and
# `t in @attr` stay OUT — those are compose.ex's documented ALIAS forms, and an
# alias has no tier of its own.
#
# The port was proved against the Elixir extractor as an oracle: on compose.ex at
# 7bc83e643 the two agree exactly — 80 types, empty set difference in BOTH
# directions — and they agree on all four of #18166's fixtures and on compose.ex
# at e671915ea^, where `table_col_types/2` still used the literal-pattern form.
# 80 types minus the 15 EXCLUDED = 65 = EXPECTED_COUNT, which the golden-fixture
# directory independently corroborates at 65 files.
#
# `bash scripts/pd-parity-completeness.sh --selftest` runs the controls on the
# instrument (a green on the real file proves nothing when the instrument IS the
# subject). It plants nothing in the tree.
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

# ── THE EXTRACTOR ────────────────────────────────────────────────────────────
# Reads ONLY `def compose_block/2,3` clause heads. The awk program tracks quote
# and bracket depth so it can (a) find where each clause head ends and stop
# before the body, and (b) split the argument list on TOP-LEVEL commas to check
# the arity. Nothing outside a clause head can move the number.
compose_block_clause_types() {
  awk '
function scan(line,   i, n, c) {
  n = length(line)
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)
    if (instr) {
      buf = buf c
      if (c == "\\") { i++; buf = buf substr(line, i, 1); continue }
      if (c == "\"") instr = 0
      continue
    }
    if (c == "#") return 0
    if (c == "\"") { instr = 1; buf = buf c; continue }
    if (c == "(" || c == "[" || c == "{") { depth++; buf = buf c; continue }
    if (c == ")" || c == "]" || c == "}") { depth--; buf = buf c; continue }
    if (depth == 0 && c == "d" && substr(line, i, 3) == "do:" &&
        (i == 1 || substr(line, i - 1, 1) !~ /[A-Za-z0-9_.:@]/)) return 1
    if (depth == 0 && c == "d" && substr(line, i, 2) == "do" &&
        (i == 1 || substr(line, i - 1, 1) !~ /[A-Za-z0-9_.:@]/) &&
        (i + 2 > n || substr(line, i + 2, 1) !~ /[A-Za-z0-9_?!:]/)) return 1
    buf = buf c
  }
  return 0
}
function emit(h,   p, s, i, c, d, q, cur, nargs, a1, m, var, guard, g, seg, lit) {
  p = index(h, "compose_block(")
  if (p == 0) return
  s = substr(h, p + 14)
  delete args
  d = 0; q = 0; cur = ""; nargs = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (q) {
      cur = cur c
      if (c == "\\") { i++; cur = cur substr(s, i, 1); continue }
      if (c == "\"") q = 0
      continue
    }
    if (c == "\"") { q = 1; cur = cur c; continue }
    if (c == "(" || c == "[" || c == "{") { d++; cur = cur c; continue }
    if (c == ")" || c == "]" || c == "}") { if (d == 0) break; d--; cur = cur c; continue }
    if (c == "," && d == 0) { nargs++; args[nargs] = cur; cur = ""; continue }
    cur = cur c
  }
  nargs++; args[nargs] = cur
  guard = substr(s, i + 1)
  # arity 2 or 3 only — `compose_block/1` is the email-default shim, not a dispatch.
  if (nargs != 2 && nargs != 3) return
  a1 = args[1]
  # a literal `"type" => "x"` in the first-argument map pattern …
  if (match(a1, /"type"[ \t]*=>[ \t]*"[A-Za-z0-9_-]+"/)) {
    m = substr(a1, RSTART, RLENGTH)
    sub(/^"type"[ \t]*=>[ \t]*"/, "", m); sub(/"$/, "", m)
    print m
    return
  }
  # … or a literal `t in ["x","y"]` guard over the variable it binds.
  # `t == "x"` and `t in @attr` are compose.ex ALIAS forms and stay out.
  if (match(a1, /"type"[ \t]*=>[ \t]*[a-z_][A-Za-z0-9_]*/)) {
    m = substr(a1, RSTART, RLENGTH)
    sub(/^"type"[ \t]*=>[ \t]*/, "", m)
    var = m
    g = guard
    while (match(g, "(^|[^A-Za-z0-9_])" var "[ \t]+in[ \t]*\\[[^]]*\\]")) {
      seg = substr(g, RSTART, RLENGTH)
      g = substr(g, RSTART + RLENGTH)
      while (match(seg, /"[A-Za-z0-9_-]+"/)) {
        lit = substr(seg, RSTART + 1, RLENGTH - 2)
        print lit
        seg = substr(seg, RSTART + RLENGTH)
      }
    }
  }
}
# Track literals outside clause heads too: documentation/body strings can
# contain apparent function declarations that must not start a census entry.
function track_literals(line,   i, c, triple) {
  for (i = 1; i <= length(line); i++) {
    c = substr(line, i, 1)
    triple = substr(line, i, 3)
    if (heredoc) {
      if (triple == heredoc) { heredoc = ""; i += 2 }
      continue
    }
    if (quote) {
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
  }
}
BEGIN { collecting = 0; depth = 0; instr = 0; buf = "" }
{
  if (!collecting && !quote && !heredoc &&
      $0 ~ /^[ \t]*def[ \t]+compose_block\(/) {
    collecting = 1; depth = 0; instr = 0; buf = ""
  }
  if (collecting) {
    if (scan($0)) { emit(buf); collecting = 0; buf = "" } else { buf = buf " " }
  }
  track_literals($0)
}
END { if (collecting) emit(buf) }
' "$1" | sort -u
}

# The RETIRED file-wide greps, kept for exactly one purpose: they are the control
# arm of --selftest. Without running the OLD computation on the SAME fixture and
# showing that it DOES swallow the column types, "the new one ignores them" would
# pass on a fixture that never had a trap in it, and the control would be vacuous.
legacy_dispatched_types() {
  {
    grep -oE '"type" => "[a-zA-Z-]+"' "$1" | sed -E 's/.*"type" => "//; s/"$//' || true
    grep -oE '(when|and) t in \[[^]]+\]' "$1" | grep -oE '"[a-zA-Z-]+"' | tr -d '"' || true
  } | sort -u
}

# The 15 excluded types (charter D7), plus `master-ref` (task-59f078a2fd248698:
# a linked master instance resolves server side at read time, like `embed`). Space-padded so a `case` glob matches whole
# words only. This is the ONE lever a later wave edits to pull the field-* set in.
EXCLUDED=" field-string field-slug field-text field-boolean field-select field-datetime field-color field-reference field-image field-number composite arrayOf codelist localizedText embed master-ref "

# ── --selftest: CONTROLS ON THE INSTRUMENT ───────────────────────────────────
# This guard's whole failure mode is a census that answers confidently about a
# population it never measured. A green on the real compose.ex proves nothing
# about that, so every arm below runs on a FIXTURE whose correct answer is known
# by construction. Plants nothing in the tree: everything lives in a mktemp dir.
selftest_fail=0

_st_assert() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ok   $label"
  else
    echo "  FAIL $label" >&2
    echo "         expected: [$expected]" >&2
    echo "         actual:   [$actual]" >&2
    selftest_fail=1
  fi
}

# Build a throwaway repo root: this script + a compose.ex + the real golden dir.
_st_root() {
  local dir="$1" compose_src="$2"
  mkdir -p "$dir/scripts" "$dir/api/lib/barkpark/portable_doc/render" "$dir/api/test/support"
  cp "${BASH_SOURCE[0]}" "$dir/scripts/pd-parity-completeness.sh"
  cp "$compose_src" "$dir/api/lib/barkpark/portable_doc/render/compose.ex"
  ln -s "$FIXTURES" "$dir/api/test/support/fixtures" 2>/dev/null || {
    mkdir -p "$dir/api/test/support/fixtures"
    ln -s "$FIXTURES" "$dir/api/test/support/fixtures/pd-parity"
  }
}

run_selftest() {
  # NOT `local`: the EXIT trap fires after this function has returned, so a
  # function-scoped $tmp would be unbound by the time the trap runs (`set -u`
  # then turns a clean SELFTEST OK into exit 1 — measured).
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  cat > "$tmp/two_forms.ex" <<'EOF'
defmodule Fixture do
  def compose_block(%{"type" => "alpha"} = b, style), do: {b, style}
  def compose_block(%{"type" => t} = b, style) when t in ["beta", "gamma"], do: {b, style}
end
EOF

  # #17811's trap, GUARD form — what compose.ex has today.
  cat > "$tmp/trap_guard.ex" <<'EOF'
defmodule Fixture do
  def compose_block(%{"type" => "alpha"} = b, style), do: {b, style}

  defp table_col_types(cols) do
    Enum.map(cols, fn
      %{"type" => t} when t in ["text", "num", "delta", "spark"] -> t
      _ -> "text"
    end)
  end
end
EOF

  # #17811's trap, LITERAL-PATTERN form — what the ban comment deleted by #18166
  # mandated. THIS is the shape that red *this* script: the retired file-wide
  # `"type" => "X"` grep never cared which form it was.
  cat > "$tmp/trap_literal.ex" <<'EOF'
defmodule Fixture do
  def compose_block(%{"type" => "alpha"} = b, style), do: {b, style}

  defp table_col_types(cols) do
    Enum.map(cols, fn
      %{"type" => "num"} -> "num"
      %{"type" => "delta"} -> "delta"
      %{"type" => "spark"} -> "spark"
      _ -> "text"
    end)
  end
end
EOF

  cat > "$tmp/multiline.ex" <<'EOF'
defmodule Fixture do
  def compose_block(
        %{"type" => "alpha"} = b,
        style
      ),
      do: {b, style}
end
EOF

  cat > "$tmp/none.ex" <<'EOF'
defmodule Fixture do
  defp helper(t) when t in ["alpha", "beta"], do: t
end
EOF

  echo "POSITIVE CONTROL: both clause-head forms are read"
  _st_assert "literal head + \`t in [...]\` guard head" \
    "alpha beta gamma" \
    "$(compose_block_clause_types "$tmp/two_forms.ex" | tr '\n' ' ' | sed 's/ $//')"

  echo "NEGATIVE CONTROL (#17811's trap): a non-block helper cannot move the count"
  _st_assert "guard form: new census sees only the block type" \
    "alpha" \
    "$(compose_block_clause_types "$tmp/trap_guard.ex" | tr '\n' ' ' | sed 's/ $//')"
  _st_assert "guard form: the RETIRED computation DOES swallow the column types" \
    "alpha delta num spark text" \
    "$(legacy_dispatched_types "$tmp/trap_guard.ex" | tr '\n' ' ' | sed 's/ $//')"
  _st_assert "literal form: new census sees only the block type" \
    "alpha" \
    "$(compose_block_clause_types "$tmp/trap_literal.ex" | tr '\n' ' ' | sed 's/ $//')"
  _st_assert "literal form: the RETIRED computation DOES swallow the column types" \
    "alpha delta num spark" \
    "$(legacy_dispatched_types "$tmp/trap_literal.ex" | tr '\n' ' ' | sed 's/ $//')"

  # A wrapped clause head. NOTE, and this is a REAL divergence from #18166: the
  # Elixir test's retired regex required `compose_block(%{"type" => "` contiguous
  # on one line, so it was BLIND to a formatter-wrapped head. THIS script's
  # retired regex was looser still — a bare file-wide `"type" => "X"` with no
  # `compose_block(` anchor at all — so it was never blind in that direction. It
  # failed in the OVER-match direction ONLY, which is exactly why the literal
  # map-pattern form the (now deleted) ban comment in compose.ex mandated did not
  # protect this consumer the way it protected the Elixir one. The arm asserts
  # that difference rather than assuming the two retired regexes were the same.
  echo "MULTI-LINE CLAUSE HEAD: read by the new census"
  _st_assert "new census reads the wrapped head" \
    "alpha" \
    "$(compose_block_clause_types "$tmp/multiline.ex" | tr '\n' ' ' | sed 's/ $//')"
  _st_assert "the RETIRED computation was NOT blind here — it over-matched, never under-matched" \
    "alpha" \
    "$(legacy_dispatched_types "$tmp/multiline.ex" | tr '\n' ' ' | sed 's/ $//')"

  echo "EMPTY-POPULATION REFUSAL: a census that narrows to nothing must REFUSE"
  _st_assert "nothing to read yields an empty census" \
    "" \
    "$(compose_block_clause_types "$tmp/none.ex" | tr '\n' ' ' | sed 's/ $//')"
  # …and the empty census is a real outcome on the file this guard is about:
  local real_n
  real_n="$(compose_block_clause_types "$COMPOSE" | wc -l | tr -d ' ')"
  if [ "$real_n" -gt 30 ]; then
    echo "  ok   the real compose.ex census is non-empty ($real_n types)"
  else
    echo "  FAIL the real compose.ex census is $real_n — the extractor measured nothing" >&2
    selftest_fail=1
  fi
  # …and the WHOLE GUARD refuses on it rather than reporting 0 missing and exit 0.
  _st_root "$tmp/empty" "$tmp/none.ex"
  set +e
  local out rc
  out="$(bash "$tmp/empty/scripts/pd-parity-completeness.sh" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "census is EMPTY"; then
    echo "  ok   the guard REFUSES an empty census (exit $rc)"
  else
    echo "  FAIL an empty census did not refuse: exit $rc" >&2
    printf '%s\n' "$out" >&2
    selftest_fail=1
  fi

  echo "STILL-SIGHTED: narrowing the census until the red goes away is the FORBIDDEN remedy"
  _st_root "$tmp/sighted" "$COMPOSE"
  # A genuinely new DISPATCHED block type with no golden fixture.
  cat >> "$tmp/sighted/api/lib/barkpark/portable_doc/render/compose.ex" <<'EOF'

defmodule SelftestProbe do
  def compose_block(%{"type" => "selftest-probe"} = b, style), do: {b, style}
end
EOF
  set +e
  out="$(bash "$tmp/sighted/scripts/pd-parity-completeness.sh" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "selftest-probe"; then
    echo "  ok   a new dispatched type with no golden still REDs (exit $rc)"
  else
    echo "  FAIL a new dispatched type with no golden did not red: exit $rc" >&2
    printf '%s\n' "$out" >&2
    selftest_fail=1
  fi

  if [ "$selftest_fail" -ne 0 ]; then
    echo "SELFTEST FAILED" >&2
    exit 1
  fi
  echo "SELFTEST OK"
}

if [ "${1:-}" = "--selftest" ]; then
  if [ ! -f "$COMPOSE" ]; then
    echo "FAIL: compose.ex not found at $COMPOSE" >&2
    exit 1
  fi
  run_selftest
  exit 0
fi

if [ ! -f "$COMPOSE" ]; then
  echo "FAIL: compose.ex not found at $COMPOSE" >&2
  exit 1
fi

DISPATCHED="$(compose_block_clause_types "$COMPOSE")"

# A census that silently narrows to nothing makes every membership check below it
# pass vacuously. Refuse, loudly, rather than report "0 missing fixtures".
if [ -z "$DISPATCHED" ]; then
  echo "FAIL: the \`def compose_block/2,3\` census is EMPTY — the extractor measured nothing" >&2
  echo "  → compose.ex moved, or the clause-head reader broke. Run --selftest." >&2
  exit 1
fi

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
