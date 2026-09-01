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
  `Barkpark.Content.get_document/4`, tenant-scoped), an integer total, and a
  `meta` map — which on this path is ALWAYS `%{}`. The engine's `facets` and
  `truncationIndex` are deliberately dropped; see "Why this retriever returns
  no `facets` and no `truncation`" below for the ruling.

  ## Pipeline

    1. Parse the query terms out of `parsed` and join them into a CloudQuery
       text string.
    2. `Client.search_full/3` against the scope's live dataset (from
       `Indexer.current_dataset/1`) → a WIDE pool of `documentKey` records
       (score-ordered by the engine — `@candidate_pool`, the whole matched
       set, NOT just the display limit; see `do_search/6`).
    3. `Client.get_json/3` hydrates those keys → light index records carrying
       the embedded Barkpark `"_id"`/`"_type"` plus `title`/`slug`/`body`.
    4. `rerank_by_title/2` applies a stable title-affinity re-rank over those
       light records so the engine's flat BM25F order gains the Postgres
       ranker's decisive "exact/whole title wins" behaviour — across the WHOLE
       pool, so a title-perfect doc BM25F buried at rank 100+ still surfaces.
    5. The top `display_limit` re-ranked records are re-read from Postgres via
       `Content.get_document/4` (tenant-scoped) so the returned structs are
       authoritative — the index is a relevance oracle, Postgres is the source
       of truth. Only the display slice is hydrated, never the whole pool.

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

    # An empty `text` is NOT short-circuited: Indx's empty-query mode is the
    # browse listing (the finder's landing), which still returns records. Only a
    # missing live dataset degrades to empty.
    cond do
      is_nil(dataset) ->
        {[], 0, %{}}

      true ->
        do_search(scope, dataset, text, parsed, config, opts)
    end
  end

  # Candidate pool fetched from the engine before re-ranking — deliberately far
  # wider than any display limit. A doc TITLED for the query can sit at raw
  # BM25F-rank 100+ because dozens of docs mention the term in their bodies
  # (q="search relevance" buried the doc literally titled "Search Relevance…" at
  # raw-rank 128 of 131). `rerank_by_title/2` can only promote a doc it can SEE,
  # so we fetch the whole matched set, re-rank, and truncate to the display limit
  # AFTERWARDS. 200 is the engine's max page and covers the demo corpus whole.
  @candidate_pool 200

  defp do_search(scope, dataset, text, parsed, _config, opts) do
    client = Keyword.get(opts, :client, Client)
    display_limit = Keyword.get(opts, :limit, 50)
    pool = display_limit |> max(@candidate_pool) |> min(@candidate_pool)
    client_opts = client_opts(opts)

    # The engine's reply also carries `facets` and `truncation_index`. Neither is
    # bound: both describe the SHARED, dataset-keyed index rather than this
    # caller's tenant-scoped match set. See the ruling below.
    with {:ok, %{records: records}} <-
           client.search_full(dataset, text, [max: pool] ++ client_opts),
         keys = Enum.map(records, &record_key/1) |> Enum.reject(&is_nil/1),
         {:ok, indx_docs} <- hydrate(client, dataset, keys, client_opts) do
      # Re-rank + exclude on the LIGHT embedded index records (title/slug/body
      # ride in each), THEN hydrate only the display slice from Postgres — so a
      # wide pool never costs 200 authoritative re-reads per keystroke.
      ranked =
        indx_docs
        |> reject_excluded(parsed)
        |> rerank_by_title(parsed)

      hits =
        ranked
        |> Enum.take(display_limit)
        |> hydrate_documents(scope, opts)

      Barkpark.Plugins.Indx.Monitor.record_success(scope, %{dataset: dataset})

      {hits, total_for(ranked, scope, opts), %{}}
    else
      {:error, err} ->
        # P4b Hardening A: turn silent fallback into a queryable signal.
        # Monitor counts the outcome + remembers the last error per scope;
        # a telemetry event lets a handler surface this to logs/Datadog.
        Logger.warning("Indx.Retriever: search failed for #{dataset}: #{inspect(err)}")
        Barkpark.Plugins.Indx.Monitor.record_fallback(scope, err, %{dataset: dataset})
        {[], 0, %{}}
    end
  end

  # ---------------------------------------------------------------------------
  # Why this retriever returns no `facets` and no `truncation`
  # ---------------------------------------------------------------------------
  #
  # It used to. A private `engine_meta/2` re-shaped the engine's `facets`
  # payload onto the pipeline's `facets:` key and its `truncationIndex` onto
  # `truncation:`.
  #
  # The facet buckets were computed BY THE ENGINE over an index keyed on the
  # Barkpark dataset STRING alone (`Indexer.current_dataset/1`), so every
  # workspace sharing a dataset name shares ONE index — the same shared pool
  # `total_for/3` below is written for. The rows beside those buckets are
  # re-read from Postgres under full tenant scope; the buckets were not re-read
  # at all. `author` and `category` are tenant-authored FREE TEXT (`Indexer`'s
  # `field_proxies/1` marks them facetable), so workspace A received workspace
  # B's author names and category names VERBATIM — not merely counts. Measured:
  # A could read 1 document while the bucket beside it said 2.
  #
  # Reachable with no credentials. `engine` is a raw caller-supplied query param
  # (`SearchController`), not an admin surface, and a tokenless flat request is
  # still stamped with a real binary `workspace_id` by `Plugs.AssignDefaultScope`
  # — so both halves of the D3-b gate in `QueryPipeline` are satisfiable
  # anonymously. The `search:*` channel DEFAULTS `engine` to `"indx"`, so every
  # WS query took this path with no param at all: the default, not an odd URL.
  #
  # There is a prior ruling and dropping these restores compliance with it.
  # `DocumentsRetriever` (at `count_and_facets/1`): "Facets + count stay on the
  # FULL match set (not the ranking pool): the user wants 'this query matched
  # 1.2k items across these facets', not 'the top 500 break down this way'."
  # Barkpark already decided that a facet number means a count over the CALLER'S
  # full, tenant-scoped match set. Indx never implemented that — it reported the
  # index's own counts. With the buckets dropped, `facets` means exactly one
  # thing everywhere it is non-null: a Postgres count over rows the caller could
  # have reached one by one. `truncation` goes with it — it is a coverage
  # boundary over that same dataset-wide pool, describing a set the caller
  # cannot see either.
  #
  # DO NOT "restore the facet rail" here. Tenant-scoped facets over an Indx
  # result would require the ENGINE to narrow by workspace at query time (a
  # `filterable` proxy `Client.search_full/3` does not currently send);
  # recomputing them from the shared index reopens an anonymous cross-tenant
  # read of another workspace's author and category strings.
  # `Barkpark.Plugins.Indx.RetrieverDropsEngineFacetsTest` reds if it comes back.

  # Indx has no native negation in this path: query_text/1 builds only the
  # POSITIVE query for the engine. The parsed `:excludes` are honored here as a
  # pre-hydration filter on the EMBEDDED index records, mirroring
  # DocumentsRetriever's exclude semantics — a hit is dropped when an excluded
  # term appears (case-insensitive substring, like Postgres' `ilike '%t%'`) in
  # the record's title, slug or body. Running it before hydration keeps an
  # excluded doc from consuming a display slot and needs no Postgres read (the
  # index record already carries title/slug/body).
  defp reject_excluded(indx_docs, parsed) do
    excludes =
      Map.get(parsed, :excludes, [])
      |> Enum.map(&String.downcase(to_string(&1)))
      |> Enum.reject(&(&1 == ""))

    case excludes do
      [] -> indx_docs
      _ -> Enum.reject(indx_docs, &indx_excluded?(&1, excludes))
    end
  end

  defp indx_excluded?(indx_doc, excludes) do
    haystack =
      [Map.get(indx_doc, "title"), Map.get(indx_doc, "slug"), Map.get(indx_doc, "body")]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")
      |> String.downcase()

    haystack != "" and Enum.any?(excludes, &String.contains?(haystack, &1))
  end

  @doc """
  Stable title-affinity re-rank applied to the engine's score-ordered hits.

  Indx hands back a flat BM25F ordering with no equivalent of the Postgres
  ranker's decisive rules (`DocumentsRetriever`: an EXACT title match wins
  outright; a title match outranks a body-only match). On a long corpus that
  lets a long, body-heavy document accumulate enough term-frequency to overtake
  the document actually TITLED for the query — the documented `@body_max`
  regression in `Indexer` (q="fork" ranked a long CLI paper above the paper
  titled "Fork reconciliation").

  This pass restores Postgres-parity intent WITHOUT discarding Indx's superior
  fuzzy / BM25F recall: it buckets hits into title-affinity tiers and
  stable-sorts by tier, preserving the engine's order WITHIN each tier (the
  original index is the tiebreak, so the sort is fully deterministic regardless
  of `Enum.sort_by`'s stability). Tiers — lower wins:

    * `0` exact title  — normalized title == the positive query
    * `1` title prefix — title STARTS WITH the query ("Studio (LiveView)" for q="studio")
    * `2` whole title  — every query token appears in the title (any position)
    * `3` partial      — at least one query token appears in the title
    * `4` body/fuzzy   — no title signal; the engine's order is kept as-is

  Browse (empty query) yields no tokens, so the hits pass through untouched —
  the engine's relevance/recency order is authoritative there.
  """
  @spec rerank_by_title([map()], map()) :: [map()]
  def rerank_by_title(hits, parsed) do
    tokens = title_tokens(parsed)

    if tokens == [] do
      hits
    else
      query_join = positive_query(parsed)

      hits
      |> Enum.with_index()
      |> Enum.sort_by(fn {doc, idx} -> {title_tier(doc, tokens, query_join), idx} end)
      |> Enum.map(fn {doc, _idx} -> doc end)
    end
  end

  # Downcased query tokens (terms + phrases + prefixes) for the in-title test.
  defp title_tokens(parsed) when is_map(parsed) do
    (Map.get(parsed, :terms, []) ++
       Map.get(parsed, :phrases, []) ++
       Map.get(parsed, :prefixes, []))
    |> Enum.map(&(&1 |> to_string() |> String.downcase() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp title_tokens(_), do: []

  # The positive query (terms + phrases) joined + normalized — mirrors the
  # Postgres ranker's `positive_query` for the exact / starts-with compare.
  defp positive_query(parsed) do
    (Map.get(parsed, :terms, []) ++ Map.get(parsed, :phrases, []))
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> normalize_title()
  end

  defp title_tier(doc, tokens, query_join) do
    title = normalize_title(doc_title(doc))
    words = title_word_set(title)

    cond do
      title == "" ->
        4

      query_join != "" and title == query_join ->
        0

      query_join != "" and String.starts_with?(title, query_join) ->
        1

      Enum.all?(tokens, &token_in_title?(title, words, &1)) ->
        2

      Enum.any?(tokens, &token_in_title?(title, words, &1)) ->
        3

      true ->
        4
    end
  end

  defp doc_title(%{title: t}), do: t
  defp doc_title(%{"title" => t}), do: t
  defp doc_title(_), do: nil

  defp normalize_title(t) do
    t
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp title_word_set(title) do
    title
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> MapSet.new()
  end

  # A token "hits" the title when it is a whole word, a word PREFIX (mirrors the
  # prefix* / typo-tolerant intent), or — for a multi-word phrase — a substring.
  defp token_in_title?(title, words, token) do
    cond do
      String.contains?(token, " ") ->
        String.contains?(title, token)

      MapSet.member?(words, token) ->
        true

      Enum.any?(words, &String.starts_with?(&1, token)) ->
        true

      # Typo tolerance: a query token within a close Jaro distance of a title
      # WORD still counts as a title hit (q="workspce" → title "Workspace"). This
      # is what lets Indx's fuzzy recall — its signature strength — win the title
      # TIER, not merely land the doc somewhere in the pool. Guarded to tokens
      # AND words ≥4 chars + a strict 0.88 threshold (measured: real typos score
      # ≥0.95, unrelated words ≤0.73 — a wide, safe gap, so no false promotions).
      String.length(token) >= 4 ->
        Enum.any?(words, fn w ->
          String.length(w) >= 4 and String.jaro_distance(w, token) >= 0.88
        end)

      true ->
        false
    end
  end

  defp hydrate(_client, _dataset, [], _opts), do: {:ok, []}
  defp hydrate(client, dataset, keys, opts), do: client.get_json(dataset, keys, opts)

  # Read the embedded Barkpark _id + _type off the Indx doc and re-read the
  # authoritative row from Postgres, workspace+dataset-scoped via threaded opts.
  # Drop docs we cannot map. `Content.get_document/4` is the scoped read on the
  # integration base; passing the tenant `:workspace_id`/`:project_id` opts
  # forwards them into `scope_to_workspace_or_global/3`, so the index can never
  # surface another workspace's row even when two workspaces share a dataset
  # STRING. The index is a relevance oracle, Postgres is the source of truth.
  # Hydrate a page of light index records into authoritative Postgres docs in a
  # SINGLE scoped query (was N per-hit reads — an N+1 that dominated search
  # latency). Preserves the re-rank ORDER, and keeps `get_document/4`'s
  # type-match semantics (a row whose Postgres `type` differs from the index's
  # `_type` is dropped). The batch read is tenant-scoped via
  # `Content.get_documents_by_ids/3` (same P0 leak guard), so it can never
  # surface another workspace's row.
  defp hydrate_documents(indx_docs, scope, opts) do
    pairs =
      indx_docs
      |> Enum.map(&id_type_pair/1)
      |> Enum.reject(&is_nil/1)

    doc_ids = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    by_id = Content.get_documents_by_ids(doc_ids, scope, scope_opts(opts))

    pairs
    |> Enum.map(fn {id, type} ->
      case Map.get(by_id, id) do
        %{type: ^type} = doc -> doc
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp id_type_pair(indx_doc) when is_map(indx_doc) do
    id = to_string_or_nil(Map.get(indx_doc, "_id") || Map.get(indx_doc, "id"))
    type = to_string_or_nil(Map.get(indx_doc, "_type") || Map.get(indx_doc, "type"))

    if is_binary(id) and id != "" and is_binary(type) and type != "" do
      {id, type}
    else
      nil
    end
  end

  defp id_type_pair(_other), do: nil

  # Reported total — ALWAYS recomputed as ONE scoped Postgres count over the
  # ranked candidate id set, never `length(ranked)`.
  #
  # The candidate pool is NOT tenant-scoped. `Indexer.current_dataset/1` keys the
  # live Indx dataset on the Barkpark dataset STRING alone, so every workspace
  # sharing a dataset name shares ONE pool — the situation `hydrate_documents/3`
  # above is written for ("even when two workspaces share a dataset STRING").
  # Hydration re-reads through `Content.get_documents_by_ids/3` and drops the
  # other tenants' rows, so the HITS were always correct.
  #
  # The COUNT was not. This used to return the raw pool length for every
  # non-grant caller, on the premise that "for an ordinary read the
  # candidate-pool length is the honest match count". That premise holds only if
  # the pool is tenant-scoped, and it is dataset-scoped — so workspace A's search
  # reported a total that counted workspace B's matching documents while
  # returning only A's rows: the existence and volume of another tenant's
  # content, disclosed as a number. Same class as the `Content.Analytics`
  # type_census leak (task-c6d2e34c64100678), one boundary over.
  #
  # `count_documents_by_ids/3` applies the SAME stack the hydration read does
  # (dataset + workspace/project + owner + grant), so the total can never exceed
  # what the caller may actually see — and the grant-derived case it already
  # covered is unchanged, now as one branch of a rule instead of the exception.
  defp total_for(ranked, scope, opts) do
    ranked_ids =
      ranked
      |> Enum.map(&id_type_pair/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()

    Content.count_documents_by_ids(ranked_ids, scope, scope_opts(opts))
  end

  # Forward the tenant-scope opts AND the caller_context into the authoritative
  # Postgres read. Tenancy keys cannot bypass `scope_to_workspace_or_global/3`
  # (the P0 leak guard); the caller_context lets `get_documents_by_ids/3`'s
  # row/ownership ACL (`scope_to_owner/2`) admit the caller's OWN owner_scoped
  # rows — parity with the Postgres `DocumentsRetriever`. Without it a logged-in
  # user's Indx search dropped their own owned docs (a nil caller now fails
  # CLOSED to unowned-only — over-restrictive, the LOW seam this closes). It is
  # NOT a leak: a missing/anonymous caller still resolves to unowned-only.
  # `:grant_scoped` rides through so the hydration read
  # (`get_documents_by_ids/3` → `maybe_scope_to_grants/2`) narrows a
  # grant-derived caller's ROWS, and `count_documents_by_ids/3` narrows the
  # reported total — parity with the Postgres `DocumentsRetriever` seal.
  defp scope_opts(opts),
    do: Keyword.take(opts, [:workspace_id, :project_id, :caller_context, :grant_scoped])

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
