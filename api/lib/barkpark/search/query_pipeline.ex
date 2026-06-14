defmodule Barkpark.Search.QueryPipeline do
  @moduledoc """
  Unified search pipeline: parse → expand → retrieve → recover → highlight.
  """

  alias Barkpark.Search.{
    DocumentsRetriever,
    Highlighter,
    QueryParser,
    Retrievers,
    SurfaceConfigs,
    Synonyms
  }

  @type result :: %{
          hits: list(),
          total: non_neg_integer(),
          parsed: map(),
          highlights: map(),
          recovery: String.t() | nil,
          ms: non_neg_integer()
        }

  @spec search(String.t(), String.t(), map(), keyword()) :: {:ok, result()}
  def search(surface, scope, context, opts \\ []) when is_binary(surface) and is_binary(scope) do
    t0 = System.monotonic_time(:microsecond)
    config = SurfaceConfigs.get(surface, scope)
    raw_query = Map.get(context, :query, "") || ""
    parsed = QueryParser.parse(raw_query)
    parsed = expand_synonyms(surface, scope, parsed)

    {hits, total, recovery, engine_meta} =
      case surface do
        "documents" ->
          search_documents(scope, parsed, config, context, opts)

        "media" ->
          {h, t, r} = search_media(scope, parsed, config, context, opts)
          {h, t, r, %{}}

        _ ->
          {[], 0, nil, %{}}
      end

    highlights = highlight_hits(surface, hits, parsed, config, opts)
    ms = div(System.monotonic_time(:microsecond) - t0, 1000)

    {:ok,
     %{
       hits: hits,
       total: total,
       parsed: QueryParser.to_map(parsed),
       highlights: highlights,
       recovery: recovery,
       # Indx-only engine diagnostics (absent for Postgres): dataset-wide facet
       # buckets and the coverage truncation boundary.
       facets: Map.get(engine_meta, :facets),
       truncation: Map.get(engine_meta, :truncation),
       ms: ms
     }}
  end

  defp expand_synonyms(surface, scope, parsed) do
    positive = Map.get(parsed, :terms, []) ++ Map.get(parsed, :phrases, [])

    if positive == [] do
      parsed
    else
      extra =
        positive
        |> Enum.flat_map(fn term -> Synonyms.search_terms(surface, scope, term) end)
        |> Enum.reject(&(&1 in positive or &1 == ""))
        |> Enum.uniq()

      %{parsed | terms: parsed.terms ++ extra}
    end
  end

  defp search_documents(scope, parsed, config, context, opts) do
    filters = Map.get(context, :filters, %{})
    type = Map.get(filters, "type") || Map.get(filters, :type) || Keyword.get(opts, :type)
    perspective = Keyword.get(opts, :perspective, :published)
    limit = Keyword.get(opts, :limit, 50)
    offset = Map.get(context, :offset, 0) || Keyword.get(opts, :offset, 0)

    retriever_opts =
      [
        type: type,
        perspective: perspective,
        limit: limit,
        offset: offset,
        relaxed: false,
        workspace_id: Keyword.get(opts, :workspace_id),
        project_id: Keyword.get(opts, :project_id)
      ]

    # Engine dispatch lives here (not the controller) so highlights + recovery
    # wrap EVERY engine. The D3-b gate: a non-postgres engine without a binary
    # `:workspace_id` in opts cannot prove tenant scope, so it falls back to the
    # scoped Postgres retriever rather than risk a cross-workspace bypass.
    engine = Keyword.get(opts, :engine, "postgres")

    retriever =
      if engine != "postgres" and not is_binary(Keyword.get(opts, :workspace_id)) do
        DocumentsRetriever
      else
        Retrievers.resolve(%{"engine" => engine})
      end

    {hits, total, engine_meta} = retriever.search(scope, parsed, config, retriever_opts)

    {final_hits, final_total, recovery} =
      case {total, Map.get(config, "zero_hit_strategy", "drop_tokens")} do
        {0, "none"} ->
          {hits, total, nil}

        {0, strategy} ->
          case recover_documents(scope, parsed, config, retriever_opts, strategy) do
            {rh, rt, recovery} -> {rh, rt, recovery}
            nil -> {hits, total, nil}
          end

        _ ->
          {hits, total, nil}
      end

    # Carry the PRIMARY retriever's engine meta (Indx facets + truncation)
    # regardless of zero-hit recovery — facets describe the whole dataset, so
    # they stay meaningful even when the text matched nothing.
    {final_hits, final_total, recovery, engine_meta}
  end

  defp recover_documents(scope, parsed, config, opts, strategy) do
    with nil <- try_drop_tokens(scope, parsed, config, opts, strategy),
         nil <- try_typo_widen(scope, parsed, config, opts, strategy) do
      nil
    end
  end

  defp try_drop_tokens(scope, parsed, config, opts, "drop_tokens") do
    terms = parsed.terms ++ parsed.phrases

    if length(terms) <= 1 do
      nil
    else
      dropped = %{
        parsed
        | terms: Enum.drop(parsed.terms, -1),
          phrases: Enum.drop(parsed.phrases, -1)
      }

      {hits, total, _meta} = DocumentsRetriever.search(scope, dropped, config, opts)

      if total > 0 do
        {hits, total, "drop_tokens"}
      else
        try_drop_tokens(scope, dropped, config, opts, "drop_tokens")
      end
    end
  end

  defp try_drop_tokens(_scope, _parsed, _config, _opts, _strategy), do: nil

  defp try_typo_widen(scope, parsed, config, opts, strategy)
       when strategy in ["drop_tokens", "typo_widen"] do
    relaxed_opts = Keyword.put(opts, :relaxed, true)
    {hits, total, _meta} = DocumentsRetriever.search(scope, parsed, config, relaxed_opts)

    if total > 0 do
      {hits, total, "typo_widen"}
    end
  end

  defp try_typo_widen(_scope, _parsed, _config, _opts, _strategy), do: nil

  defp search_media(_scope, _parsed, _config, _context, _opts) do
    # Media search runs through Media.Search.search/2 with pipeline opts; hits filled by caller.
    {[], 0, nil}
  end

  @doc false
  def media_recovery(parsed, config, search_fn) when is_function(search_fn, 2) do
    case search_fn.(parsed, false) do
      {hits, total} when total > 0 ->
        {hits, total, nil}

      _ ->
        strategy = Map.get(config, "zero_hit_strategy", "drop_tokens")

        case try_drop_tokens_media(parsed, search_fn, strategy) do
          {h, t, r} ->
            {h, t, r}

          nil ->
            case try_typo_widen_media(parsed, search_fn, strategy) do
              {h, t, r} -> {h, t, r}
              nil -> {[], 0, nil}
            end
        end
    end
  end

  defp try_drop_tokens_media(parsed, search_fn, "drop_tokens") do
    if length(parsed.terms ++ parsed.phrases) <= 1 do
      nil
    else
      dropped = %{
        parsed
        | terms: Enum.drop(parsed.terms, -1),
          phrases: Enum.drop(parsed.phrases, -1)
      }

      {hits, total} = search_fn.(dropped, false)

      if total > 0 do
        {hits, total, "drop_tokens"}
      else
        try_drop_tokens_media(dropped, search_fn, "drop_tokens")
      end
    end
  end

  defp try_drop_tokens_media(_parsed, _search_fn, _strategy), do: nil

  defp try_typo_widen_media(parsed, search_fn, strategy)
       when strategy in ["drop_tokens", "typo_widen"] do
    {hits, total} = search_fn.(parsed, true)

    if total > 0 do
      {hits, total, "typo_widen"}
    end
  end

  defp try_typo_widen_media(_parsed, _search_fn, _strategy), do: nil

  defp highlight_hits("documents", docs, parsed, config, _opts) do
    Highlighter.highlight_documents(docs, parsed, config)
  end

  defp highlight_hits("media", files, parsed, config, opts) do
    docs = Keyword.get(opts, :asset_docs, %{})
    Highlighter.highlight_media(files, parsed, config, docs)
  end

  defp highlight_hits(_, _, _, _, _), do: %{}
end
