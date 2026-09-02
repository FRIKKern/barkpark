defmodule BarkparkWeb.Studio.SheetGrid.Ops do
  @moduledoc """
  Commit + persistence plumbing for `BarkparkWeb.Studio.SheetGrid` — every
  edit becomes a `Session.apply_ops/3` call (no HTTP hop) and the component
  NEVER applies an op to its own assigns; the session broadcasts the delta
  back through `apply_delta/2`. Read-only hosts drop every mutation in
  `send_ops/2` (the server-side half of stripping the affordances), ops are
  stamped with the studio identity's `user_id` for per-user undo, and big
  batches chunk to the session's per-call bound. Presence meta merges ride
  `push_presence/2`. Each function takes `socket` as the explicit first arg.
  """

  import Phoenix.Component, only: [assign: 2]

  alias Barkpark.Plugins.Sheets.Core, as: Sheets
  alias Barkpark.Plugins.Sheets.Session
  alias BarkparkWeb.Presence
  alias BarkparkWeb.Studio.SheetGrid.{Cells, GridData}

  # ── delta application ───────────────────────────────────────────────────

  def apply_delta(socket, %{rev: rev} = payload) do
    epoch = Map.get(payload, :epoch)

    # First frame from any incarnation: adopt its epoch before judging revs.
    socket =
      if epoch != nil and socket.assigns.epoch == nil,
        do: assign(socket, epoch: epoch),
        else: socket

    cond do
      # A different session incarnation restarted the rev counter — every
      # local rev/gap assumption is void. Without this, a client at rev N
      # silently drops the new incarnation's frames 1..N and then MERGES
      # frame N+1 onto content missing 1..N: permanent grid divergence.
      epoch != nil and socket.assigns.epoch != epoch ->
        socket |> assign(epoch: epoch) |> refetch(rev)

      # Stale or duplicate frame (our own op's echo after a refetch).
      rev <= socket.assigns.rev ->
        socket

      # Structural ops re-key widths/heights/merges/frozen bands beyond the
      # changed-cells map; a rev gap means a missed frame. Both refetch. The
      # structure map (nil on a pure rev-gap) drives the @tab remap below.
      Map.has_key?(payload, :structure) or
          (socket.assigns.rev > 0 and rev > socket.assigns.rev + 1) ->
        refetch(socket, rev, Map.get(payload, :structure))

      true ->
        merge_changed(socket, payload)
    end
  end

  defp merge_changed(socket, %{rev: rev, tab: tab_idx, changed: changed}) do
    content = socket.assigns.content
    tabs = Map.get(content, "tabs") || []

    case Enum.at(tabs, tab_idx) do
      nil ->
        refetch(socket, rev)

      tab ->
        cells =
          Enum.reduce(changed, Map.get(tab, "cells") || %{}, fn
            {addr, nil}, acc -> Map.delete(acc, addr)
            {addr, cell}, acc -> Map.put(acc, addr, cell)
          end)

        tabs = List.replace_at(tabs, tab_idx, Map.put(tab, "cells", cells))
        assign(socket, content: Map.put(content, "tabs", tabs), rev: rev)
    end
  end

  defp refetch(socket, rev), do: refetch(socket, rev, nil)

  # A tab-REORDERING structural op (move_tab / duplicate_tab / delete_tab)
  # re-indexes the tab list under this viewer. Without remapping @tab the grid
  # silently swaps to whatever tab now sits at the OLD index — already true for
  # a remote delete_tab today, and every reorder/insert makes it worse. Remap
  # @tab by the SAME permutation the op applied, BEFORE the clamp; the clamp
  # stays as the safety net (a shrink past the end, or a nil/unknown structure).
  #
  # Contract with the session's `structure` delta (Sheets.Session ops.ex):
  #   move_tab      → %{op: "move_tab", from: i, to: j}
  #   duplicate_tab → %{op: "duplicate_tab", at: i}   (copy inserted at i+1)
  #   delete_tab    → %{op: "delete_tab", tab: i}      (already emitted)
  # Every non-reordering structural op (add_tab appends; rename/merge/resize/
  # frozen/row-col edit in place) leaves the order intact → @tab is untouched.
  # move_tab/duplicate_tab wire ops + their structure keys land with the tab-ops
  # slice; a shape drift here degrades to the clamp, never a crash.
  defp refetch(socket, rev, structure) do
    socket =
      cond do
        # LIVENESS axis: a host not entitled to draft bytes NEVER peeks — the
        # session is draft-backed. This is unreachable once those deltas no-op
        # (sheet_grid.ex update/2), but sealed anyway: fail closed, every read
        # path independently. `[]` access + `!=` so a socket that predates the
        # assign reads as NOT live.
        socket.assigns[:live_session] != true ->
          assign(socket, rev: rev)

        true ->
          case Session.peek(
                 socket.assigns.slug,
                 socket.assigns.dataset,
                 GridData.session_workspace_id(socket)
               ) do
            {:ok, content} -> assign(socket, content: content, rev: rev)
            {:error, :no_session} -> assign(socket, rev: rev)
          end
      end

    remapped = remap_tab(socket.assigns.tab, structure)
    clamped = min(remapped, max(length(GridData.tabs(socket)) - 1, 0))

    socket
    |> assign(tab: clamped)
    |> clear_editing_if_clamped(clamped, remapped)
    |> remap_selection(structure)
    |> refresh_find_hits()
  end

  # When the tab CLAMP OVERRIDES the remapped intention (clamped != remapped —
  # the tab list shrank UNDER this viewer, so remap_tab pointed past the new end
  # and the clamp pulled it back onto a DIFFERENT tab; this also covers the
  # nil/degenerate structure of a pure rev-gap / epoch refetch onto a shorter
  # session), the viewer is forcibly shown different content. An edit-in-progress
  # on the tab they were moved OFF is now stale — its next commit would write the
  # draft onto the WRONG tab's cell. Clear it, mirroring the active_deleted? clear
  # above (assign editing: nil + notice + push_presence). When remap_tab FOLLOWED
  # its logical tab (clamped == remapped — move_tab / duplicate_tab / delete-shift
  # keep the SAME content under the viewer) the edit stays valid: NO clear. That
  # equality IS the guard against over-clearing a still-valid edit.
  #
  # Known narrower sibling, named + parked for the next tab-ops owner (QR-D2):
  # delete_tab of the ACTIVE tab where the index STAYS in range shows the
  # successor tab's content at the same index WITHOUT tripping the clamp —
  # remap_tab falls through (tab == i, no shift) so clamped == remapped and this
  # guard misses it. No fix here; it needs its own remap_tab clause.
  defp clear_editing_if_clamped(socket, clamped, remapped) when clamped != remapped do
    if socket.assigns.editing != nil do
      socket
      |> assign(
        editing: nil,
        notice: "the tab you were editing was removed by a collaborator"
      )
      |> push_presence(%{editing: nil})
    else
      socket
    end
  end

  defp clear_editing_if_clamped(socket, _clamped, _remapped), do: socket

  # A remote row/col shift on the viewer's CURRENT tab moves the CONTENT under
  # every held coordinate — {active, anchor} (and the open editor, which
  # targets `active`) must shift by the SAME at/count offset Structure applied,
  # or the next commit writes the OLD coordinate and silently clobbers the
  # shifted-in neighbour (the two-session clobber: B edits A3, A inserts row 1,
  # B's commit lands on the cell that is now A3 — old A2). When the edited
  # row/col was DELETED there is no coordinate to follow: close the editor with
  # a notice — NEVER silently retarget the draft onto deleted coordinates.
  # A shift on ANOTHER tab never touches this viewer's coordinates; the tab
  # clamp above stays the safety net for every unknown/degenerate shape.
  defp remap_selection(socket, %{op: op, at: at, count: count, tab: tab})
       when op in ["insert_rows", "delete_rows", "insert_cols", "delete_cols"] and
              is_integer(at) and is_integer(count) and count > 0 do
    if tab == socket.assigns.tab do
      {active, active_deleted?} =
        case shift_pos(socket.assigns.active, op, at, count) do
          {:ok, pos} -> {pos, false}
          :deleted -> {land_after_delete(socket.assigns.active, op, at), true}
        end

      anchor =
        case socket.assigns.anchor do
          nil ->
            nil

          pos ->
            case shift_pos(pos, op, at, count) do
              {:ok, shifted} -> shifted
              :deleted -> land_after_delete(pos, op, at)
            end
        end

      socket =
        socket
        |> assign(active: active, anchor: anchor)
        |> remap_filters(op, at, count)

      if active_deleted? and socket.assigns.editing != nil do
        socket
        |> assign(
          editing: nil,
          notice:
            "the #{if op == "delete_rows", do: "row", else: "column"} you were editing was deleted by a collaborator"
        )
        |> push_presence(%{editing: nil})
      else
        socket
      end
    else
      socket
    end
  end

  # A remote sort_range on the viewer's CURRENT tab moves whole rows WITHIN the
  # sorted rect (SF-AM3). A held {c, r} inside the rect follows its row: the
  # perm maps old row-OFFSET (r - r1) → new position, so new_r = r1 + perm[off]
  # (Structure.sort_rows/3 doc). Cells moved VERBATIM — the open editor targets
  # `active`, so it follows its remapped cell and its draft still targets the
  # same content (no editor close, no notice: a sort deletes nothing, unlike a
  # delete_rows/cols). Positions outside the rect and other-tab sorts are
  # untouched. Malformed/missing rect|perm (older peer, shape drift) falls
  # through to the catch-all → today's no-remap, never a crash.
  defp remap_selection(
         socket,
         %{op: "sort_range", tab: tab, rect: {c1, r1, c2, r2}, perm: perm} = s
       )
       when is_list(perm) do
    # SF-R×SF-W: the row-follow remap is for REMOTE peers only. The originator
    # of the sort (`by` == this viewer's user_id) keeps their cursor at its
    # ADDRESS — SF-W's sort-column/sort-selection already set the selection
    # (column-top anchor) BEFORE dispatch, and Excel semantics say the initiator's
    # cursor stays put, it does not chase the data. A missing/blank `by` (the
    # unit-remap payloads, anonymous/import sorts) is treated as remote → remap.
    cond do
      tab != socket.assigns.tab ->
        socket

      is_binary(Map.get(s, :by)) and Map.get(s, :by) == socket.assigns[:user_id] ->
        socket

      true ->
        active = sort_pos(socket.assigns.active, c1, r1, c2, r2, perm)

        anchor =
          case socket.assigns.anchor do
            nil -> nil
            pos -> sort_pos(pos, c1, r1, c2, r2, perm)
          end

        assign(socket, active: active, anchor: anchor)
    end
  end

  defp remap_selection(socket, _structure), do: socket

  # Follow one {c, r} through a row permutation over the rect. Inside the rect,
  # the row moves by perm[r - r1]; a defensive out-of-range perm index (shape
  # drift) leaves the cell put. Outside the rect: untouched.
  defp sort_pos({c, r} = pos, c1, r1, c2, r2, perm)
       when c >= c1 and c <= c2 and r >= r1 and r <= r2 do
    case Enum.at(perm, r - r1) do
      new_off when is_integer(new_off) -> {c, r1 + new_off}
      _ -> pos
    end
  end

  defp sort_pos(pos, _c1, _r1, _c2, _r2, _perm), do: pos

  # A remote COLUMN insert/delete on the viewer's current tab shifts the
  # per-viewer filter keys (SF-B `filters` is `%{1-based-col => criterion}`) and
  # an open funnel panel's column so a criterion keeps following its data. On
  # insert, keys >= at shift +count; on delete, keys inside the deleted band
  # (at..at+count-1) DROP their criterion and keys >= at+count shift -count — the
  # same pivot arithmetic as shift_pos for columns. `visible_rows` re-derives for
  # free via update/2's derive_grid after apply_delta. Row ops leave the
  # column-keyed filters untouched.
  defp remap_filters(socket, "insert_cols", at, count) do
    filters =
      Map.new(socket.assigns.filters, fn {col, crit} ->
        {if(col >= at, do: col + count, else: col), crit}
      end)

    assign(socket,
      filters: filters,
      filter_panel: shift_filter_panel(socket.assigns.filter_panel, at, count)
    )
  end

  defp remap_filters(socket, "delete_cols", at, count) do
    filters =
      for {col, crit} <- socket.assigns.filters,
          col < at or col >= at + count,
          into: %{} do
        {if(col >= at + count, do: col - count, else: col), crit}
      end

    assign(socket,
      filters: filters,
      filter_panel: clip_filter_panel(socket.assigns.filter_panel, at, count)
    )
  end

  # Row ops never touch column-keyed filters.
  defp remap_filters(socket, _op, _at, _count), do: socket

  # An open funnel panel's "col" (1-based) shifts like a filter key on a column
  # insert; nil/keyless panels pass through unchanged.
  defp shift_filter_panel(%{"col" => col} = panel, at, count) when is_integer(col) and col >= at,
    do: Map.put(panel, "col", col + count)

  defp shift_filter_panel(panel, _at, _count), do: panel

  # On a column delete: a panel open on a deleted column CLOSES (nil); one to the
  # right of the band shifts -count; anything else passes through.
  defp clip_filter_panel(%{"col" => col}, at, count)
       when is_integer(col) and col >= at and col < at + count,
       do: nil

  defp clip_filter_panel(%{"col" => col} = panel, at, count)
       when is_integer(col) and col >= at + count,
       do: Map.put(panel, "col", col - count)

  defp clip_filter_panel(panel, _at, _count), do: panel

  # Shift one {c, r} by a row/col structural op: at/after the pivot follows the
  # content (+count on insert, -count past a delete); inside a deleted span
  # there is nothing to follow — :deleted, the caller decides. Before the
  # pivot (and any unknown op) the coordinate is untouched.
  defp shift_pos({c, r}, "insert_rows", at, count) when r >= at, do: {:ok, {c, r + count}}

  defp shift_pos({c, r}, "insert_cols", at, count) when c >= at, do: {:ok, {c + count, r}}

  defp shift_pos({c, r}, "delete_rows", at, count) do
    cond do
      r >= at + count -> {:ok, {c, r - count}}
      r >= at -> :deleted
      true -> {:ok, {c, r}}
    end
  end

  defp shift_pos({c, r}, "delete_cols", at, count) do
    cond do
      c >= at + count -> {:ok, {c - count, r}}
      c >= at -> :deleted
      true -> {:ok, {c, r}}
    end
  end

  defp shift_pos(pos, _op, _at, _count), do: {:ok, pos}

  # A deleted coordinate collapses onto the delete pivot (the cell that shifted
  # into its place) — a plain SELECTION landing there is Excel's behavior; an
  # open EDITOR never silently follows it (the caller closes it instead).
  defp land_after_delete({c, _r}, "delete_rows", at), do: {c, max(at, 1)}
  defp land_after_delete({_c, r}, "delete_cols", at), do: {max(at, 1), r}

  # Find hits are {c, r} keyed to the PREVIOUS content — after any refetch the
  # cells under them may have shifted wholesale, so the highlight would paint
  # the wrong cells. Re-run the match scan over the refetched current tab
  # (same scan `run_find` does); a blank/absent query clears the set.
  defp refresh_find_hits(socket) do
    case socket.assigns[:find_query] do
      q when is_binary(q) ->
        if String.trim(q) == "" do
          assign(socket, find_hits: MapSet.new())
        else
          cells = Map.get(GridData.current_tab(socket), "cells") || %{}
          assign(socket, find_hits: MapSet.new(Cells.find_matches(cells, q)))
        end

      _ ->
        assign(socket, find_hits: MapSet.new())
    end
  end

  # @tab follows its logical tab across a reorder. duplicate_tab deliberately
  # keeps the viewer on the SOURCE tab (auto-switch to the copy is a later UX
  # call). delete_tab of the ACTIVE tab (tab == i) falls through to the clamp,
  # preserving the prior behavior.
  defp remap_tab(tab, %{op: "move_tab", from: from, to: to})
       when is_integer(from) and is_integer(to) do
    cond do
      tab == from -> to
      from < to and tab > from and tab <= to -> tab - 1
      from > to and tab >= to and tab < from -> tab + 1
      true -> tab
    end
  end

  defp remap_tab(tab, %{op: "duplicate_tab", at: at})
       when is_integer(at) and tab >= at + 1,
       do: tab + 1

  defp remap_tab(tab, %{op: "delete_tab", tab: i}) when is_integer(i) and tab > i, do: tab - 1

  defp remap_tab(tab, _structure), do: tab

  # ── ops plumbing ─────────────────────────────────────────────────────────

  def commit(socket, pos, value) do
    ref = Sheets.format_ref(pos)
    tab = socket.assigns.tab

    op =
      if String.trim(value) == "" do
        %{"op" => "clear_cell", "tab" => tab, "ref" => ref}
      else
        %{"op" => "set_cell", "tab" => tab, "ref" => ref, "raw" => parse_raw(value)}
      end

    send_ops(socket, [op])
  end

  # All mutations ride Session.apply_ops — the session recomputes,
  # broadcasts the delta (which updates this and every other client) and
  # debounce-persists. The component never mutates `content` here. Ops are
  # stamped with the studio identity's user_id so the session records
  # per-user undo stacks. A host without `write_capable` (the public reader,
  # and any Studio principal `Caps` denies write) drops EVERY mutation here —
  # the server-side half of stripping the affordances.
  #
  # The session refuses batches over its per-call bound (batch_too_large) —
  # a big TSV paste or clear-selection can exceed it, so the batch chunks
  # here; the session's mailbox serializes the chunks back-to-back and the
  # per-op semantics (individual rejection, LWW) are unchanged.
  def send_ops(socket, []), do: socket

  # THE LAST WALL — the authorization axis, and the only site here that reads
  # it. Everything above may be forged by a client; nothing gets past this.
  def send_ops(%{assigns: %{write_capable: false}} = socket, _ops), do: socket

  def send_ops(socket, ops) do
    ops =
      case socket.assigns[:user_id] do
        user_id when is_binary(user_id) and user_id != "" ->
          Enum.map(ops, &Map.put_new(&1, "user", user_id))

        _ ->
          ops
      end

    result =
      ops
      |> Enum.chunk_every(Session.max_ops_per_call())
      |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, errors} ->
        case Session.apply_ops(
               socket.assigns.slug,
               socket.assigns.dataset,
               chunk,
               nil,
               GridData.session_workspace_id(socket)
             ) do
          {:ok, %{errors: chunk_errors}} ->
            acc = errors ++ chunk_errors

            # The cell cap is session-total: once a whole chunk is rejected on
            # it, every later chunk will be too — stop the serial grind (a
            # fat-finger paste past the cap that slipped the preflight) instead
            # of blocking the LiveView on hundreds of doomed calls.
            if chunk_errors != [] and length(chunk_errors) == length(chunk) and
                 Enum.all?(chunk_errors, &(&1.code == "cell_cap_exceeded")) do
              {:halt, {:ok, acc}}
            else
              {:cont, {:ok, acc}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, []} ->
        assign(socket, notice: nil)

      {:ok, [%{message: message} | _] = errors} ->
        assign(socket, notice: "#{length(errors)} op(s) rejected: #{message}")

      {:error, reason} ->
        assign(socket, notice: "edit failed: #{inspect(reason)}")
    end
  end

  # The importer convention: a leading "=" means formula (passes through as
  # the string the session parses); otherwise numbers/booleans coerce so the
  # engine sees real scalars, everything else stays text.
  def parse_raw("=" <> _ = value), do: value

  def parse_raw(value) do
    case Integer.parse(value) do
      {i, ""} ->
        i

      _ ->
        case Float.parse(value) do
          {f, ""} ->
            f

          _ ->
            case String.upcase(value) do
              "TRUE" -> true
              "FALSE" -> false
              _ -> value
            end
        end
    end
  end

  # ── collaborator presence (M4) ───────────────────────────────────────────

  # Merge `updates` into this user's meta on the sheet presence topic. The
  # hosting StudioLive tracked the entry (resub_sheet_presence) on THIS pid —
  # LiveComponents run in the LV process, so the update binds correctly.
  # No-op when presence isn't wired (disconnected render, read-only hosts).
  def push_presence(socket, updates) do
    with topic when is_binary(topic) <- socket.assigns[:presence_topic],
         user_id when is_binary(user_id) <- socket.assigns[:user_id] do
      Presence.update(self(), topic, user_id, &Map.merge(&1, updates))
    end

    socket
  end
end
