defmodule BarkparkWeb.Studio.StudioLive.Handlers.DeskSearch do
  @moduledoc """
  The desk's own search box (Gyldendal parity E8).

  Sanity's Studio puts a global search in the navbar: you type, you get
  documents across every type you may see, you click one and it opens. Barkpark
  had the search API and the reference picker's per-type box, but nothing in
  the desk — the editor had to know which list a document lived in before they
  could find it.

  The read is `Content.search_documents_across_types/4`, which carries the same
  tenant, owner, grant and schema-visibility guards as the typeless batch read.
  Hits are rendered as ordinary links to `/…/studio/<type>/<doc_id>`, so a hit
  is deep-linkable and survives a reload; the E3.5 dead-head alias opens a type
  the desk does not list at its root.
  """
  import Phoenix.Component, only: [assign: 2]

  alias Barkpark.Content
  alias BarkparkWeb.ScopeHelpers

  @limit 20
  @min_query 2

  @doc """
  Runs the search for `value` and assigns `desk_search` + `desk_search_hits`.

  A query under #{@min_query} characters assigns the text but NO hits: a
  one-letter ILIKE matches most of the corpus and the round trip is wasted.
  """
  def search(%{"value" => value}, socket) when is_binary(value) do
    {:noreply, assign(socket, desk_search: value, desk_search_hits: hits(value, socket))}
  end

  def search(_params, socket), do: {:noreply, socket}

  @doc "Clears the box and its hits — the desk's own items come back."
  def clear(socket), do: {:noreply, assign(socket, desk_search: "", desk_search_hits: [])}

  defp hits(value, socket) do
    trimmed = String.trim(value)

    if String.length(trimmed) < @min_query do
      []
    else
      scope = ScopeHelpers.scope_opts(socket)

      found =
        Content.search_documents_across_types(trimmed, socket.assigns.dataset, scope, @limit)

      titles = type_titles(found, socket.assigns.dataset, scope)

      Enum.map(found, fn d ->
        %{
          # A draft-only document's row is `drafts.<id>`; the Studio path
          # addresses every document by its published id.
          id: Content.published_id(d.doc_id),
          type: d.type,
          # The label an editor reads is the schema's title ("Utgivelse"), as
          # on the desk and the pane headers; the id stays in the link.
          type_title: Map.get(titles, d.type, d.type),
          title: ((is_binary(d.title) and d.title != "") && d.title) || d.doc_id,
          status: d.status || ""
        }
      end)
    end
  end

  # One schema read per search, only when there are hits; a type without a
  # title keeps its id.
  defp type_titles([], _dataset, _scope), do: %{}

  defp type_titles(_found, dataset, scope) do
    dataset
    |> Content.list_schemas(scope)
    |> Map.new(fn schema -> {schema.name, title_or_name(schema)} end)
  end

  defp title_or_name(%{title: title}) when is_binary(title) and title != "", do: title
  defp title_or_name(%{name: name}), do: name
end
