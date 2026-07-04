defmodule Barkpark.Plugins.Sheets.CondFormat do
  @moduledoc """
  Conditional-formatting kernel — pure, no Repo, no I/O.

  Single-rule-per-range cell-value conditions (`gt`/`lt`/`eq`/`between`/
  `contains`) driving a background color plus optional bold/italic, evaluated
  SERVER-SIDE into the snapshot `"styles"` map during synthesis
  (`Core.snapshot_for/2`), so every surface that honors `"styles"` shows the
  same formatting with zero cross-surface drift (arc-2 decision CF-D1).

  ## Gate-strict / synthesis-lenient

  This module is the LENIENT side of the merges precedent. Storage validation
  (`plugins/sheets.ex` `before_save`, slice CF-B) is STRICT — it rejects a
  malformed rule at write time (409 `halted`). Evaluation here is TOTAL: a
  malformed rule, an unknown op, or a type-mismatched value produces NO match,
  never a raise. `parse_rules/1` silently drops anything it can't understand,
  and `matches?/2` returns `false` rather than blowing up synthesis — a stored
  cell must never 500 the whole snapshot/export/render.

  ## Public API

    * `parse_rules/1` — a tab's raw `"cond_formats"` value → normalized rules.
    * `matches?/2` — the CF-D5 eval matrix: does a rule's `"when"` fire on a
      raw cell map (or `nil`)?
    * `style_for/3` — first matching rule's sanitized style for a `{col, row}`
      (CF-D4, first-match-wins, no stacking).
    * `compose/2` — per-key merge of a manual `"s"` style with a CF style
      (CF-D3, CF wins the keys it sets).
    * `sanitize_bg/1` — the ONE `#rrggbb` sanitizer (binary in → normalized
      lowercase `"#rrggbb"` or `nil`); Core's manual-style sanitizer and the
      CF-B gate both route through here (single owner — arc-2 parked hygiene).
    * `valid_bg?/1` — the boolean twin for the gate's reject-with-message path;
      acceptance is byte-identical to `sanitize_bg/1` returning non-nil.
  """

  alias Barkpark.Plugins.Sheets.Core
  alias Barkpark.Plugins.Sheets.Engine

  # The op whitelist. `parse_rules/1` drops a rule whose op is not here; the
  # STRICT typing of each op's value(s) is the gate's job (CF-B) — eval is
  # lenient and simply returns false on a type mismatch.
  @known_ops ~w(gt lt eq between contains)

  # The SINGLE `#rrggbb` sanitizer regex (arc-2 parked-hygiene dedup: this
  # module is the one owner). `\z`, not `$`: PCRE `$` also matches before a
  # trailing newline, and a stored bg is emitted into style attributes
  # downstream — no stowaways. Applied AFTER `String.downcase/1`, so the class
  # is lowercase-only yet acceptance stays case-insensitive.
  @bg_re ~r/^#[0-9a-f]{6}\z/

  @typedoc """
  A normalized rule: corner-normalized range, the raw `"when"` map (kept
  verbatim for `matches?/2`), and the sanitized style map (non-empty).
  """
  @type rule :: %{
          range: {pos_integer(), pos_integer(), pos_integer(), pos_integer()},
          condition: map(),
          style: map()
        }

  @doc """
  Read a tab's `"cond_formats"` value into a list of normalized rules — TOTAL.

  Non-list input → `[]`. Each entry is kept only when ALL of:

    * `"range"` parses to a single A1 cell or `A1:B2` (any corner order),
      normalized to `{c1, r1, c2, r2}` top-left corners via `Core.parse_ref/1`;
    * `"when"` is a map whose `"op"` is one of `#{inspect(@known_ops)}`;
    * `"style"` sanitizes (same vocabulary as Core's manual sanitizer: `"bg"`
      a lowercase `#rrggbb`, `"b"`/`"i"` kept only when literally `true`) to a
      NON-empty map.

  Anything else is silently skipped. List order is preserved — it is the
  first-match priority `style_for/3` relies on (CF-D4).
  """
  @spec parse_rules(term()) :: [rule()]
  def parse_rules(rules) when is_list(rules), do: Enum.flat_map(rules, &parse_rule/1)
  def parse_rules(_), do: []

  defp parse_rule(%{} = rule) do
    with {:ok, corners} <- parse_range(Map.get(rule, "range")),
         %{} = when_map <- Map.get(rule, "when"),
         op when op in @known_ops <- Map.get(when_map, "op"),
         %{} = style <- sanitize_style(Map.get(rule, "style")) do
      [%{range: corners, condition: when_map, style: style}]
    else
      _ -> []
    end
  end

  defp parse_rule(_), do: []

  # A1 range → {c1, r1, c2, r2} corners with top-left normalized. A single cell
  # collapses to a degenerate 1×1 range. Malformed → :error (rule skipped).
  defp parse_range(ref) when is_binary(ref) do
    case String.split(ref, ":") do
      [a] ->
        case Core.parse_ref(a) do
          {:ok, {c, r}} -> {:ok, {c, r, c, r}}
          :error -> :error
        end

      [a, b] ->
        with {:ok, {c1, r1}} <- Core.parse_ref(a),
             {:ok, {c2, r2}} <- Core.parse_ref(b) do
          {:ok, {min(c1, c2), min(r1, r2), max(c1, c2), max(r1, r2)}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_range(_), do: :error

  # Same vocabulary as Core's private manual-style sanitizer, minus `"al"` (CF
  # sets only bg/b/i). Returns nil for a non-map or a style that sanitizes to
  # empty so parse_rule drops the rule.
  defp sanitize_style(%{} = s) do
    style =
      %{}
      |> put_flag("b", Map.get(s, "b"))
      |> put_flag("i", Map.get(s, "i"))
      |> put_bg(Map.get(s, "bg"))

    if map_size(style) == 0, do: nil, else: style
  end

  defp sanitize_style(_), do: nil

  defp put_flag(style, key, true), do: Map.put(style, key, true)
  defp put_flag(style, _key, _), do: style

  defp put_bg(style, bg) do
    case sanitize_bg(bg) do
      nil -> style
      hex -> Map.put(style, "bg", hex)
    end
  end

  @doc """
  Sanitize a background-color value to the canonical snapshot form — the ONE
  `#rrggbb` sanitizer for the sheets plugin (arc-2 parked-hygiene dedup).

  A binary `#rrggbb` (case-insensitive in) normalizes to lowercase; anything
  else — a non-binary, a bad shape, or a value with stowaway characters like a
  trailing newline — returns `nil`. Core's manual-style sanitizer routes here;
  a new consumer MUST call this (or `valid_bg?/1`) rather than write a fourth
  copy of the regex.

  ## Examples

      iex> Barkpark.Plugins.Sheets.CondFormat.sanitize_bg("#FF0000")
      "#ff0000"

      iex> Barkpark.Plugins.Sheets.CondFormat.sanitize_bg("#ff0000\\n")
      nil

      iex> Barkpark.Plugins.Sheets.CondFormat.sanitize_bg("red")
      nil
  """
  @spec sanitize_bg(term()) :: String.t() | nil
  def sanitize_bg(bg) when is_binary(bg) do
    down = String.downcase(bg)
    if Regex.match?(@bg_re, down), do: down, else: nil
  end

  def sanitize_bg(_), do: nil

  @doc """
  Is `bg` a valid `#rrggbb` color? The boolean twin of `sanitize_bg/1` for the
  CF-B gate's reject-with-message path — acceptance is byte-identical (case
  insensitive, `\\z`-anchored so a trailing newline is rejected).

  ## Examples

      iex> Barkpark.Plugins.Sheets.CondFormat.valid_bg?("#FF0000")
      true

      iex> Barkpark.Plugins.Sheets.CondFormat.valid_bg?("#ff0000\\n")
      false
  """
  @spec valid_bg?(term()) :: boolean()
  def valid_bg?(bg), do: not is_nil(sanitize_bg(bg))

  @doc """
  The CF-D5 eval matrix — does `when_map` fire on `cell` (a raw cell map or
  `nil`)? TOTAL: never raises; an unknown op or malformed input → `false`.

  The RAW cell is classified first (never the display string):

    * **error** — `is_binary(v) and (t == "e" or v in Engine.error_values())` →
      NEVER matches any op;
    * **blank** — no cell (`nil`), or `v` is `nil`/`""` → NEVER matches;
    * **number** — `is_number(v)`;
    * **boolean** — `true`/`false`;
    * **text** — the remaining binaries.

  Then per op:

    * `gt`/`lt` — numeric cell AND numeric rule value only;
    * `between` — numeric cell AND both rule values numeric, INCLUSIVE, with the
      endpoints order-normalized (min/max) defensively at eval;
    * `eq` — SAME-class only (number `==` number, so `1 == 1.0`; text
      case-insensitive via `String.downcase/1`; boolean `==` boolean); NO
      cross-type coercion;
    * `contains` — case-insensitive substring over the cell's SNAPSHOT DISPLAY
      string (`Core.display_value/1` — the exact string the user sees).
  """
  @spec matches?(term(), map() | nil) :: boolean()
  def matches?(%{} = when_map, cell) do
    eval(Map.get(when_map, "op"), classify(cell), when_map, cell)
  end

  def matches?(_, _), do: false

  # Classify the RAW cell, in CF-D5 order: error, then blank, then value type.
  defp classify(%{} = cell) do
    v = Map.get(cell, "v")
    t = Map.get(cell, "t")

    cond do
      is_binary(v) and (t == "e" or v in Engine.error_values()) -> :error
      is_nil(v) or v == "" -> :blank
      is_number(v) -> :number
      is_boolean(v) -> :boolean
      is_binary(v) -> :text
      true -> :blank
    end
  end

  defp classify(_), do: :blank

  # error / blank never match any op.
  defp eval(_op, :error, _when, _cell), do: false
  defp eval(_op, :blank, _when, _cell), do: false

  # gt / lt / between — numeric cell AND numeric rule value(s) only.
  defp eval("gt", :number, w, cell), do: num_cmp(cell, Map.get(w, "value"), &(&1 > &2))
  defp eval("lt", :number, w, cell), do: num_cmp(cell, Map.get(w, "value"), &(&1 < &2))

  defp eval("between", :number, w, cell) do
    cv = Map.get(cell, "v")
    v1 = Map.get(w, "value")
    v2 = Map.get(w, "value2")

    is_number(cv) and is_number(v1) and is_number(v2) and
      cv >= min(v1, v2) and cv <= max(v1, v2)
  end

  # eq — SAME-class only, no cross-type coercion.
  defp eval("eq", :number, w, cell) do
    rv = Map.get(w, "value")
    is_number(rv) and Map.get(cell, "v") == rv
  end

  defp eval("eq", :boolean, w, cell) do
    rv = Map.get(w, "value")
    is_boolean(rv) and Map.get(cell, "v") == rv
  end

  defp eval("eq", :text, w, cell) do
    cv = Map.get(cell, "v")
    rv = Map.get(w, "value")
    is_binary(cv) and is_binary(rv) and String.downcase(cv) == String.downcase(rv)
  end

  # contains — case-insensitive substring over the snapshot DISPLAY string;
  # fires for any non-blank/non-error class (number/boolean/text).
  defp eval("contains", class, w, cell) when class in [:number, :boolean, :text] do
    needle = Map.get(w, "value")

    if is_binary(needle) and needle != "" do
      String.contains?(String.downcase(Core.display_value(cell)), String.downcase(needle))
    else
      false
    end
  end

  # Unknown op, or an op on a class it doesn't support (e.g. gt on text) → false.
  defp eval(_op, _class, _when, _cell), do: false

  defp num_cmp(cell, rv, cmp) do
    cv = Map.get(cell, "v")
    is_number(cv) and is_number(rv) and cmp.(cv, rv)
  end

  @doc """
  The sanitized style of the FIRST rule (list order) whose range CONTAINS
  `{col, row}` AND whose condition `matches?/2` the raw `cell` — else `nil`.

  Ranges may overlap; there is no stacking in v1 (CF-D4). `rules` is expected
  to be the output of `parse_rules/1`.
  """
  @spec style_for([rule()], {pos_integer(), pos_integer()}, map() | nil) :: map() | nil
  def style_for(rules, {col, row}, cell) when is_list(rules) do
    Enum.find_value(rules, fn %{range: {c1, r1, c2, r2}, condition: w, style: style} ->
      if col >= c1 and col <= c2 and row >= r1 and row <= r2 and matches?(w, cell),
        do: style,
        else: nil
    end)
  end

  def style_for(_, _, _), do: nil

  @doc """
  Per-key merge of a manual `"s"` style map with a CF style (CF-D3).

  The CF style wins the keys it sets (`"bg"`, and `"b"`/`"i"` when present);
  every other manual key survives (today: `"al"`, plus `"b"`/`"i"`/`"bg"` when
  the rule doesn't set them). A `nil` CF style leaves the manual style
  untouched.
  """
  @spec compose(map() | nil, map() | nil) :: map()
  def compose(manual, nil), do: to_map(manual)
  def compose(manual, cf) when is_map(cf), do: Map.merge(to_map(manual), cf)

  defp to_map(m) when is_map(m), do: m
  defp to_map(_), do: %{}
end
