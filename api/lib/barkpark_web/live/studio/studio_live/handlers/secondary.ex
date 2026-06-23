defmodule BarkparkWeb.Studio.StudioLive.Handlers.Secondary do
  @moduledoc """
  Secondary pane (read-only second editor) + blast-radius graph open.
  Behaviour-preserving extraction of the StudioLive handler bodies.
  """
  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView

  alias Barkpark.Content
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.StudioLive.Shared

  def open_secondary_picker(socket) do
    type = socket.assigns[:editor_type]

    candidates =
      if type do
        type
        |> Content.list_documents(
          socket.assigns.dataset,
          [perspective: :drafts] ++ ScopeHelpers.scope_opts(socket)
        )
        |> Enum.map(fn d ->
          pub = Content.published_id(d.doc_id)
          %{id: pub, title: d.title || "Untitled", type: type}
        end)
        |> Enum.reject(fn c ->
          socket.assigns[:editor_doc] &&
            c.id == Content.published_id(socket.assigns.editor_doc.doc_id)
        end)
      else
        []
      end

    {:noreply,
     assign(socket,
       show_secondary_picker: true,
       secondary_search: "",
       secondary_candidates: candidates
     )}
  end

  def view_graph(socket) do
    case socket.assigns[:editor_doc] do
      %{doc_id: doc_id} when is_binary(doc_id) ->
        pub_id = Content.published_id(doc_id)
        path = ["graph", pub_id]
        {:noreply, push_patch(socket, to: Shared.studio_path(socket, path, socket.assigns.dataset))}

      _ ->
        {:noreply, socket}
    end
  end

  def close_secondary_picker(socket) do
    {:noreply, assign(socket, show_secondary_picker: false, secondary_search: "")}
  end

  def secondary_search(%{"value" => q}, socket) do
    {:noreply, assign(socket, secondary_search: q)}
  end

  def select_secondary(%{"id" => doc_id}, socket) do
    type = socket.assigns[:editor_type]
    dataset = socket.assigns.dataset

    case Content.fetch_doc_with_draft(type, doc_id, dataset, ScopeHelpers.scope_opts(socket)) do
      {nil, _, _} ->
        {:noreply, put_flash(socket, :error, "Document not found")}

      {doc, _, _} ->
        schema =
          case Content.get_schema(type, dataset) do
            {:ok, s} -> s
            _ -> nil
          end

        {:noreply,
         assign(socket,
           secondary_doc: doc,
           secondary_schema: schema,
           secondary_type: type,
           show_secondary_picker: false,
           secondary_search: ""
         )}
    end
  end

  def close_secondary(socket) do
    {:noreply, assign(socket, secondary_doc: nil, secondary_schema: nil, secondary_type: nil)}
  end
end
