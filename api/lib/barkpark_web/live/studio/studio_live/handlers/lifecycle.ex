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
  alias BarkparkWeb.Studio.StudioLive.Shared

  def finish_handle_params(socket, dataset, path, desk, uri, params) do
    socket =
      socket
      |> Shared.ensure_list_subscription(dataset)
      |> Shared.ensure_presence_subscription()

    current_path =
      case uri do
        u when is_binary(u) ->
          case URI.parse(u) do
            %URI{path: p} when is_binary(p) -> p
            _ -> nil
          end

        _ ->
          nil
      end

    socket =
      socket
      |> assign(
        dataset: dataset,
        nav_path: path,
        nav_desk: desk,
        current_path: current_path
      )
      |> Shared.maybe_open_shares(params)
      |> Shared.rebuild_panes()
      |> Shared.subscribe_to_doc()
      |> Shared.track_presence()

    {:noreply, socket}
  end

  def doc_updated(%{sender: sender, doc: doc_data}, socket) do
    if sender != self() && socket.assigns[:editor_doc] do
      schema = socket.assigns[:editor_schema]
      updated_form = Content.doc_to_form(doc_data, schema)

      {:noreply,
       assign(socket, editor_form: updated_form, save_status: "Updated by another user")}
    else
      {:noreply, socket}
    end
  end

  def paper_block(frame, socket) do
    cond do
      socket.assigns[:editor_view] != :paper ->
        {:noreply, socket}

      not socket.assigns.paper_block_mode ->
        {:noreply, Shared.refetch_paper(socket)}

      Shared.paper_gap?(socket.assigns.paper_rev, frame.rev) ->
        {:noreply, Shared.refetch_paper(socket)}

      true ->
        socket = Shared.apply_paper_delta(socket, frame)

        socket =
          if socket.assigns[:paper_edit_mode] do
            socket
            |> Shared.sync_paper_edit_doc()
            |> Shared.push_block_to_wc(frame.block_id)
          else
            socket
          end

        {:noreply, socket}
    end
  end

  def paper_updated(%{html: html} = msg, socket) do
    if socket.assigns[:editor_view] == :paper do
      {:noreply,
       socket
       |> assign(:paper_html, html)
       |> assign(:paper_block_mode, false)
       |> assign(:paper_rev, msg[:rev] || socket.assigns.paper_rev)}
    else
      {:noreply, socket}
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

  def document_changed(%{type: type}, socket) do
    viewing_type = socket.assigns[:editor_type] || Enum.at(socket.assigns.nav_path, 0)

    if viewing_type == type do
      {:noreply, Shared.rebuild_panes(socket)}
    else
      {:noreply, socket}
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
