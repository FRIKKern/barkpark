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
  alias Barkpark.Plugins.Sheets.Session
  alias Barkpark.Plugins.Sheets.Structure

  # Excel's grid bounds — column XFD, row 1_048_576. Deliberately duplicated
  # (the established convention: `Barkpark.Plugins.Sheets.Engine` and the plugin gate
  # `Barkpark.Plugins.Sheets` each keep their own copy of the same two
  # integers): the Session is CORE and must not reach into the plugin, and
  # `Barkpark.Plugins.Sheets.Core.parse_ref/1` stays a pure, total A1 parser.
  @grid_max_col 16_384
  @grid_max_row 1_048_576

  # Per-user undo/redo stack depth (M4, bound at the grill).
  @undo_depth 100

  # ── op application ───────────────────────────────────────────────────────
  #
  # Every clause returns {:ok, state, inverse | nil} — the inverse is the
  # per-user undo entry (see apply_entry/2), nil when the op records no
  # history (undo/redo themselves mutate the stacks inline).

  def apply_one(%{"op" => "set_cell", "tab" => tab, "ref" => ref, "raw" => raw}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         {:ok, ref} <- validate_ref(ref),
         {:ok, cell} <- build_cell(raw),
         :ok <- check_cap(state, tab_idx, ref, cell) do
      inverse = {:cell, tab_idx, ref, cell_before(state, tab_idx, ref)}
      {:ok, apply_cell(state, tab_idx, ref, cell), inverse}
    end
  end

  def apply_one(%{"op" => "clear_cell", "tab" => tab, "ref" => ref}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         {:ok, ref} <- validate_ref(ref) do
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

  def apply_one(%{"op" => op} = op_map, state) when op in ["undo", "redo"] do
    apply_history(op_map, state, String.to_existing_atom(op))
  end

  def apply_one(_op, _state) do
    {:error, "malformed_op",
     "op must be set_cell/clear_cell (\"tab\"+\"ref\"), " <>
       "insert_rows/delete_rows/insert_cols/delete_cols (\"tab\"+\"at\"+\"count\"), " <>
       "set_col_width (\"tab\"+\"col\"+\"px\"), set_row_height (\"tab\"+\"row\"+\"px\"), " <>
       "rename_tab (\"tab\"+\"name\"), add_tab (\"name\"), delete_tab (\"tab\") " <>
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
        # (its tab vanished under another user) would otherwise jam the
        # stack permanently.
        state = put_stack(state, from, user, rest)

        case apply_entry(entry, state) do
          {:ok, state, counter} -> {:ok, push_stack(state, onto, user, counter), nil}
          {:error, _code, _message} = error -> error
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

  # Leading "=" means formula — the importer convention; the canonical
  # stored "f" drops the "=" (the engine tolerates both, see its moduledoc).
  defp build_cell("=" <> formula), do: {:ok, %{"f" => formula}}

  defp build_cell(raw) when is_binary(raw) or is_number(raw) or is_boolean(raw) or is_nil(raw),
    do: {:ok, %{"v" => raw}}

  defp build_cell(_raw),
    do: {:error, "invalid_raw", "raw must be a scalar (string, number, boolean or null)"}

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
    payload = %{sheet_id: state.slug, rev: state.rev, tab: tab_idx, changed: changed}
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
