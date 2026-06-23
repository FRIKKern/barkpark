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
    cond do
      # Stale or duplicate frame (our own op's echo after a refetch).
      rev <= socket.assigns.rev ->
        socket

      # Structural ops re-key widths/heights/merges/frozen bands beyond the
      # changed-cells map; a rev gap means a missed frame. Both refetch.
      Map.has_key?(payload, :structure) or
          (socket.assigns.rev > 0 and rev > socket.assigns.rev + 1) ->
        refetch(socket, rev)

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

  defp refetch(socket, rev) do
    socket =
      case Session.peek(socket.assigns.slug, socket.assigns.dataset) do
        {:ok, content} -> assign(socket, content: content, rev: rev)
        {:error, :no_session} -> assign(socket, rev: rev)
      end

    # delete_tab may have removed the active tab — clamp.
    assign(socket, tab: min(socket.assigns.tab, max(length(GridData.tabs(socket)) - 1, 0)))
  end

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
          {:ok, %{errors: chunk_errors}} -> {:cont, {:ok, errors ++ chunk_errors}}
          {:error, reason} -> {:halt, {:error, reason}}
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
