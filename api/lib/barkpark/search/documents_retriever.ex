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
  alias Barkpark.Search.TypoPolicy

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

    base = if browse?, do: base, else: where_match(base, parsed, terms, config, relaxed)
    base = if type, do: where(base, [d], d.type == ^type), else: base
    # Optional type allowlist (the finder's content types) — applied to `base`
    # so results, count, AND facets are all consistent over the same set.
    types = Keyword.get(opts, :types)
    base = if is_list(types) and types != [], do: where(base, [d], d.type in ^types), else: base
    base = perspective_filter(base, perspective)

    # Count + all four facet dimensions in ONE round trip over the match set
    # (search-latency slice c). Runs BEFORE the retrieve so its exact `count`
    # can gate the bounded-pool self-subquery below. Facets + count stay on the
    # FULL match set (not the ranking pool): the user wants "this query matched
    # 1.2k items across these facets", not "the top 500 break down this way".
    {count, facets} = count_and_facets(base)

    # Bounded ranking pool: for real queries, narrow to a cheap-signal candidate
    # set BEFORE running the expensive ranking ORDER BY. Browse stays unbounded
    # (its only ORDER BY is `updated_at DESC` — already cheap, and its contract
    # returns the whole scoped set in recency order). ELIDE the pool when the
    # match set already fits inside it (`count <= pool_size`): `bounded_pool`
    # would then select EVERY matched id into the `id IN (...)` subquery, a
    # no-op filter that only costs a second scan of the predicate. Skipping it
    # is provably identical (|match| ≤ pool ⇒ {top pool by updated_at} ⊇ match ⇒
    # the intersection IS the match set) and halves the retrieve's predicate
    # evals on the common small-corpus path (prod: ≤335 matches < 500 pool). At
    # `count > pool_size` the bound is load-bearing and stays.
    ranking_input =
      if browse? or count <= pool_size do
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

    {docs, count, %{facets: facets}}
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
  @g_type 0b0111
  @g_status 0b1011
  @g_author 0b1101
  @g_category 0b1110
  @g_total 0b1111

  defp count_and_facets(base) do
    rows =
      base
      |> exclude(:order_by)
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
          "GROUPING SETS ((?), (?), (?), (?), ())",
          d.type,
          d.status,
          d.author_text,
          d.category_text
        )
      )
      |> Repo.all()

    init = %{count: 0, type: [], status: [], author: [], category: []}

    acc =
      Enum.reduce(rows, init, fn row, acc ->
        case row.g do
          @g_total -> %{acc | count: row.count}
          @g_type -> %{acc | type: [{row.type, row.count} | acc.type]}
          @g_status -> %{acc | status: [{row.status, row.count} | acc.status]}
          @g_author -> %{acc | author: [{row.author, row.count} | acc.author]}
          @g_category -> %{acc | category: [{row.category, row.count} | acc.category]}
          _ -> acc
        end
      end)

    facets =
      %{}
      |> put_facet("type", acc.type)
      |> put_facet("status", acc.status)
      |> put_facet("author", acc.author)
      |> put_facet("category", acc.category)

    {acc.count, facets}
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
    threshold = TypoPolicy.threshold(config, relaxed)

    term_dyn =
      Enum.reduce(terms, nil, fn term, dyn ->
        pattern = like_pattern(term)
        prefix_pattern = prefix_pattern(term)

        clause =
          dynamic(
            [d],
            fragment("?.search_vector @@ plainto_tsquery('english', ?)", d, ^term) or
              ilike(d.title, ^pattern) or
              ilike(d.slug_text, ^pattern)
          )

        # Fuzzy title arm only for tokens long enough to be meaningful.
        #
        # WHY-LEFT (authoring-excellence D49 — do NOT `%`-rewrite this). This
        # `similarity(?, ?) > ?` arm is index-OPAQUE, but rewriting it to the
        # GIN-engaging `%` operator (the D46 idiom) still buys NOTHING: it is OR-d
        # (`^clause or …`) with the UNINDEXED `slug_text ILIKE ?` sibling in
        # `clause` above. A BitmapOr can only form when EVERY branch is
        # independently indexable, so the slug-ILIKE keeps the whole disjunction a
        # bitmap-filter scan — PROVEN live: even a trgm expression index on
        # content->>'slug', created CONCURRENTLY, went EXPLAIN-unused (planner
        # bitmap-scans documents_type_dataset_index then FILTERs the OR arms
        # per row), and was dropped. The `%`-rewrite prohibition therefore stands.
        #
        # What slice b (migration 20260718090000) DID fix is the poison the D49
        # note called out separately: the slug arm no longer reads
        # `content->>'slug'` (a per-row detoast of the ~88KB `content` jsonb,
        # measured +1,501 buffers on EVERY predicate eval — count + facets re-run
        # it 4-5x/keystroke). It now reads the narrow `slug_text` GENERATED STORED
        # column, so the filter is cheap without changing the plan shape or the
        # matched set (slug_text = coalesce(content->>'slug','') by construction).
        # The fuzzy arm runs only for terms `TypoPolicy` admits: typo tolerance
        # ON (`typo_policy.enabled`) and the token at least `min_len_1typo`
        # long. Short tokens like "hi"/"by" otherwise trigram-match almost
        # anything above threshold — pure false positives — and an admin who
        # switched typo tolerance off used to get this arm anyway.
        clause =
          if TypoPolicy.fuzzy_term?(config, term) do
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
    # NOTE the empty config: the exclude arm has never read the surface config's
    # thresholds, so it keeps the code defaults here. Routed through the shared
    # reader anyway so the defaults cannot drift from the include arm's.
    threshold = TypoPolicy.threshold(%{}, relaxed)
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
            ilike(d.slug_text, ^pattern) or
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
