defmodule Barkpark.Content.Search do
  @moduledoc """
  Document search facade over `Barkpark.Search.QueryPipeline`.

  Thin leaf concern — resolves a title/keyword query against the search
  pipeline and returns `{hits, total, meta}`. No DB writes, no scope
  resolution of its own; tenancy/perspective ride through `opts`.

  Extracted from `Barkpark.Content`, which keeps a thin delegating facade.
  """

  @doc "Search documents by title using the QueryPipeline. Returns `{docs, count, meta}`."
  def search_documents(query, dataset, opts \\ []) do
    context = %{
      query: query,
      filters: %{"type" => Keyword.get(opts, :type)},
      offset: Keyword.get(opts, :offset, 0)
    }

    {:ok, result} = Barkpark.Search.QueryPipeline.search("documents", dataset, context, opts)

    meta = Map.take(result, [:parsed, :highlights, :recovery, :corrected_to, :facets, :truncation])
    {result.hits, result.total, meta}
  end
end
