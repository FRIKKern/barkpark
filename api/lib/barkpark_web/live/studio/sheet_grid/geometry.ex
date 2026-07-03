defmodule BarkparkWeb.Studio.SheetGrid.Geometry do
  @moduledoc """
  Pure grid geometry for `BarkparkWeb.Studio.SheetGrid` — selection
  rectangles, A1 range parsing, peer cursor/selection box math, and the
  px sums the frozen bands pin with (`left_px`/`top_px`). No socket, no
  side effects: every function takes plain args and returns data, so the
  facade and its render template call these qualified
  (`Geometry.col_px(...)`) without re-marking change-tracked assigns.
  """

  alias Barkpark.Plugins.Sheets.Core, as: Sheets
  alias BarkparkWeb.Studio.PresenceState

  # Layout constants — the single home for the px dimensions used by the
  # frozen-band math here; the facade does not keep its own copies.
  @default_col_px 88
  @default_row_px 24
  @rowhead_px 44
  @headrow_px 25

  def selection_rect({c, r}, nil), do: {c, c, r, r}

  def selection_rect({c1, r1}, {c2, r2}),
    do: {min(c1, c2), max(c1, c2), min(r1, r2), max(r1, r2)}

  # Pure attr expressions for the template (tracked on @active/@anchor/
  # @read_only — never re-marked by unrelated updates). The reader strips
  # the active-cell/selection highlight — {0, 0} sits off the 1-based grid,
  # so no cell matches.
  def grid_sel(_active, _anchor, true), do: {0, 0, 0, 0}
  def grid_sel(active, anchor, _read_only), do: selection_rect(active, anchor)

  def grid_cursor(_active, true), do: {0, 0}
  def grid_cursor(active, _read_only), do: active

  # Excel's Ctrl/Cmd+Arrow data-edge jump, pure over the sparse A1-keyed cells
  # map. From a filled cell whose neighbour in `dir` is also filled: the run's
  # last filled cell before the gap. From a run's end or from an empty cell:
  # the next filled cell in that direction. Nothing ahead: the grid edge.
  # `bounds` is the {cols, rows} extent the result clamps inside (1-based).
  def data_edge(cells, {_c, _r} = pos, dir, {_cols, _rows} = bounds)
      when dir in ["up", "down", "left", "right"] do
    step = edge_step(dir)
    next = edge_advance(pos, step)

    cond do
      not edge_in?(next, bounds) ->
        pos

      edge_filled?(cells, pos) and edge_filled?(cells, next) ->
        edge_run(cells, next, step, bounds)

      true ->
        edge_seek(cells, next, step, bounds)
    end
  end

  def parse_range(m) when is_binary(m) do
    with [a, b] <- String.split(m, ":"),
         {:ok, {c1, r1}} <- Sheets.parse_ref(a),
         {:ok, {c2, r2}} <- Sheets.parse_ref(b) do
      {:ok, {min(c1, c2), min(r1, r2), max(c1, c2), max(r1, r2)}}
    else
      _ -> :error
    end
  end

  def parse_range(_), do: :error

  # `{cursor-boxes, selection-rects}` for the overlay layer, in table px
  # (the same `left_px`/`top_px` sums the frozen bands pin with, so the
  # boxes align with the cells by construction). One box per peer cursor,
  # ONE rect per peer selection — never per cell: the layer must stay tiny
  # so a presence frame re-renders boxes, not the grid body. Ranges clip to
  # the rendered grid, out-of-bounds cursors drop.
  def peer_boxes(peers, cols, rows, col_widths, row_heights) do
    Enum.reduce(peers, {[], []}, fn peer, {cursors, sels} ->
      cursors =
        case cursor_pos(peer, cols, rows) do
          nil ->
            cursors

          {c, r} ->
            box = %{
              ref: Sheets.format_ref({c, r}),
              left: left_px(c, col_widths),
              top: top_px(r, row_heights),
              w: col_px(col_widths, c),
              h: row_px(row_heights, r),
              peer: peer
            }

            [box | cursors]
        end

      sels =
        case parse_range(peer.selection) do
          {:ok, {c1, r1, c2, r2}} when c1 <= cols and r1 <= rows ->
            c2 = min(c2, cols)
            r2 = min(r2, rows)

            rect = %{
              range: peer.selection,
              color: peer.color,
              left: left_px(c1, col_widths),
              top: top_px(r1, row_heights),
              w: Enum.sum(for c <- c1..c2, do: col_px(col_widths, c)),
              h: Enum.sum(for r <- r1..r2, do: row_px(row_heights, r))
            }

            [rect | sels]

          _ ->
            sels
        end

      {cursors, sels}
    end)
  end

  # The cursor cell — the `editing` ref when set (the emphasized soft-lock
  # tag follows the cell being edited), the active cell otherwise.
  def cursor_pos(peer, cols, rows) do
    with ref when is_binary(ref) <- peer.editing || peer.active,
         {:ok, {c, r}} when c <= cols and r <= rows <- Sheets.parse_ref(ref) do
      {c, r}
    else
      _ -> nil
    end
  end

  def rgba("#" <> hex, alpha) do
    [r, g, b] =
      for i <- [0, 2, 4], do: hex |> String.slice(i, 2) |> String.to_integer(16)

    "rgba(#{r}, #{g}, #{b}, #{alpha})"
  end

  # Collaborators on the CURRENT tab, self excluded; one entry per meta (a
  # user's second window is a second cursor). Colors normalize to the
  # deterministic palette when the meta carries a non-hex value — the color
  # lands in inline styles, so this is also the sanitizer.
  def grid_peers(presences, user_id, tab) do
    for %{user_id: uid} = p <- presences || [],
        uid != user_id,
        Map.get(p, :tab, 0) == tab do
      %{
        name: Map.get(p, :name) || "User #{String.slice(uid, 0..3)}",
        color: peer_color(p, uid),
        active: Map.get(p, :active),
        selection: Map.get(p, :selection),
        editing: Map.get(p, :editing)
      }
    end
  end

  def peer_color(p, uid) do
    case Map.get(p, :color) do
      color when is_binary(color) ->
        if Regex.match?(~r/^#[0-9a-fA-F]{6}$/, color),
          do: color,
          else: PresenceState.pick_color(uid)

      _ ->
        PresenceState.pick_color(uid)
    end
  end

  def col_px(col_widths, c),
    do: usable_px(Map.get(col_widths, Integer.to_string(c)), @default_col_px)

  def row_px(row_heights, r),
    do: usable_px(Map.get(row_heights, Integer.to_string(r)), @default_row_px)

  defp usable_px(px, _default) when is_number(px) and px > 0, do: round(px)
  defp usable_px(_px, default), do: default

  def left_px(c, col_widths),
    do: @rowhead_px + Enum.sum(for i <- 1..(c - 1)//1, do: col_px(col_widths, i))

  def top_px(r, row_heights),
    do: @headrow_px + Enum.sum(for i <- 1..(r - 1)//1, do: row_px(row_heights, i))

  def col_letters(c) when c <= 26, do: <<?A + c - 1>>
  def col_letters(c), do: col_letters(div(c - 1, 26)) <> col_letters(rem(c - 1, 26) + 1)

  # ── data_edge helpers (pure, private) ─────────────────────────────────────

  defp edge_step("up"), do: {0, -1}
  defp edge_step("down"), do: {0, 1}
  defp edge_step("left"), do: {-1, 0}
  defp edge_step("right"), do: {1, 0}

  defp edge_advance({c, r}, {dc, dr}), do: {c + dc, r + dr}

  defp edge_in?({c, r}, {cols, rows}), do: c >= 1 and c <= cols and r >= 1 and r <= rows

  # Presence in the sparse map IS "filled" — the same predicate the facade's
  # `occupied?` uses, so fill-extent and data-edge agree on what data is.
  defp edge_filled?(cells, pos), do: Map.has_key?(cells, Sheets.format_ref(pos))

  # Walk a filled run to its last cell before the gap (or the grid edge).
  defp edge_run(cells, pos, step, bounds) do
    next = edge_advance(pos, step)

    if edge_in?(next, bounds) and edge_filled?(cells, next),
      do: edge_run(cells, next, step, bounds),
      else: pos
  end

  # Skip empties to the next filled cell; none before the edge → the edge.
  defp edge_seek(cells, pos, step, bounds) do
    next = edge_advance(pos, step)

    cond do
      edge_filled?(cells, pos) -> pos
      edge_in?(next, bounds) -> edge_seek(cells, next, step, bounds)
      true -> pos
    end
  end
end
