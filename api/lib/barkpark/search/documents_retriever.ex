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
      # Grant row-narrowing (airdrop-grants Layer 2). A NO-OP unless the caller
      # is grant-derived (`opts[:grant_scoped]`, threaded from the pipeline's
      # retriever_opts). Applied ONCE on `base` — count (below) and facets both
      # derive from `base`, so this single clause seals results + count + facets
      # for EVERY consumer of `Content.search_documents` (SearchController,
      # SearchChannel, federated) at once. Fail-closed via `scope_to_grants`'
      # `where: false` on an undecidable grant.
      |> maybe_scope_to_grants(opts)

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
      |> maybe_light_select(Keyword.get(opts, :fields))
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
        #
        # WHY-LEFT (authoring-excellence D49 — do NOT `%`-rewrite this). This
        # `similarity(?, ?) > ?` arm is index-OPAQUE but rewriting it to the
        # GIN-engaging `%` operator (the D46 idiom) buys NOTHING here: it is OR-d
        # (`^clause or …`) with the UNINDEXED `coalesce(?->>'slug') ILIKE ?`
        # sibling built into `clause` above. A BitmapOr can only form when EVERY
        # branch is independently indexable, so the slug-ILIKE poisons the whole
        # disjunction into a Seq Scan — PROVEN live: the full chain Seq-Scans even
        # with the prod jsonb_path_ops slug index present, and dropping ONLY the
        # slug arm restores a 3-way BitmapOr. A `%` rewrite here plans byte-
        # identically to the Seq Scan; a full-path EXPLAIN "proving" a win is the
        # vacuous-green trap. Un-poisoning needs a trgm expression index on
        # content->>'slug' (backlog ae-search-or-arm-restructure). See D49(c).
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
    excludes = Enum.reject(excludes, &(&1 == ""))

    Enum.reduce(excludes, nil, fn term, dyn ->
      pattern = like_pattern(term)

      # WHY-LEFT (authoring-excellence D49 — do NOT `%`-rewrite this exclude
      # arm). This whole clause is NEGATED at `where_match/5` via
      # `not(^exclude_dyn)` — the query asks "which rows do NOT match this
      # term". A trgm GIN answers "which rows MATCH" (it enumerates candidates
      # ABOVE the similarity floor), never the complement; `NOT (title % ?)`
      # alone Seq-Scans even under `enable_seqscan=off` (proven live), because
      # the planner has no index that lists non-matching rows. Rewriting the
      # `similarity() > ?` to `%` changes nothing — the negation is the hard
      # disqualifier, not the operator form. See D49(b).
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

  defp order_rank(queryable, parsed, config) do
    # Rank on the WHOLE positive query (every term + phrase), not just the first
    # token. plainto_tsquery AND-chains the words, so a multi-word query ranks
    # on ALL of them; for a single term this is identical to the old hd(terms).
    positive_query =
      (Map.get(parsed, :terms, []) ++ Map.get(parsed, :phrases, []))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    # Lowercased query tokens for the weighted-tag boost arm below — a tag's
    # NAME must equal a query term for its strength to move rank (topic-aware
    # by construction; a high-strength tag on an unrelated topic buys nothing).
    tag_terms =
      positive_query
      |> String.downcase()
      |> String.split()

    if positive_query == "" do
      # Browse path (empty query) — recency, then the id PK so the order is TOTAL.
      # updated_at is not unique; without the tiebreaker LIMIT/OFFSET paging over
      # same-timestamp rows can skip or duplicate across page boundaries.
      order_by(queryable, [d], desc: d.updated_at, asc: d.id)
    else
      # Dynamic ORDER BY so the relevance key can fold the ADMIN-CONFIGURED
      # `searchable_fields` per-field weights into the trigram-similarity arm
      # (charter W7 / bpb-searchable-fields-dead-config). The knob was echoed in
      # admin settings but never read on the query path — a lie in the UI. Now a
      # per-field weight change actually reorders results (Kinsta/Vercel bar).
      order_by(
        queryable,
        ^[
          # 1) Exact title match wins outright — typing a doc's exact title
          #    guarantees it ranks #1, ahead of any relevance score.
          {:desc, exact_title_key(positive_query)},
          # 2) Relevance: GREATEST(full-text rank, weighted per-field similarity)
          #    + the weighted-tag boost.
          {:desc, relevance_key(positive_query, tag_terms, config)},
          # 3) Recency tiebreak.
          {:desc, dynamic([d], d.updated_at)},
          # 4) id PK — final unique tiebreaker so the whole rank order is TOTAL
          #    (rank AND recency can both tie); keeps LIMIT/OFFSET paging stable.
          {:asc, dynamic([d], d.id)}
        ]
      )
    end
  end

  # ORDER BY key #1: exact (case-insensitive) title match → 1, else 0.
  defp exact_title_key(positive_query) do
    dynamic(
      [d],
      fragment("CASE WHEN lower(?) = lower(?) THEN 1 ELSE 0 END", d.title, ^positive_query)
    )
  end

  # ORDER BY key #2: GREATEST(full-text ts_rank, weighted per-field trigram
  # similarity) PLUS the weighted-tag boost (authoring excellence D8/D21):
  # + 0.1·max(strength)/100 over the doc's weighted tags whose name matches a
  # query term. ADDITIVE with small w=0.1, never a bare GREATEST arm — a
  # normalized strength (0.2–0.95) would dwarf typical ts_rank (~0.05) and erase
  # textual relevance.
  #
  # The similarity arm is no longer hardcoded to `similarity(title, query)`: it
  # is the weighted composite over `config["searchable_fields"]` (per-field
  # {path, weight}), max-weight-normalized so the default `[{title,10},…]` still
  # reduces to title-dominated ranking when no other field matches.
  #
  # WHY-LEFT (authoring-excellence D49 — these `similarity()` arms are NOT
  # trgm-index material). They live in an ORDER BY GREATEST(ts_rank, …)
  # composite ranking key, not a WHERE candidate filter. A GIN trgm index
  # accelerates set MEMBERSHIP (`%` / `similarity() > floor`), never a KNN/ranked
  # ORDER BY — only a GiST `<->` distance operator can drive an ordered index
  # scan, and this is a GREATEST of scalar signals, not a single-column
  # distance. The pool is already bounded to 500 rows upstream, so the per-row
  # cost is negligible; leave it. See D49(d).
  defp relevance_key(positive_query, tag_terms, config) do
    ts_rank =
      dynamic(
        [d],
        fragment("ts_rank(?.search_vector, plainto_tsquery('english', ?))", d, ^positive_query)
      )

    field_sim = weighted_field_similarity(positive_query, config)
    boost = tag_boost_key(tag_terms)

    dynamic([_d], fragment("GREATEST(?, ?) + ?", ^ts_rank, ^field_sim, ^boost))
  end

  # Weighted-tag boost subplan. Shape guards make legacy content contribute 0
  # without erroring: non-array `tags` → '[]'::jsonb, flat string elements fail
  # jsonb_typeof(e)='object', and a non-integer strength fails the digits guard
  # instead of blowing up the ::int cast mid-query. Untagged docs get +0.
  defp tag_boost_key(tag_terms) do
    dynamic(
      [d],
      fragment(
        "0.1 * COALESCE((SELECT max((e->>'strength')::int) FROM jsonb_array_elements(CASE WHEN jsonb_typeof(?->'tags') = 'array' THEN ?->'tags' ELSE '[]'::jsonb END) e WHERE jsonb_typeof(e) = 'object' AND e->>'strength' ~ '^[0-9]+$' AND lower(e->>'tag') = ANY(?)), 0)::float / 100.0",
        d.content,
        d.content,
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

  # Per-field weighted trigram-similarity term. `title` is a column; every other
  # path is a jsonb path into `content` (a leading `content.` prefix is optional,
  # so both "content.slug" and "slug" resolve to content->>'slug'). Deeper dotted
  # paths ("a.b") use the `#>>` text-array accessor. All keys are bound params —
  # no identifier interpolation, so config values can never inject SQL.
  defp field_similarity_term("title", weight, query) do
    dynamic(
      [d],
      fragment("? * similarity(coalesce(?, ''), ?)", ^(weight * 1.0), d.title, ^query)
    )
  end

  defp field_similarity_term(path, weight, query) do
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

  def like_pattern(term) do
    escaped =
      term
      |> String.replace("\\", "\\\\")
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

  def perspective_filter(query, :drafts) do
    where(query, [d], like(d.doc_id, "drafts.%"))
  end

  def perspective_filter(query, :raw), do: query

  def perspective_filter(query, _other), do: perspective_filter(query, :published)
end
