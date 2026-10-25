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

  A `by` path that ends in `[]` or `[]._ref` names an ARRAY of references,
  Sanity's `parentCategories[]._ref` or `contributors[]._ref`. Equality on an
  array matches nothing, so such a view reads with the `has` operator, which
  matches an element's `_ref` or its scalar value.

  The list reads one page per query, `desk_page/0` rows at first, and "Show
  more" grows the page by the same amount up to the query layer's 1000-row
  cap. Rows are the desk list's own rows (`PaneBuilder.view_rows/4`).
  """
  import Phoenix.Component, only: [assign: 2]

  alias Barkpark.Content
  alias Barkpark.Content.DraftId
  alias BarkparkWeb.ScopeHelpers
  alias BarkparkWeb.Studio.PaneBuilder

  @max_limit 1000

  @doc """
  Selects a view by id, or returns to the form when the id is blank or names
  the view already open (a second click on the active tab).
  """
  def select(%{"view" => id}, socket) when is_binary(id) do
    current = socket.assigns[:nav_view]

    if id == "" or id == current do
      {:noreply, assign(socket, closed())}
    else
      case find_view(socket, id) do
        nil -> {:noreply, assign(socket, closed())}
        view -> {:noreply, open(socket, id, view, PaneBuilder.desk_page())}
      end
    end
  end

  def select(_params, socket), do: {:noreply, socket}

  @doc """
  "Show more" on the open view's list: reads the next, larger page.
  """
  def more(socket) do
    with id when is_binary(id) <- socket.assigns[:nav_view],
         %{} = view <- find_view(socket, id) do
      limit = min((socket.assigns[:nav_view_limit] || 0) + PaneBuilder.desk_page(), @max_limit)
      {:noreply, open(socket, id, view, limit)}
    else
      _ -> {:noreply, socket}
    end
  end

  @doc "The assigns of a closed view: the form shows and no list is held."
  def closed, do: [nav_view: nil, nav_view_docs: [], nav_view_more: false, nav_view_limit: 0]

  defp open(socket, id, view, limit) do
    {rows, more} = page(view, socket, limit)
    assign(socket, nav_view: id, nav_view_docs: rows, nav_view_more: more, nav_view_limit: limit)
  end

  @doc """
  The views an open document shows. A declared desk list's `views`
  (`desk_views`, task-ea2e544fec8ee6db) replace the schema's, as an item's
  `S.document().views([...])` replaces Sanity's default document node; nil
  falls back to the schema's `desk.views`.
  """
  def views_for(schema, desk_views)

  def views_for(_schema, desk_views) when is_list(desk_views), do: desk_views
  def views_for(schema, _desk_views), do: views_for(schema)

  @doc """
  The views declared on a schema, `[]` for a schema that declares none, so an
  editor without the declaration renders exactly as before.
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
    |> views_for(socket.assigns[:editor_views])
    |> Enum.find(fn v -> (v["id"] || v[:id]) == id end)
  end

  # One scoped read of `limit` rows (plus the one extra row that answers
  # `more`), then the desk list's row builder over them.
  defp page(view, socket, limit) do
    doc = socket.assigns[:editor_doc]
    dataset = socket.assigns.dataset
    scope = ScopeHelpers.scope_opts(socket)

    with %{doc_id: doc_id} <- doc,
         type when is_binary(type) <- view["type"],
         by when is_binary(by) <- view["by"] do
      opts =
        [
          perspective: :drafts,
          limit: limit,
          filter_map: filter_map(by, DraftId.published_id(doc_id))
        ] ++ order_opt(view) ++ scope

      {docs, more} = Content.list_documents_page(type, dataset, opts)

      schema =
        case Content.resolve_schema(type, dataset, scope) do
          {:ok, s} -> s
          _ -> nil
        end

      rows =
        docs
        |> PaneBuilder.view_rows(schema, dataset, scope)
        |> Enum.map(&Map.put(&1, :type, type))

      {rows, more}
    else
      _ -> {[], false}
    end
  end

  @doc """
  The filter a view reads with. `by` ending in `[]` or `[]._ref` names an array
  of references and matches with `has`; any other path matches with `eq`.

      iex> filter_map("content.parentCategories[]._ref", "cat-1")
      %{"content.parentCategories" => %{"has" => "cat-1"}}

      iex> filter_map("content.series", "ser-1")
      %{"content.series" => %{"eq" => "ser-1"}}
  """
  def filter_map(by, id) when is_binary(by) do
    case array_path(by) do
      nil -> %{by => %{"eq" => id}}
      path -> %{path => %{"has" => id}}
    end
  end

  @doc """
  The array's path when `by` names an array of references (`a.b[]` or
  `a.b[]._ref`), else nil.
  """
  def array_path(by) when is_binary(by) do
    cond do
      String.ends_with?(by, "[]._ref") -> binary_part(by, 0, byte_size(by) - 7)
      String.ends_with?(by, "[]") -> binary_part(by, 0, byte_size(by) - 2)
      true -> nil
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
