defmodule Barkpark.Plugins.Indx.Retriever do
  @moduledoc """
  `Barkpark.Search.Retriever` implementation backed by the dedicated Indx
  engine.

  Registered under the engine name `"indx"`:

      config :barkpark, :search_retrievers, %{"indx" => Barkpark.Plugins.Indx.Retriever}

  A surface whose `config["engine"]` is `"indx"` routes its searches here
  via `Barkpark.Search.Retrievers.resolve/1` +
  `Barkpark.Search.QueryPipeline`. Everything else stays on Postgres
  (`DocumentsRetriever`) — additive, no behaviour change with plugins off.

  ## Hit shape parity

  `Barkpark.Search.DocumentsRetriever.search/4` returns
  `{[%Barkpark.Content.Document{}, ...], total, meta}`. This retriever returns
  the SAME shape: a list of `%Document{}` structs (hydrated from Postgres via
  `Barkpark.Content.get_document/4`, tenant-scoped), an integer total, and an
  engine-diagnostics `meta` map (defaults to `%{}`).

  ## Pipeline

    1. Parse the query terms out of `parsed` and join them into a CloudQuery
       text string.
    2. `Client.search/3` against the scope's live dataset (from
       `Indexer.current_dataset/1`) → `documentKey` records (score-ordered
       by the engine).
    3. `Client.get_json/3` hydrates those keys → docs carrying the embedded
       Barkpark `"_id"` and `"_type"`.
    4. Each `_id`/`_type` is re-read from Postgres via
       `Content.get_document/3` (tenant-scoped) so the returned structs are
       authoritative — the index is a relevance oracle, Postgres is the
       source of truth.

  Indx-down / empty corpus / unconfigured all degrade to `{[], 0, %{}}` — a
  search never crashes the pipeline because the engine is unreachable.
  """

  @behaviour Barkpark.Search.Retriever

  require Logger

  alias Barkpark.Content
  alias Barkpark.Plugins.Indx.{Client, Indexer}

  @impl Barkpark.Search.Retriever
  @spec search(String.t(), map(), map(), keyword()) :: {[struct()], non_neg_integer(), map()}
  def search(scope, parsed, config, opts) when is_binary(scope) do
    text = query_text(parsed)
    dataset = Indexer.current_dataset(scope)

    # An empty `text` is NOT short-circuited: Indx's empty-query + enableFacets
    # is the browse-with-facets mode (the finder's landing). Only a missing live
    # dataset degrades to empty.
    cond do
      is_nil(dataset) ->
        {[], 0, %{}}

      true ->
        do_search(scope, dataset, text, parsed, config, opts)
    end
  end

  defp do_search(scope, dataset, text, parsed, config, opts) do
    client = Keyword.get(opts, :client, Client)
    limit = Keyword.get(opts, :limit, 50) |> min(200)
    client_opts = client_opts(opts)

    with {:ok, %{records: records, facets: facets, truncation_index: tindex}} <-
           client.search_full(dataset, text, [max: limit] ++ client_opts),
         keys = Enum.map(records, &record_key/1) |> Enum.reject(&is_nil/1),
         {:ok, docs} <- hydrate(client, dataset, keys, client_opts) do
      hits =
        docs
        |> Enum.map(&load_document(&1, scope, opts))
        |> Enum.reject(&is_nil/1)
        |> apply_excludes(parsed, config)

      {hits, length(hits), engine_meta(facets, tindex)}
    else
      {:error, err} ->
        Logger.warning("Indx.Retriever: search failed for #{dataset}: #{inspect(err)}")
        {[], 0, %{}}
    end
  end

  # Engine diagnostics surfaced to the pipeline → HTTP response: Indx-computed
  # dataset-wide facet buckets and the coverage `truncation` boundary. Both are
  # genuinely Indx (the API gateway exposes neither for Postgres).
  defp engine_meta(facets, tindex) do
    %{}
    |> maybe_put(:facets, normalize_facets(facets))
    |> maybe_put(:truncation, if(is_integer(tindex), do: %{index: tindex}))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, v) when v == %{}, do: map
  defp maybe_put(map, key, v), do: Map.put(map, key, v)

  # Indx returns `%{"type" => [%{"key" => "post", "value" => 2}], ...}` (key =
  # bucket value, value = count). Re-shape to `%{"type" => [%{"label","count"}]}`
  # and drop the empty-string bucket (docs that lack the field).
  defp normalize_facets(facets) when is_map(facets) do
    facets
    |> Enum.map(fn {field, buckets} ->
      {field,
       buckets
       |> List.wrap()
       |> Enum.map(fn b ->
         %{"label" => to_string(Map.get(b, "key", "")), "count" => Map.get(b, "value", 0)}
       end)
       |> Enum.reject(&(&1["label"] in ["", nil]))}
    end)
    |> Enum.reject(fn {_field, buckets} -> buckets == [] end)
    |> Map.new()
  end

  defp normalize_facets(_), do: %{}

  # Indx has no native negation in this path: query_text/1 builds only the
  # POSITIVE query for the engine. The parsed `:excludes` are honored here as a
  # post-filter on the resolved Barkpark Documents, mirroring
  # DocumentsRetriever's exclude semantics — a hit is dropped when an excluded
  # term appears (case-insensitive substring, like Postgres' `ilike '%t%'`) in
  # any of the surface's searchable fields (title + content.slug by default).
  defp apply_excludes(hits, parsed, config) do
    excludes =
      Map.get(parsed, :excludes, [])
      |> Enum.map(&String.downcase(to_string(&1)))
      |> Enum.reject(&(&1 == ""))

    case excludes do
      [] ->
        hits

      _ ->
        fields = searchable_paths(config)
        Enum.reject(hits, &excluded?(&1, excludes, fields))
    end
  end

  defp searchable_paths(config) do
    config
    |> Map.get("searchable_fields", [])
    |> Enum.map(fn
      %{"path" => p} -> p
      %{path: p} -> p
      p when is_binary(p) -> p
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ["title", "content.slug"]
      paths -> paths
    end
  end

  defp excluded?(doc, excludes, fields) do
    haystack =
      fields
      |> Enum.map(&field_text(doc, &1))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")
      |> String.downcase()

    haystack != "" and Enum.any?(excludes, &String.contains?(haystack, &1))
  end

  # Path resolution mirrors Search.Highlighter.document_field_text/2 so the
  # exclude filter reads the same fields the surface searches/highlights.
  defp field_text(doc, "title"), do: doc.title

  defp field_text(doc, "content.slug") do
    case doc.content do
      %{"slug" => slug} when is_binary(slug) -> slug
      _ -> nil
    end
  end

  defp field_text(_doc, _field), do: nil

  defp hydrate(_client, _dataset, [], _opts), do: {:ok, []}
  defp hydrate(client, dataset, keys, opts), do: client.get_json(dataset, keys, opts)

  # Read the embedded Barkpark _id + _type off the Indx doc and re-read the
  # authoritative row from Postgres, workspace+dataset-scoped via threaded opts.
  # Drop docs we cannot map. `Content.get_document/4` is the scoped read on the
  # integration base; passing the tenant `:workspace_id`/`:project_id` opts
  # forwards them into `scope_to_workspace_or_global/3`, so the index can never
  # surface another workspace's row even when two workspaces share a dataset
  # STRING. The index is a relevance oracle, Postgres is the source of truth.
  defp load_document(indx_doc, scope, opts) when is_map(indx_doc) do
    id = Map.get(indx_doc, "_id") || Map.get(indx_doc, "id")
    type = Map.get(indx_doc, "_type") || Map.get(indx_doc, "type")

    with id when is_binary(id) and id != "" <- to_string_or_nil(id),
         type when is_binary(type) and type != "" <- to_string_or_nil(type),
         {:ok, doc} <- Content.get_document(id, type, scope, scope_opts(opts)) do
      doc
    else
      _ -> nil
    end
  end

  defp load_document(_other, _scope, _opts), do: nil

  # Forward only the tenant-scope opts into the authoritative Postgres read so
  # the seam cannot bypass `scope_to_workspace_or_global/3` (the P0 leak guard).
  defp scope_opts(opts), do: Keyword.take(opts, [:workspace_id, :project_id])

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(v) when is_binary(v), do: v
  defp to_string_or_nil(v), do: to_string(v)

  defp record_key(%{"documentKey" => k}) when is_integer(k), do: k
  defp record_key(%{"documentKey" => k}) when is_binary(k), do: parse_int(k)
  defp record_key(_), do: nil

  defp parse_int(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp query_text(parsed) when is_map(parsed) do
    (Map.get(parsed, :terms, []) ++
       Map.get(parsed, :phrases, []) ++
       Map.get(parsed, :prefixes, []))
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.join(" ")
    |> String.trim()
  end

  defp query_text(_), do: ""

  defp client_opts(opts), do: Keyword.take(opts, [:base_url, :timeout])
end
