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
      {:ok, apply_cell(state, tab_idx, ref, cell, true), inverse}
    end
  end

  def apply_one(%{"op" => "clear_cell", "tab" => tab, "ref" => ref}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         {:ok, ref} <- validate_ref(ref) do
      # Excel's Delete clears content AND format; our model has no
      # empty-but-formatted cell, so clear_cell stays a full delete (unlike
      # set_cell, which preserves "fmt"/"s").
      inverse = {:cell, tab_idx, ref, cell_before(state, tab_idx, ref)}
      {:ok, apply_cell(state, tab_idx, ref, nil, true), inverse}
    end
  end

  # Display-only meta write (the toolbar apply-UI): stamp a cell's number
  # format ("fmt") and/or style ("s") onto the EXISTING cell WITHOUT touching
  # its "v"/"f". Deliberately NOT set_cell with a re-sent raw — build_cell
  # re-parses raw and can coerce a stored string like "0123" into a number,
  # silently mutating data on a formatting gesture. An absent "fmt"/"s" key is
  # a no-op; nil clears; "fmt" validates against Fmt.vocabulary and "s" against
  # the STRICT style grammar (b/i boolean, al left|center|right, bg #rrggbb) —
  # tighter than set_cell's lax override_style, whose "s" arrives copied from an
  # already-stored cell (fill) or an import. Formatting an EMPTY cell is REFUSED
  # (empty_cell): the model has no empty-but-formatted cell (clear_cell's comment
  # locks that), so a meta write onto a blank ref would plant a phantom the next
  # clear/retype silently drops. A merge-covered ref is refused like set_cell
  # (merged_cell). The inverse is the existing {:cell, …, prior} undo shape.
  def apply_one(%{"op" => "set_cell_meta", "tab" => tab, "ref" => ref} = op, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         {:ok, ref} <- validate_ref(ref),
         :ok <- refuse_covered_ref(state, tab_idx, ref),
         prior = cell_before(state, tab_idx, ref),
         {:ok, prior} <- refuse_empty_meta(prior),
         {:ok, cell} <- override_fmt(op, prior),
         {:ok, cell} <- override_meta_style(op, cell) do
      inverse = {:cell, tab_idx, ref, prior}
      {:ok, apply_cell(state, tab_idx, ref, cell, true), inverse}
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

  # Whole-tab conditional-formatting replace (CF-C). The op carries the tab's
  # FULL new `cond_formats` list; apply_one validates it with byte-identical
  # strictness to the CF-B before_save gate (via the plugin's public validator)
  # BEFORE storing — a session-accepted rule the gate would later reject would
  # strand the debounced persist forever (the CF-AM1 bug class). The inverse is
  # a structural set_cond_format back to the PRIOR list, so undo/redo ride the
  # existing structural machinery (no new inverse shape). No recompute: rules
  # never change a cell VALUE, only its rendered style.
  def apply_one(%{"op" => "set_cond_format", "tab" => tab, "rules" => rules}, state)
      when is_list(rules) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         :ok <- validate_cond_formats(rules, tab_idx) do
      old_tab = Sheets.get_tab(state.content, tab_idx)
      prior = Map.get(old_tab, "cond_formats") || []
      inverse = {:structural, %{"op" => "set_cond_format", "tab" => tab_idx, "rules" => prior}}
      new_tab = Map.put(old_tab, "cond_formats", rules)

      {:ok,
       apply_structural(state, tab_idx, new_tab, false, %{
         op: "set_cond_format",
         at: nil,
         count: nil,
         tab: tab_idx
       }), inverse}
    end
  end

  def apply_one(%{"op" => "set_cond_format", "tab" => _tab}, _state),
    do: {:error, "invalid_cond_format", "\"rules\" must be a list"}

  # Sort a range's rows in place (SF-A) — a PURE row permutation that moves
  # every cell map VERBATIM (`f` never rewritten, SF-D1). Validate the range
  # like a merge range (A1:B2 within grid bounds), then hand the whole tab to
  # the kernel, which runs the comparator + the merge/frozen/keys guards.
  # Apply through `apply_structural` with recompute TRUE (the insert/delete
  # precedent — recompute refreshes `v` for the verbatim-moved formulas). The
  # inverse is the NEW 5th inverse shape `{:permute, tab_idx, rect, perm}`
  # (SF-D6): undo re-applies the inverse permutation over the same rect,
  # loss-free. An already-sorted range (identity permutation) is a true no-op
  # — no rev bump, no undo entry, no broadcast (the move_tab from==to
  # precedent).
  def apply_one(%{"op" => "sort_range", "tab" => tab, "range" => range, "keys" => keys}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         {:ok, rect} <- validate_sort_range(range),
         old_tab = Sheets.get_tab(state.content, tab_idx),
         {:ok, new_tab, perm} <- Structure.sort_rows(old_tab, rect, keys) do
      if identity_perm?(perm) do
        {:ok, state, nil}
      else
        inverse = {:permute, tab_idx, rect, Structure.invert_perm(perm)}

        {:ok,
         apply_structural(state, tab_idx, new_tab, true, %{
           op: "sort_range",
           at: nil,
           count: nil,
           tab: tab_idx
         }), inverse}
      end
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

        state =
          finalize_structural(state, content, tab_idx, changed, %{
            op: "delete_tab",
            at: nil,
            count: nil,
            tab: tab_idx
          })

        # Every stack index AFTER the deleted slot slides down by one —
        # the mirror of duplicate_tab's insert shift. Entries pinned to the
        # deleted index itself are deliberately KEPT AS-IS: they surface as
        # a consumed dead entry at undo time (see apply_history), keeping
        # the history behind them reachable.
        {:ok, remap_tab_indexes(state, delete_remap_fun(tab_idx)),
         {:tab_restore, tab_idx, old_tab}}
      end
    end
  end

  # Reorder a tab: pull it out and re-insert at `to` (a pure permutation, so
  # List.delete_at |> List.insert_at is self-inverting). `from`/`to` both must
  # be existing 0..len-1 indices; `from == to` is a true no-op (no rev bump,
  # no undo entry, no broadcast). No recompute — refs are tab-local, so a
  # reorder never changes a value; only the tab-keyed counters re-index.
  # CRUCIAL: every undo/redo entry pins an ABSOLUTE tab index, so after the
  # permutation we remap EVERY user's stacks or a later undo lands on the
  # wrong tab (silent cross-user corruption). The :structure payload carries
  # "from"/"to" so the Studio refetch remaps its own view identically.
  def apply_one(%{"op" => "move_tab", "from" => from, "to" => to}, state) do
    with {:ok, from_idx} <- fetch_tab(state.content, from),
         {:ok, to_idx} <- fetch_tab(state.content, to) do
      if from_idx == to_idx do
        {:ok, state, nil}
      else
        tabs = Map.get(state.content, "tabs")
        moved = Enum.at(tabs, from_idx)
        new_tabs = tabs |> List.delete_at(from_idx) |> List.insert_at(to_idx, moved)
        content = Map.put(state.content, "tabs", new_tabs)
        inverse = {:structural, %{"op" => "move_tab", "from" => to_idx, "to" => from_idx}}

        state =
          finalize_structural(state, content, to_idx, %{}, %{
            op: "move_tab",
            at: nil,
            count: nil,
            tab: to_idx,
            from: from_idx,
            to: to_idx
          })

        {:ok, remap_tab_indexes(state, move_remap_fun(from_idx, to_idx)), inverse}
      end
    end
  end

  # Duplicate a tab immediately after itself. The cap check runs FIRST — the
  # non-empty cap is session-total but only set_cell enforced it, so a
  # duplicate of a full tab could bypass it; count the source's non-empty
  # cells against the session total (matching check_cap's "cell_cap_exceeded"
  # code). The copy carries the WHOLE tab map (cells/merges/col_widths/
  # row_heights/frozen_* and any future keys ride along); only "name" changes
  # — "Copy of <src>", deduped case-insensitively with " 2"/" 3"… suffixes.
  # Inverse is a delete_tab of the inserted slot; every stack index >= the
  # insert slot shifts up by one.
  def apply_one(%{"op" => "duplicate_tab", "tab" => tab}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab) do
      tabs = Map.get(state.content, "tabs")
      src = Enum.at(tabs, tab_idx)
      src_cells = Map.get(src, "cells") || %{}
      src_nonempty = tab_nonempty(src_cells)

      if state.nonempty + src_nonempty > state.cfg.cell_cap do
        {:error, "cell_cap_exceeded",
         "the sheet holds #{state.nonempty} non-empty cells; the cap is #{state.cfg.cell_cap}"}
      else
        existing_names = Enum.map(tabs, &(Map.get(&1, "name") || ""))
        src_name = Map.get(src, "name") || "Sheet #{tab_idx + 1}"
        copy_name = dedupe_tab_name("Copy of " <> src_name, existing_names)
        # In BEAM every map is immutable, so Map.put over the source IS a deep
        # copy for our purposes — a later write to the copy allocates a fresh
        # map and never touches the source's cells.
        copy = Map.put(src, "name", copy_name)
        insert_idx = tab_idx + 1
        content = Map.put(state.content, "tabs", List.insert_at(tabs, insert_idx, copy))
        inverse = {:structural, %{"op" => "delete_tab", "tab" => insert_idx}}

        state =
          finalize_structural(state, content, insert_idx, src_cells, %{
            op: "duplicate_tab",
            at: nil,
            count: nil,
            tab: insert_idx
          })

        {:ok, remap_tab_indexes(state, dup_remap_fun(insert_idx)), inverse}
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
      # Granular inverse: undo removes EXACTLY the canonical this op added,
      # leaving every other user's merges (and any later re-keying by a shift)
      # untouched — NOT a whole-list snapshot that would clobber them.
      inverse = {:remove_merges, tab_idx, [canonical]}
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
        # Granular inverse: undo re-adds ONLY the merges this op removed,
        # skipping any that a later op has since re-covered — never a whole-list
        # snapshot that would resurrect pre-shift coordinates over other users'
        # merges.
        inverse = {:add_merges, tab_idx, removed}
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
       "set_cell_meta (\"tab\"+\"ref\"+\"fmt\"?/\"s\"?), " <>
       "insert_rows/delete_rows/insert_cols/delete_cols (\"tab\"+\"at\"+\"count\"), " <>
       "set_col_width (\"tab\"+\"col\"+\"px\"), set_row_height (\"tab\"+\"row\"+\"px\"), " <>
       "set_frozen (\"tab\"+\"rows\"+\"cols\"), " <>
       "set_cond_format (\"tab\"+\"rules\"), " <>
       "sort_range (\"tab\"+\"range\"+\"keys\"), " <>
       "rename_tab (\"tab\"+\"name\"), add_tab (\"name\"), delete_tab (\"tab\"), " <>
       "move_tab (\"from\"+\"to\"), duplicate_tab (\"tab\"), " <>
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
  #   * {:remove_merges, tab_idx, canonicals}  — drop exactly these merge
  #     ranges (the inverse of merge_cells; no-op for any already gone)
  #   * {:add_merges, tab_idx, canonicals}     — re-add these merge ranges,
  #     SKIPPING any that now overlap (the inverse of unmerge_cells)
  #   * {:permute, tab_idx, rect, perm}        — re-apply a row permutation
  #     over the rect (the inverse of sort_range; SF-D6). Applying it yields
  #     its own inverse for the opposite stack — verbatim moves both ways.
  #   * {:merges, tab_idx, merges}             — LEGACY whole-list snapshot,
  #     tolerated on read for any in-flight stack entry but no longer PRODUCED
  #     (it clobbered other users' merges and resurrected pre-shift coords)
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

  # ── tab-index remap (move_tab / duplicate_tab / delete_tab / tab_restore) ─
  #
  # A tab reorder, insert, or delete permutes tab indices, but EVERY
  # undo/redo entry pins an ABSOLUTE tab index, so the same permutation must
  # be applied to every user's stacks — otherwise a later undo restores on the
  # WRONG tab (a silent cross-user corruption). `fun` maps an old index to its
  # new one; we walk all five inverse-entry shapes plus the structural op_maps
  # they wrap — including move_tab op_maps, whose "from"/"to" keys are
  # permuted just like a "tab" key (see remap_op_tab).
  defp remap_tab_indexes(state, fun) do
    %{state | undo: remap_stacks(state.undo, fun), redo: remap_stacks(state.redo, fun)}
  end

  defp remap_stacks(by_user, fun) do
    Map.new(by_user, fn {user, stack} -> {user, Enum.map(stack, &remap_entry(&1, fun))} end)
  end

  defp remap_entry({:cell, tab, ref, cell}, fun), do: {:cell, fun.(tab), ref, cell}
  defp remap_entry({:structural, op_map}, fun), do: {:structural, remap_op_tab(op_map, fun)}

  defp remap_entry({:structural_restore, op_map, cells}, fun),
    do: {:structural_restore, remap_op_tab(op_map, fun), cells}

  defp remap_entry({:tab_restore, idx, tab}, fun), do: {:tab_restore, fun.(idx), tab}
  defp remap_entry({:remove_merges, tab, list}, fun), do: {:remove_merges, fun.(tab), list}
  defp remap_entry({:add_merges, tab, list}, fun), do: {:add_merges, fun.(tab), list}
  defp remap_entry({:merges, tab, prior}, fun), do: {:merges, fun.(tab), prior}
  # A sort undo pins an ABSOLUTE tab index like every other shape — the #843
  # all-inverse-shapes remap contract (a missing clause crashes undo after a
  # tab move/delete with a pending sort undo). The rect/perm are row-space and
  # do not shift under a tab permutation.
  defp remap_entry({:permute, tab, rect, perm}, fun), do: {:permute, fun.(tab), rect, perm}

  # A stacked move_tab inverse pins "from"/"to", not "tab". `fun.(from)` is
  # exact — "from" tracks the IDENTITY of the tab to move back, and the
  # permutation follows that tab wherever it went. `fun.(to)` is a destination
  # SLOT, not an identity, so pushing it through the same permutation is
  # best-effort only — the same lossy contract as merge re-add: after an
  # unrelated reorder the "original" destination may no longer be a single
  # well-defined index, and we take the permuted slot as the closest truth.
  defp remap_op_tab(%{"op" => "move_tab", "from" => from, "to" => to} = op_map, fun) do
    op_map
    |> Map.put("from", fun.(from))
    |> Map.put("to", fun.(to))
  end

  defp remap_op_tab(op_map, fun) do
    case Map.fetch(op_map, "tab") do
      {:ok, idx} -> Map.put(op_map, "tab", fun.(idx))
      :error -> op_map
    end
  end

  # move from -> to: the moved tab lands on `to`; the tabs it stepped over
  # shift one slot the other way (a pure permutation, self-inverting).
  defp move_remap_fun(from, to) do
    fn
      ^from -> to
      idx when from < to and idx > from and idx <= to -> idx - 1
      idx when to < from and idx >= to and idx < from -> idx + 1
      idx -> idx
    end
  end

  # duplicate (or a tab_restore) inserts a tab at `insert_idx`; everything
  # at or after it slides up by one.
  defp dup_remap_fun(insert_idx) do
    fn idx -> if idx >= insert_idx, do: idx + 1, else: idx end
  end

  # delete removes the tab at `deleted_idx`; everything after it slides down
  # by one. The deleted index itself is NOT remapped — an entry pinned to the
  # vanished tab stays put on purpose, surfacing as a consumed dead entry at
  # undo time so the history behind it stays reachable (see apply_history).
  defp delete_remap_fun(deleted_idx) do
    fn idx -> if idx > deleted_idx, do: idx - 1, else: idx end
  end

  # Count a tab's non-empty cells for the session-total cap (duplicate_tab).
  defp tab_nonempty(cells) do
    Enum.reduce(cells, 0, fn {_addr, cell}, acc -> acc + nonempty_flag(cell) end)
  end

  # Case-insensitive tab-name dedupe with " 2"/" 3"… suffixes — the same
  # convention as `Barkpark.Plugins.Sheets.XlsxExport.dedupe/2` (module
  # convention: CORE keeps its own copy; no xlsx 31-char re-slice here, these
  # are session names, not sheet-XML names).
  defp dedupe_tab_name(base, existing) do
    seen = MapSet.new(existing, &String.downcase/1)

    if MapSet.member?(seen, String.downcase(base)) do
      dedupe_tab_suffix(base, seen, 2)
    else
      base
    end
  end

  defp dedupe_tab_suffix(base, seen, n) do
    candidate = base <> " #{n}"

    if MapSet.member?(seen, String.downcase(candidate)) do
      dedupe_tab_suffix(base, seen, n + 1)
    else
      candidate
    end
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

  # Granular merge undo — drop exactly the named canonical ranges (a range
  # already gone is silently ignored, never an error), leaving every other
  # merge in place. The counter re-adds precisely what was removed, so redo
  # restores the post-op state. This is the inverse of merge_cells and the
  # redo-counter of {:add_merges, …}.
  defp apply_entry({:remove_merges, tab, canonicals}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab) do
      old_tab = Sheets.get_tab(state.content, tab_idx)
      merges = Map.get(old_tab, "merges") || []
      wanted = MapSet.new(canonicals)
      {removed, kept} = Enum.split_with(merges, &MapSet.member?(wanted, &1))
      counter = {:add_merges, tab_idx, removed}
      new_tab = Map.put(old_tab, "merges", kept)

      {:ok,
       apply_structural(state, tab_idx, new_tab, false, %{
         op: "merges",
         at: nil,
         count: nil,
         tab: tab_idx
       }), counter}
    end
  end

  # Granular merge redo/undo re-add — re-append each canonical range that does
  # NOT overlap the CURRENT list; a range a later op has re-covered is SKIPPED
  # (never write an overlapping list — the persist gate depends on it). A
  # re-added merge may land at pre-shift coordinates (the same lossy contract
  # as delete_* undo). The counter removes exactly what was re-added, so the
  # opposite direction inverts cleanly. Inverse of unmerge_cells and the
  # redo-counter of {:remove_merges, …}.
  defp apply_entry({:add_merges, tab, canonicals}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab) do
      old_tab = Sheets.get_tab(state.content, tab_idx)
      merges = Map.get(old_tab, "merges") || []

      {added_rev, merges} =
        Enum.reduce(canonicals, {[], merges}, fn canonical, {added, acc} ->
          with {:ok, rect} <- parse_range_corners(canonical),
               :ok <- check_merge_overlap(acc, rect) do
            {[canonical | added], acc ++ [canonical]}
          else
            _ -> {added, acc}
          end
        end)

      counter = {:remove_merges, tab_idx, Enum.reverse(added_rev)}
      new_tab = Map.put(old_tab, "merges", merges)

      {:ok,
       apply_structural(state, tab_idx, new_tab, false, %{
         op: "merges",
         at: nil,
         count: nil,
         tab: tab_idx
       }), counter}
    end
  end

  # LEGACY whole-list snapshot — tolerated on read for any pre-upgrade in-memory
  # stack entry, but no longer produced (it clobbered other users' merges). The
  # counter captures the CURRENT list so a redo of a legacy entry still inverts.
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
    # Re-inserting the tab shifts every tab at/after the restored slot up by
    # one — apply the same insert shift to the stacks that duplicate_tab
    # applies at its insert site, or an entry written between the delete and
    # this restore lands one slot short of its logical tab. Uses the CLAMPED
    # idx: that is the slot the tab actually lands in.
    state = remap_tab_indexes(state, dup_remap_fun(idx))
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

  # Re-apply a stored row permutation over the rect (the inverse of a
  # sort_range; SF-D6). `permute_rows` moves cells verbatim and hands back the
  # perm that undoes THIS application — the counter for the opposite stack, so
  # undo and redo ride the same machine. Recompute TRUE settles moved
  # formulas' `v`, mirroring the forward sort op.
  defp apply_entry({:permute, tab, rect, perm}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab) do
      old_tab = Sheets.get_tab(state.content, tab_idx)
      {:ok, new_tab, inverse_perm} = Structure.permute_rows(old_tab, rect, perm)
      counter = {:permute, tab_idx, rect, inverse_perm}

      {:ok,
       apply_structural(state, tab_idx, new_tab, true, %{
         op: "sort_range",
         at: nil,
         count: nil,
         tab: tab_idx
       }), counter}
    end
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

  # Gate-parity validation for set_cond_format — delegates to the plugin's
  # PUBLIC before_save validator (`Barkpark.Plugins.Sheets.cond_format_list_errors/2`)
  # so the session admits EXACTLY the rule lists the persist gate admits (CF-D6,
  # CF-AM1). This is the one deliberate CORE→plugin reach in this module: unlike
  # the duplicated grid/merge bounds (kept in sync by hand), the CF gate is far
  # richer, so the charter mandates ONE validator shared by both sides (no
  # fourth copy — the parked-hygiene rule). Runtime call only; no compile cycle.
  defp validate_cond_formats(rules, tab_idx) do
    case Barkpark.Plugins.Sheets.cond_format_list_errors(rules, tab_idx) do
      [] -> :ok
      errors -> {:error, "invalid_cond_format", Enum.join(errors, "; ")}
    end
  end

  defp validate_tab_name(name) do
    if is_binary(name) and String.trim(name) != "" do
      {:ok, name}
    else
      {:error, "invalid_name", "name must be a non-blank string, got #{inspect(name)}"}
    end
  end

  # Parse + bounds-check a sort range the same way merges do (any corner
  # order, within the grid bounds) — the merge/frozen/keys guards run in the
  # kernel. Returns the normalized 1-based rect.
  defp validate_sort_range(range) do
    case parse_range_corners(range) do
      {:ok, {_c1, _r1, c2, r2} = rect} ->
        if c2 > @grid_max_col or r2 > @grid_max_row do
          {:error, "sort_out_of_bounds",
           "sort range #{inspect(range)} is beyond the grid bounds (column #{@grid_max_col}/XFD, row #{@grid_max_row})"}
        else
          {:ok, rect}
        end

      :error ->
        {:error, "invalid_range", "range must be an A1:B2-style pair, got #{inspect(range)}"}
    end
  end

  # True when the sort left every row where it was — the caller records no
  # undo entry and skips the broadcast (an already-sorted range is a no-op).
  defp identity_perm?(perm), do: perm == Enum.to_list(0..(length(perm) - 1)//1)

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

  # set_cell_meta refuses a meta write onto a blank ref — see the op clause's
  # comment for why the model has no empty-but-formatted cell.
  defp refuse_empty_meta(nil),
    do: {:error, "empty_cell", "cannot format an empty cell — enter a value first"}

  defp refuse_empty_meta(cell), do: {:ok, cell}

  # set_cell_meta's STRICT style path — its "s" is a raw user toolbar gesture,
  # so every key/value is validated (unlike override_style, whose "s" is copied
  # from an already-stored cell). An empty map clears "s" (the toggle-off path).
  defp override_meta_style(op, cell) do
    if Map.has_key?(op, "s") do
      case op["s"] do
        nil ->
          {:ok, Map.delete(cell, "s")}

        s when is_map(s) ->
          case validate_style_map(s) do
            :ok when map_size(s) == 0 -> {:ok, Map.delete(cell, "s")}
            :ok -> {:ok, Map.put(cell, "s", s)}
            {:error, msg} -> {:error, "invalid_style", msg}
          end

        other ->
          {:error, "invalid_style", "\"s\" must be a style map or null, got #{inspect(other)}"}
      end
    else
      {:ok, cell}
    end
  end

  defp validate_style_map(s) do
    Enum.reduce_while(s, :ok, fn {k, v}, _acc ->
      if valid_style_pair?(k, v),
        do: {:cont, :ok},
        else:
          {:halt,
           {:error,
            "invalid \"s\" entry #{inspect({k, v})} — keys are b/i (boolean), " <>
              "al (left|center|right), bg (#rrggbb)"}}
    end)
  end

  defp valid_style_pair?("b", v), do: is_boolean(v)
  defp valid_style_pair?("i", v), do: is_boolean(v)
  defp valid_style_pair?("al", v), do: v in ["left", "center", "right"]
  defp valid_style_pair?("bg", v), do: is_binary(v) and Regex.match?(~r/^#[0-9a-fA-F]{6}$/, v)
  defp valid_style_pair?(_k, _v), do: false

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

  # `defer?` coalesces the batch hot path: every cell op in an `apply_ops`
  # batch (`set_cell`/`clear_cell`/`set_cell_meta`) writes its raw cell and
  # bumps the counters immediately, but DEFERS the (expensive) full
  # `Engine.recompute` and the delta broadcast to a single per-tab
  # `flush_pending/1` at the batch boundary. A 1000-op paste into a
  # formula-bearing tab was 1000 whole-tab recomputes (each ~70–90ms at the
  # 50k-cell cap → past the 30s call timeout); it is now ONE. The undo/redo
  # cell-restore path (`apply_entry({:cell, …})`) calls with `defer?`
  # defaulted false, keeping its recompute+broadcast immediate — unchanged.
  defp apply_cell(state, tab_idx, ref, cell_or_nil, defer? \\ false) do
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

    base_tab = Map.put(old_tab, "cells", base_cells)
    # Refs are tab-local (engine contract), so only the op's tab can change —
    # and a tab with zero formula cells has nothing to derive: skip the
    # engine entirely (the bulk-import fast path; see the moduledoc). In the
    # deferred batch path the recompute is skipped here too and settled once
    # at flush.
    new_tab = if not defer? and formula_count > 0, do: recompute_tab(base_tab), else: base_tab

    state = %{
      state
      | content: Map.put(state.content, "tabs", List.replace_at(tabs, tab_idx, new_tab)),
        rev: state.rev + 1,
        dirty?: true,
        ops_since_flush: state.ops_since_flush + 1,
        nonempty: state.nonempty + nonempty_flag(cell_or_nil) - nonempty_flag(old_cell),
        formula_counts: Map.put(state.formula_counts, tab_idx, formula_count)
    }

    if defer? do
      # Capture the tab's cells as they were BEFORE the batch's first touch
      # (Map.put_new keeps the earliest), so the coalesced flush still diffs
      # against the pre-batch state and its `changed` carries every recomputed
      # dependent — the wire contract stays byte-identical in structure.
      %{state | dirty_tabs: Map.put_new(state.dirty_tabs, tab_idx, old_cells)}
    else
      changed = diff_cells(old_cells, Map.get(new_tab, "cells") || %{})
      broadcast_delta(state, tab_idx, changed)
      state
    end
  end

  # True for the ops whose recompute+broadcast the batch coalesces. Any other
  # op (structural, undo/redo) forces a `flush_pending/1` first (see
  # `Session.handle_call/3`), so it observes — and broadcasts from — a fully
  # recomputed grid.
  def cell_op?(%{"op" => op}) when op in ["set_cell", "clear_cell", "set_cell_meta"], do: true
  def cell_op?(_op), do: false

  # Settle every tab a deferred cell op touched: recompute each formula-bearing
  # tab ONCE, then broadcast one coalesced delta per tab (diffing the captured
  # pre-batch cells against the recomputed cells). No-op when nothing is
  # pending. Runs at the batch boundary and before any non-cell op.
  def flush_pending(%{dirty_tabs: dirty} = state) when map_size(dirty) == 0, do: state

  def flush_pending(state) do
    Enum.reduce(state.dirty_tabs, %{state | dirty_tabs: %{}}, fn {tab_idx, pre_cells}, st ->
      tabs = Map.get(st.content, "tabs")
      tab = Enum.at(tabs, tab_idx)
      tab = if Map.get(st.formula_counts, tab_idx, 0) > 0, do: recompute_tab(tab), else: tab
      changed = diff_cells(pre_cells, Map.get(tab, "cells") || %{})
      st = %{st | content: Map.put(st.content, "tabs", List.replace_at(tabs, tab_idx, tab))}
      broadcast_delta(st, tab_idx, changed)
      st
    end)
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
    # Test-visible probe for the coalescing invariant (one recompute per dirty
    # tab per batch, not one per op). Cheap when no handler is attached.
    :telemetry.execute([:barkpark, :sheets, :recompute_tab], %{count: 1}, %{})
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
