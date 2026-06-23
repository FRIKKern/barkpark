defmodule BarkparkWeb.Studio.StudioLive.Handlers.Refs do
  @moduledoc """
  Reference field events — picker open/close, search, select, clear.
  Behaviour-preserving extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]

  alias Barkpark.Content
  alias BarkparkWeb.ScopeHelpers

  def open_ref_picker(%{"field" => field_name, "ref-type" => ref_type}, socket) do
    docs =
      Content.list_documents(
        ref_type,
        socket.assigns.dataset,
        [perspective: :drafts] ++ ScopeHelpers.scope_opts(socket)
      )

    candidates =
      Enum.map(docs, fn doc ->
        %{id: Content.published_id(doc.doc_id), title: doc.title || "Untitled"}
      end)

    {:noreply,
     assign(socket, ref_picker_field: field_name, ref_candidates: candidates, ref_search: "")}
  end

  def close_ref_picker(socket) do
    {:noreply, assign(socket, ref_picker_field: nil, ref_candidates: [], ref_search: "")}
  end

  def ref_search(%{"value" => query}, socket) do
    {:noreply, assign(socket, ref_search: query)}
  end

  def select_ref(%{"id" => ref_id, "field" => field_name}, socket) do
    form = Map.put(socket.assigns.editor_form, field_name, ref_id)

    socket =
      assign(socket, editor_form: form, ref_picker_field: nil, ref_candidates: [], ref_search: "")

    send(self(), {:autosave_form, form})
    {:noreply, socket}
  end

  def clear_ref(%{"field" => field_name}, socket) do
    form = Map.put(socket.assigns.editor_form, field_name, "")
    socket = assign(socket, editor_form: form)
    send(self(), {:autosave_form, form})
    {:noreply, socket}
  end
end
