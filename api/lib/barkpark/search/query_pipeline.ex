defmodule Barkpark.Search.QueryPipeline do
  @moduledoc """
  Unified search pipeline: parse → expand → retrieve → recover → highlight.
  """

  alias Barkpark.Content

  alias Barkpark.Search.{
    DocumentsRetriever,
    Highlighter,
    QueryParser,
    Retrievers,
    SurfaceConfigs,
    Synonyms,
    TypoPolicy
  }

  @type result :: %{
          hits: list(),
          total: non_neg_integer(),
          parsed: map(),
          highlights: map(),
          recovery: String.t() | nil,
          corrected_to: String.t() | nil,
          engine_used: String.t() | nil,
          match: String.t() | nil,
          ms: non_neg_integer()
        }

  @spec search(String.t(), String.t(), map(), keyword()) :: {:ok, result()}
  def search(surface, scope, context, opts \\ []) when is_binary(surface) and is_binary(scope) do
    # TIMED: the search READ path had ZERO telemetry — it computed `ms` locally
    # (t0/System.monotonic_time below) for the response body but never fired a
    # `:telemetry` event, so "what is p95 of a search?" was unanswerable and the
    # only search event ([:barkpark, :search, :intel, :record]) is a WRITE with no
    # `workspace_id`. This is the single choke point every documents+media search
    # caller funnels through, so one `:telemetry.span` here covers them all.
    # Mirrors the D12 content-write precedent (content/mutations.ex): the span
    # emits `[:barkpark, :search, :query, :start | :stop | :exception]` with a
    # `:duration`; BarkparkWeb.Telemetry subscribes a Prometheus histogram to
    # `:stop` (p95 via histogram_quantile). `workspace_id` — already live in
    # `opts` via `scope_opts/1` — tags per-workspace search volume/latency; nil
    # (anonymous / unscoped caller) coerces to "global" so the Prometheus tag is
    # always present and never crashes the reporter handler.
    workspace_id = Keyword.get(opts, :workspace_id) || "global"
    meta = %{surface: surface, scope: scope, workspace_id: workspace_id}

    :telemetry.span([:barkpark, :search, :query], meta, fn ->
      {do_search(surface, scope, context, opts), meta}
    end)
  end

  defp do_search(surface, scope, context, opts) do
    t0 = System.monotonic_time(:microsecond)
    # Resolve the surface config for the CALLER'S workspace (charter D63). The
    # resolved `workspace_id` already rides in `opts` (set by scope_opts/1 from
    # `current_workspace`); thread it STRAIGHT — never coerce to nil, or a
    # per-workspace admin's search tuning would be attributed on write yet never
    # reach the read path (the W5 functional regression this closes). A nil
    # `workspace_id` (anonymous / unscoped) still resolves the global row.
    config = SurfaceConfigs.get(surface, scope, Keyword.get(opts, :workspace_id))
    raw_query = Map.get(context, :query, "") || ""
    parsed = QueryParser.parse(raw_query)

    {parsed, corrected_to} =
      expand_synonyms(surface, scope, parsed, Keyword.get(opts, :workspace_id))

    {hits, total, recovery, engine_meta, engine_used} =
      case surface do
        "documents" ->
          search_documents(scope, parsed, config, context, opts)

        "media" ->
          {h, t, r} = search_media(scope, parsed, config, context, opts)
          {h, t, r, %{}, nil}

        _ ->
          {[], 0, nil, %{}, nil}
      end

    highlights = highlight_hits(surface, hits, parsed, config, scope, opts)
    ms = div(System.monotonic_time(:microsecond) - t0, 1000)

    {:ok,
     %{
       hits: hits,
       total: total,
       parsed: QueryParser.to_map(parsed),
       highlights: highlights,
       recovery: recovery,
       # The canonical corrected term when a LEARNED/synonym correction fired
       # for a query term (nil otherwise). The UI shows "Showing results for …".
       corrected_to: corrected_to,
       # `facets` comes from WHICHEVER retriever answered — it is NOT Indx-only.
       # (An earlier version of this comment claimed it was, exactly backwards.)
       # `DocumentsRetriever.search/4` returns `%{facets: facets}`: its
       # `count_and_facets/1` computes all four dimensions over the caller's
       # full, tenant-scoped match set. The Indx retriever now returns `%{}` and
       # DROPS the engine's buckets — they were computed over an index keyed on
       # the dataset STRING and shared across workspaces, so they leaked another
       # tenant's author/category strings (see `Plugins.Indx.Retriever`). So
       # `facets` is non-null only when the Postgres engine answered.
       # `truncation` genuinely IS Indx-only, and is now always absent because
       # that path no longer emits it.
       facets: Map.get(engine_meta, :facets),
       truncation: Map.get(engine_meta, :truncation),
       # "all" when every word had to match, "any" when one word was enough
       # (the caller asked, or `match_any` recovery ran). nil for a browse and
       # for an engine that does not report it.
       match: Map.get(engine_meta, :match),
       # Which retriever ACTUALLY served the returned hits — "postgres" whenever
       # the served result came from the Postgres retriever, even when the
       # caller asked for another engine (zero-hit recovery, the D3-b tenant
       # gate, an unregistered engine). The client heuristic guessing this has
       # shipped dead code twice; the pipeline is the only place that knows.
       engine_used: engine_used,
       ms: ms
     }}
  end

  defp expand_synonyms(surface, scope, parsed, workspace_id) do
    positive = Map.get(parsed, :terms, []) ++ Map.get(parsed, :phrases, [])

    if positive == [] do
      {parsed, nil}
    else
      # Each term's synonyms are its alternatives: the retriever matches a term
      # OR any of its synonyms, never a synonym as one more word every document
      # must hold. `terms` still lists them, as `parsedQuery` always has.
      # Every word's synonyms and the correction in one read (Synonyms.expand_terms/4),
      # not two reads per word.
      {terms_of, corrected_to} = Synonyms.expand_terms(surface, scope, positive, workspace_id)

      alternatives =
        Map.new(positive, fn term ->
          {term,
           terms_of
           |> Map.get(term, [])
           |> Enum.reject(&(&1 in positive or &1 == ""))
           |> Enum.uniq()}
        end)

      extra = alternatives |> Map.values() |> List.flatten() |> Enum.uniq()

      # The corrected term is the canonical to_query of the FIRST positive term
      # for which an enabled synonym fired — null when nothing matched.

      {Map.put(%{parsed | terms: parsed.terms ++ extra}, :alternatives, alternatives),
       corrected_to}
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
        types: Keyword.get(opts, :types),
        perspective: perspective,
        limit: limit,
        offset: offset,
        relaxed: false,
        workspace_id: Keyword.get(opts, :workspace_id),
        project_id: Keyword.get(opts, :project_id),
        # Row/ownership ACL (Phase 4, core-auth): thread the caller so the
        # full-text retriever can drop another user's owner_scoped rows. A nil
        # caller now FAILS CLOSED — scope_to_owner/2 restricts to unowned rows
        # (owner_id IS NULL) only; byte-identical only for non-owner_scoped types
        # (whose rows are all unowned), never a window onto another owner's rows.
        caller_context: Keyword.get(opts, :caller_context),
        # Grant row-narrowing (airdrop-grants Layer 2). Thread the grant flag so
        # BOTH retrievers can apply `Scope.maybe_scope_to_grants/2`. This single
        # thread-point covers the primary retrieve (:130), try_drop_tokens (:192)
        # and try_typo_widen (:207) — they all reuse `retriever_opts`. Without it
        # a grant-derived caller's search dropped the flag before either retriever
        # and saw out-of-grant hits (the ag-search-grant-leak deny). nil/absent =
        # ordinary read (no narrowing), so members/tokens/anonymous are unchanged.
        grant_scoped: Keyword.get(opts, :grant_scoped),
        # Retrieval column projection (search-latency slice a). The caller's
        # `?fields=` allowlist — threaded to the Postgres retriever so a hit set
        # it will render+project down to a few scalars is SELECTed without the
        # heavy `content` blobs (a paper's body_html is ~37KB/row; at limit=100
        # that dominates the DB→Elixir transfer + jsonb decode the pipeline `ms`
        # measures). The DB-level twin of `Content.Envelope.project/2`: it only
        # ever DROPS content keys the caller did not ask for, so the rendered
        # envelope is byte-identical. nil/absent → the full struct (unchanged).
        fields: Keyword.get(opts, :fields),
        # task-3623955d22974d71: every word must match (`:all`) unless the
        # caller asked for `:any`. Field filters and named facets
        # (task-c7395e0d27e1121b) ride to the retriever with the same opts, so
        # every recovery pass keeps them.
        match: Keyword.get(opts, :match, :all),
        filter_map: Keyword.get(opts, :filter_map),
        # `?order=` instead of relevance (task-5ddc3e08684f0d48): `{order,
        # collation}` from QueryController.search_order/3, or nil.
        order: Keyword.get(opts, :order),
        facet_fields: Keyword.get(opts, :facet_fields),
        # With a field filter, the retriever counts the words' matches without
        # the filter up to this many (`meta.text_count`), so the recovery
        # choice below is the one the unfiltered search makes.
        text_count_cap: Map.get(config, "low_hit_threshold", 3),
        # The type-ahead fast path (task-7e7891dbf1f488ee): no facets, a small
        # ranking pool, no stored vector read, and no recovery pass below.
        suggest: Keyword.get(opts, :suggest, false),
        # `?boost=popularity` (task-5feac4e826cff9a5): the Postgres retriever
        # adds the document's view score to relevance. Other engines ignore it.
        boost: Keyword.get(opts, :boost)
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

    # Engine honesty: the requested engine only counts as SERVED when its own
    # retriever module answered. Both silent postgres substitutions — the D3-b
    # tenant gate above and Retrievers.resolve/1's unknown-engine fallback —
    # resolve to DocumentsRetriever, so the module identity IS the truth.
    primary_engine = if retriever == DocumentsRetriever, do: "postgres", else: engine

    {hits, total, engine_meta} = retriever.search(scope, parsed, config, retriever_opts)

    strategy = Map.get(config, "zero_hit_strategy", "drop_tokens")
    # Thin-results threshold: when a query returns SOME but few hits, widening
    # the fuzzy net often surfaces near-miss docs the strict pass dropped. Fires
    # below this count (the zero-hit path below is unchanged).
    low_hit_threshold = Map.get(config, "low_hit_threshold", 3)

    # A field filter leaves fewer hits; it does not make the words wrong. So
    # with a filter, recovery follows the words' match WITHOUT the filter
    # (`text_count`, set by the retriever only for a filtered search, counted
    # up to `low_hit_threshold`): enough matches there and no recovery runs,
    # because widening would add near misses the unfiltered search never
    # shows (task-6496d34cb0a43ca7) and the passes cost seconds
    # (task-b2a224d49a3f27eb). A few matches there and the filtered search
    # gets the one typo-widened pass the unfiltered search would get, not the
    # zero-hit chain.
    words_found = Map.get(engine_meta, :text_count)

    {total_for_recovery, filter_narrowed?} =
      cond do
        not is_integer(words_found) -> {total, false}
        words_found >= low_hit_threshold -> {total, true}
        total == 0 and words_found > 0 -> {words_found, false}
        true -> {total, false}
      end

    # Every branch also reports which retriever the FINAL hits came from: the
    # recovery passes (recover_documents / try_typo_widen) run the Postgres
    # DocumentsRetriever regardless of the primary engine, so a successful
    # recovery is a served-by-postgres answer — the exact silent substitution
    # (indx request → empty → postgres re-run → happy 200 wearing indx's name)
    # this field exists to make visible.
    {final_hits, final_total, recovery, engine_used, final_meta} =
      cond do
        # No recovery configured, or a suggestion: the type-ahead answers from
        # one pass, so a keystroke never pays for a recovery chain.
        total == 0 and (strategy == "none" or retriever_opts[:suggest] == true) ->
          {hits, total, nil, primary_engine, %{}}

        retriever_opts[:suggest] == true ->
          {hits, total, nil, primary_engine, %{}}

        filter_narrowed? ->
          {hits, total, nil, primary_engine, %{}}

        # Zero-hit path. When every word had to match: the typo-widened pass
        # under the same rule, then any word (`match_any`, ranked by how many
        # words a document holds), then the drop_tokens / typo_widen chain.
        total_for_recovery == 0 ->
          case recover_documents(scope, parsed, config, retriever_opts, strategy) do
            {rh, rt, recovery, meta} -> {rh, rt, recovery, "postgres", meta}
            nil -> {hits, total, nil, primary_engine, %{}}
          end

        # Thin-results path — widen fuzzy on a positive-but-small result set and
        # keep it ONLY when it strictly improves the hit count. Postgres engine
        # ONLY: try_typo_widen runs the Postgres retriever, and Indx is already
        # natively typo-tolerant, so widening an Indx result set would just
        # replace its hits with Postgres ones (a surprising engine swap). The
        # zero-hit path above still falls back to Postgres for any engine.
        engine == "postgres" and total_for_recovery < low_hit_threshold and strategy != "none" ->
          case try_typo_widen(scope, parsed, config, retriever_opts, strategy) do
            {rh, rt, _r, meta} when rt > total -> {rh, rt, "typo_widen", "postgres", meta}
            _ -> {hits, total, nil, primary_engine, %{}}
          end

        true ->
          {hits, total, nil, primary_engine, %{}}
      end

    # Carry the PRIMARY retriever's engine meta (Indx facets + truncation)
    # regardless of zero-hit recovery — facets describe the whole dataset, so
    # they stay meaningful even when the text matched nothing. `match` names
    # the rule of the pass that SERVED the hits.
    engine_meta =
      case Map.fetch(final_meta, :match) do
        {:ok, m} -> Map.put(engine_meta, :match, m)
        :error -> engine_meta
      end

    {final_hits, final_total, recovery, engine_meta, engine_used}
  end

  defp recover_documents(scope, parsed, config, opts, strategy) do
    with nil <- try_typo_widen_all(scope, parsed, config, opts, strategy),
         nil <- try_match_any(scope, parsed, config, opts, strategy),
         nil <- try_drop_tokens(scope, parsed, config, opts, strategy),
         nil <- try_typo_widen(scope, parsed, config, Keyword.put(opts, :match, :any), strategy) do
      nil
    end
  end

  # Under `:all`, the widened typo pass keeps the rule: every word must still
  # match, each one now a little more loosely.
  defp try_typo_widen_all(scope, parsed, config, opts, strategy) do
    if all_words?(opts) and positive_count(parsed) > 1,
      do: try_typo_widen(scope, parsed, config, opts, strategy),
      else: nil
  end

  # task-3623955d22974d71: when no document holds every word, any word will
  # do. The ranking puts the documents that hold most of the words first.
  defp try_match_any(scope, parsed, config, opts, strategy)
       when strategy in ["drop_tokens", "typo_widen"] do
    if all_words?(opts) and positive_count(parsed) > 1 do
      {hits, total, meta} =
        DocumentsRetriever.search(scope, parsed, config, Keyword.put(opts, :match, :any))

      if total > 0, do: {hits, total, "match_any", meta}
    end
  end

  defp try_match_any(_scope, _parsed, _config, _opts, _strategy), do: nil

  defp all_words?(opts), do: Keyword.get(opts, :match, :all) not in [:any, "any"]

  defp positive_count(parsed),
    do:
      length(
        Enum.uniq(
          Map.get(parsed, :terms, []) --
            List.flatten(Map.values(Map.get(parsed, :alternatives, %{})))
        )
      ) + length(Map.get(parsed, :phrases, [])) + length(Map.get(parsed, :prefixes, []))

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

      {hits, total, meta} = DocumentsRetriever.search(scope, dropped, config, opts)

      if total > 0 do
        {hits, total, "drop_tokens", meta}
      else
        try_drop_tokens(scope, dropped, config, opts, "drop_tokens")
      end
    end
  end

  defp try_drop_tokens(_scope, _parsed, _config, _opts, _strategy), do: nil

  # The widen pass IS typo tolerance (it re-runs the query at the relaxed
  # pg_trgm threshold), so `typo_policy.enabled => false` turns it off — a
  # config that suppresses the fuzzy arms and then re-admits the same near
  # misses through recovery would honour the knob only until it mattered.
  # `drop_tokens` is untouched: dropping a term is not a typo correction.
  defp try_typo_widen(scope, parsed, config, opts, strategy)
       when strategy in ["drop_tokens", "typo_widen"] do
    if TypoPolicy.enabled?(config) do
      relaxed_opts = Keyword.put(opts, :relaxed, true)
      {hits, total, meta} = DocumentsRetriever.search(scope, parsed, config, relaxed_opts)

      if total > 0 do
        {hits, total, "typo_widen", meta}
      end
    end
  end

  defp try_typo_widen(_scope, _parsed, _config, _opts, _strategy), do: nil

  defp search_media(_scope, _parsed, _config, _context, _opts) do
    # Media search runs through Media.Delivery.Search.search/2 with pipeline opts; hits filled by caller.
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
            case try_typo_widen_media(parsed, search_fn, strategy, config) do
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

  defp try_typo_widen_media(parsed, search_fn, strategy, config)
       when strategy in ["drop_tokens", "typo_widen"] do
    if TypoPolicy.enabled?(config) do
      {hits, total} = search_fn.(parsed, true)

      if total > 0 do
        {hits, total, "typo_widen"}
      end
    end
  end

  defp try_typo_widen_media(_parsed, _search_fn, _strategy, _config), do: nil

  defp highlight_hits("documents", docs, parsed, config, scope, opts) do
    # Resolve each hit type's schema ONCE so the highlighter can drop only the
    # `content.*` highlight fields THIS caller may not see (field visibility),
    # instead of over-redacting every `content.*` field. Memoised per distinct
    # type across the hit set.
    schema_by_type =
      docs
      |> Enum.map(&doc_type/1)
      |> Enum.uniq()
      |> Map.new(fn type -> {type, resolve_schema(type, scope, opts)} end)

    Highlighter.highlight_documents(
      docs,
      parsed,
      config,
      Keyword.get(opts, :caller_context),
      fn type -> Map.get(schema_by_type, type) end
    )
  end

  defp highlight_hits("media", files, parsed, config, _scope, opts) do
    docs = Keyword.get(opts, :asset_docs, %{})
    Highlighter.highlight_media(files, parsed, config, docs)
  end

  defp highlight_hits(_, _, _, _, _, _), do: %{}

  defp doc_type(%{type: t}), do: t
  defp doc_type(_), do: nil

  defp resolve_schema(nil, _scope, _opts), do: nil

  defp resolve_schema(type, scope, opts) do
    schema_opts = [
      workspace_id: Keyword.get(opts, :workspace_id),
      project_id: Keyword.get(opts, :project_id)
    ]

    case Content.get_schema(type, scope, schema_opts) do
      {:ok, schema} -> schema
      _ -> nil
    end
  end
end
