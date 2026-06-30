defmodule Barkpark.Search.DocumentsRetriever do
  @moduledoc false

  @behaviour Barkpark.Search.Retriever

  import Ecto.Query
  import Barkpark.Content.Scope, only: [scope_to_workspace_or_global: 3, scope_to_owner: 2]
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  # Default ranking-pool size (Barkpark Cloud P4 / Move B). The expensive
  # per-row ranking computation (`ts_rank` + `similarity`) runs only on this
  # many candidates, picked cheaply via the GIN match + recency. Without the
  # bound, a broad query that matches 10k rows pays ranking cost on all of
  # them before the LIMIT; with the bound, cost stays constant regardless of
  # corpus size. 500 is generous headroom — the user-visible LIMIT defaults to
  # 50 and never exceeds 200, and recency-shifted candidates are exactly the
  # ones a relevance score is most likely to crown.
  @default_ranking_pool_size 500

  @impl Barkpark.Search.Retriever
  @spec search(String.t(), map(), map(), keyword()) ::
          {[struct()], non_neg_integer(), map()}
  def search(scope, parsed, config, opts) when is_binary(scope) do
    terms = search_terms(parsed)
    type = Keyword.get(opts, :type)
    perspective = Keyword.get(opts, :perspective, :published)
    limit = Keyword.get(opts, :limit, 50) |> min(200)
    offset = Keyword.get(opts, :offset, 0)
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
      Document
      |> scope_to_dataset(scope, project_id)
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

    base = if browse?, do: base, else: where_match(base, parsed, terms, config, relaxed)
    base = if type, do: where(base, [d], d.type == ^type), else: base
    # Optional type allowlist (the finder's content types) — applied to `base`
    # so results, count, AND facets are all consistent over the same set.
    types = Keyword.get(opts, :types)
    base = if is_list(types) and types != [], do: where(base, [d], d.type in ^types), else: base
    base = perspective_filter(base, perspective)

    # Bounded ranking pool: for real queries, narrow to a cheap-signal candidate
    # set BEFORE running the expensive ranking ORDER BY. Browse stays unbounded
    # since its only ORDER BY is `updated_at DESC` — already cheap and the
    # browse contract returns the whole scoped set in recency order.
    ranking_input =
      if browse? do
        base
      else
        bounded_pool(base, pool_size)
      end

    docs =
      ranking_input
      |> order_rank(parsed, config)
      |> limit(^limit)
      |> offset(^offset)
      |> Repo.all()

    count = base |> exclude(:order_by) |> select([d], count(d.id)) |> Repo.one() || 0
    # Facet counts via GROUP BY over the matching set — Postgres's parity with
    # Indx's native facets, surfaced through the same `meta.facets` channel.
    # Facets stay on the FULL match set (not the ranking pool), because the
    # user wants "this query matched 1.2k items across these facets", not
    # "the top 500 break down this way".
    {docs, count, %{facets: facet_counts(base)}}
  end

  # Apply the bounded ranking pool: filter the query to the `pool_size` rows
  # with the highest cheap-signal score (`updated_at DESC`, with exact-title
  # matches always surviving via the ranking ORDER BY's #1 sort key). The full
  # ranking computation in `order_rank/3` then runs on at most `pool_size`
  # rows, regardless of how big the match set is.
  #
  # Implementation: a subquery selecting just the id of the top-pool candidates,
  # used as an `id IN (...)` filter on the outer query. Two index lookups, one
  # cheap, one expensive — but expensive runs on a bounded input.
  defp bounded_pool(base, pool_size) when pool_size > 0 do
    candidate_ids =
      base
      |> exclude(:order_by)
      |> order_by([d], desc: d.updated_at)
      |> limit(^pool_size)
      |> select([d], d.id)

    base |> exclude(:order_by) |> where([d], d.id in subquery(candidate_ids))
  end

  defp bounded_pool(base, _), do: base

  # Dataset-wide (browse) / match-set (query) facet buckets per dimension, in
  # the same shape the Indx retriever returns: %{field => [%{"label","count"}]},
  # empty-label buckets dropped, biggest first.
  defp facet_counts(base) do
    %{}
    |> put_facet("type", group_column(base, :type))
    |> put_facet("status", group_column(base, :status))
    |> put_facet("author", group_content(base, "author"))
    |> put_facet("category", group_content(base, "category"))
  end

  defp group_column(base, field) do
    base
    |> exclude(:order_by)
    |> group_by([d], field(d, ^field))
    |> select([d], {field(d, ^field), count(d.id)})
    |> Repo.all()
  end

  defp group_content(base, key) do
    # `selected_as` so GROUP BY references the SELECT alias — a parameterized
    # `content->>$1` in both clauses reads as two different params to Postgres
    # ("must appear in GROUP BY"); grouping by the alias avoids that.
    base
    |> exclude(:order_by)
    |> select([d], {selected_as(fragment("?->>?", d.content, ^key), :facet_val), count(d.id)})
    |> group_by([d], selected_as(:facet_val))
    |> Repo.all()
  end

  defp put_facet(map, name, rows) do
    buckets =
      rows
      |> Enum.reject(fn {label, _} -> label in [nil, ""] end)
      |> Enum.sort_by(fn {_, count} -> -count end)
      |> Enum.map(fn {label, count} -> %{"label" => to_string(label), "count" => count} end)

    if buckets == [], do: map, else: Map.put(map, name, buckets)
  end

  # Mirror of Content.scope_to_dataset for the search read path (barkpark-y9ee).
  # Resolve the dataset STRING → its dataset_id within the read's project scope
  # and filter authoritatively by `dataset_id`; same-name datasets across
  # projects (and within a workspace) no longer conflate. Fall back to the
  # legacy `dataset` STRING filter only when the dataset can't be resolved
  # (no project scope / dataset row predates the W2 dual-write), which keeps the
  # leaf discriminator working for back-compat reads.
  defp scope_to_dataset(query, scope, project_id) do
    case Barkpark.Content.resolve_read_dataset_id(scope, project_id: project_id) do
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

  defp where_match(queryable, parsed, terms, config, relaxed) do
    include_dyn = include_dynamic(terms, parsed, config, relaxed)
    exclude_dyn = exclude_dynamic(Map.get(parsed, :excludes, []), relaxed)

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

  defp include_dynamic(terms, parsed, config, relaxed) do
    threshold = similarity_threshold(config, relaxed)
    # Min token length below which the pg_trgm fuzzy arm is suppressed (still
    # matchable via tsvector/ilike). Short tokens like "hi"/"by" otherwise
    # trigram-match almost anything above threshold — pure false positives.
    min_fuzzy_len = fuzzy_min_len(config)

    term_dyn =
      Enum.reduce(terms, nil, fn term, dyn ->
        pattern = like_pattern(term)
        prefix_pattern = prefix_pattern(term)

        clause =
          dynamic(
            [d],
            fragment("?.search_vector @@ plainto_tsquery('english', ?)", d, ^term) or
              ilike(d.title, ^pattern) or
              ilike(coalesce(fragment("?->>'slug'", d.content), ""), ^pattern)
          )

        # Fuzzy title arm only for tokens long enough to be meaningful.
        clause =
          if String.length(term) >= min_fuzzy_len do
            dynamic([d], ^clause or fragment("similarity(?, ?) > ?", d.title, ^term, ^threshold))
          else
            clause
          end

        clause =
          if prefix_pattern do
            dynamic([d], ^clause or ilike(d.title, ^prefix_pattern))
          else
            clause
          end

        if dyn, do: dynamic([d], ^dyn or ^clause), else: clause
      end)

    # Phrase arms: phraseto_tsquery enforces true word adjacency, so the
    # advertised "exact phrase" syntax actually matches adjacent words (a phrase
    # also still matches its words individually via the term arms above, since
    # each phrase is folded into `terms` by search_terms/1).
    Enum.reduce(Map.get(parsed, :phrases, []), term_dyn, fn phrase, dyn ->
      clause =
        dynamic(
          [d],
          fragment("?.search_vector @@ phraseto_tsquery('english', ?)", d, ^phrase)
        )

      if dyn, do: dynamic([d], ^dyn or ^clause), else: clause
    end)
  end

  defp exclude_dynamic(excludes, relaxed) do
    threshold = similarity_threshold(%{}, relaxed)

    Enum.reduce(excludes, nil, fn term, dyn ->
      pattern = like_pattern(term)

      clause =
        dynamic(
          [d],
          fragment("?.search_vector @@ plainto_tsquery('english', ?)", d, ^term) or
            ilike(d.title, ^pattern) or
            ilike(coalesce(fragment("?->>'slug'", d.content), ""), ^pattern) or
            fragment("similarity(?, ?) > ?", d.title, ^term, ^threshold)
        )

      if dyn, do: dynamic([d], ^dyn or ^clause), else: clause
    end)
  end

  defp order_rank(queryable, parsed, _config) do
    # Rank on the WHOLE positive query (every term + phrase), not just the first
    # token. plainto_tsquery AND-chains the words, so a multi-word query ranks
    # on ALL of them; for a single term this is identical to the old hd(terms).
    positive_query =
      (Map.get(parsed, :terms, []) ++ Map.get(parsed, :phrases, []))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    if positive_query == "" do
      # Browse path (empty query) — recency, then the id PK so the order is TOTAL.
      # updated_at is not unique; without the tiebreaker LIMIT/OFFSET paging over
      # same-timestamp rows can skip or duplicate across page boundaries.
      order_by(queryable, [d], desc: d.updated_at, asc: d.id)
    else
      order_by(queryable, [d],
        # 1) Exact title match wins outright — typing a doc's exact title
        #    guarantees it ranks #1, ahead of any relevance score.
        desc:
          fragment("CASE WHEN lower(?) = lower(?) THEN 1 ELSE 0 END", d.title, ^positive_query),
        # 2) Relevance over the whole query: best of full-text rank and title
        #    trigram similarity.
        desc:
          fragment(
            "GREATEST(ts_rank(?.search_vector, plainto_tsquery('english', ?)), similarity(?, ?))",
            d,
            ^positive_query,
            d.title,
            ^positive_query
          ),
        # 3) Recency tiebreak.
        desc: d.updated_at,
        # 4) id PK — final unique tiebreaker so the whole rank order is TOTAL
        #    (rank AND recency can both tie); keeps LIMIT/OFFSET paging stable.
        asc: d.id
      )
    end
  end

  # Minimum token length for the pg_trgm fuzzy title arm — reads
  # typo_policy.min_len_1typo, defaulting to 4 when absent. Tokens shorter than
  # this skip the similarity() arm (they still match via tsvector/ilike).
  defp fuzzy_min_len(config) do
    config
    |> Map.get("typo_policy", %{})
    |> Map.get("min_len_1typo", 4)
  end

  defp similarity_threshold(config, true) do
    config
    |> Map.get("typo_policy", %{})
    |> Map.get("similarity_threshold_relaxed", 0.15)
  end

  defp similarity_threshold(config, false) do
    config
    |> Map.get("typo_policy", %{})
    |> Map.get("similarity_threshold", 0.25)
  end

  defp like_pattern(term) do
    escaped =
      term
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%" <> escaped <> "%"
  end

  defp prefix_pattern(term) do
    if String.ends_with?(term, "*") do
      String.trim_trailing(term, "*")
      |> then(fn t ->
        if t == "", do: nil, else: like_pattern(t)
      end)
    else
      nil
    end
  end

  defp perspective_filter(query, :published) do
    where(query, [d], not like(d.doc_id, "drafts.%"))
  end

  defp perspective_filter(query, :drafts) do
    where(query, [d], like(d.doc_id, "drafts.%"))
  end

  defp perspective_filter(query, _raw), do: query
end
