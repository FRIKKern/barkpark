defmodule BarkparkWeb.Studio.StudioLive.Handlers.Lifecycle do
  @moduledoc """
  handle_info/2 bodies + handle_params finishing for StudioLive.

  Thin routing heads stay on StudioLive (Phoenix dispatch); the bodies — which
  thread `socket` through `Shared` — live here. Behaviour-preserving.
  """
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView

  alias Barkpark.Content
  alias BarkparkWeb.Studio.PresenceState
  alias BarkparkWeb.Studio.StudioLive.{PaperCanvas, Shared}

  # `current_path` is NOT set here — `BarkparkWeb.StudioChrome`'s
  # `:handle_params` hook is the single producer (it runs before this
  # callback, deriving current_path from `uri` for every studio-layout
  # surface), so `uri` is unused in this body now.
  def finish_handle_params(socket, dataset, path, desk, _uri, params) do
    socket =
      socket
      |> Shared.ensure_list_subscription(dataset)
      |> Shared.ensure_presence_subscription()

    socket =
      socket
      |> assign(
        dataset: dataset,
        nav_path: path,
        nav_desk: desk
      )
      |> Shared.maybe_open_shares(params)
      |> Shared.rebuild_panes()
      |> Shared.subscribe_to_doc()
      |> Shared.track_presence()
      # Navigating (re)loads the editor from the DB, so the buffer is clean:
      # clear the dirty flag + any stale concurrent-edit banner.
      |> assign(editor_dirty: false, doc_conflict: false)

    {:noreply, socket}
  end

  # A remote save of the open document arrived (another editor/session — the
  # `sender != self()` guard skips our own writes).
  #
  # With NO unsaved local edits, auto-refresh the form in place (unchanged
  # behaviour). With unsaved local edits (`editor_dirty`), do NOT overwrite the
  # buffer — that would silently drop the user's pre-debounce edits. Instead
  # raise the `doc_conflict` banner and let the user choose to reload.
  def doc_updated(%{sender: sender, doc: doc_data}, socket) do
    cond do
      sender == self() or is_nil(socket.assigns[:editor_doc]) ->
        {:noreply, socket}

      socket.assigns[:editor_dirty] ->
        {:noreply, assign(socket, doc_conflict: true, save_status: "Updated by another user")}

      true ->
        schema = socket.assigns[:editor_schema]
        updated_form = Content.doc_to_form(doc_data, schema)

        {:noreply,
         assign(socket,
           editor_form: updated_form,
           doc_conflict: false,
           save_status: "Updated by another user"
         )}
    end
  end

  def paper_block(frame, socket) do
    cond do
      # Our OWN paper write echoing back — the handle_event that applied it
      # already re-read the confirmed state (`paper_ops/2`), so a broadcast-driven
      # `refetch_paper` is redundant AND, in tests, a DB reload that outlives the
      # event and races sandbox teardown (`client exited`). Mirrors `doc_updated/2`.
      frame[:sender] == self() ->
        {:noreply, socket}

      socket.assigns[:editor_view] != :paper ->
        {:noreply, socket}

      not socket.assigns.paper_block_mode ->
        {:noreply, Shared.refetch_paper(socket)}

      Shared.paper_gap?(socket.assigns.paper_rev, frame.rev) ->
        {:noreply, Shared.refetch_paper(socket)}

      true ->
        socket = Shared.apply_paper_delta(socket, frame)

        # Rule 5 (pdd-t12b): with the canvas the mainline default there is no
        # Edit mode — the always-editable editor is live whenever the flag is
        # on, so an external delta must re-sync `paper_doc` (the sidebar, the
        # display pushes, and the next preview/paint all read it) and push the
        # block to the per-block WCs, exactly as legacy Edit mode did. The
        # flag-OFF opt-out keeps the old shape: only Edit mode syncs; the
        # read-only View rides `apply_paper_delta` alone.
        socket =
          if socket.assigns[:paper_edit_mode] or PaperCanvas.paper_canvas_enabled?() do
            socket
            |> Shared.sync_paper_edit_doc()
            |> Shared.push_block_to_wc(frame.block_id)
          else
            socket
          end

        {:noreply, socket}
    end
  end

  def paper_updated(%{sender: sender}, socket) when sender == self() do
    # Our own whole-paper write echoing back — no self-refresh (see paper_block/2).
    {:noreply, socket}
  end

  def paper_updated(%{html: html} = msg, socket) do
    cond do
      socket.assigns[:editor_view] != :paper ->
        {:noreply, socket}

      # THE THIRD `:paper_html` FEED (task-fa27740cb3162dbd). The two mount-side
      # reads are clamped in `Shared.Paper.reader_paper_html/2`; this one
      # re-assigns AFTER mount, so an unclamped arm here would hand the raw
      # cache back to the same anonymous `:docs`-share viewer one broadcast
      # later. For a write-denied (non-editing) socket the frame is ADVISORY —
      # exactly what `BulldocsLive` already does with it: re-read the store and
      # let the reader clamp decide, rather than painting bytes off the wire.
      # A stale `paper_doc` cannot be sanitized into the fresh body, so the
      # refetch (not the frame's html) is what keeps the view both current and
      # safe; `refetch_paper/1` carries the store's own rev, which is the truth
      # the frame's `rev` was only advertising.
      Shared.write_denied?(socket) ->
        {:noreply, Shared.refetch_paper(socket)}

      true ->
        {:noreply,
         socket
         |> assign(:paper_html, html)
         |> assign(:paper_block_mode, false)
         |> assign(:paper_rev, msg[:rev] || socket.assigns.paper_rev)}
    end
  end

  def sheets_op(payload, socket) do
    if socket.assigns[:editor_view] == :sheet and socket.assigns[:sheet_doc] do
      send_update(BarkparkWeb.Studio.SheetGrid,
        id: "sheet-grid-#{Content.published_id(socket.assigns.sheet_doc.doc_id)}",
        sheets_op: payload
      )
    end

    {:noreply, socket}
  end

  # The session's persist-outcome frame (both success and failure branches of
  # `Session.persist_result/1`). Mirrors `sheets_op/2` — relay it to the same
  # SheetGrid component, which drives the toolbar save-status indicator.
  def sheets_persisted(payload, socket) do
    if socket.assigns[:editor_view] == :sheet and socket.assigns[:sheet_doc] do
      send_update(BarkparkWeb.Studio.SheetGrid,
        id: "sheet-grid-#{Content.published_id(socket.assigns.sheet_doc.doc_id)}",
        sheets_persisted: payload
      )
    end

    {:noreply, socket}
  end

  def presence_diff(topic, socket) do
    cond do
      topic != nil and topic == socket.assigns[:sheet_presence_topic] ->
        {:noreply, assign(socket, sheet_presences: PresenceState.list(topic))}

      socket.assigns[:presence_topic] != nil ->
        {:noreply, assign(socket, presences: PresenceState.list(socket.assigns.presence_topic))}

      true ->
        {:noreply, socket}
    end
  end

  def document_changed(%{type: type} = msg, socket) do
    viewing_type = socket.assigns[:editor_type] || Enum.at(socket.assigns.nav_path, 0)

    cond do
      # Our OWN write — the handle_event that performed it already refreshed our
      # state, so a broadcast-driven `rebuild_panes` (a fresh DB reload) is both
      # redundant AND, in tests, an in-flight query that outlives the test that
      # spawned it: when the LiveView is torn down mid-reload the shared Ecto
      # sandbox connection reports `client exited`, poisoning the pool for
      # unrelated tests' setup. Mirrors the `sender == self()` guard in
      # `doc_updated/2` (the sibling broadcast on the same mutation).
      msg[:sender] == self() ->
        {:noreply, socket}

      viewing_type != type ->
        {:noreply, socket}

      # A rebuild reloads the open doc's form from the DB — with unsaved local
      # edits that would clobber the buffer just like `doc_updated`. Skip the
      # refresh; `doc_updated` (same broadcast) raises the reload banner.
      socket.assigns[:editor_dirty] ->
        {:noreply, socket}

      true ->
        {:noreply, Shared.rebuild_panes(socket)}
    end
  end

  def autosave_form(form, socket) do
    {:noreply, Shared.do_autosave(socket, form)}
  end

  def paper_op(%{"op" => _} = op, socket) do
    {:noreply, Shared.paper_op(socket, op)}
  end

  def tree_codelist_change(%{id: id, value: code}, socket) do
    send_update(BarkparkWeb.Studio.PaperFieldBlock, id: id, tree_value: code)
    {:noreply, socket}
  end
end
