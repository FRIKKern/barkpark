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
      trimmed
      |> Content.search_documents_across_types(
        socket.assigns.dataset,
        ScopeHelpers.scope_opts(socket),
        @limit
      )
      |> Enum.map(fn d ->
        %{
          id: d.doc_id,
          type: d.type,
          title: ((is_binary(d.title) and d.title != "") && d.title) || d.doc_id,
          status: d.status || ""
        }
      end)
    end
  end
end
