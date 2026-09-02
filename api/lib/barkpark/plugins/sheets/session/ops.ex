defmodule Barkpark.Plugins.Sheets.Session.Ops do
  @moduledoc """
  Op-application machinery for `Barkpark.Plugins.Sheets.Session`.

  Plain module (no GenServer) — every function operates on the session's
  in-memory state map. The owning GenServer's `handle_call({:apply_ops, …})`
  dispatches each wire-shaped op through `apply_one/2`, accumulates the
  batch's inverses, and records them as ONE per-user entry via
  `record_batch_undo/2` (per-gesture undo, QL-D4 — a >100-cell paste is a
  single `{:group, …}` step); the per-user undo/redo machine
  (`apply_history/3`, `apply_entry/2`) rides the same path.

  Validation, cell mutation, structural shifts, recompute, the compact
  delta broadcast, and the cached non-empty / formula counters all live
  here. The only call back into the GenServer module is
  `Session.topic/3` for the broadcast topic (the public, byte-stable API).

  See `Barkpark.Plugins.Sheets.Session`'s moduledoc for the op grammar,
  the undo/redo semantics, the recompute + delta contract, and the
  inverse-entry term shapes.
  """

  alias Barkpark.Plugins.Sheets.CondFormat
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

  # Cap on DISTINCT `"user"` keys across the undo/redo maps — the depth cap
  # above bounds each stack, this bounds HOW MANY stacks. `"user"` is
  # client-supplied and unauthenticated on the :ingest tier (identity rides
  # the op — see `OpsController`), so without this bound N distinct user
  # strings grow `map_size(state.undo)` to N: unbounded per-session
  # GenServer memory an anonymous client controls. Mirrors the `ReplayRing`
  # bounded cache (@cap + evict-on-write): a push by a NEW user beyond the
  # cap evicts the least-recently-touched user's undo AND redo stacks
  # together (see `touch_undo_user/2`). 64 is generous for legitimate
  # same-sheet collaboration; an evicted user merely loses undo history —
  # the same lossy degradation as depth overflow — nothing else.
  @undo_user_cap 64

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
      axis = if op in ["insert_rows", "delete_rows"], do: :row, else: :col
      kind = if op in ["insert_rows", "insert_cols"], do: :insert, else: :delete
      change = {kind, at, count}

      # Built from the PRE-op content — for a delete_* it captures the
      # pre-rewrite cells of every formula the two rewrite passes below touch
      # (own tab and every other tab holding a cross-tab ref), which is what
      # makes the undo lossless. See `shift_inverse/6`.
      inverse = shift_inverse(op, tab_idx, old_tab, state, axis, change)

      state =
        apply_structural(state, tab_idx, new_tab, true, %{
          op: op,
          at: at,
          count: count,
          tab: tab_idx
        })

      # CT (design §3.2, B-CT-5): a row/col insert/delete on this tab shifts
      # cross-tab refs to it living in OTHER tabs' formulas (via X2's
      # `Structure.shift_cross_tab_refs/4`, keyed by the tab INDEX). Those other
      # tabs ride the SAME capture the own tab does — the inverse's 4th element.
      state = apply_cross_tab_shift(state, tab_idx, axis, change)

      {:ok, state, inverse}
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

  # Set (or clear) a tab's color — the per-sheet tab-color swatch (QL-D2/D3).
  # Stores a lowercase `#rrggbb` under the tab map's `"color"` key, sibling of
  # `name`/`cells`/`merges`/`cond_formats`; a nil/"" color DELETES the key (no
  # empty-string colors ever land in the doc). NOT a cell op — no value
  # changes, so no recompute; it flushes pending like every other structural op
  # and broadcasts a `set_tab_color` structure delta so peers repaint the tab.
  # The inverse reuses `{:structural, op_map}` — a set_tab_color back to the
  # PRIOR color (nil ⇒ the inverse CLEARS the key), self-inverting through
  # apply_one; `remap_op_tab` already permutes its `"tab"` key on
  # reorder/delete. `c` is validated `#rrggbb`-or-nil at the op boundary,
  # byte-for-byte the plugin gate's `color_errors` branch, so the session never
  # admits a color the before_save gate would 409 on (the merges precedent).
  def apply_one(%{"op" => "set_tab_color", "tab" => tab} = op, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         {:ok, color} <- validate_tab_color(Map.get(op, "color")) do
      old_tab = Sheets.get_tab(state.content, tab_idx)
      prior = Map.get(old_tab, "color")
      inverse = {:structural, %{"op" => "set_tab_color", "tab" => tab_idx, "color" => prior}}

      new_tab =
        case color do
          nil -> Map.delete(old_tab, "color")
          hex -> Map.put(old_tab, "color", hex)
        end

      {:ok,
       apply_structural(state, tab_idx, new_tab, false, %{
         op: "set_tab_color",
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
  def apply_one(
        %{"op" => "sort_range", "tab" => tab, "range" => range, "keys" => keys} = op,
        state
      ) do
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
           tab: tab_idx,
           # SF-AM3: the broadcast carries the rect sorted + the permutation
           # ACTUALLY APPLIED (old row-offset → new position) so a collaborator
           # with a selection/editor inside the rect can remap_selection its
           # coordinates instead of clobbering with stale ones.
           rect: rect,
           perm: perm,
           # SF-R×SF-W: the originating user (op's "user" stamp, nil for
           # anonymous/import) so the remap follows ONLY remote peers' rows —
           # the initiator keeps their cursor at its ADDRESS (Excel semantics:
           # when YOU sort, the selection stays put; it does not chase the data).
           by: Map.get(op, "user")
         }), inverse}
      end
    end
  end

  # Rename a tab. CROSS-TAB (CT / wave-1): because refs are NAME-based
  # (design decision 1), a rename rewrites every `OldName!`/`'Old Name'!`
  # qualifier across ALL OTHER tabs to the new name — that sweep is owned by
  # `Structure.rename_refs/3` (X2), wired here behind a `function_exported?`
  # guard so this slice compiles + gates BEFORE X2 merges (no-op until then;
  # the own-tab rename always works). The named SILENT-CORRUPTION hazard
  # (design §6): the sweep touches OTHER users' tabs, so the inverse MUST
  # capture the PRE-rewrite cells of every rewritten tab — the
  # `{:rename_restore, …}` multi-tab capture — or undo cannot restore the
  # rewritten refs. When no tab depends on this one, the capture is empty and
  # the inverse degrades to the plain `{:structural, rename}` (byte-identical
  # to the pre-CT behavior).
  def apply_one(%{"op" => "rename_tab", "tab" => tab, "name" => name}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         {:ok, name} <- validate_tab_name(name) do
      prior_name = tab_name(state.content, tab_idx)
      captured = capture_cross_tab_cells(state, tab_idx)

      inverse =
        if map_size(captured) == 0 do
          {:structural, %{"op" => "rename_tab", "tab" => tab_idx, "name" => prior_name}}
        else
          {:rename_restore, tab_idx, prior_name, captured}
        end

      {:ok, rename_apply(state, tab_idx, name, %{}), inverse}
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
        deleted_name = tab_name(state.content, tab_idx)
        changed = Map.new(old_cells, fn {addr, _cell} -> {addr, nil} end)
        content = Map.put(state.content, "tabs", List.delete_at(tabs, tab_idx))

        state =
          finalize_structural(state, content, tab_idx, changed, %{
            op: "delete_tab",
            at: nil,
            count: nil,
            tab: tab_idx
          })

        # CT (design §3.2): rewrite every `Name!` ref to the deleted tab, across
        # all OTHER tabs, to the literal `#REF!` (Excel). Guarded/no-op until
        # X2's `Structure.delete_tab_refs/2`; when live those rewrites inherit
        # the DOCUMENTED lossy-undo contract — `rename_tab` and `delete_rows`/
        # `delete_cols` capture a lossless multi-tab inverse, `delete_tab` does
        # NOT — and the delete_tab structure delta already drives a client
        # refetch.
        state =
          commit_cross_tab_content(
            state,
            state.content,
            delete_cross_tab_refs(state.content, deleted_name)
          )

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
       "set_tab_color (\"tab\"+\"color\"), " <>
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
  #   * {:structural_restore, op_map, cells, cross} — insert_* + the deleted
  #     span's captured cells AND every cell whose formula the delete's rewrite
  #     touched: `cells` (%{ref => pre-rewrite cell}) is the mutated tab, `cross`
  #     (%{other_tab_idx => %{ref => pre-rewrite cell}}) every other tab whose
  #     cross-tab refs the sweep rewrote. The inverse of a delete_*, and what
  #     makes it LOSSLESS — without the two rewrite captures undo restored the
  #     span but left the `#REF!`s standing (task-bb0b8faf5a9a2a37). A `cross`
  #     dimension cannot live in the flat `cells` map (its keys are refs, not
  #     tab indexes), hence the 4th element rather than a new shape. The 3-tuple
  #     is tolerated on read for an in-flight pre-upgrade entry.
  #   * {:tab_restore, idx, tab}               — re-insert a deleted tab
  #   * {:rename_restore, tab, name, captured} — rename `tab` back to `name`
  #     AND overlay `captured` (%{dep_tab_idx => %{ref => pre-rewrite cell}}) —
  #     the lossless multi-tab inverse of a rename that rewrote cross-tab refs
  #     (design §6). Applying it re-captures the current cells for the redo
  #     counter, so undo/redo ride the same machine.
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
  #   * {:group, entries}                       — per-gesture compound undo
  #     (QL-D4): the same-user inverses produced across ONE `apply_ops` batch
  #     (in application order), pushed as ONE stack entry so a >100-cell paste
  #     undoes as a single step and `@undo_depth` counts ENTRIES, not cells.
  #     apply_entry folds the members in REVERSE application order (undoing the
  #     batch back-to-front) and collects each produced inverse into a redo
  #     {:group, …} that replays forward. Recorded ONLY for a batch that yielded
  #     ≥2 inverses for a user; a lone inverse is pushed BARE (byte-identical to
  #     the pre-group per-op record — the single-edit regression lock).
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

  # Per-gesture batch undo (QL-D4). The GenServer accumulates the `(op,
  # inverse)` pairs a whole `apply_ops` batch produced (in application order)
  # and hands them here ONCE, instead of calling `record_undo/3` per op inside
  # the reduce. For each user, this pushes ONE stack entry: `{:group, inverses}`
  # when the batch yielded ≥2 undoable inverses for that user (so a >100-cell
  # paste undoes as a single step and `@undo_depth` counts it as one entry), or
  # the BARE single inverse when exactly 1 — byte-identical to the pre-group
  # per-op record, the single-edit regression lock. Each recorded user's redo
  # stack is cleared (mirroring `record_undo/3`'s redo-clear). Pairs with a nil
  # inverse (undo/redo themselves, no-op ops) or no valid `"user"` (imports,
  # anonymous wire calls) contribute nothing — the same filter as record_undo.
  def record_batch_undo(state, pairs) do
    pairs
    |> Enum.reduce(%{}, fn {op, inverse}, acc ->
      case undo_user(op, inverse) do
        nil -> acc
        user -> Map.update(acc, user, [inverse], &[inverse | &1])
      end
    end)
    |> Enum.reduce(state, fn {user, inverses_rev}, st ->
      entry =
        case Enum.reverse(inverses_rev) do
          [single] -> single
          inverses -> {:group, inverses}
        end

      st |> push_stack(:undo, user, entry) |> put_stack(:redo, user, [])
    end)
  end

  # A pair is undoable iff it produced a non-nil inverse AND carries a
  # non-blank "user" — the exact filter record_undo/3 applies per op.
  defp undo_user(_op, nil), do: nil

  defp undo_user(op, _inverse) do
    case Map.get(op, "user") do
      user when is_binary(user) and user != "" -> user
      _ -> nil
    end
  end

  defp push_stack(state, key, user, entry) do
    state = touch_undo_user(state, user)
    stacks = Map.fetch!(state, key)
    stack = Enum.take([entry | Map.get(stacks, user, [])], @undo_depth)
    Map.put(state, key, Map.put(stacks, user, stack))
  end

  # Recency spine for the @undo_user_cap bound: `state.undo_users` is an MRU
  # list (most-recently-touched first), created lazily on first push so the
  # key never needs to pre-exist in the state map. Every push counts as a
  # touch — own-op record, batch record, and the undo/redo cross-push in
  # `apply_history/3` — so an actively undoing user can never be the LRU
  # victim (a pure pop is not a touch, but a popped entry always re-pushes
  # its counter-inverse onto the opposite stack in the same call). Eviction
  # drops the stale users from the MRU list AND both stack maps; the
  # invariant is that every undo/redo map key appears in `undo_users`, which
  # is what bounds `map_size/1` of either map to @undo_user_cap. O(cap)
  # list work per push — negligible next to the entry building above.
  defp touch_undo_user(state, user) do
    mru = Map.get(state, :undo_users, [])

    cond do
      List.first(mru) == user ->
        state

      user in mru ->
        Map.put(state, :undo_users, [user | List.delete(mru, user)])

      length(mru) < @undo_user_cap ->
        Map.put(state, :undo_users, [user | mru])

      true ->
        {keep, evict} = Enum.split(mru, @undo_user_cap - 1)

        evict
        |> Enum.reduce(state, fn stale, st ->
          st
          |> Map.update!(:undo, &Map.delete(&1, stale))
          |> Map.update!(:redo, &Map.delete(&1, stale))
        end)
        |> Map.put(:undo_users, [user | keep])
    end
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

  # A structural_restore pins the mutated tab index AND (in its cross-tab
  # capture) every OTHER tab it restores — a tab move/delete permutes them all
  # (the #843 all-inverse-shapes remap contract), exactly as rename_restore does.
  defp remap_entry({:structural_restore, op_map, cells, cross}, fun) do
    {:structural_restore, remap_op_tab(op_map, fun), cells,
     Map.new(cross, fn {t, cells} -> {fun.(t), cells} end)}
  end

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
  # A group's absolute tab indices live inside its member entries — a tab
  # move/delete permutes each one (the #843 all-inverse-shapes remap contract;
  # a missing clause would crash undo after a reorder with a pending group).
  defp remap_entry({:group, entries}, fun),
    do: {:group, Enum.map(entries, &remap_entry(&1, fun))}

  # A rename_restore pins the renamed tab index AND every dependent-tab index in
  # its multi-tab capture — a tab move/delete permutes them all (the #843
  # all-inverse-shapes remap contract; a missing clause crashes undo after a
  # reorder with a pending rename undo).
  defp remap_entry({:rename_restore, tab, name, captured}, fun) do
    {:rename_restore, fun.(tab), name, Map.new(captured, fn {t, cells} -> {fun.(t), cells} end)}
  end

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

  # Per-gesture compound undo (QL-D4): a `{:group, entries}` holds one batch's
  # same-user inverses in APPLICATION order (op1..opN). Fold them in REVERSE
  # application order — undoing the batch back-to-front (opN..op1), exactly as N
  # sequential single undos would — and collect each member's produced counter
  # in PRODUCTION order into a redo `{:group, …}`. That order is load-bearing
  # when a batch touches the same cell twice: redo must replay FORWARD
  # (op1..opN) or it lands on the wrong intermediate value, and apply_entry
  # folds a group in reverse, so the redo group must hold the counters in
  # production order (opN's counter first) for the redo fold to apply op1's
  # counter first. The result is self-similar — a redo group's own fold rebuilds
  # the original undo group, so it survives an undo/redo/undo/redo cycle. A
  # member that no longer applies (its tab vanished under another user) halts
  # the fold and surfaces as a consumed dead entry — apply_history drops the
  # whole group and rolls back to the post-pop state, the standard dead-entry
  # contract.
  defp apply_entry({:group, entries}, state) do
    result =
      Enum.reduce_while(Enum.reverse(entries), {state, []}, fn member, {st, produced} ->
        case apply_entry(member, st) do
          {:ok, st, counter} -> {:cont, {st, [counter | produced]}}
          {:error, _code, _message} = error -> {:halt, error}
        end
      end)

    case result do
      {state, produced} -> {:ok, state, {:group, Enum.reverse(produced)}}
      {:error, _code, _message} = error -> error
    end
  end

  # Undo of a delete_rows/delete_cols: re-insert the span, then overlay the
  # captured PRE-rewrite cells BEFORE the recompute, so every dependent settles
  # from the real formulas instead of from the `#REF!` the delete wrote.
  # `captured` restores the mutated tab (deleted span + own rewritten formulas);
  # `cross` restores the OTHER tabs whose cross-tab refs the sweep rewrote.
  #
  # The restore deliberately does NOT re-run `apply_cross_tab_shift/4` for the
  # insert: the capture already holds every cell the forward sweep changed, so
  # sweeping again would shift those refs a second time.
  defp apply_entry(
         {:structural_restore, %{"op" => op, "tab" => tab, "at" => at, "count" => count},
          captured, cross},
         state
       ) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab),
         {:ok, new_tab} <- structural_shift(op, Sheets.get_tab(state.content, tab_idx), at, count) do
      new_tab = Map.update(new_tab, "cells", captured, &Map.merge(&1, captured))

      counter =
        {:structural,
         %{"op" => delete_op_for(op), "tab" => tab_idx, "at" => at, "count" => count}}

      structure = %{op: op, at: at, count: count, tab: tab_idx}

      state =
        if map_size(cross) == 0 do
          apply_structural(state, tab_idx, new_tab, true, structure)
        else
          restore_with_cross(state, tab_idx, new_tab, cross, structure)
        end

      {:ok, state, counter}
    end
  end

  # LEGACY 3-tuple — an in-flight stack entry recorded before the lossless
  # capture landed (a live session survives a code change). Carries no
  # cross-tab capture; behaves exactly as it did.
  defp apply_entry({:structural_restore, op_map, captured}, state),
    do: apply_entry({:structural_restore, op_map, captured, %{}}, state)

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
  # re-added merge carries its ORIGINAL coordinates, so after an intervening
  # row/col shift it may land where the range used to be — merge GEOMETRY,
  # unlike formula text, is not captured. The counter removes exactly what was
  # re-added, so the opposite direction inverts cleanly. Inverse of
  # unmerge_cells and the redo-counter of {:remove_merges, …}.
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
         tab: tab_idx,
         # SF-AM3/SF-D6: undo and redo frames carry their OWN correct rect +
         # perm — `perm` is the permutation this application re-applies (the
         # inverse on undo, the original on redo), so a remote viewer remaps
         # coherently in either direction.
         rect: rect,
         perm: perm
       }), counter}
    end
  end

  # Undo/redo of a rename that rewrote cross-tab refs — the lossless multi-tab
  # inverse (design §6). Rename `tab` back to `prior_name` (which re-runs the
  # guarded X2 sweep) and overlay the captured PRE-rewrite cells of every
  # dependent tab, restoring every ref the forward rename rewrote. The counter
  # re-captures the CURRENT cells at those addresses + the current name, so redo
  # re-applies exactly — undo and redo are the same machine run either way.
  defp apply_entry({:rename_restore, tab, prior_name, captured}, state) do
    with {:ok, tab_idx} <- fetch_tab(state.content, tab) do
      cur_name = tab_name(state.content, tab_idx)
      redo_captured = recapture_cells(state, captured)
      counter = {:rename_restore, tab_idx, cur_name, redo_captured}
      {:ok, rename_apply(state, tab_idx, prior_name, captured), counter}
    end
  end

  # The multi-tab arm of the restore: overlay the captured cells of every OTHER
  # tab, then settle the WHOLE document in ONE `Engine.recompute/1` (a cross-tab
  # capture exists only when a cross-tab dependency does — the CT-D4 path), and
  # broadcast the own-tab structure delta plus one cell delta per restored tab.
  # Mirrors `finalize_rename/5`, the same shape for the rename inverse.
  defp restore_with_cross(state, tab_idx, new_tab, cross, structure) do
    before = state.content

    content =
      before
      |> put_tab(tab_idx, new_tab)
      |> overlay_captured_content(cross)
      |> Engine.recompute()

    changed = diff_cells(tab_cells(before, tab_idx), tab_cells(content, tab_idx))
    state = finalize_structural(state, content, tab_idx, changed, structure)

    Enum.each(Map.keys(cross), fn dep_idx ->
      dep_changed = diff_cells(tab_cells(before, dep_idx), tab_cells(content, dep_idx))
      if map_size(dep_changed) > 0, do: broadcast_delta(state, dep_idx, dep_changed)
    end)

    state
  end

  # insert_* invert to plain deletes; delete_* invert to inserts carrying THREE
  # things the shift destroyed (task-bb0b8faf5a9a2a37):
  #
  #   1. the deleted span's cells, keyed by their original refs (`captured_span`);
  #   2. every SURVIVING own-tab cell whose formula the local rewrite changed —
  #      a dead ref collapsed to the literal `#REF!`, a partially covered range
  #      clipped (`Structure.rewritten_formula_cells/3`), keyed by its PRE-op
  #      address (the re-insert puts each survivor back exactly there);
  #   3. every OTHER tab's cell whose CROSS-TAB ref the sweep rewrote
  #      (`Structure.cross_tab_rewritten_cells/4`), as %{tab_idx => %{ref =>
  #      cell}} in the 4th element.
  #
  # (2) and (3) are what used to be "lossy by design": undo gave the span back
  # and left the `#REF!`s standing, so a delete + undo destroyed formulas.
  # Both captures are computed from the PRE-op state and are proportional to the
  # number of REWRITTEN formulas — never a tab snapshot.
  #
  # The mutated tab's own SELF-qualified refs (`ThisTab!A1`) come out of the
  # cross-tab sweep, not the local pass, so its entry is popped off (3) and
  # merged into (2): same tab, same PRE-op address space (the sweep keys on the
  # tab NAME, so it is address independent and the two passes commute).
  defp shift_inverse(op, tab_idx, _old_tab, _state, _axis, {_kind, at, count})
       when op in ["insert_rows", "insert_cols"] do
    {:structural, %{"op" => delete_op_for(op), "tab" => tab_idx, "at" => at, "count" => count}}
  end

  defp shift_inverse(op, tab_idx, old_tab, state, axis, {_kind, at, count} = change) do
    insert_op = if op == "delete_rows", do: "insert_rows", else: "insert_cols"

    tabs = Map.get(state.content, "tabs") || []
    swept = Structure.cross_tab_rewritten_cells(tabs, tab_idx, axis, change)
    {own_swept, cross} = Map.pop(swept, tab_idx, %{})

    captured =
      old_tab
      |> captured_span(axis, at, count)
      |> Map.merge(Structure.rewritten_formula_cells(old_tab, axis, change))
      |> Map.merge(own_swept)

    {:structural_restore, %{"op" => insert_op, "tab" => tab_idx, "at" => at, "count" => count},
     captured, cross}
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

  # set_tab_color's `"color"`: a `#rrggbb` hex (case-insensitive in, normalized
  # lowercase) or nil/"" to CLEAR (QL-D2). Reuses `CondFormat.sanitize_bg/1` —
  # the ONE `#rrggbb` sanitizer (validates AND lowercases, rejects a trailing
  # newline) — so no fourth copy is written (the parked-hygiene rule) and the
  # op boundary matches the gate's `color_errors` byte-for-byte.
  defp validate_tab_color(color) when color in [nil, ""], do: {:ok, nil}

  defp validate_tab_color(color) do
    case CondFormat.sanitize_bg(color) do
      nil ->
        {:error, "invalid_color",
         "\"color\" must be a #rrggbb hex string or null, got #{inspect(color)}"}

      hex ->
        {:ok, hex}
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
  # SF-1 caveat 4: the `$`-anchored regex accepted a trailing "\n" (`$` matches
  # before a final newline); `CondFormat.valid_bg?/1` is `\z`-anchored and the
  # single bg owner since #1090 — reuse it, never write a fourth copy.
  defp valid_style_pair?("bg", v), do: CondFormat.valid_bg?(v)
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
      #
      # CT (design §3.2, B-CT-3): an edit to tab j also dirties every tab that
      # references j by name (`mark_dependents_dirty/3`, via the precedent
      # index). flush_pending then whole-doc-recomputes and broadcasts each
      # dependent's delta. A zero-cross-tab document adds no dependents, so the
      # dirty set — and the per-tab fast path — stays byte-identical.
      dirty = Map.put_new(state.dirty_tabs, tab_idx, old_cells)
      %{state | dirty_tabs: mark_dependents_dirty(state, tab_idx, dirty)}
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
    # Refresh the precedent index from the batch's CURRENT formulas BEFORE
    # choosing the path, so a cross-tab formula ADDED earlier in this batch
    # still routes to the whole-doc recompute. Recompute changes only values,
    # never formula text, so this index also holds for the next batch. Cheap: a
    # formula-text scan over the (few) formula cells.
    state = %{state | cross_tab_index: build_cross_tab_index(state.content)}

    if whole_doc_recompute?(state) do
      flush_whole_doc(state)
    else
      flush_per_tab(state)
    end
  end

  # The per-tab fast path (byte-identical to the pre-CT flush): recompute each
  # dirty formula-bearing tab once, diff, broadcast. Taken whenever no dirty tab
  # participates in a cross-tab dependency — the overwhelmingly common case.
  defp flush_per_tab(state) do
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

  # CT-D4 — whole-document recompute: when any dirty tab participates in a
  # cross-tab dependency, ONE unified `Engine.recompute/1` over the whole
  # content resolves cross-tab reads AND cross-tab cycles (a `{tab,col,row}`
  # Kahn graph, X1), then one per-tab delta is broadcast for EACH dirty tab
  # (the touched tab plus every dependent `mark_dependents_dirty/3` added).
  # `Engine.recompute/1` is the SAME unified path the persist pipeline already
  # calls — before X1 lands it just leaves cross-tab refs `#REF!`; this slice
  # wires the SESSION propagation X1's eval then lights up.
  defp flush_whole_doc(state) do
    recomputed = Engine.recompute(state.content)
    tabs = Map.get(recomputed, "tabs") || []
    st = %{state | content: recomputed, dirty_tabs: %{}}

    Enum.each(state.dirty_tabs, fn {tab_idx, pre_cells} ->
      new_cells = Map.get(Enum.at(tabs, tab_idx) || %{}, "cells") || %{}
      broadcast_delta(st, tab_idx, diff_cells(pre_cells, new_cells))
    end)

    st
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
        formula_counts: count_formulas(content),
        # A structural op can add/remove/reorder tabs or rewrite formulas — any
        # of which shifts the tab-index-keyed precedent index. Rebuild it (CT).
        cross_tab_index: build_cross_tab_index(content)
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

  # ── cross-tab dependency (CT / wave-1) ───────────────────────────────────
  #
  # X1 generalizes a formula ref from `{col,row}` to `{tab,col,row}`: a formula
  # in one tab may read `Sheet2!A1`, so editing Sheet2 must recompute — and
  # re-broadcast — the DEPENDENT tab. That BREAKS this module's founding
  # assumption "formulas are tab-local, other tabs can't change".
  #
  # The session keeps a tab-granular PRECEDENT INDEX in state:
  #   cross_tab_index :: %{target_tab_idx => MapSet(dependent_tab_idx)}
  # "tab d depends on tab t" iff a formula in d references t BY NAME (d != t; a
  # same-tab self-name-ref like `Sheet1!A1` inside Sheet1 stays on the per-tab
  # fast path). Rebuilt cheaply — a formula-text scan — whenever formulas or the
  # tab layout change (every flush, every structural finalize). It is a pure
  # session-side scan with NO dependency on the engine, so propagation is
  # correct even before X1 merges (X1 makes the REF resolve; this makes the
  # SESSION dirty + broadcast the dependent).

  @doc """
  Build the cross-tab precedent index for `content`:
  `%{target_tab_idx => MapSet(dependent_tab_idx)}`. Public — the session seeds
  it in `init/1`; the op machinery rebuilds it after formula/layout changes.
  Self-name-refs (`d == t`) are excluded so a same-tab qualified ref keeps the
  per-tab fast path.
  """
  def build_cross_tab_index(content) do
    tabs = Map.get(content, "tabs") || []
    name_index = tab_name_index(tabs)

    for {tab, dep_idx} <- Enum.with_index(tabs),
        is_map(tab),
        {_addr, cell} <- Map.get(tab, "cells") || %{},
        is_map(cell),
        f = Map.get(cell, "f"),
        is_binary(f),
        target_name <- formula_tab_refs(f),
        target_idx = Map.get(name_index, String.downcase(target_name)),
        is_integer(target_idx),
        target_idx != dep_idx,
        reduce: %{} do
      acc -> Map.update(acc, target_idx, MapSet.new([dep_idx]), &MapSet.put(&1, dep_idx))
    end
  end

  # name (downcased) => index. Excel tab names are unique + case-insensitive for
  # lookup; a stray duplicate resolves to the last-listed tab (harmless — the
  # gate keeps names unique).
  defp tab_name_index(tabs) do
    for {tab, idx} <- Enum.with_index(tabs), is_map(tab), into: %{} do
      {String.downcase(Map.get(tab, "name") || "Sheet #{idx + 1}"), idx}
    end
  end

  # Every tab-qualifier NAME in a formula — the `Name!` / `'Quoted Name'!`
  # prefix of a cross-tab ref. `!` has no other meaning in the grammar (the
  # pre-X1 lexer rejects it), so every `!` here is a cross-tab qualifier. A
  # quoted name un-escapes `''` → `'` (Excel convention). Regex.scan returns a
  # 3-group list for a bare match (`[full, "", bare]`) and a 2-group list for a
  # quoted one (`[full, quoted]`) — both handled below.
  @tab_ref_regex ~r/(?:'((?:[^']|'')*)'|([A-Za-z_][A-Za-z0-9_]*))!/
  defp formula_tab_refs(f) do
    # Cheap prefilter (this runs per formula on every flush — the hot path): a
    # cross-tab qualifier ALWAYS contains `!`, so a formula with no `!` — the
    # overwhelming majority — skips the regex entirely. `:binary.match/2` is the
    # fastest substring test; semantically identical to running the scan.
    if :binary.match(f, "!") == :nomatch do
      []
    else
      formula_tab_refs_scan(f)
    end
  end

  defp formula_tab_refs_scan(f) do
    @tab_ref_regex
    |> Regex.scan(f)
    |> Enum.map(fn
      [_full, "", bare] -> bare
      [_full, quoted, _bare] -> String.replace(quoted, "''", "'")
      [_full, quoted] -> String.replace(quoted, "''", "'")
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp cross_tab_dependents(state, tab_idx) do
    case Map.get(state.cross_tab_index, tab_idx) do
      nil -> []
      set -> MapSet.to_list(set)
    end
  end

  # On a deferred cell op to `tab_idx`, add each dependent tab to the dirty set,
  # capturing its pre-batch cells (Map.put_new keeps the earliest). The
  # dependent's cells are untouched until flush, so the current cells ARE the
  # pre-batch cells.
  defp mark_dependents_dirty(state, tab_idx, dirty) do
    Enum.reduce(cross_tab_dependents(state, tab_idx), dirty, fn dep_idx, acc ->
      Map.put_new(acc, dep_idx, tab_cells(state.content, dep_idx))
    end)
  end

  # Whole-doc recompute is required iff a dirty tab either has dependents (its
  # edit changes another tab) or is itself a dependent (its formulas read
  # another tab). Both are captured by "the dirty set intersects the union of
  # every target and dependent index". Empty index ⇒ never (fast path).
  defp whole_doc_recompute?(state) do
    participants = cross_tab_participants(state.cross_tab_index)

    participants != MapSet.new() and
      Enum.any?(Map.keys(state.dirty_tabs), &MapSet.member?(participants, &1))
  end

  defp cross_tab_participants(index) do
    Enum.reduce(index, MapSet.new(), fn {target, deps}, acc ->
      acc |> MapSet.put(target) |> MapSet.union(deps)
    end)
  end

  # The multi-tab undo capture: for every tab that depends on `tab_idx`, the
  # SUBSET of its cells whose formula references `tab_idx` by name — surgical,
  # not the whole tab, so undo never clobbers unrelated edits a collaborator
  # made to the dependent tab between the rename and the undo. Empty when no tab
  # depends on `tab_idx`.
  defp capture_cross_tab_cells(state, tab_idx) do
    name_index = tab_name_index(Map.get(state.content, "tabs") || [])

    for dep_idx <- cross_tab_dependents(state, tab_idx),
        cells = cross_tab_cells(tab_cells(state.content, dep_idx), tab_idx, name_index),
        map_size(cells) > 0,
        into: %{} do
      {dep_idx, cells}
    end
  end

  defp cross_tab_cells(cells, target_idx, name_index) do
    for {ref, cell} <- cells,
        is_map(cell),
        f = Map.get(cell, "f"),
        is_binary(f),
        references_tab?(f, target_idx, name_index),
        into: %{} do
      {ref, cell}
    end
  end

  defp references_tab?(f, target_idx, name_index) do
    Enum.any?(formula_tab_refs(f), &(Map.get(name_index, String.downcase(&1)) == target_idx))
  end

  # Re-capture the CURRENT cells at the addresses a prior multi-tab capture
  # holds — the redo counter for a `{:rename_restore, …}` undo.
  defp recapture_cells(state, captured) do
    for {dep_idx, cells} <- captured, into: %{} do
      {dep_idx, Map.take(tab_cells(state.content, dep_idx), Map.keys(cells))}
    end
  end

  # Rename tab `tab_idx` to `new_name`: rename the own tab, run X2's guarded
  # cross-tab sweep over OTHER tabs, overlay any `overlay` captured cells (the
  # undo-restore path; empty on the forward op), then finalize + broadcast the
  # rename structure delta plus one cell delta per changed dependent tab. Shared
  # by the forward `rename_tab` op and the `{:rename_restore, …}` inverse.
  defp rename_apply(state, tab_idx, new_name, overlay) do
    prior_name = tab_name(state.content, tab_idx)
    before = state.content
    renamed = Map.put(Sheets.get_tab(before, tab_idx) || %{}, "name", new_name)

    after_content =
      before
      |> put_tab(tab_idx, renamed)
      |> rename_cross_tab_refs(prior_name, new_name)
      |> overlay_captured_content(overlay)

    dep_idxs = Enum.uniq(cross_tab_dependents(state, tab_idx) ++ Map.keys(overlay))
    finalize_rename(state, before, after_content, tab_idx, dep_idxs)
  end

  defp finalize_rename(state, before, after_content, tab_idx, dep_idxs) do
    state = %{
      state
      | content: after_content,
        rev: state.rev + 1,
        dirty?: true,
        ops_since_flush: state.ops_since_flush + 1,
        nonempty: count_nonempty(after_content),
        formula_counts: count_formulas(after_content),
        cross_tab_index: build_cross_tab_index(after_content)
    }

    broadcast_delta(state, tab_idx, %{}, %{op: "rename_tab", at: nil, count: nil, tab: tab_idx})

    Enum.each(dep_idxs, fn dep_idx ->
      changed = diff_cells(tab_cells(before, dep_idx), tab_cells(after_content, dep_idx))
      if map_size(changed) > 0, do: broadcast_delta(state, dep_idx, changed)
    end)

    state
  end

  defp overlay_captured_content(content, overlay) when map_size(overlay) == 0, do: content

  defp overlay_captured_content(content, overlay) do
    Enum.reduce(overlay, content, fn {dep_idx, cells}, acc ->
      dep_tab = Sheets.get_tab(acc, dep_idx) || %{}
      merged = Map.merge(Map.get(dep_tab, "cells") || %{}, cells)
      put_tab(acc, dep_idx, Map.put(dep_tab, "cells", merged))
    end)
  end

  # ── X2 Structure integration seams (guarded until X2 merges) ─────────────
  #
  # Cross-tab formula-text rewrites are owned by
  # `Barkpark.Plugins.Sheets.Structure` (X2) under the single-writer rule — this
  # module never rewrites formula text itself. Each call is guarded on
  # `function_exported?/3` so X3 compiles + gates on origin/main BEFORE X2
  # lands; every seam is a NO-OP until then (own-tab work always happens; only
  # the cross-tab ref rewrite waits on X2). The ASSUMED contracts below are the
  # integration points the merging agent rebases if a signature differs.

  # `Structure.rename_refs(tabs, old_name, new_name) :: tabs` (X2) — rewrite
  # every `OldName!`/`'Old Name'!` qualifier across ALL tabs to the new name.
  # X2 operates on the `tabs` list (its module boundary); this session adapter
  # peels tabs off content and puts the rewritten list back (integration seam).
  defp rename_cross_tab_refs(content, old_name, new_name) do
    if old_name != new_name and function_exported?(Structure, :rename_refs, 3) do
      tabs = Map.get(content, "tabs") || []
      Map.put(content, "tabs", apply(Structure, :rename_refs, [tabs, old_name, new_name]))
    else
      content
    end
  end

  # `Structure.delete_tab_refs(tabs, deleted_name) :: tabs` (X2) — rewrite every
  # ref to the deleted tab, across all tabs, to the literal `#REF!`. Same
  # content↔tabs adapter as rename above.
  defp delete_cross_tab_refs(content, deleted_name) do
    if function_exported?(Structure, :delete_tab_refs, 2) do
      tabs = Map.get(content, "tabs") || []
      Map.put(content, "tabs", apply(Structure, :delete_tab_refs, [tabs, deleted_name]))
    else
      content
    end
  end

  # `Structure.shift_cross_tab_refs(tabs, target_index, axis, {kind, at, count})
  # :: tabs` (X2) — shift cross-tab refs to the tab at `target_index` (row/col
  # insert/delete) living in OTHER tabs' formulas; a deleted axis → `#REF!`.
  # Session adapter: peel tabs off content, call X2 with the tab INDEX + change
  # tuple, put the rewritten list back (the X2 seam — content↔tabs + /4 shape).
  defp apply_cross_tab_shift(state, target_index, axis, {_kind, _at, _count} = change) do
    if function_exported?(Structure, :shift_cross_tab_refs, 4) do
      before = state.content
      tabs = Map.get(before, "tabs") || []
      new_tabs = apply(Structure, :shift_cross_tab_refs, [tabs, target_index, axis, change])
      commit_cross_tab_content(state, before, Map.put(before, "tabs", new_tabs))
    else
      state
    end
  end

  # Commit an X2 cross-tab content transform: when it changed anything, swap the
  # content in, recount the caches + precedent index, and broadcast one per-tab
  # cell delta for every tab whose cells moved. Does NOT bump rev — the primary
  # op already did. A no-op transform (the guarded seams today) returns the
  # state untouched, so existing behavior is byte-identical.
  defp commit_cross_tab_content(state, before, after_content) when before == after_content,
    do: state

  defp commit_cross_tab_content(state, before, after_content) do
    state = %{
      state
      | content: after_content,
        nonempty: count_nonempty(after_content),
        formula_counts: count_formulas(after_content),
        cross_tab_index: build_cross_tab_index(after_content)
    }

    for {tab, idx} <- Enum.with_index(Map.get(after_content, "tabs") || []) do
      changed = diff_cells(tab_cells(before, idx), Map.get(tab, "cells") || %{})
      if map_size(changed) > 0, do: broadcast_delta(state, idx, changed)
    end

    state
  end

  defp tab_cells(content, idx), do: Map.get(Sheets.get_tab(content, idx) || %{}, "cells") || %{}

  defp tab_name(content, idx),
    do: Map.get(Sheets.get_tab(content, idx) || %{}, "name") || "Sheet #{idx + 1}"

  defp put_tab(content, idx, tab) do
    tabs = Map.get(content, "tabs") || []
    Map.put(content, "tabs", List.replace_at(tabs, idx, tab))
  end

  # ── counters ─────────────────────────────────────────────────────────────
  #
  # Shared by the GenServer's init/1 (initial seed) and the structural ops
  # (full recount). The per-cell flags are the import controller's
  # non-empty predicate: a usable "v" or a formula.

  def nonempty_flag(nil), do: 0

  def nonempty_flag(cell) do
    cond do
      # An engine-owned spilled cell (a NON-anchor cell of a dynamic-array
      # spill) is materialized array OUTPUT, not user content: it carries the
      # anchor's `"spill"` marker but no formula of its own. It must count 0 so
      # a spill never (a) consumes the session's cell-cap budget as N user
      # cells, (b) inflates the persisted non-empty guard, or (c) reads as
      # occupancy that would spuriously block a re-spill. The ANCHOR carries a
      # `"spill"` marker too (pointing at itself) but ALSO carries an `"f"` — it
      # is user-authored and still counts 1 via the second clause. Design §3.3
      # (B-SP-5). This is THE seam: every counting path (`count_nonempty`,
      # `tab_nonempty`, and the incremental cell-cap arithmetic in
      # `apply_cell`/`check_cap`) inherits the exclusion through this one
      # predicate — a spill is invisible to user-content accounting everywhere.
      spilled_output?(cell) -> 0
      Map.get(cell, "v") not in [nil, ""] or is_binary(Map.get(cell, "f")) -> 1
      true -> 0
    end
  end

  # An engine-materialized, anchor-owned spilled cell: it carries a `"spill"`
  # anchor-ref string AND has no formula of its own. The anchor is deliberately
  # NOT matched here (it has an `"f"`), so only the distributed (non-anchor)
  # output cells return true. Locked to S1's marker contract: spilled cells are
  # `%{"v" => …, "spill" => anchorRef}` with no `"f"`; the anchor keeps its
  # `"f"` (and its own `"spill"`/`"spill_dims"`).
  defp spilled_output?(cell) do
    is_binary(Map.get(cell, "spill")) and not is_binary(Map.get(cell, "f"))
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
