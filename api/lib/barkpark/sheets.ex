defmodule Barkpark.Sheets do
  @moduledoc """
  Core sheet utilities — A1 address helpers and snapshot synthesis.

  Pure functions: no Repo, no I/O. A sheet document's `content` carries
  `"tabs"`, each tab a sparse `"cells"` map keyed by A1 address (see
  `priv/plugins/sheets/schemas/sheet.json`). `snapshot_for/2` densifies one
  tab into the cached value grid that the core `"sheet"` portable-doc block
  embeds — the snapshot is what keeps documents rendering with the Sheets
  plugin off (fresh-install invariant), and the write-through path in
  `Barkpark.Content` refreshes it on every sheet mutation.

  The formula engine (M1) lands at `Barkpark.Sheets.Engine`. It slots in
  AHEAD of snapshot synthesis — recomputing stale `"v"` values on the cells
  map — so the dense grid here stays a pure projection of cell values.
  """

  @a1 ~r/^([A-Za-z]+)([1-9][0-9]*)$/

  @doc """
  Parse an A1 cell address into a `{col, row}` pair (1-based).

  Returns `{:ok, {col, row}}` or `:error`.

  ## Examples

      iex> Barkpark.Sheets.parse_ref("A1")
      {:ok, {1, 1}}

      iex> Barkpark.Sheets.parse_ref("AA3")
      {:ok, {27, 3}}

      iex> Barkpark.Sheets.parse_ref("bad")
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

      iex> Barkpark.Sheets.format_ref({1, 1})
      "A1"

      iex> Barkpark.Sheets.format_ref({27, 3})
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
      row/col. Every cell is `to_string(v)`; gaps pad with `""`.
    * `"head"` — present only when the tab freezes at least one row; row 1
      becomes the column-label list and data rows start at row 2.
    * `"col_widths"` — present only when the tab carries a usable
      `"col_widths"` map (sparse `"1"`-based string key → px). Densified to
      a list indexed 1..max_col, gaps as `0`.

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

  defp build_snapshot(tab) do
    occupied = occupied_cells(tab)

    if occupied == %{} do
      %{"rows" => []}
    else
      {max_col, max_row} =
        Enum.reduce(occupied, {0, 0}, fn {{c, r}, _v}, {mc, mr} -> {max(mc, c), max(mr, r)} end)

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

  defp cell_value(%{"v" => v}) when is_binary(v), do: v
  defp cell_value(%{"v" => v}) when is_number(v), do: to_string(v)
  defp cell_value(%{"v" => v}) when is_boolean(v), do: to_string(v)
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
