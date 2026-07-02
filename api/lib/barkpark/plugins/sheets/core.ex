defmodule Barkpark.Plugins.Sheets.Core do
  @moduledoc """
  Core sheet utilities — A1 address helpers and snapshot synthesis.

  Pure functions: no Repo, no I/O. A sheet document's `content` carries
  `"tabs"`, each tab a sparse `"cells"` map keyed by A1 address (see
  `priv/plugins/sheets/schemas/sheet.json`). `snapshot_for/2` densifies one
  tab into the cached value grid that the core `"sheet"` portable-doc block
  embeds — the snapshot is what keeps documents rendering with the Sheets
  plugin off (fresh-install invariant), and the write-through path in
  `Barkpark.Content` refreshes it on every sheet mutation.

  The formula engine lives at `Barkpark.Plugins.Sheets.Engine`. It slots in AHEAD of
  snapshot synthesis — `Barkpark.Content` recomputes formula `"v"` values on
  the cells map on every sheet save — so the dense grid here stays a pure
  projection of cell values.
  """

  @a1 ~r/^([A-Za-z]+)([1-9][0-9]*)$/

  @doc """
  Parse an A1 cell address into a `{col, row}` pair (1-based).

  Returns `{:ok, {col, row}}` or `:error`.

  ## Examples

      iex> Barkpark.Plugins.Sheets.Core.parse_ref("A1")
      {:ok, {1, 1}}

      iex> Barkpark.Plugins.Sheets.Core.parse_ref("AA3")
      {:ok, {27, 3}}

      iex> Barkpark.Plugins.Sheets.Core.parse_ref("bad")
      :error
  """
  @spec parse_ref(term()) :: {:ok, {pos_integer(), pos_integer()}} | :error
  def parse_ref(addr) when is_binary(addr) do
    case Regex.run(@a1, addr) do
      [_, letters, row] ->
        {:ok, {letters_to_col(String.upcase(letters)), String.to_integer(row)}}

      _ ->
        :error
    end
  end

  def parse_ref(_), do: :error

  @doc """
  Format a 1-based `{col, row}` pair back to an A1 address string.

  ## Examples

      iex> Barkpark.Plugins.Sheets.Core.format_ref({1, 1})
      "A1"

      iex> Barkpark.Plugins.Sheets.Core.format_ref({27, 3})
      "AA3"
  """
  @spec format_ref({pos_integer(), pos_integer()}) :: String.t()
  def format_ref({col, row}) when col >= 1 and row >= 1 do
    col_to_letters(col, "") <> Integer.to_string(row)
  end

  @doc """
  The tab at `index` (0-based) from a sheet document's content, or `nil`
  when the index is out of range or the content carries no tab list.
  """
  @spec get_tab(term(), non_neg_integer()) :: map() | nil
  def get_tab(%{"tabs" => tabs}, index) when is_list(tabs) and is_integer(index) and index >= 0 do
    Enum.at(tabs, index)
  end

  def get_tab(_, _), do: nil

  @doc """
  Build the dense embed snapshot from a sheet document's content + tab index.

  Returns a string-keyed, JSON-ready map — the exact shape the `"sheet"`
  portable-doc block stores under `"snapshot"`:

    * `"rows"` — dense 2-D value grid, row-major, bounded by the max occupied
      row/col. Every cell is `to_string(v)` (booleans as `"TRUE"`/`"FALSE"`,
      matching the Studio grid's display); gaps pad with `""`.
    * `"head"` — present only when the tab freezes at least one row; row 1
      becomes the column-label list and data rows start at row 2.
    * `"col_widths"` — present only when the tab carries a usable
      `"col_widths"` map (sparse `"1"`-based string key → px). Densified to
      a list indexed 1..max_col, gaps as `0`.
    * `"merges"` — present only when the tab carries a usable `"merges"`
      list (`["A1:B2", …]`). Encoded as `[row, col, rowspan, colspan]`
      entries, 0-based into the dense `"rows"` body grid. Merge ranges
      NEVER extend the grid bounds — a range reaching past the last valued
      cell clips to the occupied bounds (defense in depth: a hostile range
      cannot inflate the dense grid); ranges are also clipped to the body —
      a merge touching a frozen head row keeps only its body part — and a
      range that clips down to a single cell is dropped.
    * `"styles"` — present only when at least one body cell carries a
      usable `"s"` style map. A sparse map keyed `"row,col"` (0-based body
      grid) → sanitized style: `"b"`/`"i"` booleans (kept only when `true`),
      `"bg"` (#rrggbb hex, normalized lowercase), `"al"`
      (`left|center|right`). Unknown keys and invalid values are dropped;
      styles on a frozen head row are dropped (the head band has its own
      fixed style).

  Fidelity note: the HTML walker (`Barkpark.PortableDoc.Render`) honors
  `"merges"` (colspan/rowspan) and `"styles"`; the TUI's pdrender ignores
  both keys and renders a merged range as its anchor-cell value (covered
  cells are `""` in the dense grid) with no styling — values-first fidelity.

  The dense grid is hard-capped at 200_000 positions (rows × cols), on
  BOTH axes: COLUMNS clamp against the cap first (legacy content may
  store refs past column XFD — the write-side gate now rejects them),
  then ROWS truncate to as many full rows as fit (minimum 1),
  deterministically — rows × cols never exceeds the cap regardless of
  stored content. Cells beyond the truncated bounds do not appear in the
  snapshot. Every snapshot consumer — embeds, the save write-through,
  csv/md/html exports — inherits the bound.

  An empty, missing, or malformed tab yields `%{"rows" => []}` — even a
  blank sheet snapshots to a valid (empty) grid. Cells with an invalid A1
  key are skipped, not raised on: the write-side validation in
  `Barkpark.Plugins.Sheets` is the gate; synthesis stays total.
  """
  @spec snapshot_for(term(), non_neg_integer()) :: map()
  def snapshot_for(content, tab_index \\ 0) do
    case get_tab(content, tab_index) do
      %{} = tab -> build_snapshot(tab)
      _ -> %{"rows" => []}
    end
  end

  # ── snapshot synthesis ─────────────────────────────────────────────────────

  # The dense grid is hard-capped at this many positions (rows × cols) —
  # see the moduledoc. Truncation is two-axis: columns clamp against the
  # cap first, then rows truncate to as many full rows as fit, minimum 1.
  @snapshot_position_cap 200_000

  @doc """
  The dense-grid position cap (rows × cols) shared by snapshot synthesis and
  the sibling export paths (`XlsxExport`) so every densifier clamps alike.
  """
  @spec position_cap() :: pos_integer()
  def position_cap, do: @snapshot_position_cap

  defp build_snapshot(tab) do
    occupied = occupied_cells(tab)

    if occupied == %{} do
      %{"rows" => []}
    else
      merges = tab_merges(tab)

      {max_col, max_row} =
        Enum.reduce(occupied, {0, 0}, fn {{c, r}, _v}, {mc, mr} -> {max(mc, c), max(mr, r)} end)

      # Merges never extend the grid past the occupied bounds — hostile or
      # sloppy ranges clip in maybe_put_merges. The grid itself then
      # hard-caps at @snapshot_position_cap positions, two-axis: columns
      # clamp against the cap first, then rows truncate to as many full
      # rows as fit — rows × cols stays under the cap whatever legacy
      # content stores.
      max_col = min(max_col, @snapshot_position_cap)
      max_row = min(max_row, max(div(@snapshot_position_cap, max_col), 1))

      {head, data_start} =
        if frozen_rows(tab) >= 1 do
          {Enum.map(1..max_col, &Map.get(occupied, {&1, 1}, "")), 2}
        else
          {nil, 1}
        end

      rows =
        for r <- data_start..max_row//1 do
          for c <- 1..max_col, do: Map.get(occupied, {c, r}, "")
        end

      %{"rows" => rows}
      |> maybe_put_head(head)
      |> maybe_put_widths(tab, max_col)
      |> maybe_put_merges(merges, data_start, max_col, max_row)
      |> maybe_put_styles(tab, data_start, max_col, max_row)
    end
  end

  # Sparse cells map → %{{col, row} => value_string}, skipping malformed entries.
  defp occupied_cells(tab) do
    case Map.get(tab, "cells") do
      cells when is_map(cells) ->
        Enum.reduce(cells, %{}, fn {addr, cell}, acc ->
          case {parse_ref(addr), cell} do
            {{:ok, pos}, %{} = cell} -> Map.put(acc, pos, cell_value(cell))
            _ -> acc
          end
        end)

      _ ->
        %{}
    end
  end

  @doc """
  Excel-General-like number → display string, shared by every snapshot
  surface (paper embeds, csv/md/html exports, the TUI) and the Studio grid
  (`SheetGrid.Cells.display/1` calls THIS, not `to_string/1`).

  Plain `to_string(1_000_000.0)` is `"1.0e6"` — any formula yielding a float
  ≥ 1e6 (a `*1000`, any division) would otherwise render as scientific
  notation on the read surfaces while the web renderer shows `1,000,000`.
  Whole floats render integral, non-whole floats decimal; only magnitudes
  Excel General also keeps in exponent form (`< 1e-6` or `≥ 1e15`) stay in
  exponent form (lock: sheets_parity_test.exs).
  """
  @spec number_to_display(number()) :: String.t()
  def number_to_display(v) when is_integer(v), do: Integer.to_string(v)

  def number_to_display(v) when is_float(v) do
    cond do
      v == trunc(v) and abs(v) < 1.0e15 ->
        Integer.to_string(trunc(v))

      true ->
        s = :erlang.float_to_binary(v, [:short])
        a = abs(v)

        if String.contains?(s, "e") and a >= 1.0e-6 and a < 1.0e15 do
          v
          |> :erlang.float_to_binary([{:decimals, 12}])
          |> String.trim_trailing("0")
          |> String.trim_trailing(".")
        else
          s
        end
    end
  end

  defp cell_value(%{"v" => v}) when is_binary(v), do: v
  defp cell_value(%{"v" => v}) when is_number(v), do: number_to_display(v)
  # Booleans render TRUE/FALSE — the Studio grid (`SheetGrid.display/1`) and
  # the engine's own text coercion (`TRUE&""` → `"TRUE"`) both speak Excel's
  # uppercase; every snapshot surface (paper embeds, csv/md/html exports, the
  # TUI) must show the SAME string (lock: sheets_parity_test.exs).
  defp cell_value(%{"v" => true}), do: "TRUE"
  defp cell_value(%{"v" => false}), do: "FALSE"
  defp cell_value(_), do: ""

  # The schema stores frozen_rows as a string field; in-memory writers may
  # carry an integer. Anything else means "no frozen rows".
  defp frozen_rows(tab) do
    case Map.get(tab, "frozen_rows") do
      n when is_integer(n) -> n
      s when is_binary(s) -> with({n, ""} <- Integer.parse(s), do: n, else: (_ -> 0))
      _ -> 0
    end
  end

  defp maybe_put_head(snapshot, nil), do: snapshot
  defp maybe_put_head(snapshot, head), do: Map.put(snapshot, "head", head)

  defp maybe_put_widths(snapshot, tab, max_col) do
    case Map.get(tab, "col_widths") do
      widths when is_map(widths) and map_size(widths) > 0 ->
        dense = Enum.map(1..max_col, &width_at(widths, &1))

        if Enum.any?(dense, &(&1 > 0)) do
          Map.put(snapshot, "col_widths", dense)
        else
          snapshot
        end

      _ ->
        snapshot
    end
  end

  defp width_at(widths, col) do
    case Map.get(widths, Integer.to_string(col)) do
      w when is_integer(w) and w > 0 -> w
      w when is_float(w) and w > 0 -> round(w)
      _ -> 0
    end
  end

  # Tab "merges" (`["A1:B2", …]`) → normalized corner pairs. Malformed
  # entries are skipped (synthesis stays total); corners are reordered so
  # the first is always top-left.
  defp tab_merges(tab) do
    case Map.get(tab, "merges") do
      merges when is_list(merges) ->
        Enum.flat_map(merges, fn merge ->
          with true <- is_binary(merge),
               [a, b] <- String.split(merge, ":"),
               {:ok, {c1, r1}} <- parse_ref(a),
               {:ok, {c2, r2}} <- parse_ref(b) do
            [{{min(c1, c2), min(r1, r2)}, {max(c1, c2), max(r1, r2)}}]
          else
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  # Encode merges against the dense BODY grid as [row, col, rowspan, colspan]
  # (0-based). Clipped to the body (head row excluded) and the grid bounds;
  # a range that clips to a single cell carries no information and is dropped.
  defp maybe_put_merges(snapshot, merges, data_start, max_col, max_row) do
    encoded =
      merges
      |> Enum.flat_map(fn {{c1, r1}, {c2, r2}} ->
        r1 = max(r1, data_start)
        c2 = min(c2, max_col)
        r2 = min(r2, max_row)

        if r1 > r2 or c1 > c2 or (r1 == r2 and c1 == c2) do
          []
        else
          [[r1 - data_start, c1 - 1, r2 - r1 + 1, c2 - c1 + 1]]
        end
      end)
      |> Enum.sort()

    if encoded == [], do: snapshot, else: Map.put(snapshot, "merges", encoded)
  end

  # Project per-cell "s" style maps into a sparse `"row,col"`-keyed map over
  # the dense body grid, sanitizing as we go. Head-row styles are dropped
  # (the head band has its own fixed style), as is anything out of bounds.
  defp maybe_put_styles(snapshot, tab, data_start, max_col, max_row) do
    styles =
      case Map.get(tab, "cells") do
        cells when is_map(cells) ->
          Enum.reduce(cells, %{}, fn {addr, cell}, acc ->
            with {:ok, {c, r}} <- parse_ref(addr),
                 true <- r >= data_start and r <= max_row and c <= max_col,
                 %{} = style <- cell_style(cell) do
              Map.put(acc, "#{r - data_start},#{c - 1}", style)
            else
              _ -> acc
            end
          end)

        _ ->
          %{}
      end

    if styles == %{}, do: snapshot, else: Map.put(snapshot, "styles", styles)
  end

  defp cell_style(%{"s" => %{} = s}) do
    style =
      %{}
      |> put_style_flag("b", Map.get(s, "b"))
      |> put_style_flag("i", Map.get(s, "i"))
      |> put_style_bg(Map.get(s, "bg"))
      |> put_style_align(Map.get(s, "al"))

    if style == %{}, do: nil, else: style
  end

  defp cell_style(_), do: nil

  defp put_style_flag(style, key, true), do: Map.put(style, key, true)
  defp put_style_flag(style, _key, _), do: style

  defp put_style_bg(style, bg) when is_binary(bg) do
    bg = String.downcase(bg)
    if Regex.match?(~r/^#[0-9a-f]{6}$/, bg), do: Map.put(style, "bg", bg), else: style
  end

  defp put_style_bg(style, _), do: style

  defp put_style_align(style, al) when al in ["left", "center", "right"],
    do: Map.put(style, "al", al)

  defp put_style_align(style, _), do: style

  # ── A1 column arithmetic (bijective base-26) ───────────────────────────────

  defp letters_to_col(letters) do
    letters
    |> String.to_charlist()
    |> Enum.reduce(0, fn ch, acc -> acc * 26 + (ch - ?A + 1) end)
  end

  defp col_to_letters(0, acc), do: acc

  defp col_to_letters(n, acc) do
    col_to_letters(div(n - 1, 26), <<rem(n - 1, 26) + ?A>> <> acc)
  end
end
