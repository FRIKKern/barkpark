#!/usr/bin/env bash
# Hermetic regression: exercise the real gate with copies of committed goldens.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pd-parity-completeness.XXXXXX")"
# Recoverable local cleanup; disposable CI runners need no trash installation.
trap 'if command -v trash >/dev/null 2>&1; then trash "$TMP"; else echo "Test tree retained: $TMP"; fi' EXIT
mkdir -p "$TMP/scripts" "$TMP/api/lib/barkpark/portable_doc/render" \
  "$TMP/api/test/support/fixtures/pd-parity"
cp -f "$ROOT/scripts/pd-parity-completeness.sh" "$TMP/scripts/"
cp -f "$ROOT"/api/test/support/fixtures/pd-parity/*.golden.json \
  "$TMP/api/test/support/fixtures/pd-parity/"
COMPOSE="$TMP/api/lib/barkpark/portable_doc/render/compose.ex"
checks=0
failures=0
run() {
  local label="$1" expected="$2" needle="$3" output rc=0
  output="$(bash "$TMP/scripts/pd-parity-completeness.sh" 2>&1)" || rc=$?
  checks=$((checks + 1))
  if [ "$rc" -eq "$expected" ] && [[ "$output" == *"$needle"* ]]; then
    echo "PASS: $label (exit $rc)"
  else
    echo "FAIL: $label (expected exit $expected and '$needle', got $rc)"
    printf '%s\n' "$output"
    failures=$((failures + 1))
  fi
}
baseline() {
  : > "$COMPOSE"
  for fixture in "$TMP"/api/test/support/fixtures/pd-parity/*.golden.json; do
    type="${fixture##*/}"
    type="${type%.golden.json}"
    case "$type" in stats|stat-grid) continue ;; esac
    printf 'def compose_block(%%{"type" => "%s"}, _style), do: nil\n' "$type" >> "$COMPOSE"
  done
  echo 'def compose_block(%{"type" => t}, _style) when t in ["stats", "stat-grid"], do: nil' >> "$COMPOSE"
}
baseline
run 'literal heads and literal-list alias pair' 0 'in-scope count: 65'
cat >> "$COMPOSE" <<'EX'
@aliases ~w(bulletList h1 h2 h3)
def compose_block(%{"type" => t}, style) when t in @aliases, do: nil
def compose_block(%{"type" => t}, style) when t == "quote", do: nil
EX
run 'attribute and equality aliases retain their target golden' 0 'in-scope count: 65'
cat >> "$COMPOSE" <<'EX'
defp table_col_types(b) do
  case b do
    %{"type" => t} when t in ["num", "delta", "spark"] -> t
    %{"type" => "helper-literal"} -> nil
  end
end
defp helper(t) when is_binary(t) and t in ["helper-guard"], do: nil
def compose_block(_other, _style) do
  case nil do
    t when t in ["body-guard"] -> %{"type" => "body-literal"}
  end
end
def compose_block(_other, _style), do: %{"type" => "inline-body"}
# def compose_block(%{"type" => "comment-head"}, s), do: nil
# when t in ["comment-guard"]
EX
run 'helper, body and comment literals are not dispatch' 0 'in-scope count: 65'
baseline
cat >> "$COMPOSE" <<'EX'
@doc """
def compose_block(%{"type" => "doc-head"}, s), do: nil
when t in ["doc-guard"]
"""
defp text(), do: """
def compose_block(%{"type" => "string-head"}, s), do: nil
"""
defp layout(layout) when layout in ["chapters", "timeline"], do: nil
EX
run 'documentation, multiline strings and layout guards are not dispatch' 0 'in-scope count: 65'
baseline
# Replace the single-line alias dispatch with a multiline literal guard.
sed '$d' "$COMPOSE" > "$TMP/multiline.ex"
cp -f "$TMP/multiline.ex" "$COMPOSE"
cat >> "$COMPOSE" <<'EX'
def compose_block(
  %{"type" => t},
  style
) when is_atom(style) and
  t in [
    "stats", # when t in ["comment-in-header"]
    "stat-grid"
  ],
  do: %{"type" => "inline-body"}
EX
run 'multiline literal guard and inline body boundary' 0 'in-scope count: 65'
cat >> "$COMPOSE" <<'EX'
def compose_block(
  %{
    "type" =>
      "new-dispatch"
  }, _style
), do: nil
EX
run 'new multiline literal dispatch requires its own golden' 1 'no golden fixture for in-scope type(s): new-dispatch'
baseline
echo 'def compose_block(%{"type" => "new-dispatch"}, s), do: nil' >> "$COMPOSE"
run 'new literal dispatch requires its own golden' 1 'no golden fixture for in-scope type(s): new-dispatch'
baseline
mv -f "$TMP/api/test/support/fixtures/pd-parity/heading.golden.json" "$TMP/heading.golden.json"
run 'missing existing golden remains fatal' 1 'no golden fixture for in-scope type(s): heading'
mv -f "$TMP/heading.golden.json" "$TMP/api/test/support/fixtures/pd-parity/heading.golden.json"
sed '/"heading"/d' "$COMPOSE" > "$TMP/shrunk.ex"
cp -f "$TMP/shrunk.ex" "$COMPOSE"
run 'census shrink remains fatal with all dispatched goldens present' 1 'expected 65 in-scope types, computed 64'
cp -f "$ROOT/api/lib/barkpark/portable_doc/render/compose.ex" "$COMPOSE"
run 'actual compose source has exactly 65 covered types' 0 'in-scope count: 65'
cat >> "$COMPOSE" <<'EX'
def compose_block(%{"type" => t}, _style)
    when t in [
      "new-guard"
    ], do: nil
EX
run 'new guarded dispatch in actual source requires a golden' 1 'no golden fixture for in-scope type(s): new-guard'
echo "$checks checks, $failures failures"
[ "$failures" -eq 0 ]
