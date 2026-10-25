defmodule Barkpark.Search.DocumentsRetriever do
  @moduledoc false

  @behaviour Barkpark.Search.Retriever

  import Ecto.Query

  import Barkpark.Content.Scope,
    only: [
      scope_to_workspace_or_global: 3,
      scope_to_owner: 2,
      maybe_scope_to_grants: 2
    ]

  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Search.{Fold, SearchRefresh, TypoPolicy}

  # Default ranking-pool size (Barkpark Cloud P4 / Move B). The expensive
  # per-row ranking computation (`ts_rank` + `similarity`) runs only on this
  # many candidates, picked cheaply via the GIN match + recency. Without the
  # bound, a broad query that matches 10k rows pays ranking cost on all of
  # them before the LIMIT; with the bound, cost stays constant regardless of
  # corpus size. 500 is generous headroom — the user-visible LIMIT defaults to
  # 50 and never exceeds 200, and recency-shifted candidates are exactly the
  # ones a relevance score is most likely to crown.
  @default_ranking_pool_size 500

  # Heavy `content` keys that dominate the DB→Elixir transfer + jsonb decode of
  # the RETURNED rows. Measured on guerrilla (barkpark_prod, 2026-07-18): a
  # paper's `content` JSON averages 87,916 bytes, of which the heavy keys are
  # ~98.8% — stripping them drops the per-row payload to 1,040 bytes. At
  # limit=100 that is ~8.6MB → ~102KB of content text shipped Elixir-ward and
  # jsonb-decoded per keystroke (the returned-row half of the search latency; a
  # calm-box limit=5→100 delta of +132ms). When a `?fields=` caller's allowlist
  # needs NONE of these keys, `maybe_light_select/2` drops them at the DB so only
  # the scalar content the envelope keeps crosses the wire. The DB detoast itself
  # is already paid by the ranking ORDER BY on the keyword path, so this is pure
  # ship+decode savings there. MUST stay in sync with the drop fragment below.
  @heavy_content_keys ~w(body body_html blocks cells)

  # A search query carries its words as values, so it is prepared unnamed and
  # Postgres plans it for the values it is sent (the tsquery constants and the
  # LIKE patterns), as `Barkpark.Groq.DocumentSource` does. A named statement
  # switches to a generic plan after five runs, which cannot see how selective
  # a word is.
  @planned_per_call [prepare: :unnamed]

  @search_random_page_cost "1.1"

  # The ranking pool of a suggestion request: the type-ahead shows a handful
  # of rows, so it ranks the 100 best by the cheap signals, not 500.
  @suggest_pool_size 100

  @impl Barkpark.Search.Retriever
  @spec search(String.t(), map(), map(), keyword()) ::
          {[struct()], non_neg_integer(), map()}
  def search(scope, parsed, config, opts) when is_binary(scope) do
    terms = search_terms(parsed)
    type = Keyword.get(opts, :type)
    perspective = Keyword.get(opts, :perspective, :published)
    # Floor at 1 / 0: a negative :limit/:offset (from an unclamped `?limit=-1`)
    # would emit `LIMIT -1`/`OFFSET -1`, which Postgres rejects → 500. Ceil the
    # offset too: a giant `?offset=1000000000` would force Postgres to walk and
    # discard the rows — a free DoS amplifier on public browse — so cap it at
    # 100_000; beyond the cap the page is empty.
    limit = Keyword.get(opts, :limit, 50) |> min(200) |> max(1)
    offset = Keyword.get(opts, :offset, 0) |> max(0) |> min(100_000)
    relaxed = Keyword.get(opts, :relaxed, false)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    pool_size = Keyword.get(opts, :ranking_pool_size, @default_ranking_pool_size)

    browse? =
      terms == [] and Map.get(parsed, :phrases, []) == [] and
        Map.get(parsed, :prefixes, []) == []

    # Browse (empty query) enumerates the scoped published set — mirrors Indx's
    # empty-query browse so the finder's landing has docs + facets on Postgres
    # too. A real query adds the full-text/trigram match.
    base =
      from(d in Document, as: :search_doc)
      |> scope_to_dataset(scope, project_id, workspace_id)
      |> scope_to_workspace_or_global(workspace_id, project_id)
      # Row/ownership ACL (Phase 4, core-auth). Applied UNCONDITIONALLY: it is
      # byte-identical for non-owner_scoped types because their rows carry a
      # NULL owner_id (stamped ONLY on owner_scoped writes), and a NULL owner is
      # always visible. The full-text retriever can't gate per-type (a hit set
      # may span many types), so — like get_documents_by_ids — it scopes by
      # owner regardless. A nil caller_context now FAILS CLOSED — scope_to_owner/2
      # restricts to unowned rows (owner_id IS NULL) only; a no-op solely for
      # non-owner_scoped types (all-unowned), never another owner's rows.
      |> scope_to_owner(Keyword.get(opts, :caller_context))
      # Grant row-narrowing (airdrop-grants Layer 2). A NO-OP unless the caller
      # is grant-derived (`opts[:grant_scoped]`, threaded from the pipeline's
      # retriever_opts). Applied ONCE on `base` — count (below) and facets both
      # derive from `base`, so this single clause seals results + count + facets
      # for EVERY consumer of `Content.search_documents` (SearchController,
      # SearchChannel, federated) at once. Fail-closed via `scope_to_grants`'
      # `where: false` on an undecidable grant.
      |> maybe_scope_to_grants(opts)
      # Schema-visibility gate (search-template W10 / D62). Anonymous callers
      # are restricted to PUBLIC-visibility schema types — the search twin of
      # QueryController's `preview? or authed? or schema_public?` gate, which
      # 404s an anonymous read of a private (or schemaless) type while this
      # path used to serve full private bodies (live: `?type=session` returned
      # cwd/machine/git_head to a tokenless caller). Same one-clause-on-`base`
      # law as the grant clause above: results, count AND facets all derive
      # from `base`, so this seals flat/scoped HTTP, federated, the WS channel,
      # loopback AND the pipeline's drop_tokens/typo_widen recovery retries
      # (they reuse retriever_opts) in one place — never duplicated per
      # transport. ALLOWLIST, not denylist: it matches the query route's live
      # 404 for schemaless types and fails closed on any future visibility
      # value; an empty allowlist yields an empty result. Bypassed for an
      # authenticated principal (`:api_token`/`:user`) EXCEPT the public-read
      # tier, which is clamped exactly like an anonymous caller — EXACT parity
      # with query_controller.ex's `authed?`, which moved in the same commit
      # (the "filed separately" this comment used to name is now discharged).
      |> restrict_anonymous_to_public_types(scope, opts)

    # Which full-text index this caller matches against (owner ruling #20,
    # task-3c68de39a19285c4). Only an admin (or the internal sentinel) may
    # match words inside private fields; everyone else matches the public
    # index, so a word that occurs only in a field they cannot read neither
    # matches nor moves the count. A search of one type whose schemas restrict
    # no field reads the full vector: the public vector of every such document
    # is NULL, so the two are the same index, and only the full one is a plain
    # GIN probe.
    index = text_index(Keyword.get(opts, :caller_context), type, Keyword.get(opts, :types))

    # A schema change that made a field restricted on a large type recomputes
    # the public vectors in batches after the write (task-9d83c3e0c3b8fabf).
    # Until that is done, a stale vector may still hold a word the field now
    # hides, so a non-admin text search leaves those documents out.
    base = exclude_pending_refresh(base, Keyword.get(opts, :caller_context), browse?)
    match = match_mode(opts)
    suggest? = Keyword.get(opts, :suggest, false) == true
    groups = if browse?, do: [], else: term_groups(parsed)
    # The ranking pool also weighs a 1-letter last word (`pool_hint/2`).
    pool_groups = groups ++ pool_hint(parsed, groups)

    # A text search compares the type without its btree index. With the index,
    # Postgres reads every document of the type and runs the text match on each
    # row, decompressing its stored vector, which its cost model counts as
    # nearly free: 198 ms for `lydbok` over 10,592 products, against 26 ms
    # through the GIN and trigram indexes. A browse keeps the index.
    base =
      cond do
        is_nil(type) -> base
        browse? -> where(base, [d], d.type == ^type)
        true -> where(base, [d], fragment("(?::text || '') = ?", d.type, ^type))
      end

    # Optional type allowlist (the finder's content types) — applied to `base`
    # so results, count, AND facets are all consistent over the same set.
    types = Keyword.get(opts, :types)
    base = if is_list(types) and types != [], do: where(base, [d], d.type in ^types), else: base
    base = perspective_filter(base, perspective)

    # The query API's field filters (task-c7395e0d27e1121b). Applied to `base`,
    # so they run before the limit, and the count and every facet describe the
    # filtered match.
    filter_map = Keyword.get(opts, :filter_map)
    filtered? = is_map(filter_map) and map_size(filter_map) > 0
    text_base = base
    base = apply_field_filters(base, filter_map, type, scope, opts)

    with_trgm_thresholds(browse?, config, relaxed, fn ->
      # Count + all four facet dimensions in ONE round trip over the match set
      # (search-latency slice c). Runs BEFORE the retrieve so its exact `count`
      # can gate the bounded-pool self-subquery below. Facets + count stay on the
      # FULL match set (not the ranking pool): the user wants "this query matched
      # 1.2k items across these facets", not "the top 500 break down this way".
      #
      # The match runs in two steps. First the words: the full-text index and
      # the document id, one GIN probe that needs no recheck of the stored
      # vector, so a broad word costs a visit to its matching rows only. When
      # no document holds the words (or on the widened recovery pass), the
      # substring, fold and typo arms on the search title and slug join in.
      #
      # A suggestion request (`:suggest`, the type-ahead fast path) skips the
      # facets and, when the words find nothing, tries only a near-miss of a
      # word in the search names (the trigram index), never the full second
      # step.
      count_fun =
        if suggest?,
          do: fn q -> {count_only(q), %{}} end,
          else: fn q -> count_and_facets(q, scope, opts) end

      fallback_arms = if suggest?, do: :names_typo, else: :broad

      # A field filter narrows the hits of the words; it does not make the
      # words wrong. So with a filter, the choice between the words and the
      # wider arms is the one the search makes without the filter: when a
      # document holds the words but the filter leaves none, the answer is
      # empty, not a typo match (task-6496d34cb0a43ca7). `text_count` is how
      # many documents the words find without the filter, counted up to
      # `:text_count_cap`, so the pipeline can make the same choice for its
      # recovery passes.
      text_probe = text_probe(filtered? and not suggest? and not relaxed, opts)

      match_on = fn q, arms ->
        where_match(q, parsed, groups, config, relaxed, index, match, arms)
      end

      {base, count, facets, near_miss?, text_count, arms} =
        if browse? do
          {count, facets} = count_fun.(base)
          {base, count, facets, false, nil, nil}
        else
          words = match_on.(base, :words)
          {count, facets} = if relaxed, do: {0, %{}}, else: count_fun.(words)
          text_count = text_probe.(count, fn -> match_on.(text_base, :words) end)

          if count > 0 or (is_integer(text_count) and text_count > 0) do
            {words, count, facets, false, text_count, :words}
          else
            wider = match_on.(base, fallback_arms)
            {count, facets} = count_fun.(wider)
            text_count = text_probe.(count, fn -> match_on.(text_base, fallback_arms) end)
            {wider, count, facets, true, text_count, fallback_arms}
          end
        end

      # Bounded ranking pool: for real queries, narrow to a cheap-signal
      # candidate set BEFORE running the expensive ranking ORDER BY. Browse
      # stays unbounded (its only ORDER BY is `updated_at DESC`). The pool is
      # skipped when the match set fits inside it, and it always holds the
      # requested page, so `offset` pages through the whole match set rather
      # than stopping at the pool's edge.
      pool = if(suggest?, do: @suggest_pool_size, else: pool_size)

      # Paging stays one order across pages: the pool's documents, ranked, then
      # every other match, ranked. A page inside the pool reads the pool only;
      # a deeper page ranks the whole match set with the pool first, so
      # `offset` walks the whole match without a repeat or a gap.
      {ranking_input, lead} =
        cond do
          browse? or count <= pool ->
            {base, []}

          offset + limit <= pool and filtered? ->
            {filtered_pool(base, match_on.(text_base, arms), pool, pool_groups), []}

          offset + limit <= pool ->
            {bounded_pool(base, pool, pool_groups), []}

          true ->
            {base, [{:desc, in_pool_key(base, pool, pool_groups)}]}
        end

      # An empty match ranks nothing. A recovery pass that finds no document
      # (task-722697f4650b2a21) used to run the ranking statement anyway, a
      # second evaluation of the whole match for an empty page.
      docs =
        if count == 0 do
          []
        else
          ranking_input
          |> order_rank(
            parsed,
            groups,
            config,
            if(suggest?, do: :none, else: index),
            near_miss?,
            lead,
            Keyword.get(opts, :boost),
            held_key(near_miss? and not suggest?, groups, index, match)
          )
          |> limit(^limit)
          |> offset(^offset)
          |> maybe_light_select(Keyword.get(opts, :fields))
          |> Repo.all(@planned_per_call)
        end

      meta = %{facets: facets, match: if(browse?, do: nil, else: Atom.to_string(match))}
      meta = if is_integer(text_count), do: Map.put(meta, :text_count, text_count), else: meta

      {docs, count, meta}
    end)
  end

  # With a field filter, how many documents the words match without it, up to
  # `:text_count_cap` (at least 1). A filtered count at or over the cap already
  # answers that, so the probe runs only below it, and it stops at the cap.
  defp text_probe(false, _opts), do: fn _count, _query_fun -> nil end

  defp text_probe(true, opts) do
    cap = max(Keyword.get(opts, :text_count_cap, 1), 1)

    fn
      count, _query_fun when count >= cap ->
        count

      _count, query_fun ->
        capped =
          query_fun.()
          |> exclude(:order_by)
          |> exclude(:select)
          |> select([d], %{id: d.id})
          |> limit(^cap)

        from(s in subquery(capped), select: count())
        |> Repo.one(@planned_per_call)
    end
  end

  # `:all` (the default): a document must match every word of the query.
  # `:any`: a document matches when it matches one word. The pipeline asks for
  # `:any` only when `:all` found nothing (task-3623955d22974d71).
  defp match_mode(opts) do
    case Keyword.get(opts, :match, :all) do
      m when m in [:any, "any"] -> :any
      _ -> :all
    end
  end

  # The substring and typo arms use pg_trgm's `%` and `<%` operators, which the
  # trigram GIN indexes on the search title serve. Their thresholds are
  # settings, so the search runs in a transaction that sets them for itself
  # only: `similarity_threshold` is the surface's `typo_policy` floor,
  # `word_similarity_threshold` its word-level twin. A browse runs no trigram
  # arm and skips the transaction.
  #
  # The same transaction sets `random_page_cost` to 1.1, the value Postgres
  # documents for solid-state storage, in place of the default 4. At 4 the
  # planner read every row of the table for a common word (154 ms for `har`
  # over 47,361 documents); at 1.1 it reads the bitmap of the word's index
  # entries (35 ms). It also turns off the sequential scan, which only loses
  # its place to an index path: every arm of the match has an index, and the
  # cost model counts the decompression of each stored vector as free, so for
  # a word in nearly every document (`norsk`, in the publisher's name) it chose
  # to read all 47,361 rows (277 ms) over the word's bitmap (28 ms).
  #
  # It also turns off parallel workers. The names vector arm
  # (`bp_search_names_vector/2`) is costed as a `to_tsvector` call per row, so
  # its plans cost more and crossed the parallel threshold, while the work
  # stays the same index bitmap: starting two workers made `barnebok` 11 to
  # 16 ms against 6 ms serial on the gyldendal-no copy.
  defp with_trgm_thresholds(true, _config, _relaxed, fun), do: fun.()

  defp with_trgm_thresholds(false, config, relaxed, fun) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!(
          "SELECT set_config('pg_trgm.similarity_threshold', $1, true), " <>
            "set_config('pg_trgm.word_similarity_threshold', $2, true), " <>
            "set_config('random_page_cost', '#{@search_random_page_cost}', true), " <>
            "set_config('enable_seqscan', 'off', true), " <>
            "set_config('max_parallel_workers_per_gather', '0', true)",
          [
            Float.to_string(TypoPolicy.threshold(config, relaxed) * 1.0),
            Float.to_string(TypoPolicy.word_threshold(config, relaxed))
          ]
        )

        fun.()
      end)

    result
  end

  defp apply_field_filters(query, filter_map, _type, _scope, _opts)
       when not is_map(filter_map) or map_size(filter_map) == 0,
       do: query

  # The filters test the stored `content`, which Postgres decompresses for
  # each row it tests. Written as plain conditions, they cost the planner
  # about as little as the type test, so it ran them on every document of the
  # workspace before the type and the words narrowed the rows: `norsk` with
  # `filter[IsHidden][notContains]=true` decompressed 47,334 documents to keep
  # 10,232 (1.3 s against 0.2 s with no filter, task-b2a224d49a3f27eb).
  #
  # A correlated `EXISTS` on the same row with `OFFSET 0` stays a subplan, and
  # Postgres tests a subplan after every cheaper condition of the scan. So
  # the filters only see documents that are already in scope, of the type
  # and matching the words.
  defp apply_field_filters(query, filter_map, type, scope, opts) do
    filtered =
      from(f in Document,
        where: f.id == parent_as(:search_doc).id,
        select: 1,
        offset: 0
      )
      |> Barkpark.Content.Query.apply_search_filters(filter_map, type, scope, opts)

    where(query, [d], exists(filtered))
  end

  # Value counts of content fields the caller named with `?facet=`, over the
  # filtered match set. A string field counts its value, an array field each
  # element once per document. At most 100 values per field, biggest first.
  #
  # They ride in the count's own scan (`count_and_facets/3`) as one more
  # grouping set, `(field, value)`, so a named facet costs one read of each
  # matched document's `content` and no second run of the match. They used
  # to be one more query per field that ran the whole match again and read
  # `content` three times per document: the facet on `norsk` cost more than
  # the search itself (task-b2a224d49a3f27eb).
  @field_facet_limit 100

  defp field_facets(fields, rows) do
    counts =
      for %{fg: 0, field: field, values: values, field_count: n} <- rows,
          label <- values,
          reduce: %{} do
        acc -> Map.update(acc, {field, label}, n, &(&1 + n))
      end

    Map.new(fields, fn field ->
      buckets =
        for({{^field, label}, count} <- counts, do: {label, count})
        |> Enum.sort_by(fn {label, count} -> {-count, label} end)
        |> Enum.take(@field_facet_limit)
        |> Enum.map(fn {label, count} -> %{"label" => label, "count" => count} end)

      {field, buckets}
    end)
  end

  # Apply the bounded ranking pool: keep the `pool_size` rows with the highest
  # cheap signal, then run the full ranking in `order_rank/4` on those only.
  # The cheap signal is how many query words start a word of the search title
  # or author (`cover_key/1`, read from the narrow title and author columns,
  # never the `content` blob), then recency. A book whose name holds the query
  # therefore always reaches the ranking, however many documents mention the
  # words in a description.
  defp bounded_pool(base, pool_size, groups) when pool_size > 0 do
    base |> exclude(:order_by) |> where([d], d.id in subquery(pool_ids(base, pool_size, groups)))
  end

  defp bounded_pool(base, _, _), do: base

  # The pool of a filtered search. The filter reads each document's stored
  # `content`, so testing it on every match costs a decompression per match,
  # and the count has already paid that once. The pool takes the matches in
  # pool order WITHOUT the filter, twice the pool's size, and tests the
  # filter on those only. When at least a pool's worth pass, they are the
  # first `pool_size` filtered matches in pool order, the same pool
  # `bounded_pool/3` builds. When fewer pass (a narrow filter), the pool
  # falls back to `bounded_pool/3`.
  @filtered_pool_factor 2

  defp filtered_pool(base, text_match, pool_size, groups) when pool_size > 0 do
    candidates =
      text_match
      |> pool_ids(pool_size * @filtered_pool_factor, groups)
      |> Repo.all(@planned_per_call)

    ids =
      base
      |> exclude(:order_by)
      |> where([d], d.id in ^candidates)
      |> pool_ids(pool_size, groups)
      |> Repo.all(@planned_per_call)

    if length(ids) == pool_size,
      do: base |> exclude(:order_by) |> where([d], d.id in ^ids),
      else: bounded_pool(base, pool_size, groups)
  end

  defp filtered_pool(base, _text_match, pool_size, groups),
    do: bounded_pool(base, pool_size, groups)

  # The pool: the `pool_size` matches with the most query words at a word
  # start of the title or author, then the newest, then by id so the set is the
  # same on every request.
  defp pool_ids(base, pool_size, groups) do
    base
    |> exclude(:order_by)
    |> order_by(
      ^[desc: cover_key(groups), desc: dynamic([d], d.updated_at), asc: dynamic([d], d.id)]
    )
    |> limit(^pool_size)
    |> select([d], d.id)
  end

  defp in_pool_key(base, pool_size, groups) do
    ids = pool_ids(base, pool_size, groups)
    dynamic([d], d.id in subquery(ids))
  end

  # Retrieval column projection (search-latency slice a). The DB-level twin of
  # `Content.Envelope.project/2`: when the caller passed `?fields=`, SELECT the
  # identity/versioning/tenancy columns + `title` the envelope always needs, plus
  # a `content` with the heavy blobs (`@heavy_content_keys`) stripped — so a
  # paper hit ships its scalars (title/description/slug/…) but not its ~37KB
  # `body_html`. Returns MAPS (atom-keyed) instead of `%Document{}`; every
  # downstream consumer (Envelope.render/3, Highlighter, the pipeline's
  # `doc_type/1`) reads hits via `doc.field` / `%{field: _}` and is map-safe.
  #
  # FAIL-SAFE, never lossy: applied ONLY when the `fields=` allowlist requests
  # NONE of the heavy keys. A `fields=blocks` / `fields=body` caller (or the
  # no-`fields=` full-envelope caller) keeps the full `%Document{}` struct, so
  # `Envelope.render`'s paper block-promotion (which reads `content["body"]`/
  # `["blocks"]`) is never silently starved. Every scalar in the allowlist is
  # SELECTed verbatim, so the rendered+projected envelope is byte-identical.
  defp maybe_light_select(query, fields) when is_binary(fields) do
    requested =
      fields
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if requested != [] and Enum.all?(@heavy_content_keys, &(&1 not in requested)) do
      select(query, [d], %{
        id: d.id,
        doc_id: d.doc_id,
        type: d.type,
        dataset: d.dataset,
        dataset_id: d.dataset_id,
        title: d.title,
        status: d.status,
        rev: d.rev,
        owner_id: d.owner_id,
        workspace_id: d.workspace_id,
        project_id: d.project_id,
        inserted_at: d.inserted_at,
        updated_at: d.updated_at,
        content:
          type(
            fragment("(? - 'body' - 'body_html' - 'blocks' - 'cells')", d.content),
            :map
          )
      })
    else
      query
    end
  end

  defp maybe_light_select(query, _fields), do: query

  # Count + the four facet dimensions in ONE pass over the match set (slice c).
  #
  # WAS: five statements — a `count(id)` plus one `GROUP BY` per dimension
  # (type / status / author_text / category_text) — each independently
  # re-running the full match predicate. Now a single `GROUP BY GROUPING SETS`
  # aggregates all five in one scan: the four single-column sets give the facet
  # buckets, the empty set `()` gives the grand total (the old `count`). The
  # `grouping(a,b,c,d)` bitmask tags which set each returned row belongs to, so
  # NULL-because-not-grouped is never confused with NULL-as-a-real-facet-value.
  #
  # BYTE-IDENTICAL to the five-statement path by construction: the SAME columns,
  # the SAME `count(id)` aggregate, the SAME `put_facet` shaping (nil/'' labels
  # dropped, biggest-count first). GROUPING SETS is pure aggregation batching —
  # it changes the number of round trips, not the buckets. Empty match set: the
  # `()` set still emits its grand-total row (count 0) while the column sets emit
  # nothing, so count=0 with empty facets — matching the old count/GROUP-BY pair.
  #
  # `grouping(type,status,author_text,category_text)` is a 4-bit mask, MSB first;
  # a bit is 1 when that column is aggregated AWAY in the current set. So a set
  # grouping ONLY `type` has status/author/category away → 0111 = 7; `()` (all
  # away) → 1111 = 15.
  #
  # THE AUTHOR AND CATEGORY SETS CARRY `type` TOO (task-3c68de39a19285c4, the
  # facet half). `author_text` / `category_text` are `content->>'author'` /
  # `content->>'category'`, and a type may declare either field private /
  # owner_only / readable_by. A facet label IS that field's value, so emitting
  # it for a caller who cannot read the field echoes a private value by name
  # (results are redacted by `Envelope.render/3`; facets never were). Grouping
  # `(type, author_text)` lets the fold keep only the types where
  # `Envelope.field_readable?/3` says this caller may read the field, then sum
  # the surviving per-type buckets per label. For a caller who can read every
  # type's field (an admin, or no type declaring it) the buckets are the same
  # totals as before. (type, author) away-bits: status + category → 0101 = 5;
  # (type, category): status + author → 0110 = 6.
  @g_type 0b0111
  @g_status 0b1011
  @g_type_author 0b0101
  @g_type_category 0b0110
  @g_total 0b1111

  defp count_and_facets(base, scope, opts) do
    facet_fields =
      case Keyword.get(opts, :facet_fields) do
        fields when is_list(fields) and fields != [] -> fields
        _ -> nil
      end

    rows =
      base
      |> exclude(:order_by)
      |> count_and_facets_query(facet_fields)
      |> Repo.all(@planned_per_call)

    readable = facet_readability(rows, scope, opts)

    init = %{count: 0, type: [], status: [], author: [], category: []}

    # The `(field, value)` rows of named facets are read by `field_facets/2`.
    set_rows = Enum.reject(rows, &(Map.get(&1, :fg) == 0))

    acc =
      Enum.reduce(set_rows, init, fn row, acc ->
        case row.g do
          @g_total ->
            %{acc | count: row.count}

          @g_type ->
            %{acc | type: [{row.type, row.count} | acc.type]}

          @g_status ->
            %{acc | status: [{row.status, row.count} | acc.status]}

          @g_type_author ->
            if readable.({row.type, "author"}),
              do: %{acc | author: [{row.author, row.count} | acc.author]},
              else: acc

          @g_type_category ->
            if readable.({row.type, "category"}),
              do: %{acc | category: [{row.category, row.count} | acc.category]},
              else: acc

          _ ->
            acc
        end
      end)

    # The per-type author/category buckets fold back to one bucket per label.
    acc = %{acc | author: sum_by_label(acc.author), category: sum_by_label(acc.category)}

    facets =
      %{}
      |> put_facet("type", acc.type)
      |> put_facet("status", acc.status)
      |> put_facet("author", acc.author)
      |> put_facet("category", acc.category)

    facets =
      if facet_fields,
        do: Map.put(facets, "fields", field_facets(facet_fields, rows)),
        else: facets

    {acc.count, facets}
  end

  defp count_and_facets_query(base, nil) do
    base
    |> select([d], %{
      g: fragment("grouping(?, ?, ?, ?)", d.type, d.status, d.author_text, d.category_text),
      type: d.type,
      status: d.status,
      author: d.author_text,
      category: d.category_text,
      count: count(d.id)
    })
    |> group_by(
      [d],
      fragment(
        "GROUPING SETS ((?), (?), (?, ?), (?, ?), ())",
        d.type,
        d.status,
        d.type,
        d.author_text,
        d.type,
        d.category_text
      )
    )
  end

  # With named facets, each matched document joins one row per field (`o` is
  # the field's place, 1 for the first), holding the field's value. The four
  # facet sets and the total count only the rows of the first field, so they
  # count each document once, as without facets. The `(field, value)` set
  # counts documents per value of each field; `values` turns a value into the
  # distinct texts the facet counts: the elements of an array, a string
  # itself, nothing for any other value. `fg` is 0 on those rows only.
  defp count_and_facets_query(base, fields) do
    base
    |> join(
      :inner_lateral,
      [d],
      fx in fragment(
        "SELECT u.k, u.o, ?->u.k AS v FROM unnest(?::text[]) WITH ORDINALITY AS u(k, o) OFFSET 0",
        d.content,
        ^fields
      ),
      on: true
    )
    |> select([d, ..., fx], %{
      g: fragment("grouping(?, ?, ?, ?)", d.type, d.status, d.author_text, d.category_text),
      fg: fragment("grouping(?, ?)", fx.k, fx.v),
      type: d.type,
      status: d.status,
      author: d.author_text,
      category: d.category_text,
      count: fragment("count(?) FILTER (WHERE ? = 1)", d.id, fx.o),
      field: fx.k,
      values:
        fragment(
          "ARRAY(SELECT DISTINCT e.value FROM jsonb_array_elements_text(CASE jsonb_typeof(?) WHEN 'array' THEN ? WHEN 'string' THEN jsonb_build_array(?) ELSE '[]'::jsonb END) AS e(value))",
          fx.v,
          fx.v,
          fx.v
        ),
      field_count: count(d.id)
    })
    |> group_by(
      [d, ..., fx],
      fragment(
        "GROUPING SETS ((?), (?), (?, ?), (?, ?), (), (?, ?))",
        d.type,
        d.status,
        d.type,
        d.author_text,
        d.type,
        d.category_text,
        fx.k,
        fx.v
      )
    )
  end

  # The suggestion fast path's count: the match set's size, without facets.
  defp count_only(base) do
    base
    |> exclude(:order_by)
    |> select([d], count(d.id))
    |> Repo.one(@planned_per_call)
  end

  # {type, field} -> may THIS caller read that field on that type? Resolved once
  # per type that actually contributed an author/category bucket, through the
  # same `Envelope.field_readable?/3` the query route's filter gate and the
  # highlighter use. A type whose schema does not resolve reads as `nil` schema,
  # which `field_readable?/3` treats as undeclared (public).
  defp facet_readability(rows, scope, opts) do
    # A nil caller is the anonymous PUBLIC-ONLY principal on this path (the
    # visibility gate above already treats it so); `field_readable?/3` would
    # fail it closed even for an UNDECLARED field, which would blank a public
    # facet. Reading it as `anonymous/0` keeps undeclared fields public and
    # every declared private/owner_only/readable_by field hidden.
    ctx = Keyword.get(opts, :caller_context) || Barkpark.Content.CallerContext.anonymous()

    types =
      for %{g: g, type: t} <- rows, g in [@g_type_author, @g_type_category], uniq: true, do: t

    schemas =
      Map.new(types, fn t ->
        schema =
          case Barkpark.Content.Schema.get_schema_for_redaction(t, scope, opts) do
            {:ok, s} -> s
            _ -> nil
          end

        {t, schema}
      end)

    fn {type, field} ->
      Barkpark.Content.Envelope.field_readable?(Map.get(schemas, type), field, ctx)
    end
  end

  defp sum_by_label(rows) do
    rows
    |> Enum.group_by(fn {label, _} -> label end, fn {_, count} -> count end)
    |> Enum.map(fn {label, counts} -> {label, Enum.sum(counts)} end)
  end

  # Shape a dimension's `{label, count}` rows into the `meta.facets` bucket list:
  # drop nil/'' labels, biggest count first, label ascending as the tiebreak.
  #
  # The label tiebreak makes the order TOTAL and deterministic. Without it, the
  # sort key is `-count` alone: a STABLE sort over a planner-arbitrary GROUP BY
  # emission order, so two equal-count buckets ("post"/"note" both matched 3x)
  # came out in whichever order Postgres happened to emit — nondeterministic
  # across identical queries (the standalone GROUP BY and the collapsed GROUPING
  # SETS pass can emit the same rows in different orders). That surfaced as facet
  # jitter in the finder and non-reproducible snapshots. `{-count, label}` pins a
  # single canonical order; the biggest-first contract for DISTINCT counts is
  # unchanged.
  defp put_facet(map, name, rows) do
    buckets =
      rows
      |> Enum.reject(fn {label, _} -> label in [nil, ""] end)
      |> Enum.map(fn {label, count} -> %{"label" => to_string(label), "count" => count} end)
      |> Enum.sort_by(fn %{"label" => label, "count" => count} -> {-count, label} end)

    if buckets == [], do: map, else: Map.put(map, name, buckets)
  end

  # Schema-visibility gate (D62) — see the `base` pipeline comment above. An
  # authenticated principal (any api_token or user session) bypasses, EXCEPT the
  # public-read tier: exact parity with QueryController's `authed?/1`, which
  # moved in the same commit, never stricter on one route. Everyone else —
  # anonymous, nil, the public-read tier, or any unknown future principal —
  # fails CLOSED onto the public-type allowlist.
  #
  # KEYED ON THE PERMISSION, NOT ON `principal_type`. The old shape asked "is
  # this caller authenticated"; a `public-read` token IS an `:api_token`, so the
  # browser-shipped site credential (cloud sites/deploy.ex ships it into the
  # build as BARKPARK_TOKEN against the SCOPED `/w/:ws/p/:proj` base URL) skipped
  # the visibility filter wholesale and read every private type through the
  # scoped search door. The flat mirror never leaked because `:api_grant_read`
  # mounts `Plugs.PublicRead`; `:scoped_api` does not — and MUST NOT, because
  # PublicRead is deny-by-default outside a query/doc/graph allowlist and 21
  # routes ride bare `:scoped_api` (scoped search, scoped federated search,
  # suggestions/interaction/correction, the six preview reads, the whole scoped
  # media surface). Mounting it there would 403 all of them and take the live
  # flagship dark (search-template D49). The clamp belongs HERE, where it filters
  # rather than denies: a public-read caller still gets 200, just the public
  # types — and because this is the same one-clause-on-`base` seat as the grant
  # clause, results, count AND facets are clamped together (a leaked count or
  # type facet is an existence leak by itself).
  defp restrict_anonymous_to_public_types(query, scope, opts) do
    if bypasses_visibility_gate?(Keyword.get(opts, :caller_context)) do
      query
    else
      where(query, [d], d.type in ^public_type_names(scope, opts))
    end
  end

  # True only for an authenticated principal OUTSIDE the public-read tier.
  # Anything else — anonymous, nil, a non-CallerContext, any future principal —
  # is false, so the allowlist applies (fail CLOSED).
  #
  # The predicate itself now lives in `Content.Schema.bypasses_visibility_gate?/1`
  # (canonical slug `visibility-gate-tier`): the SAME tier test the corpus
  # graph clamp and the batch document read (`Query.restrict_to_visible_types/3`,
  # the seat `?expand=` walked through) read. One rule, one implementation — the
  # hand-copied twin that used to live here is exactly how this family recurs.
  defp bypasses_visibility_gate?(ctx),
    do: Barkpark.Content.Schema.bypasses_visibility_gate?(ctx)

  # The ALLOWLIST of schema type names an anonymous caller may search: schemas
  # in the caller's tenancy scope whose visibility is EXPLICITLY "public" —
  # `visibility: nil` / "private" / any future value is NOT public, matching
  # `Content.schema_public?/3` (the query route's gate) byte-for-byte. A type
  # with no schema row at all is absent by construction (the query route 404s
  # it; a denylist would admit it). Cost: one 39-row scan measured at 0.078ms
  # on live prod vs a 224-675ms search fixed cost. Empty allowlist ⇒
  # `d.type in []` ⇒ WHERE false ⇒ empty results/count/facets (fail closed).
  # The Indx indexer applies the same predicate at index time
  # (IndexerWorker.schema_public?/1) — one invariant, two enforcement points.
  #
  # The derivation itself now lives in `Content.Schema.public_type_names/2` so
  # the corpus graph (`TasksController.graph_corpus/2`) restricts its type list
  # through the SAME predicate rather than a second hand-rolled copy — the gap
  # this comment used to name as filed-separately.
  defp public_type_names(scope, opts) do
    Barkpark.Content.Schema.public_type_names(scope,
      workspace_id: Keyword.get(opts, :workspace_id),
      project_id: Keyword.get(opts, :project_id)
    )
  end

  # Mirror of Content.scope_to_dataset for the search read path (barkpark-y9ee).
  # Resolve the dataset STRING → its dataset_id within the read's project scope
  # and filter authoritatively by `dataset_id`; same-name datasets across
  # projects (and within a workspace) no longer conflate. Fall back to the
  # legacy `dataset` STRING filter only when the dataset can't be resolved
  # (no project scope / dataset row predates the W2 dual-write), which keeps the
  # leaf discriminator working for back-compat reads.
  #
  # The workspace MUST be forwarded too (barkpark-sknf). `resolve_read_dataset_id/2`
  # only falls back to the seeded Default project when the caller passed NO
  # scope at all, and it detects that by the PRESENCE of a `:workspace_id` key.
  # This call site used to build a fresh `[project_id: project_id]` list, so the
  # guard was unreachable from here: a workspace-only read (the shape the flat
  # routes produce — `DeriveWorkspaceFromToken` sets the workspace and
  # `AssignDefaultScope` deliberately leaves a derived non-Default workspace
  # project-less) resolved the DEFAULT project's dataset_id and this clause
  # applied it as a strict `d.dataset_id == <Default's id>`. ANDed with
  # `scope_to_workspace_or_global`'s `d.workspace_id == <tenant>` that is empty
  # by construction — document search went fully BLIND for every token-derived
  # non-Default workspace.
  #
  # The key is added ONLY when the workspace is actually present, mirroring
  # `ScopeHelpers.scope_opts/1`, which drops an absent assign rather than
  # emitting `workspace_id: nil`. Passing a nil workspace as a PRESENT key
  # would make the guard fire for the genuinely-unscoped flat caller too and
  # regress the y9ee dataset_id resolution above.
  #
  # DECIDED (task-273fd8908ec43aa4): the `:shared_only` sentinel STAYS OUT of
  # the `is_binary/1` branch. It names no tenant to resolve a dataset within,
  # so it keeps the Default-project resolution. The tenant boundary is the
  # AND-ed `scope_to_workspace_or_global(:shared_only)` (`workspace_id IS
  # NULL`), not this guard. That reliance is pinned at the door by
  # test/barkpark_web/controllers/search_scope_shared_layer_test.exs (a
  # seat-vacant search returns the shared layer and never workspace A's row).
  defp scope_to_dataset(query, scope, project_id, workspace_id) do
    opts =
      if is_binary(workspace_id),
        do: [project_id: project_id, workspace_id: workspace_id],
        else: [project_id: project_id]

    case Barkpark.Content.resolve_read_dataset_id(scope, opts) do
      id when is_binary(id) -> where(query, [d], d.dataset_id == ^id)
      _ -> where(query, [d], d.dataset == ^scope)
    end
  end

  defp search_terms(parsed) do
    (Map.get(parsed, :terms, []) ++
       Map.get(parsed, :phrases, []) ++ Map.get(parsed, :prefixes, []))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # `:full` — `search_vector`, every content string. `:public` —
  # `coalesce(public_search_vector, search_vector)`: the trigger-maintained
  # vector over the content with every restricted field removed, NULL (so the
  # full vector stands in) when the document carries nothing restricted. See
  # migration 20261003200000_add_documents_public_search_vector.
  defp text_index(%Barkpark.Content.CallerContext{is_admin: true}, _type, _types), do: :full
  defp text_index(:internal, _type, _types), do: :full

  defp text_index(_ctx, type, types) when is_binary(type) and (types == nil or types == []) do
    # The same test the public vector's trigger makes (migration
    # 20261003200000): a schema row of this name anywhere whose fields mention
    # a restriction. Read over every row of the name, so it can only answer
    # "restricted" more often than the trigger, never less.
    %{rows: [[restricted?]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM schema_definitions sd WHERE sd.name = $1 " <>
          "AND to_jsonb(sd.fields)::text ~ '\"(private|visibility|readable_by)\"')",
        [type]
      )

    if restricted?, do: :public, else: :full
  end

  defp text_index(_ctx, _type, _types), do: :public

  # The scopes `SearchRefresh.gates/0` names, left out of a text search by
  # anyone who reads the public index. A browse reads no vector and keeps them.
  defp exclude_pending_refresh(base, _ctx, true), do: base
  defp exclude_pending_refresh(base, %Barkpark.Content.CallerContext{is_admin: true}, _), do: base
  defp exclude_pending_refresh(base, :internal, _), do: base

  defp exclude_pending_refresh(base, _ctx, false) do
    case SearchRefresh.exclude(SearchRefresh.gates()) do
      nil -> base
      condition -> where(base, ^condition)
    end
  end

  # The full index is two vectors: the stored `search_vector` (every content
  # string) and the names vector (the search title and the author slot, in
  # English and folded; migration 20261014150000). A query matches when either
  # vector holds it, each through its own GIN index. A query that needs several
  # words is split per word by the caller (`words_dynamic/3`), so a word in the
  # names vector and a word in the body still match together.
  defp vec_match(:full, text),
    do:
      dynamic(
        [d],
        fragment(
          "(?.search_vector @@ (?::text)::tsquery OR bp_search_names_vector(?.search_names_tsv, ?.title) @@ (?::text)::tsquery)",
          d,
          ^text,
          d,
          d,
          ^text
        )
      )

  # The public index is `coalesce(public_search_vector, <full index>)`, spelled
  # as arms so each one is served by its own GIN index (the full vector's, the
  # names vector's, and the partial one on the public vector). The coalesce
  # form is not indexed, and made every non-admin search a filter scan of the
  # whole type. The public vector already holds the slots of the redacted
  # content (`bp_public_search_vector`).
  defp vec_match(:public, text),
    do:
      dynamic(
        [d],
        fragment(
          "((?.public_search_vector IS NULL AND (?.search_vector @@ (?::text)::tsquery OR bp_search_names_vector(?.search_names_tsv, ?.title) @@ (?::text)::tsquery)) OR (?.public_search_vector IS NOT NULL AND ?.public_search_vector @@ (?::text)::tsquery))",
          d,
          d,
          ^text,
          d,
          d,
          ^text,
          d,
          d,
          ^text
        )
      )

  # The vector the ranking reads: the names vector, then the stored vector.
  # Together they hold the same words, weights and positions as one vector
  # built with the slots, names first (byte for byte on the gyldendal-no copy),
  # so `ts_rank` is unchanged. The names vector reads no content, so no row is
  # detoasted for it.
  defp rank_vector(:full),
    do:
      dynamic(
        [d],
        fragment(
          "(bp_search_names_vector(?.search_names_tsv, ?.title) || ?.search_vector)",
          d,
          d,
          d
        )
      )

  defp rank_vector(:public),
    do:
      dynamic(
        [d],
        fragment(
          "coalesce(?.public_search_vector, bp_search_names_vector(?.search_names_tsv, ?.title) || ?.search_vector)",
          d,
          d,
          d,
          d
        )
      )

  # ── The search title (task-3c6d02392d430c98) ──────────────────────────────
  #
  # The title the search arms read: `search_title` (the schema's declared
  # search title, or the preview field of a type with no title field), else the
  # `title` column. Migration 20261014150000 keeps `search_title` and indexes
  # this exact expression and its fold with trigram GIN indexes; the SQL text
  # here must stay identical to the index expressions for the planner to use
  # them.
  defp search_label,
    do: dynamic([d], fragment("coalesce(?, nullif(?, ''))", d.search_title, d.title))

  # The search title as the whole-title typo arm (`%`) reads it. The trailing
  # `''` changes no match (an empty title is similar to nothing, like NULL),
  # but makes it a different expression from `search_label/0`, so this arm is
  # the only one the GiST trigram index of migration 20261015170000 serves.
  # GiST keeps each title's trigrams in its leaves and answers `%` without
  # visiting the table; the GIN index of `search_label/0` returns every title
  # that shares one trigram with the word, 12,102 rows for `basis` at the
  # relaxed threshold, and the table read to recheck them was most of the
  # widened recovery pass (190 ms of 446 ms on the gyldendal-no copy). The
  # other arms stay on the GIN index, which is faster for them.
  defp similar_search_label,
    do: dynamic([d], fragment("coalesce(?, nullif(?, ''), '')", d.search_title, d.title))

  # The search title folded, and the search names (the search title and the
  # author slot, which holds `content.author` too, folded, in one text).
  # Migration 20261014150000 stores both for a row with a slot and indexes
  # both expressions with trigram GIN indexes. A row without a slot folds its
  # title here.
  defp folded_search_label,
    do: dynamic([d], fragment("bp_search_label_fold(?.search_title_fold, ?.title)", d, d))

  defp search_names,
    do:
      dynamic(
        [d],
        fragment("bp_search_names(?.search_names_fold, ?.title)", d, d)
      )

  # ── Term groups ───────────────────────────────────────────────────────────
  #
  # One group per thing the query asks for: a word, a `word*` or a "quoted
  # phrase". A group's members are the item and its synonyms, so a synonym is
  # an alternative to its word, not one more word every document must hold.
  # The last plain word of the query is the word being typed: it also
  # prefix-matches, when it has at least 2 letters. A last word of 1 letter
  # with other words before it is left out of the match (it would make the
  # query wider, never narrower) and only counts in the ranking.
  #
  # A word that is only an English stop word ("i", "the", "a") is dropped when
  # other words remain: the index holds no such word in the body, so requiring
  # it would empty the result.
  @min_prefix_chars 2

  defp term_groups(parsed) do
    alternatives = Map.get(parsed, :alternatives, %{})
    words = typed_words(parsed)
    last = List.last(words)

    word_groups =
      Enum.map(words, fn w ->
        %{
          kind: :word,
          text: w,
          prefix?: w == last and String.length(w) >= @min_prefix_chars,
          members: [w | Map.get(alternatives, w, [])]
        }
      end)

    prefix_groups =
      for p <- Map.get(parsed, :prefixes, []), p != "" do
        %{kind: :word, text: p, prefix?: true, members: [p]}
      end

    phrase_groups =
      for p <- Map.get(parsed, :phrases, []), p != "" do
        %{kind: :phrase, text: p, prefix?: false, members: [p | Map.get(alternatives, p, [])]}
      end

    groups = word_groups ++ prefix_groups ++ phrase_groups

    groups
    |> drop_short_last_word(last)
    |> resolve_group_queries()
    |> drop_stop_words()
  end

  defp drop_short_last_word([_, _ | _] = groups, last) when is_binary(last) do
    if String.length(last) < @min_prefix_chars,
      do: Enum.reject(groups, &(&1.kind == :word and &1.text == last)),
      else: groups
  end

  defp drop_short_last_word(groups, _last), do: groups

  defp typed_words(parsed) do
    synonyms =
      parsed |> Map.get(:alternatives, %{}) |> Map.values() |> List.flatten() |> MapSet.new()

    parsed
    |> Map.get(:terms, [])
    |> Enum.reject(&(&1 == "" or MapSet.member?(synonyms, &1)))
    |> Enum.uniq()
  end

  # The 1-letter last word `drop_short_last_word/2` leaves out of the match still
  # picks the ranking pool (task-7db7f8fe8b17a58e): titles with a word that starts
  # with it come first (`cover_key/1`). Without it, "bulk item 1" over 5,000 bulk
  # items pooled the newest 500, none of Bulk item 1000-1999, and the ranking
  # (which already prefers a title starting with the whole query) never saw them.
  # Not a filter: a 1-letter LIKE has no trigram to probe, and the match stays
  # index-only.
  defp pool_hint(_parsed, []), do: []

  defp pool_hint(parsed, groups) do
    last = parsed |> typed_words() |> List.last()

    if is_binary(last) and String.length(last) < @min_prefix_chars and
         not Enum.any?(groups, &(&1.kind == :word and &1.text == last)),
       do: [%{kind: :word, text: last, prefix?: true, members: [last]}],
       else: []
  end

  defp drop_stop_words([_, _ | _] = groups) do
    case Enum.reject(groups, &(&1.kind == :word and &1.stop?)) do
      [] -> groups
      kept -> kept
    end
  end

  defp drop_stop_words(groups), do: groups

  # ── The full-text query of a group ────────────────────────────────────────
  #
  # Every word goes in with each spelling the Norwegian fold can stand for
  # (`Fold.variants/1`), so "knausgard" and "knausgaard" find "Knausgård" in
  # any field, and with its fold in the `simple` config, which matches the
  # folded copy of the title and author words. A prefix query puts `:*` on the
  # last word. Only letters and digits reach `to_tsquery`, so no operator in
  # the user's text can change the query.
  #
  # The queries are resolved to tsquery TEXT in one round trip before the
  # search runs, and the search binds them as `$n::tsquery` constants. With a
  # constant the planner reads the vector's statistics and costs the GIN index;
  # a `to_tsquery(...)` call in the query hides both, and the planner then
  # filtered every vector of the type instead (272 ms against 13 ms for
  # `lydbok` over 10,592 products).
  defp resolve_group_queries([]), do: []

  defp resolve_group_queries(groups) do
    items =
      for {group, gi} <- Enum.with_index(groups),
          member <- group.members,
          source = tsquery_source(group.kind, member),
          source != nil,
          do: {gi, group.kind, source}

    resolved = resolve_tsqueries(Enum.map(items, fn {_gi, kind, source} -> {kind, source} end))

    by_group =
      items
      |> Enum.zip(resolved)
      |> Enum.group_by(fn {{gi, _, _}, _} -> gi end, fn {_, texts} -> texts end)

    groups
    |> Enum.with_index()
    |> Enum.map(fn {group, gi} ->
      texts = Map.get(by_group, gi, [])

      Map.merge(group, %{
        exact_q: or_texts(Enum.map(texts, & &1.exact)),
        prefix_q: or_texts(Enum.map(texts, & &1.prefix)),
        stop?: texts == [] or Enum.all?(texts, &(&1.english_nodes == 0))
      })
    end)
  end

  # `{english, simple, english_prefix, simple_prefix}` for a word member, the
  # phrase itself for a phrase member, nil when the text holds no word.
  defp tsquery_source(:phrase, member), do: if(String.trim(member) == "", do: nil, else: member)

  defp tsquery_source(_kind, member) do
    case Regex.scan(~r/[\p{L}\p{N}]+/u, String.downcase(member)) |> List.flatten() do
      [] ->
        nil

      words ->
        n = length(words)

        english = fn prefix? ->
          words
          |> Enum.with_index()
          |> Enum.map_join(" & ", fn {w, i} ->
            suffix = if prefix? and i == n - 1, do: ":*", else: ""
            "(" <> Enum.map_join(Fold.variants(w), " | ", &(&1 <> suffix)) <> ")"
          end)
        end

        simple = fn prefix? ->
          words
          |> Enum.with_index()
          |> Enum.map_join(" & ", fn {w, i} ->
            suffix = if prefix? and i == n - 1, do: ":*", else: ""
            Fold.fold(w) <> suffix
          end)
        end

        {english.(false), simple.(false), english.(true), simple.(true)}
    end
  end

  defp resolve_tsqueries([]), do: []

  defp resolve_tsqueries(items) do
    cols =
      Enum.map(items, fn
        {:phrase, phrase} -> ["phrase", phrase, "", "", ""]
        {_kind, {e, s, ep, sp}} -> ["word", e, s, ep, sp]
      end)

    [kinds, es, ss, eps, sps] = Enum.zip_with(cols, & &1)

    %{rows: rows} =
      Repo.query!(
        """
        SELECT
          CASE WHEN k = 'phrase' THEN phraseto_tsquery('english', e)::text
               ELSE (to_tsquery('english', e) || to_tsquery('simple', s))::text END,
          CASE WHEN k = 'phrase' THEN phraseto_tsquery('english', e)::text
               ELSE (to_tsquery('english', ep) || to_tsquery('simple', sp))::text END,
          CASE WHEN k = 'phrase' THEN numnode(phraseto_tsquery('english', e))
               ELSE numnode(to_tsquery('english', e)) END
        FROM unnest($1::text[], $2::text[], $3::text[], $4::text[], $5::text[])
          WITH ORDINALITY AS t(k, e, s, ep, sp, o)
        ORDER BY o
        """,
        [kinds, es, ss, eps, sps]
      )

    Enum.map(rows, fn [exact, prefix, nodes] ->
      %{exact: exact, prefix: prefix, english_nodes: nodes}
    end)
  end

  defp or_texts(texts), do: join_texts(texts, " | ")

  defp join_texts(texts, op) do
    case Enum.reject(texts, &(&1 in [nil, ""])) do
      [] -> nil
      [one] -> one
      many -> Enum.map_join(many, op, &("(" <> &1 <> ")"))
    end
  end

  # The tsquery text of a group: its prefix form for the word being typed.
  defp group_text(%{prefix?: true, prefix_q: q}), do: q
  defp group_text(%{exact_q: q}), do: q

  # The slug substring arm reads `slug_text`, a copy of `content.slug` that is
  # not schema-aware. For the public index it only runs on documents with no
  # restricted field (public vector NULL); elsewhere a public slug still matches
  # word-for-word through the public vector's slug component.
  defp slug_match(:full, pattern), do: dynamic([d], ilike(d.slug_text, ^pattern))

  defp slug_match(:public, pattern),
    do:
      dynamic([d], fragment("?.public_search_vector IS NULL", d) and ilike(d.slug_text, ^pattern))

  # Every arm here is served by an index, so a group is a BitmapOr and the
  # whole match a BitmapAnd of the groups (measured on 10,592 products: a
  # two-word query went from a 250 ms filter scan of the type to 3 ms):
  #
  #   * the full-text query of the group      -> documents_search_vector_idx and
  #                                              documents_search_names_vector_idx
  #   * the document id                        -> the (doc_id, ...) btree
  #   * the search title holding the word, as typed and folded, and the slug
  #     (words of 3 or more letters)           -> the trigram GIN indexes
  #   * a near-miss of the search title, whole (`%`) or word (`<%`), for
  #     words `TypoPolicy` admits             -> the trigram GIN index
  defp where_match(queryable, parsed, groups, config, relaxed, index, match, arms) do
    include_dyn =
      case arms do
        :words -> words_dynamic(groups, index, match)
        :broad -> include_dynamic(groups, config, index, match)
        :names_typo -> names_typo_dynamic(groups, config, index, match)
      end

    exclude_dyn = exclude_dynamic(Map.get(parsed, :excludes, []), relaxed, index)

    queryable =
      if include_dyn,
        do: where(queryable, ^include_dyn),
        else: queryable

    if exclude_dyn do
      where(queryable, ^dynamic([d], not (^exclude_dyn)))
    else
      queryable
    end
  end

  # The first step, built so every arm is an index probe that does not make
  # Postgres decompress the stored vector of each candidate row:
  #
  #   * the whole words of every group, as ONE tsquery (`&&` for `:all`, `||`
  #     for `:any`) against the vector's GIN index. A whole-word query needs no
  #     recheck of the stored vector;
  #   * the word being typed (the prefix group), as a word start in the search
  #     names (`search_names/0`: the search title and the author slot, folded)
  #     through their trigram index, or as a whole word anywhere;
  #   * the document id.
  #
  # A prefix of a word that occurs only in a description is left to the second
  # step: a `:*` query against the full vector costs the planner a scan of the
  # vectors of the whole table (measured 609 ms for `lydbok:*` over 47,361
  # documents, against 13 ms for the whole word).
  defp words_dynamic(groups, index, match) do
    {prefix_groups, word_groups} = Enum.split_with(groups, & &1.prefix?)

    # Under `:all` each word is its own arm (a BitmapAnd of the words), so a
    # word found only in the names vector and one found only in the body still
    # match together. Under `:any` one query serves every word.
    word_arm =
      case match do
        :all ->
          word_groups
          |> Enum.map(&group_text/1)
          |> Enum.reject(&(&1 in [nil, ""]))
          |> Enum.map(&vec_match(index, &1))
          |> combine_clauses(:all)

        :any ->
          case word_groups |> Enum.map(&group_text/1) |> join_texts(" | ") do
            nil -> nil
            word_query -> vec_match(index, word_query)
          end
      end

    prefix_arms =
      Enum.map(prefix_groups, fn group ->
        exact =
          case group.exact_q do
            nil -> nil
            q -> vec_match(index, q)
          end

        names = names_prefix_dynamic(group)
        if exact, do: dynamic([d], ^names or ^exact), else: names
      end)

    text_arm =
      [word_arm | prefix_arms]
      |> Enum.reject(&is_nil/1)
      |> combine_clauses(match)

    id_arm =
      groups
      |> Enum.flat_map(& &1.members)
      |> Enum.map(&id_match/1)
      |> combine_clauses(:any)

    combine_clauses(Enum.reject([text_arm, id_arm], &is_nil/1), :any)
  end

  # The suggestion fallback: the words of the first step, where a word that
  # `TypoPolicy` admits may also be a near miss (`<%`) of a word of the search
  # names. "harry poter" finds "Harry Potter ..." through the names trigram
  # index alone.
  defp names_typo_dynamic(groups, config, index, match) do
    groups
    |> Enum.map(fn group ->
      exact = words_dynamic([group], index, :all)

      typo =
        group.members
        |> Enum.filter(&(group.kind == :word and TypoPolicy.fuzzy_term?(config, &1)))
        |> Enum.map(fn member ->
          dynamic([d], fragment("? <% ?", ^Fold.fold(member), ^search_names()))
        end)
        |> combine_clauses(:any)

      combine_clauses(Enum.reject([exact, typo], &is_nil/1), :any)
    end)
    |> Enum.reject(&is_nil/1)
    |> combine_clauses(match)
  end

  defp combine_clauses([], _match), do: nil

  defp combine_clauses([first | rest], match) do
    Enum.reduce(rest, first, fn clause, acc ->
      case match do
        :all -> dynamic([d], ^acc and ^clause)
        :any -> dynamic([d], ^acc or ^clause)
      end
    end)
  end

  # A member starts a word of the search names: at the start, or after a
  # space. The trigram index on `search_names/0` serves both patterns.
  defp names_prefix_dynamic(group), do: word_start(search_names(), group)

  defp include_dynamic(groups, config, index, match) do
    groups
    |> Enum.map(&group_dynamic(&1, config, index))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        nil

      [first | rest] ->
        Enum.reduce(rest, first, fn clause, acc ->
          case match do
            :all -> dynamic([d], ^acc and ^clause)
            :any -> dynamic([d], ^acc or ^clause)
          end
        end)
    end
  end

  defp group_dynamic(group, config, index) do
    text_arm =
      case group_text(group) do
        nil -> nil
        text -> vec_match(index, text)
      end

    group.members
    |> Enum.map(&member_dynamic(&1, group.kind, config, index))
    |> then(&if(text_arm, do: [text_arm | &1], else: &1))
    |> Enum.reduce(fn clause, acc -> dynamic([d], ^acc or ^clause) end)
  end

  @min_substring_chars 3

  defp member_dynamic(member, kind, config, index) do
    clause = id_match(member)

    clause =
      if String.length(member) >= @min_substring_chars do
        pattern = like_pattern(member)
        folded = like_pattern(Fold.fold(member))

        dynamic(
          [d],
          ^clause or ilike(^search_label(), ^pattern) or
            like(^folded_search_label(), ^folded) or ^slug_match(index, pattern)
        )
      else
        clause
      end

    # WHY `%` / `<%` and not `similarity(?, ?) > ?` (authoring-excellence D49).
    # The function form is index-opaque and forced a filter scan of the whole
    # type. Every other arm of the group is now indexed, so the operator forms
    # let the planner build one BitmapOr. Their thresholds are the transaction
    # settings `with_trgm_thresholds/4` sets from `typo_policy`.
    if kind == :word and TypoPolicy.fuzzy_term?(config, member) do
      dynamic(
        [d],
        ^clause or fragment("? % ?", ^similar_search_label(), ^member) or
          fragment("? <% ?", ^member, ^search_label())
      )
    else
      clause
    end
  end

  defp exclude_dynamic(excludes, relaxed, index) do
    # NOTE the empty config: the exclude arm has never read the surface config's
    # thresholds, so it keeps the code defaults here. Routed through the shared
    # reader anyway so the defaults cannot drift from the include arm's.
    threshold = TypoPolicy.threshold(%{}, relaxed)
    excludes = Enum.reject(excludes, &(&1 == ""))

    Enum.reduce(excludes, nil, fn term, dyn ->
      pattern = like_pattern(term)
      folded = like_pattern(Fold.fold(term))

      text_arm =
        case resolve_tsqueries(List.wrap(if src = tsquery_source(:word, term), do: {:word, src})) do
          [%{exact: text}] when text not in [nil, ""] -> vec_match(index, text)
          _ -> dynamic([d], false)
        end

      # WHY-LEFT (authoring-excellence D49 — do NOT `%`-rewrite this exclude
      # arm). This whole clause is NEGATED at `where_match/7` via
      # `not(^exclude_dyn)`. A trgm GIN answers "which rows MATCH", never the
      # complement, so the operator form would buy nothing here.
      clause =
        dynamic(
          [d],
          ^text_arm or
            ilike(^search_label(), ^pattern) or
            like(^folded_search_label(), ^folded) or
            ^slug_match(index, pattern) or
            fragment("similarity(coalesce(?, ''), ?) > ?", ^search_label(), ^term, ^threshold)
        )

      if dyn, do: dynamic([d], ^dyn or ^clause), else: clause
    end)
  end

  # ── Ranking ───────────────────────────────────────────────────────────────
  #
  # ORDER BY, most significant first:
  #
  #   0. the document whose id IS the query;
  #   1. the search title equal to the query (as typed or folded);
  #   1b. on the near-miss pass only, the document that holds the words
  #       themselves (`held_key/4`);
  #   2. the relevance score, the sum of
  #        * the full-text rank;
  #        * on the near-miss pass only, the weighted per-field similarity,
  #          the signal the surface config's `searchable_fields` weights move;
  #        * 0.5 x the share of query words that are a whole word of the
  #          search title or an author;
  #        * 1.0 x the share of query words that start a word of the search
  #          title or of an author, 0.6 for one inside a title word
  #          (`cover_key/1`), so a book named by the query, or written by the
  #          person it names, ranks above a book whose description mentions it;
  #        * for a query of two or more words, 0.5 when the search title
  #          starts with the whole query, 0.4 when a title or author word
  #          does ("knut ham" in "Knut Hamsun"), 0.25 when the title holds it,
  #          and 0.3 when the document holds the words next to each other, so
  #          word order counts;
  #        * the weighted-tag boost, and with `boost=popularity` the view
  #          score (`boosted/2`);
  #   3. recency, then the id, so the order is total and paging is stable.
  defp order_rank(queryable, parsed, groups, config, index, near_miss?, lead, boost, held) do
    # Rank on the WHOLE positive query (every term + phrase), not just the first
    # token.
    positive_query =
      (Map.get(parsed, :terms, []) ++ Map.get(parsed, :phrases, []))
      |> Enum.reject(&(&1 == "" or synonym?(parsed, &1)))
      |> Enum.join(" ")

    # Lowercased query tokens for the weighted-tag boost arm below — a tag's
    # NAME must equal a query term for its strength to move rank (topic-aware
    # by construction; a high-strength tag on an unrelated topic buys nothing).
    tag_terms =
      positive_query
      |> String.downcase()
      |> String.split()

    if positive_query == "" and groups == [] do
      # Browse path (empty query) — recency, then the id PK so the order is TOTAL.
      # updated_at is not unique; without the tiebreaker LIMIT/OFFSET paging over
      # same-timestamp rows can skip or duplicate across page boundaries.
      order_by(queryable, [d], desc: d.updated_at, asc: d.id)
    else
      order_by(
        queryable,
        ^(lead ++
            [
              {:desc, exact_id_key(positive_query)},
              {:desc, exact_title_key(positive_query)}
            ] ++
            held ++
            [
              {:desc,
               boosted(
                 relevance_key(positive_query, groups, tag_terms, config, index, near_miss?),
                 boost
               )},
              {:desc, dynamic([d], d.updated_at)},
              {:asc, dynamic([d], d.id)}
            ])
      )
    end
  end

  defp synonym?(parsed, term) do
    parsed
    |> Map.get(:alternatives, %{})
    |> Enum.any?(fn {_word, alts} -> term in alts end)
  end

  # The share of groups that start a word of the search names, the title or
  # an author (1.0), or occur inside a word of the title (0.6). A book named by
  # the query and a book written by the person the query names score alike;
  # the full-text rank's title weight then puts the title first. Reads the two
  # narrow folded columns only.
  defp cover_key([]), do: dynamic([_d], fragment("0::float"))

  defp cover_key(groups) do
    n = length(groups) * 1.0

    groups
    |> Enum.map(fn group ->
      dynamic(
        [_d],
        fragment(
          "(CASE WHEN ? THEN 1.0 WHEN ? THEN 0.6 ELSE 0.0 END)",
          ^word_start(search_names(), group),
          ^inside(folded_search_label(), group)
        )
      )
    end)
    |> Enum.reduce(fn term, acc -> dynamic([_d], fragment("? + ?", ^acc, ^term)) end)
    |> then(&dynamic([_d], fragment("(?) / ?", ^&1, ^n)))
  end

  # 0.5 x the share of groups that are a whole word of the search names (title
  # or author), so "Peppa er storesøster" ranks above "Peppas nye sykkel" for
  # "peppa". A regex, run on the ranked pool only.
  defp whole_word_key([]), do: dynamic([_d], fragment("0.0"))

  defp whole_word_key(groups) do
    n = length(groups) * 1.0

    groups
    |> Enum.map(fn %{members: members} ->
      alternation =
        members
        |> Enum.map(&Fold.fold/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map_join("|", &Regex.escape/1)

      regex = "(^|[^[:alnum:]])(" <> alternation <> ")([^[:alnum:]]|$)"

      dynamic(
        [_d],
        fragment("CASE WHEN ? ~ ? THEN 0.5 ELSE 0.0 END", ^search_names(), ^regex)
      )
    end)
    |> Enum.reduce(fn term, acc -> dynamic([_d], fragment("? + ?", ^acc, ^term)) end)
    |> then(&dynamic([_d], fragment("(?) / ?", ^&1, ^n)))
  end

  # A member of the group, folded, occurs anywhere in `column`: the second
  # half of a compound ("krim" in "Hatkrim").
  defp inside(column, %{members: members}) do
    members
    |> Enum.map(&Fold.fold/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn folded -> dynamic([_d], like(^column, ^like_pattern(folded))) end)
    |> case do
      [] -> dynamic([_d], false)
      clauses -> combine_clauses(clauses, :any)
    end
  end

  # A member of the group, folded, starts a word of `column`: at its start or
  # after a space. Two LIKE tests per member, which cost a fraction of a regex
  # and run on every row of a broad match when the pool is chosen.
  defp word_start(column, %{members: members}) do
    members
    |> Enum.map(&Fold.fold/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn folded ->
      start = escape_like(folded) <> "%"
      inner = "% " <> escape_like(folded) <> "%"
      dynamic([_d], like(^column, ^start) or like(^column, ^inner))
    end)
    |> case do
      [] -> dynamic([_d], false)
      clauses -> combine_clauses(clauses, :any)
    end
  end

  # ── Document ids are searchable (task-aa52fb0ec971417e) ───────────────────
  #
  # A query equal to a document id must find that document. The id is not in
  # the text index, so `drafts.sq-fox` used to find only a sibling whose CONTENT
  # mentioned it. A term matches a row whose `doc_id` is the term in either
  # spelling (published or `drafts.`); a term with a `.` (a namespaced id such
  # as `drafts.x`) also matches ids it prefixes, so `drafts.sq-fox` finds
  # `drafts.sq-fox-rev` too. Every scope, perspective and visibility clause on
  # the query still applies: this only adds a match arm.
  defp id_match(term) do
    exact = dynamic([d], d.doc_id in ^id_forms(term))

    if String.contains?(term, "."),
      do: dynamic([d], ^exact or like(d.doc_id, ^id_prefix_pattern(term))),
      else: exact
  end

  defp id_forms(term) do
    published = String.replace_prefix(term, "drafts.", "")
    Enum.uniq([term, published, "drafts." <> published])
  end

  defp id_prefix_pattern(term) do
    String.replace(term, ~r/([\\%_])/, "\\\\\\1") <> "%"
  end

  # ORDER BY key #1b, the near-miss pass only. A pass widened to near misses
  # still holds the documents that contain the words themselves, and the
  # per-field similarity there lets a title that merely looks like the query
  # outrank them: for "helseøkonomi" (one exact hit, so the thin-results pass
  # widened it) "Kommuneøkonomi", "Mikroøkonomi" and 30 other look-alike titles
  # ranked above the one book whose description says "helseøkonomi", and a
  # caller reading the first 10 never saw it. A widened pass adds near misses
  # after the documents that hold the words, never above them.
  defp held_key(false, _groups, _index, _match), do: []

  defp held_key(true, groups, index, match) do
    case words_dynamic(groups, index, match) do
      nil -> []
      held -> [{:desc, dynamic([_d], fragment("CASE WHEN ? THEN 1 ELSE 0 END", ^held))}]
    end
  end

  # ORDER BY key #0: the document whose id IS the query ranks first, so an
  # exact id is never pushed off the page by text matches.
  defp exact_id_key(positive_query) do
    dynamic(
      [d],
      fragment("CASE WHEN ? = ANY(?) THEN 1 ELSE 0 END", d.doc_id, ^id_forms(positive_query))
    )
  end

  # ORDER BY key #1: the search title equals the query, case-insensitively or
  # after the Norwegian fold → 1, else 0.
  defp exact_title_key(positive_query) do
    dynamic(
      [d],
      fragment(
        "CASE WHEN lower(?) = lower(?) OR ? = ? THEN 1 ELSE 0 END",
        ^search_label(),
        ^positive_query,
        ^folded_search_label(),
        ^Fold.fold(positive_query)
      )
    )
  end

  # ORDER BY key #2. The full-text rank reads the OR of every group's query, so
  # a document holding more of the words ranks higher.
  #
  # WHY-LEFT (authoring-excellence D49 — these `similarity()` arms are NOT
  # trgm-index material). They live in an ORDER BY composite, not a WHERE
  # candidate filter, and the pool is bounded upstream. See D49(d).
  defp relevance_key(positive_query, groups, tag_terms, config, index, near_miss?) do
    rank_query =
      groups
      |> Enum.map(&group_text/1)
      |> or_texts()
      |> case do
        nil -> dynamic([_d], fragment("plainto_tsquery('english', ?)", ^positive_query))
        text -> dynamic([_d], fragment("(?::text)::tsquery", ^text))
      end

    ts_rank =
      case index do
        # A suggestion ranks on the narrow columns only: no stored vector is
        # read, so no row is decompressed.
        :none ->
          dynamic([_d], fragment("0.0::real"))

        index ->
          dynamic([_d], fragment("ts_rank(?, ?)", ^rank_vector(index), ^rank_query))
      end

    folded_query = Fold.fold(positive_query)

    phrase =
      if folded_query == "" or length(String.split(folded_query)) < 2 do
        dynamic([_d], fragment("0.0"))
      else
        dynamic(
          [_d],
          fragment(
            "(CASE WHEN ? LIKE ? THEN 0.5 WHEN ? LIKE ? THEN 0.4 WHEN ? LIKE ? THEN 0.25 ELSE 0.0 END)",
            ^folded_search_label(),
            ^(escape_like(folded_query) <> "%"),
            ^search_names(),
            ^("% " <> escape_like(folded_query) <> "%"),
            ^folded_search_label(),
            ^like_pattern(folded_query)
          )
        )
      end

    # The words in the query's order, next to each other, anywhere in the
    # document ("sofies verden" in a description): 0.3, for a query of two or
    # more words. Reads the stored vector, so a suggestion skips it.
    adjacent =
      case {index, String.split(positive_query)} do
        {:none, _} ->
          dynamic([_d], fragment("0.0"))

        {_, [_, _ | _]} ->
          vector = rank_vector(index)

          dynamic(
            [_d],
            fragment(
              "(CASE WHEN ? @@ phraseto_tsquery('english', ?) THEN 0.3 ELSE 0.0 END)",
              ^vector,
              ^positive_query
            )
          )

        _ ->
          dynamic([_d], fragment("0.0"))
      end

    # Trigram similarity is a near-miss signal. When the documents matched the
    # words themselves, a title that merely looks like the query is no better a
    # hit ("Den lydige datteren" for "lydbok"), so the per-field similarity
    # counts only on the near-miss pass, where the `searchable_fields` weights
    # decide which field's near miss ranks first.
    field_sim =
      if near_miss?,
        do: weighted_field_similarity(positive_query, config),
        else: dynamic([_d], fragment("0.0"))

    boost = tag_boost_key(tag_terms)
    cover = cover_key(groups)
    whole = whole_word_key(groups)

    dynamic(
      [_d],
      fragment(
        "? + ? + ? + ? + ? + ? + ?",
        ^ts_rank,
        ^field_sim,
        ^cover,
        ^whole,
        ^phrase,
        ^adjacent,
        ^boost
      )
    )
  end

  # `?boost=popularity` (task-5feac4e826cff9a5): adds
  # `weight * score / (score + 10)` to relevance, where `score` is the
  # document's decayed view score from `document_popularity`. The term stays
  # below `weight` (0.1 by default, `config :barkpark, Barkpark.Search.Views,
  # boost_weight:`), the same scale as the tag boost, so views reorder
  # documents of similar relevance and cannot lift a weak match over a strong
  # one. A score of 10 gives half the weight. The ranking pool bounds the
  # rows this runs on.
  defp boosted(key, :popularity) do
    weight =
      :barkpark
      |> Application.get_env(Barkpark.Search.Views, [])
      |> Keyword.get(:boost_weight, 0.1)

    score = Barkpark.Search.Views.sql_value(:score, false)

    dynamic(
      [_d],
      fragment("? + ? * (?)::float / ((?)::float + 10.0)", ^key, ^weight, ^score, ^score)
    )
  end

  defp boosted(key, _boost), do: key

  # Weighted-tag boost subplan. Shape guards make legacy content contribute 0
  # without erroring: non-array `tags` → '[]'::jsonb, flat string elements fail
  # jsonb_typeof(e)='object', and a non-integer strength fails the digits guard
  # instead of blowing up the ::int cast mid-query. Untagged docs get +0.
  #
  # PERF (search-latency slice d, task-9faff63dd9199c7d): the source array is the
  # `tags_meta` GENERATED STORED column (migration 20260718100000), NOT the inline
  # `CASE WHEN jsonb_typeof(content->'tags')='array' THEN content->'tags' ELSE
  # '[]'::jsonb END` this used to evaluate. `tags_meta` IS that exact CASE
  # materialized at write time (the non-array → '[]' guard now lives in the
  # generated expression), so `jsonb_array_elements(tags_meta)` is byte-identical
  # to the old inline form — the boost computes the same value. The win: the ORDER
  # BY no longer DETOASTs the ~8.5KB–88KB `content` jsonb per candidate row to
  # reach `->'tags'` (prod EXPLAIN over a 200-row pool: SubPlan 2,126 → 0 buffers,
  # 47 → 1.6 ms). Read via `?.tags_meta` on the row binding, mirroring how
  # `?.search_vector` reads its own virtual/GENERATED column.
  defp tag_boost_key(tag_terms) do
    dynamic(
      [d],
      fragment(
        "0.1 * COALESCE((SELECT max((e->>'strength')::int) FROM jsonb_array_elements(?.tags_meta) e WHERE jsonb_typeof(e) = 'object' AND e->>'strength' ~ '^[0-9]+$' AND lower(e->>'tag') = ANY(?)), 0)::float / 100.0",
        d,
        type(^tag_terms, {:array, :string})
      )
    )
  end

  # Fold `searchable_fields` per-field weights into a single similarity signal:
  #   Σ(weight_i · similarity(field_i, query)) / max(weight_i)
  # Max-weight normalization (not Σ-weight) keeps the default config's dominant
  # field (title, weight 10) contributing its raw similarity, so an unmatched
  # secondary field (e.g. content.slug) never dilutes the historical title-only
  # ranking. A per-field weight change reorders results because each field's
  # contribution scales linearly with its weight.
  defp weighted_field_similarity(query, config) do
    fields = searchable_fields(config)
    max_weight = fields |> Enum.map(& &1.weight) |> Enum.max()

    sum =
      Enum.reduce(fields, nil, fn %{path: path, weight: weight}, acc ->
        term = field_similarity_term(path, weight, query)
        if acc, do: dynamic([_d], fragment("? + ?", ^acc, ^term)), else: term
      end)

    dynamic([_d], fragment("(?) / ?", ^sum, ^max_weight))
  end

  # Per-field weighted trigram-similarity term. `title` is the search title; every other
  # path is a jsonb path into `content` (a leading `content.` prefix is optional,
  # so both "content.slug" and "slug" resolve to content->>'slug'). Deeper dotted
  # paths ("a.b") use the `#>>` text-array accessor. All keys are bound params —
  # no identifier interpolation, so config values can never inject SQL.
  defp field_similarity_term("title", weight, query) do
    dynamic(
      [_d],
      fragment("? * similarity(coalesce(?, ''), ?)", ^(weight * 1.0), ^search_label(), ^query)
    )
  end

  defp field_similarity_term(path, weight, query) do
    case materialized_text_column(path) do
      nil ->
        keys = content_keys(path)

        dynamic(
          [d],
          fragment(
            "? * similarity(coalesce(?#>>?, ''), ?)",
            ^(weight * 1.0),
            d.content,
            type(^keys, {:array, :string}),
            ^query
          )
        )

      column ->
        dynamic(
          [d],
          fragment(
            "? * similarity(coalesce(?, ''), ?)",
            ^(weight * 1.0),
            field(d, ^column),
            ^query
          )
        )
    end
  end

  # A jsonb path already materialized as a GENERATED STORED text column (#4174 /
  # slice b) → read the narrow column instead of the `content#>>{key}` detour, so
  # the ORDER BY's per-candidate similarity input no longer DETOASTs `content`.
  # BYTE-IDENTICAL by construction (a single-key `content#>>'{k}'` equals
  # `content->>'k'`):
  #   * ["slug"]     → slug_text     = coalesce(content->>'slug','') ; coalesce(slug_text,'')     ≡ coalesce(content#>>'{slug}','')
  #   * ["author"]   → author_text   = content->>'author'           ; coalesce(author_text,'')   ≡ coalesce(content#>>'{author}','')
  #   * ["category"] → category_text = content->>'category'         ; coalesce(category_text,'') ≡ coalesce(content#>>'{category}','')
  # Only these single-key paths map; deeper/other config paths keep the
  # `content#>>` fallback verbatim. The DEFAULT + live prod `documents` config's
  # `content.slug` field (weight 3) is exactly this case — verified on prod
  # (search_surface_config) — so the field-similarity content detoast is gone on
  # the real path with NO new column and NO ranking change.
  defp materialized_text_column(path) do
    case content_keys(path) do
      ["slug"] -> :slug_text
      ["author"] -> :author_text
      ["category"] -> :category_text
      _ -> nil
    end
  end

  defp content_keys("content." <> rest), do: String.split(rest, ".")
  defp content_keys(path), do: String.split(path, ".")

  # Normalize `config["searchable_fields"]` → [%{path, weight}] with positive
  # numeric weights. Falls back to title-only (weight 1) when the config carries
  # nothing usable, preserving the legacy single-field ranking.
  defp searchable_fields(config) do
    (config || %{})
    |> Map.get("searchable_fields", [])
    |> List.wrap()
    |> Enum.map(&normalize_search_field/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> [%{path: "title", weight: 1.0}]
      fields -> fields
    end
  end

  defp normalize_search_field(%{"path" => path} = field)
       when is_binary(path) and path != "" do
    case field_weight(Map.get(field, "weight")) do
      weight when weight > 0 -> %{path: path, weight: weight}
      _ -> nil
    end
  end

  defp normalize_search_field(_), do: nil

  defp field_weight(weight) when is_number(weight), do: weight * 1.0

  defp field_weight(weight) when is_binary(weight) do
    case Float.parse(weight) do
      {parsed, _} -> parsed
      :error -> 0.0
    end
  end

  # A field with no explicit weight defaults to 1 (still ranks, just unweighted).
  defp field_weight(nil), do: 1.0
  defp field_weight(_), do: 0.0

  def like_pattern(term), do: "%" <> escape_like(term) <> "%"

  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # Defense-in-depth: fail CLOSED. Only the explicit `:raw` ATOM (which a
  # controller produces solely for an authenticated/preview caller) returns the
  # unfiltered query. Any other value — a stray string like "published", an
  # unknown atom, garbage — falls back to the published filter rather than
  # leaking drafts. The old catch-all returned the query unfiltered for ANY
  # non-atom value, so a controller passing the string "published" silently
  # disabled the perspective filter entirely (anonymous draft disclosure).
  @doc false
  def perspective_filter(query, :published) do
    where(query, [d], not like(d.doc_id, "drafts.%"))
  end

  # `:drafts` is the draft-over-published OVERLAY, the meaning `?perspective=drafts`
  # has on the query and doc reads (owner ruling #52, 2026-10-03). It used to be
  # drafts-ONLY here, so a client passing one perspective to both surfaces never
  # found a published document in search (the Go TUI worked around it by asking
  # for `raw`). Each logical document appears once: its `drafts.` twin when one
  # exists, else the published row. A published row whose twin exists is dropped
  # whether or not the twin matches the query, so the hit set is "the overlay,
  # then the match" — the rows `Content.Query`'s DISTINCT ON would pick. One
  # WHERE clause, so results, count and facets (all derived from `base`) stay
  # consistent. The twin probe rides the (doc_id, type, dataset_id) unique index.
  def perspective_filter(query, :drafts) do
    where(
      query,
      [d],
      like(d.doc_id, "drafts.%") or
        fragment(
          "NOT EXISTS (SELECT 1 FROM documents t WHERE t.doc_id = 'drafts.' || ? AND t.type = ? AND t.dataset_id IS NOT DISTINCT FROM ? AND t.dataset = ?)",
          d.doc_id,
          d.type,
          d.dataset_id,
          d.dataset
        )
    )
  end

  def perspective_filter(query, :raw), do: query

  def perspective_filter(query, _other), do: perspective_filter(query, :published)
end
