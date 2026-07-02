defmodule Barkpark.Plugins.Sheets.Session.Ops do
  @moduledoc """
  Op-application machinery for `Barkpark.Plugins.Sheets.Session`.

  Plain module (no GenServer) — every function operates on the session's
  in-memory state map. The owning GenServer's `handle_call({:apply_ops, …})`
  dispatches each wire-shaped op through `apply_one/2`, then records the
  inverse via `record_undo/3`; the per-user undo/redo machine
  (`apply_history/3`, `apply_entry/2`) rides the same path.

  Validation, cell mutation, structural shifts, recompute, the compact
  delta broadcast, and the cached non-empty / formula counters all live
  here. The only call back into the GenServer module is
  `Session.topic/3` for the broadcast topic (the public, byte-stable API).

  See `Barkpark.Plugins.Sheets.Session`'s moduledoc for the op grammar,
  the undo/redo semantics, the recompute + delta contract, and the
  inverse-entry term shapes.
  """

  alias Barkpark.Plugins.Sheets.Core, as: Sheets
  alias Barkpark.Plugins.Sheets.Engine
  alias Barkpark.Plugins.Sheets.Fmt
  alias Barkpark.Plugins.Sheets.Session
  alias Barkpark.Plugins.Sheets.Structure

  # Excel's grid bounds — column XFD, row 1_048_576. Deliberately duplicated
  # (the established convention: `Barkpark.Plugins.Sheets.Engine` and the plugin gate
  # `Barkpark.Plugins.Sheets` each keep their own copy of the same two
  # integers): the Session is CORE and must not reach into the plugin, and
  # `Barkpark.Plugins.Sheets.Core.parse_ref/1` stays a pure, total A1 parser.
  @grid_max_col 16_384
  @grid_max_row 1_048_576

  # Cap on a single merge range's area, in cells — same deliberate duplication
  # as the grid bounds above: the plugin gate `Barkpark.Plugins.Sheets`
  # (`merge_area_cap/0`) holds the identical constant and enforces it at
  # before_save. The Session is CORE and must not reach into the plugin, so it
  # keeps its own copy; matching the gate EXACTLY guarantees a merge the
  # session admits can never make the debounced persist 409 on the gate's
  # `merge_errors` (an over-cap merge would halt the save and strand the
  # session's acknowledged state).
  @merge_area_cap 10_000

  # Per-user undo/redo stack depth (M4, bound at the grill).
  @undo_depth 100

  # Per-cell payload ceiling — mirrors Excel's 32,767-character cell limit, so
  # the fence doubles as interchange-faithful parity. Measured in BYTES, not
  # codepoints: the bytes-vs-chars divergence for multibyte text is deliberate
  # (a cheap byte_size guard that only ever admits MORE than Excel, never less)
  # and is what bounds the session GenServer, the debounced persist, every
  # delta broadcast, and the recompute lexer against a multi-megabyte cell.
  @max_cell_bytes 32_767

  # ── op application ───────────────────────────────────────────────────────
  #
  # Every clause returns {:ok, state, inverse | nil} — the inverse is the
  # per-user undo entry (see apply_entry/2), nil when the op records no
  # history (undo/redo themselves mutate the stacks inline).

  def apply_one(%{"op" => "set_cell", "tab" => tab, "ref" => ref, "raw" => raw} = op, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         {:ok, ref} <- validate_ref(ref),
         :ok <- refuse_covered_ref(state, tab_idx, ref),
         {:ok, cell} <- build_cell(raw),
         # Excel keeps a cell's number format ("fmt") and style ("s") when you
         # retype its value — carry them from the prior cell onto the freshly
         # built one (the new "v"/"f" wins) so an edit never silently drops
         # metadata. Hoisted once: the same prior is the undo inverse.
         prior = cell_before(state, tab_idx, ref),
         cell = Map.merge(Map.take(prior || %{}, ["fmt", "s"]), cell),
         # An explicit "fmt"/"s" on the op OVERRIDES the carried value (fill
         # stamps the source cell's format onto every target — Excel semantics);
         # an ABSENT key leaves the carried value (the retype-preserves-format
         # path above). nil clears; a bad fmt/s rejects the op.
         {:ok, cell} <- apply_meta_overrides(op, cell),
         :ok <- check_cap(state, tab_idx, ref, cell) do
      inverse = {:cell, tab_idx, ref, prior}
      {:ok, apply_cell(state, tab_idx, ref, cell), inverse}
    end
  end

  def apply_one(%{"op" => "clear_cell", "tab" => tab, "ref" => ref}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         {:ok, ref} <- validate_ref(ref) do
      # Excel's Delete clears content AND format; our model has no
      # empty-but-formatted cell, so clear_cell stays a full delete (unlike
      # set_cell, which preserves "fmt"/"s").
      inverse = {:cell, tab_idx, ref, cell_before(state, tab_idx, ref)}
      {:ok, apply_cell(state, tab_idx, ref, nil), inverse}
    end
  end

  def apply_one(%{"op" => op, "tab" => tab, "at" => at, "count" => count}, state)
      when op in ["insert_rows", "delete_rows", "insert_cols", "delete_cols"] do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         old_tab = Sheets.get_tab(state.content, tab_idx),
         {:ok, new_tab} <- structural_shift(op, old_tab, at, count) do
      inverse = shift_inverse(op, tab_idx, old_tab, at, count)

      {:ok,
       apply_structural(state, tab_idx, new_tab, true, %{
         op: op,
         at: at,
         count: count,
         tab: tab_idx
       }), inverse}
    end
  end

  def apply_one(%{"op" => "set_col_width", "tab" => tab, "col" => col} = op_map, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         old_tab = Sheets.get_tab(state.content, tab_idx),
         {:ok, new_tab} <- Structure.set_col_width(old_tab, col, Map.get(op_map, "px")) do
      inverse =
        {:structural,
         %{
           "op" => "set_col_width",
           "tab" => tab_idx,
           "col" => col,
           "px" => prior_px(old_tab, "col_widths", col)
         }}

      {:ok,
       apply_structural(state, tab_idx, new_tab, false, %{
         op: "set_col_width",
         at: col,
         count: nil,
         tab: tab_idx
       }), inverse}
    end
  end

  def apply_one(%{"op" => "set_row_height", "tab" => tab, "row" => row} = op_map, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         old_tab = Sheets.get_tab(state.content, tab_idx),
         {:ok, new_tab} <- Structure.set_row_height(old_tab, row, Map.get(op_map, "px")) do
      inverse =
        {:structural,
         %{
           "op" => "set_row_height",
           "tab" => tab_idx,
           "row" => row,
           "px" => prior_px(old_tab, "row_heights", row)
         }}

      {:ok,
       apply_structural(state, tab_idx, new_tab, false, %{
         op: "set_row_height",
         at: row,
         count: nil,
         tab: tab_idx
       }), inverse}
    end
  end

  def apply_one(%{"op" => "set_frozen", "tab" => tab, "rows" => rows, "cols" => cols}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         old_tab = Sheets.get_tab(state.content, tab_idx),
         {:ok, new_tab} <- Structure.set_frozen(old_tab, rows, cols) do
      inverse =
        {:structural,
         %{
           "op" => "set_frozen",
           "tab" => tab_idx,
           "rows" => prior_frozen(old_tab, "frozen_rows"),
           "cols" => prior_frozen(old_tab, "frozen_cols")
         }}

      {:ok,
       apply_structural(state, tab_idx, new_tab, false, %{
         op: "set_frozen",
         at: nil,
         count: nil,
         tab: tab_idx
       }), inverse}
    end
  end

  def apply_one(%{"op" => "rename_tab", "tab" => tab, "name" => name}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         {:ok, name} <- validate_tab_name(name) do
      old_tab = Sheets.get_tab(state.content, tab_idx)
      prior_name = Map.get(old_tab, "name") || "Sheet #{tab_idx + 1}"
      inverse = {:structural, %{"op" => "rename_tab", "tab" => tab_idx, "name" => prior_name}}
      new_tab = Map.put(old_tab, "name", name)

      {:ok,
       apply_structural(state, tab_idx, new_tab, false, %{
         op: "rename_tab",
         at: nil,
         count: nil,
         tab: tab_idx
       }), inverse}
    end
  end

  def apply_one(%{"op" => "add_tab", "name" => name}, state) do
    with {:ok, name} <- validate_tab_name(name) do
      tabs = Map.get(state.content, "tabs") || []
      new_idx = length(tabs)
      content = Map.put(state.content, "tabs", tabs ++ [%{"name" => name, "cells" => %{}}])
      inverse = {:structural, %{"op" => "delete_tab", "tab" => new_idx}}

      {:ok,
       finalize_structural(state, content, new_idx, %{}, %{
         op: "add_tab",
         at: nil,
         count: nil,
         tab: new_idx
       }), inverse}
    end
  end

  def apply_one(%{"op" => "delete_tab", "tab" => tab}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab) do
      tabs = Map.get(state.content, "tabs")

      if length(tabs) == 1 do
        {:error, "last_tab", "a sheet keeps at least one tab — cannot delete the last one"}
      else
        old_tab = Enum.at(tabs, tab_idx)
        old_cells = Map.get(old_tab, "cells") || %{}
        changed = Map.new(old_cells, fn {addr, _cell} -> {addr, nil} end)
        content = Map.put(state.content, "tabs", List.delete_at(tabs, tab_idx))

        {:ok,
         finalize_structural(state, content, tab_idx, changed, %{
           op: "delete_tab",
           at: nil,
           count: nil,
           tab: tab_idx
         }), {:tab_restore, tab_idx, old_tab}}
      end
    end
  end

  # Merge/unmerge — V1 policy is NON-destructive: covered cells KEEP their
  # data (a deliberate divergence from Excel's keep-top-left-clear-the-rest),
  # so an unmerge restores every value and xlsx consumers simply ignore the
  # covered cells under a merged span. The op only rewrites the tab's "merges"
  # list; cells are untouched (changed == %{}), and the delta's :structure key
  # forces the client to refetch the re-keyed merges.
  def apply_one(%{"op" => "merge_cells", "tab" => tab, "range" => range}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         {:ok, canonical, rect} <- normalize_merge_range(range),
         old_tab = Sheets.get_tab(state.content, tab_idx),
         merges = Map.get(old_tab, "merges") || [],
         :ok <- check_merge_overlap(merges, rect) do
      inverse = {:merges, tab_idx, merges}
      new_tab = Map.put(old_tab, "merges", merges ++ [canonical])

      {:ok,
       apply_structural(state, tab_idx, new_tab, false, %{
         op: "merge_cells",
         at: nil,
         count: nil,
         tab: tab_idx
       }), inverse}
    end
  end

  def apply_one(%{"op" => "unmerge_cells", "tab" => tab, "range" => range}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         {:ok, rect} <- parse_unmerge_range(range) do
      old_tab = Sheets.get_tab(state.content, tab_idx)
      merges = Map.get(old_tab, "merges") || []

      # Keep every merge that does NOT intersect the range; unparseable
      # entries stay untouched. If nothing intersects, there is nothing to do.
      {kept, removed} = Enum.split_with(merges, &merge_disjoint?(&1, rect))

      if removed == [] do
        {:error, "no_merge_in_range", "no merge intersects #{inspect(range)}"}
      else
        inverse = {:merges, tab_idx, merges}
        new_tab = Map.put(old_tab, "merges", kept)

        {:ok,
         apply_structural(state, tab_idx, new_tab, false, %{
           op: "unmerge_cells",
           at: nil,
           count: nil,
           tab: tab_idx
         }), inverse}
      end
    end
  end

  def apply_one(%{"op" => op} = op_map, state) when op in ["undo", "redo"] do
    apply_history(op_map, state, String.to_existing_atom(op))
  end

  def apply_one(_op, _state) do
    {:error, "malformed_op",
     "op must be set_cell/clear_cell (\"tab\"+\"ref\"), " <>
       "insert_rows/delete_rows/insert_cols/delete_cols (\"tab\"+\"at\"+\"count\"), " <>
       "set_col_width (\"tab\"+\"col\"+\"px\"), set_row_height (\"tab\"+\"row\"+\"px\"), " <>
       "set_frozen (\"tab\"+\"rows\"+\"cols\"), " <>
       "rename_tab (\"tab\"+\"name\"), add_tab (\"name\"), delete_tab (\"tab\"), " <>
       "merge_cells/unmerge_cells (\"tab\"+\"range\") " <>
       "or undo/redo (\"user\")"}
  end

  # ── per-user undo/redo (M4) ──────────────────────────────────────────────
  #
  # Inverse entries live as internal terms, never wire ops — a prior cell is
  # a FULL stored map (formula + computed value + style), not a raw scalar:
  #
  #   * {:cell, tab_idx, ref, cell | nil}      — restore one cell exactly
  #   * {:structural, op_map}                  — a plain structural wire op
  #   * {:structural_restore, op_map, cells}   — insert_* + the deleted
  #     span's captured cells (the inverse of a delete_*)
  #   * {:tab_restore, idx, tab}               — re-insert a deleted tab
  #   * {:merges, tab_idx, merges}             — restore a tab's whole
  #     "merges" list (the inverse of merge_cells/unmerge_cells)
  #
  # Applying an entry yields its OWN inverse, which lands on the opposite
  # stack — undo and redo are the same machine run in either direction.

  defp apply_history(%{"user" => user}, state, kind) when is_binary(user) and user != "" do
    {from, onto} = if kind == :undo, do: {:undo, :redo}, else: {:redo, :undo}

    case Map.get(Map.fetch!(state, from), user, []) do
      [] ->
        {:error, "nothing_to_#{kind}", "no entries on #{inspect(user)}'s #{kind} stack"}

      [entry | rest] ->
        # The entry is consumed either way: an entry that no longer applies
        # (its tab vanished under another user) is popped off the stack and
        # dropped — NOT re-tried — so it can never jam the stack permanently.
        # The error branch carries the post-pop state back so the caller
        # advances past the dead entry instead of discarding the pop.
        state = put_stack(state, from, user, rest)

        case apply_entry(entry, state) do
          {:ok, state, counter} ->
            {:ok, push_stack(state, onto, user, counter), nil}

          # apply_entry is only reachable from a wire undo/redo op, and undo
          # entries never contain undo/redo ops, so its {:structural, op_map}
          # delegate cannot recurse back into apply_history — the only 4-tuple
          # source is this branch, consumed one level up in session.ex.
          {:error, code, message} ->
            {:error, code, message, state}
        end
    end
  end

  defp apply_history(_op, _state, kind),
    do: {:error, "invalid_user", "#{kind} requires a non-blank \"user\" string"}

  # A successfully applied own-op pushes its inverse and clears the user's
  # redo stack; ops without a "user" (imports, anonymous wire calls) and
  # undo/redo themselves (inverse nil) record nothing.
  def record_undo(state, _op, nil), do: state

  def record_undo(state, op, inverse) do
    case Map.get(op, "user") do
      user when is_binary(user) and user != "" ->
        state |> push_stack(:undo, user, inverse) |> put_stack(:redo, user, [])

      _ ->
        state
    end
  end

  defp push_stack(state, key, user, entry) do
    stacks = Map.fetch!(state, key)
    stack = Enum.take([entry | Map.get(stacks, user, [])], @undo_depth)
    Map.put(state, key, Map.put(stacks, user, stack))
  end

  defp put_stack(state, key, user, stack) do
    Map.put(state, key, Map.put(Map.fetch!(state, key), user, stack))
  end

  defp apply_entry({:cell, tab, ref, cell}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab) do
      counter = {:cell, tab_idx, ref, cell_before(state, tab_idx, ref)}
      {:ok, apply_cell(state, tab_idx, ref, cell), counter}
    end
  end

  defp apply_entry({:structural, op_map}, state), do: apply_one(op_map, state)

  defp apply_entry(
         {:structural_restore, %{"op" => op, "tab" => tab, "at" => at, "count" => count},
          captured},
         state
       ) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         {:ok, new_tab} <- structural_shift(op, Sheets.get_tab(state.content, tab_idx), at, count) do
      new_tab = Map.update(new_tab, "cells", captured, &Map.merge(&1, captured))

      counter =
        {:structural,
         %{"op" => delete_op_for(op), "tab" => tab_idx, "at" => at, "count" => count}}

      {:ok,
       apply_structural(state, tab_idx, new_tab, true, %{
         op: op,
         at: at,
         count: count,
         tab: tab_idx
       }), counter}
    end
  end

  # Merge/unmerge invert by swapping the whole "merges" list back; the
  # counter captures the CURRENT list so redo restores the post-op state.
  defp apply_entry({:merges, tab, prior}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab) do
      old_tab = Sheets.get_tab(state.content, tab_idx)
      counter = {:merges, tab_idx, Map.get(old_tab, "merges") || []}
      new_tab = Map.put(old_tab, "merges", prior)

      {:ok,
       apply_structural(state, tab_idx, new_tab, false, %{
         op: "merges",
         at: nil,
         count: nil,
         tab: tab_idx
       }), counter}
    end
  end

  defp apply_entry({:tab_restore, idx, tab}, state) do
    tabs = Map.get(state.content, "tabs") || []
    idx = min(idx, length(tabs))
    content = Map.put(state.content, "tabs", List.insert_at(tabs, idx, tab))
    changed = Map.get(tab, "cells") || %{}
    counter = {:structural, %{"op" => "delete_tab", "tab" => idx}}

    {:ok,
     finalize_structural(state, content, idx, changed, %{
       op: "restore_tab",
       at: nil,
       count: nil,
       tab: idx
     }), counter}
  end

  # insert_* invert to plain deletes; delete_* invert to inserts carrying
  # the deleted span's cells (keyed by their original refs).
  defp shift_inverse(op, tab_idx, _old_tab, at, count)
       when op in ["insert_rows", "insert_cols"] do
    {:structural, %{"op" => delete_op_for(op), "tab" => tab_idx, "at" => at, "count" => count}}
  end

  defp shift_inverse(op, tab_idx, old_tab, at, count) do
    axis = if op == "delete_rows", do: :row, else: :col
    insert_op = if op == "delete_rows", do: "insert_rows", else: "insert_cols"
    captured = captured_span(old_tab, axis, at, count)

    {:structural_restore, %{"op" => insert_op, "tab" => tab_idx, "at" => at, "count" => count},
     captured}
  end

  defp delete_op_for("insert_rows"), do: "delete_rows"
  defp delete_op_for("insert_cols"), do: "delete_cols"

  defp captured_span(tab, axis, at, count) do
    for {addr, cell} <- Map.get(tab, "cells") || %{},
        {:ok, {col, row}} <- [Sheets.parse_ref(addr)],
        if(axis == :row, do: row, else: col) in at..(at + count - 1),
        into: %{} do
      {addr, cell}
    end
  end

  defp prior_px(tab, key, index) do
    case Map.get(tab, key) do
      sizes when is_map(sizes) -> Map.get(sizes, Integer.to_string(index))
      _ -> nil
    end
  end

  # A frozen band's current value as the non-negative int the inverse op
  # needs — our writes store ints, but an xlsx import may store a numeric
  # STRING; anything else (missing, garbage) reads as 0.
  defp prior_frozen(tab, key) do
    case Map.get(tab, key) do
      n when is_integer(n) and n >= 0 ->
        n

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n >= 0 -> n
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp cell_before(state, tab_idx, ref) do
    case Map.get(Sheets.get_tab(state.content, tab_idx) || %{}, "cells") do
      cells when is_map(cells) -> Map.get(cells, ref)
      _ -> nil
    end
  end

  defp structural_shift("insert_rows", tab, at, count), do: Structure.insert_rows(tab, at, count)
  defp structural_shift("delete_rows", tab, at, count), do: Structure.delete_rows(tab, at, count)
  defp structural_shift("insert_cols", tab, at, count), do: Structure.insert_cols(tab, at, count)
  defp structural_shift("delete_cols", tab, at, count), do: Structure.delete_cols(tab, at, count)

  defp validate_tab_name(name) do
    if is_binary(name) and String.trim(name) != "" do
      {:ok, name}
    else
      {:error, "invalid_name", "name must be a non-blank string, got #{inspect(name)}"}
    end
  end

  defp fetch_tab(content, tab) when is_integer(tab) and tab >= 0 do
    case Sheets.get_tab(content, tab) do
      %{} -> {:ok, tab}
      _ -> {:error, "tab_not_found", "the sheet has no tab #{tab}"}
    end
  end

  defp fetch_tab(_content, tab),
    do: {:error, "invalid_tab", "tab must be a non-negative integer, got #{inspect(tab)}"}

  # Normalizes through format_ref so "a1" and "A1" address the same cell.
  defp validate_ref(ref) do
    case Sheets.parse_ref(ref) do
      {:ok, {col, row}} when col <= @grid_max_col and row <= @grid_max_row ->
        {:ok, Sheets.format_ref({col, row})}

      {:ok, _} ->
        {:error, "ref_out_of_bounds",
         "ref #{inspect(ref)} is beyond the grid bounds (column #{@grid_max_col}/XFD, row #{@grid_max_row})"}

      :error ->
        {:error, "invalid_ref", "ref must be A1-style, got #{inspect(ref)}"}
    end
  end

  # Parse + normalize a merge_cells range: split on ":", parse both corners
  # (Core.parse_ref stays a pure, total A1 parser — CORE never reaches into
  # the plugin), order c1<=c2/r1<=r2, then reject a degenerate single cell,
  # a corner past the grid bounds, or an area over the cap. Returns the
  # canonical "A1:B3" string alongside the normalized rect.
  defp normalize_merge_range(range) do
    case parse_range_corners(range) do
      {:ok, {c1, r1, c2, r2} = rect} ->
        cond do
          c1 == c2 and r1 == r2 ->
            {:error, "merge_degenerate",
             "a merge must cover at least two cells, got #{inspect(range)}"}

          c2 > @grid_max_col or r2 > @grid_max_row ->
            {:error, "merge_out_of_bounds",
             "merge #{inspect(range)} is beyond the grid bounds (column #{@grid_max_col}/XFD, row #{@grid_max_row})"}

          (c2 - c1 + 1) * (r2 - r1 + 1) > @merge_area_cap ->
            {:error, "merge_area_exceeded",
             "merge #{inspect(range)} covers #{(c2 - c1 + 1) * (r2 - r1 + 1)} cells; the cap is #{@merge_area_cap}"}

          true ->
            canonical = Sheets.format_ref({c1, r1}) <> ":" <> Sheets.format_ref({c2, r2})
            {:ok, canonical, rect}
        end

      :error ->
        {:error, "invalid_range", "range must be an A1:B2-style pair, got #{inspect(range)}"}
    end
  end

  # unmerge only needs the normalized rect — no degenerate/area/bounds guard.
  defp parse_unmerge_range(range) do
    case parse_range_corners(range) do
      {:ok, rect} ->
        {:ok, rect}

      :error ->
        {:error, "invalid_range", "range must be an A1:B2-style pair, got #{inspect(range)}"}
    end
  end

  defp parse_range_corners(range) when is_binary(range) do
    with [a, b] <- String.split(range, ":"),
         {:ok, {ca, ra}} <- Sheets.parse_ref(a),
         {:ok, {cb, rb}} <- Sheets.parse_ref(b) do
      {:ok, {min(ca, cb), min(ra, rb), max(ca, cb), max(ra, rb)}}
    else
      _ -> :error
    end
  end

  defp parse_range_corners(_), do: :error

  # Rect intersection against every existing merge — two rects overlap unless
  # one lies entirely to a side of the other.
  defp check_merge_overlap(merges, rect) do
    if Enum.any?(merges, fn m -> not merge_disjoint?(m, rect) end) do
      {:error, "merge_overlap", "the range overlaps an existing merge"}
    else
      :ok
    end
  end

  defp merge_disjoint?(merge, {c1, r1, c2, r2}) do
    case parse_range_corners(merge) do
      {:ok, {mc1, mr1, mc2, mr2}} -> mc2 < c1 or mc1 > c2 or mr2 < r1 or mr1 > r2
      # An unparseable stored merge is treated as disjoint (never overlaps,
      # never removed) — it can only arrive via a malformed import and the
      # before_save gate already rejects it on the next persist.
      :error -> true
    end
  end

  # Leading "=" means formula — the importer convention; the canonical
  # stored "f" drops the "=" (the engine tolerates both, see its moduledoc).
  # Strings/formulas are byte-capped (@max_cell_bytes) so no single op can
  # balloon the session, the persist, a broadcast, or the recompute lexer.
  defp build_cell("=" <> formula) when byte_size(formula) > @max_cell_bytes,
    do: cell_too_large()

  defp build_cell("=" <> formula), do: {:ok, %{"f" => formula}}

  defp build_cell(raw) when is_binary(raw) and byte_size(raw) > @max_cell_bytes,
    do: cell_too_large()

  defp build_cell(raw) when is_binary(raw) or is_number(raw) or is_boolean(raw) or is_nil(raw),
    do: {:ok, %{"v" => raw}}

  defp build_cell(_raw),
    do: {:error, "invalid_raw", "raw must be a scalar (string, number, boolean or null)"}

  defp cell_too_large,
    do: {:error, "value_too_large", "cell content exceeds #{@max_cell_bytes} bytes"}

  # A set_cell into a cell a merge COVERS (inside a "merges" range but not its
  # top-left anchor) is refused: those cells render nothing in Studio, so
  # writing them plants phantom data only CSV/snapshot/exports/formulas would
  # see. The durable fence now that wave-5 lets users CREATE merges. xlsx
  # import bypasses the session, so imports stay unaffected.
  defp refuse_covered_ref(state, tab_idx, ref) do
    merges = Map.get(Sheets.get_tab(state.content, tab_idx) || %{}, "merges") || []

    case Sheets.parse_ref(ref) do
      {:ok, {c, r}} ->
        if Enum.any?(merges, &ref_covered_by?(&1, c, r)) do
          {:error, "merged_cell",
           "ref #{inspect(ref)} is covered by a merge — write to the merge's anchor cell instead"}
        else
          :ok
        end

      :error ->
        :ok
    end
  end

  defp ref_covered_by?(merge, c, r) do
    case parse_range_corners(merge) do
      {:ok, {c1, r1, c2, r2}} ->
        c1 <= c and c <= c2 and r1 <= r and r <= r2 and {c, r} != {c1, r1}

      :error ->
        false
    end
  end

  # set_cell may carry explicit "fmt"/"s" overrides. A PRESENT key wins over
  # the prior-carried value (fill stamps the source's format onto every
  # target); nil clears; an absent key is a no-op. "fmt" must be a Fmt class
  # (or nil), "s" a style map (or nil) — anything else rejects the op.
  defp apply_meta_overrides(op, cell) do
    with {:ok, cell} <- override_fmt(op, cell) do
      override_style(op, cell)
    end
  end

  defp override_fmt(op, cell) do
    if Map.has_key?(op, "fmt") do
      case op["fmt"] do
        nil ->
          {:ok, Map.delete(cell, "fmt")}

        fmt ->
          if fmt in Fmt.vocabulary() do
            {:ok, Map.put(cell, "fmt", fmt)}
          else
            {:error, "invalid_fmt",
             "\"fmt\" must be one of #{inspect(Fmt.vocabulary())} or null, got #{inspect(fmt)}"}
          end
      end
    else
      {:ok, cell}
    end
  end

  defp override_style(op, cell) do
    if Map.has_key?(op, "s") do
      case op["s"] do
        nil ->
          {:ok, Map.delete(cell, "s")}

        s when is_map(s) ->
          {:ok, Map.put(cell, "s", s)}

        other ->
          {:error, "invalid_style", "\"s\" must be a style map or null, got #{inspect(other)}"}
      end
    else
      {:ok, cell}
    end
  end

  # Cap-aware set_cell: counts non-empty cells (the import predicate — a
  # usable "v" or a formula) incrementally; an op that would push past the
  # cap errors before touching the content.
  defp check_cap(state, tab_idx, ref, cell) do
    old_cell =
      case Map.get(Sheets.get_tab(state.content, tab_idx), "cells") do
        cells when is_map(cells) -> Map.get(cells, ref)
        _ -> nil
      end

    if state.nonempty + nonempty_flag(cell) - nonempty_flag(old_cell) > state.cfg.cell_cap do
      {:error, "cell_cap_exceeded",
       "the sheet holds #{state.nonempty} non-empty cells; the cap is #{state.cfg.cell_cap}"}
    else
      :ok
    end
  end

  defp apply_cell(state, tab_idx, ref, cell_or_nil) do
    tabs = Map.get(state.content, "tabs")
    old_tab = Enum.at(tabs, tab_idx)
    old_cells = Map.get(old_tab, "cells") || %{}
    old_cell = Map.get(old_cells, ref)

    base_cells =
      case cell_or_nil do
        nil -> Map.delete(old_cells, ref)
        cell -> Map.put(old_cells, ref, cell)
      end

    formula_count =
      Map.get(state.formula_counts, tab_idx, 0) + formula_flag(cell_or_nil) -
        formula_flag(old_cell)

    new_tab = Map.put(old_tab, "cells", base_cells)
    # Refs are tab-local (engine contract), so only the op's tab can change —
    # and a tab with zero formula cells has nothing to derive: skip the
    # engine entirely (the bulk-import fast path; see the moduledoc).
    new_tab = if formula_count > 0, do: recompute_tab(new_tab), else: new_tab

    changed = diff_cells(old_cells, Map.get(new_tab, "cells") || %{})

    state = %{
      state
      | content: Map.put(state.content, "tabs", List.replace_at(tabs, tab_idx, new_tab)),
        rev: state.rev + 1,
        dirty?: true,
        ops_since_flush: state.ops_since_flush + 1,
        nonempty: state.nonempty + nonempty_flag(cell_or_nil) - nonempty_flag(old_cell),
        formula_counts: Map.put(state.formula_counts, tab_idx, formula_count)
    }

    broadcast_delta(state, tab_idx, changed)
    state
  end

  # Structural ops rewrite a whole tab: swap the rewritten tab in,
  # recompute when it still holds formulas (`recompute?` — rewritten refs
  # must settle; layout/rename ops skip the engine), diff the cells for
  # the delta, and RECOUNT the cached counters — cells move or die
  # wholesale here, so incremental bookkeeping is not worth the bug
  # surface (structural ops are rare next to cell ops).
  defp apply_structural(state, tab_idx, new_tab, recompute?, structure) do
    tabs = Map.get(state.content, "tabs")
    old_cells = Map.get(Enum.at(tabs, tab_idx), "cells") || %{}
    new_tab = if recompute? and holds_formula?(new_tab), do: recompute_tab(new_tab), else: new_tab
    changed = diff_cells(old_cells, Map.get(new_tab, "cells") || %{})
    content = Map.put(state.content, "tabs", List.replace_at(tabs, tab_idx, new_tab))
    finalize_structural(state, content, tab_idx, changed, structure)
  end

  defp finalize_structural(state, content, tab_idx, changed, structure) do
    state = %{
      state
      | content: content,
        rev: state.rev + 1,
        dirty?: true,
        ops_since_flush: state.ops_since_flush + 1,
        nonempty: count_nonempty(content),
        formula_counts: count_formulas(content)
    }

    broadcast_delta(state, tab_idx, changed, structure)
    state
  end

  defp holds_formula?(tab) do
    Enum.any?(Map.get(tab, "cells") || %{}, fn {_addr, cell} ->
      is_map(cell) and is_binary(Map.get(cell, "f"))
    end)
  end

  defp recompute_tab(tab) do
    %{"tabs" => [tab]} = Engine.recompute(%{"tabs" => [tab]})
    tab
  end

  # Every cell whose stored map changed — recompute dependents included;
  # nil marks a removal.
  defp diff_cells(old, new) do
    for addr <- Enum.uniq(Map.keys(old) ++ Map.keys(new)),
        Map.get(old, addr) != Map.get(new, addr),
        into: %{} do
      {addr, Map.get(new, addr)}
    end
  end

  defp broadcast_delta(state, tab_idx, changed, structure \\ nil) do
    payload = %{
      sheet_id: state.slug,
      rev: state.rev,
      epoch: state.epoch,
      tab: tab_idx,
      changed: changed
    }

    payload = if structure, do: Map.put(payload, :structure, structure), else: payload

    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      Session.topic(state.slug, state.dataset, state.workspace_id),
      {:sheets_op, payload}
    )
  end

  # ── counters ─────────────────────────────────────────────────────────────
  #
  # Shared by the GenServer's init/1 (initial seed) and the structural ops
  # (full recount). The per-cell flags are the import controller's
  # non-empty predicate: a usable "v" or a formula.

  def nonempty_flag(nil), do: 0

  def nonempty_flag(cell) do
    if Map.get(cell, "v") not in [nil, ""] or is_binary(Map.get(cell, "f")), do: 1, else: 0
  end

  def formula_flag(nil), do: 0
  def formula_flag(cell), do: if(is_binary(Map.get(cell, "f")), do: 1, else: 0)

  def count_nonempty(content) do
    for tab <- Map.get(content, "tabs") || [],
        is_map(tab),
        {_addr, cell} <- Map.get(tab, "cells") || %{},
        is_map(cell),
        reduce: 0 do
      acc -> acc + nonempty_flag(cell)
    end
  end

  def count_formulas(content) do
    for {tab, idx} <- Enum.with_index(Map.get(content, "tabs") || []),
        is_map(tab),
        {_addr, cell} <- Map.get(tab, "cells") || %{},
        is_map(cell),
        reduce: %{} do
      acc -> Map.update(acc, idx, formula_flag(cell), &(&1 + formula_flag(cell)))
    end
  end
end
