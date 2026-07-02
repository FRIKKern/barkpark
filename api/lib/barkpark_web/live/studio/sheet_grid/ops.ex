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
  alias BarkparkWeb.Studio.SheetGrid.GridData

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
        # Read-only hosts NEVER peek — the session is draft-backed. This is
        # unreachable once read-only deltas no-op (sheet_grid.ex update/2),
        # but sealed anyway: fail closed, every read path independently.
        socket.assigns[:read_only] ->
          assign(socket, rev: rev)

        true ->
          case Session.peek(socket.assigns.slug, socket.assigns.dataset) do
            {:ok, content} -> assign(socket, content: content, rev: rev)
            {:error, :no_session} -> assign(socket, rev: rev)
          end
      end

    tab = remap_tab(socket.assigns.tab, structure)
    assign(socket, tab: min(tab, max(length(GridData.tabs(socket)) - 1, 0)))
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
  # per-user undo stacks. Read-only hosts (the public reader) drop EVERY
  # mutation here — the server-side half of stripping the affordances.
  #
  # The session refuses batches over its per-call bound (batch_too_large) —
  # a big TSV paste or clear-selection can exceed it, so the batch chunks
  # here; the session's mailbox serializes the chunks back-to-back and the
  # per-op semantics (individual rejection, LWW) are unchanged.
  def send_ops(socket, []), do: socket

  def send_ops(%{assigns: %{read_only: true}} = socket, _ops), do: socket

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
        case Session.apply_ops(socket.assigns.slug, socket.assigns.dataset, chunk) do
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
