defmodule BarkparkWeb.Studio.StudioLive.Handlers.Views do
  @moduledoc """
  Document views (Gyldendal parity E10).

  Sanity's `defaultDocumentNode` puts tabs beside «Felt» on an open document,
  and the agency Studio uses them to list OTHER documents related to this one:
  «Bøker i serien» on a series, «Bøker av forfatteren» and «Serier av
  forfatteren» on an author. Barkpark showed generic backlinks and no typed
  list at all.

  A view is declared on the schema under `desk.views` and reads exactly one
  question: which documents of `type` carry the open document's PUBLISHED id at
  field path `by`. The read is the ordinary scoped `Content.list_documents/3`
  with a filter map, so tenancy, grants and schema visibility are the same
  guards every other Studio read passes through.

  DRAFTS ARE INCLUDED, matching Sanity's `perspective: "drafts"` on these
  panes: an editor linking a book to a series wants to see it in the series'
  list before publishing it.
  """
  import Phoenix.Component, only: [assign: 2]

  alias Barkpark.Content
  alias Barkpark.Content.DraftId
  alias BarkparkWeb.ScopeHelpers

  @limit 200

  @doc """
  Selects a view by id, or returns to the form when the id is blank or names
  the view already open (a second click on the active tab).
  """
  def select(%{"view" => id}, socket) when is_binary(id) do
    current = socket.assigns[:nav_view]

    if id == "" or id == current do
      {:noreply, assign(socket, nav_view: nil, nav_view_docs: [])}
    else
      case find_view(socket, id) do
        nil -> {:noreply, assign(socket, nav_view: nil, nav_view_docs: [])}
        view -> {:noreply, assign(socket, nav_view: id, nav_view_docs: docs(view, socket))}
      end
    end
  end

  def select(_params, socket), do: {:noreply, socket}

  @doc """
  The views declared on a schema, `[]` for a schema that declares none — which
  is every schema today, so an editor without the declaration renders exactly
  as before.
  """
  def views_for(nil), do: []

  def views_for(schema) do
    case Map.get(schema, :desk) || Map.get(schema, "desk") do
      %{} = desk ->
        case Map.get(desk, "views") || Map.get(desk, :views) do
          list when is_list(list) -> list
          _ -> []
        end

      _ ->
        []
    end
  end

  defp find_view(socket, id) do
    socket.assigns[:editor_schema]
    |> views_for()
    |> Enum.find(fn v -> (v["id"] || v[:id]) == id end)
  end

  defp docs(view, socket) do
    doc = socket.assigns[:editor_doc]

    with %{doc_id: doc_id} <- doc,
         type when is_binary(type) <- view["type"],
         by when is_binary(by) <- view["by"] do
      published = DraftId.published_id(doc_id)

      opts =
        [
          perspective: :drafts,
          limit: @limit,
          filter_map: %{by => %{"eq" => published}}
        ] ++ order_opt(view) ++ ScopeHelpers.scope_opts(socket)

      type
      |> Content.list_documents(socket.assigns.dataset, opts)
      |> Enum.map(fn d ->
        %{
          id: DraftId.published_id(d.doc_id),
          type: type,
          title: ((is_binary(d.title) and d.title != "") && d.title) || d.doc_id,
          is_draft: Content.draft?(d.doc_id)
        }
      end)
    else
      _ -> []
    end
  end

  # The desk's own ordering translation, reused rather than re-derived: it maps
  # the two accepted direction words explicitly instead of atomising authored
  # schema data (Sobelow DOS.StringToAtom).
  defp order_opt(view) do
    case BarkparkWeb.Studio.PaneBuilder.desk_order(nil, nil, view["orderings"]) do
      [] -> []
      order -> [order: order]
    end
  end
end
