defmodule BarkparkWeb.QueryController do
  use BarkparkWeb, :controller

  import Ecto.Query, only: [from: 2, where: 3]

  alias Barkpark.Content
  alias Barkpark.Content.CallerContext
  alias Barkpark.Content.Document
  alias Barkpark.Content.DraftId
  alias Barkpark.Content.Envelope
  alias Barkpark.Content.Expand
  alias Barkpark.Content.Scope
  alias Barkpark.Repo
  alias BarkparkWeb.AnonPerspective
  alias BarkparkWeb.ErrorResponse
  alias BarkparkWeb.Http.IfNoneMatch

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  action_fallback(BarkparkWeb.FallbackController)

  def index(conn, %{"dataset" => dataset, "type" => type} = params) do
    cond do
      not (preview?(conn) or authed?(conn) or
               Content.schema_public?(type, dataset, scope_opts(conn))) ->
        {:error, :not_found}

      # An unsupported ?perspective is a 400, not a silent downgrade — the
      # existence-hiding 404 above comes FIRST so the refusal can never become
      # an existence probe, exactly the ordering counts/2 uses.
      bad = unsupported_read_perspective(params) ->
        refuse_read_perspective(conn, bad)

      true ->
        query_index(conn, dataset, type, params)
    end
  end

  defp query_index(conn, dataset, type, params) do
    t0 = System.monotonic_time(:microsecond)
    perspective = AnonPerspective.resolve(conn, params)
    # Clamp to the same bounds Content.list_documents enforces (limit [1,1000],
    # offset [0,100_000] — see Content.Query) so the echoed limit/offset in the
    # response body match what the query actually used. Otherwise a paginator
    # reading `limit`/`offset` back computes the wrong next page.
    limit = parse_int(params["limit"], 100) |> min(1000) |> max(1)
    offset = parse_int(params["offset"], 0) |> max(0) |> min(100_000)
    order = parse_order_param(params["order"])
    filter_map = params |> Map.get("filter", %{}) |> normalize_filter_map()
    expand_spec = parse_expand(params["expand"])

    schema = fetch_schema(conn, type, dataset)
    caller_context = CallerContext.from_conn(conn)

    cond do
      # An unparseable flat --filter string normalizes to an {:error, …}
      # sentinel, never %{} — an empty map here used to slip past both
      # guards below and SILENTLY return the UNFILTERED set (D75: `--filter
      # 'tags hasStrong x:50'` exited 0 with every row). A refusal naming
      # the accepted grammar beats a silent passthrough.
      match?({:error, _}, filter_map) ->
        filter_map

      # An unrecognised non-empty ?order= spec used to silently default to
      # :updated_at_desc (a DIFFERENT order than asked), hiding a client typo
      # as a successful response — the Gyldendal S2 silent-failures class.
      # parse_order_param/1 now returns {:error, {:invalid_order, spec}}
      # instead; route it to the existing Ecto.Changeset 422 validation_failed
      # envelope (no new error code) naming the bad spec and the grammar.
      match?({:error, _}, order) ->
        order_error(order)

      # Fail CLOSED on an unknown filter operator. Otherwise it falls through
      # the query builder's catch-all (apply_field_op/4) and SILENTLY returns
      # every row — a typo'd op (?filter[status][bogus]=x) looked like it
      # filtered but didn't. Checked here so the reject beats the query.
      bad = invalid_filter_op(filter_map) ->
        case bad do
          # A documented operator whose value/shape can't be honoured carries
          # its OWN message — the shared "unknown filter operator" wording
          # contradicted itself for hasStrong/is/$or (see invalid_filter_op/1).
          {:clause, message, details} ->
            {:error, {:invalid_filter_clause, message, details}}

          {field, op} ->
            {:error, {:invalid_filter_op, field, op}}
        end

      # WS-B MEDIUM-4: reject a filter/order that targets a field this caller may
      # not SEE — otherwise the WHERE/ORDER becomes an oracle to binary-search or
      # sort by a hidden field's value even though the body is redacted. Checked
      # BEFORE the query so the COUNT/order never runs over a forbidden field.
      field = forbidden_query_field(filter_map, order, schema, caller_context) ->
        {:error, {:forbidden_field, field}}

      true ->
        # TRUNCATION SIGNAL. `list_documents_page/3` reads one row past the page
        # and reports whether it materialised, so `hasMore` is an EXACT answer
        # for the price of one row — no COUNT. Without it an exhausted page and
        # a truncated one were byte-identical: `count`, `limit` and `offset` read
        # the same whether the type holds exactly `limit` rows or a million,
        # `total` appeared only if the caller knew to pass ?count=true, and the
        # default page is 100 — so every type past 100 documents silently
        # truncated for every consumer that did not know the trick.
        # `/v1/media/:dataset/search` has carried hasMore all along; this brings
        # the document query path to the same contract.
        {docs, has_more} =
          Content.list_documents_page(
            type,
            dataset,
            [
              perspective: perspective,
              filter_map: filter_map,
              limit: limit,
              offset: offset,
              order: order
            ] ++ scope_opts(conn)
          )

        rendered =
          Envelope.render_many(docs, schema, caller_context)
          |> Expand.expand(
            expand_spec,
            dataset,
            [published_only: AnonPerspective.anon_pinned?(conn), caller_context: caller_context] ++
              scope_opts(conn)
          )
          |> project_fields(parse_fields(params["fields"]))
          |> maybe_resolve_tasks(conn, params)

        inner =
          %{
            perspective: to_string(perspective),
            documents: rendered,
            count: length(docs),
            limit: limit,
            offset: offset,
            hasMore: has_more
          }
          |> maybe_put_next_offset(has_more, limit, offset)
          |> maybe_put_total(conn, params, type, dataset, perspective, filter_map)

        schema_hash = Content.schema_hash_for_dataset(dataset, scope_opts(conn))
        etag = list_etag(dataset, type, rendered)

        respond(
          conn,
          inner,
          schema_hash,
          list_sync_tags(dataset, type, rendered),
          etag,
          cache_validator(etag, schema_hash),
          t0
        )
    end
  end

  @doc """
  Inbound references — the documents that reference `:id` (Sanity's
  `*[references($id)]`). Wraps `Content.Graph.reverse_referencers/2`, which is
  FAIL-CLOSED: a referencing source the caller can't see (out-of-tenant,
  owner-scoped to another user, unpublished-to-anon) is dropped entirely — never
  stubbed — so backlinks never leak the existence of an unreadable link. Scoping
  is `[dataset: dataset] ++ scope_opts/1`, the same opts an internal caller
  passes (see `Content.Edges`). Auth mirrors a doc read: preview or a token,
  otherwise 404 (existence-hiding, like `index`).
  """
  def backlinks(conn, %{"dataset" => dataset, "id" => id}) do
    if preview?(conn) or authed?(conn) do
      backlinks = Content.Graph.reverse_referencers(id, [dataset: dataset] ++ scope_opts(conn))

      json(conn, %{
        result: %{backlinks: backlinks, count: length(backlinks)},
        syncTags: ["bp:ds:#{dataset}:backlinks:#{id}"]
      })
    else
      {:error, :not_found}
    end
  end

  @doc """
  Related documents — shared weighted tags fused with inbound references
  (authoring-excellence D68–D71). Wraps `Content.Related.related_documents/3`:
  the tag leg is strength-aware SQL over the `tags_meta` GENERATED column
  (LEAST min-strength credit per shared name + main_tag bonus), the reference
  leg reuses `Content.Graph.reverse_referencers/2`'s FAIL-CLOSED hydration
  (an unreadable referencing source is dropped, never stubbed), and fusion is
  by doc identity in Elixir. A source with zero weighted tags degrades to
  backlink-only related. Scoping threads `scope_opts/1` exactly like
  `backlinks/2`; auth mirrors a doc read: preview or a token, otherwise 404
  (existence-hiding, like `backlinks`).
  """
  def related(conn, %{"dataset" => dataset, "id" => id} = params) do
    if preview?(conn) or authed?(conn) do
      related =
        Content.Related.related_documents(
          id,
          dataset,
          [limit: parse_int(params["limit"], 10)] ++ scope_opts(conn)
        )

      json(conn, %{
        result: %{related: related, count: length(related)},
        syncTags: ["bp:ds:#{dataset}:related:#{id}"]
      })
    else
      {:error, :not_found}
    end
  end

  @doc """
  Bundled per-type published-document counts for a dataset (AXI charter
  decision 19 / `data.counts`). ONE `GROUP BY d.type` aggregate — never a
  per-type loop — over the tenancy-scoped, published set, so a bare `bp <noun>`
  can show live counts across every type in a single cheap round trip
  (index-covered by `documents_workspace_project_type_dataset_id_index`).

  Perspective is fixed to `:published` (the single perspective agents care
  about; per-perspective counts change the query shape) and a `?perspective`
  naming anything else is REFUSED with a 400 (PDS-D303). It used to be read and
  silently discarded: `?perspective=raw` and `?perspective=zzzbogus` both
  returned 200 with a byte-identical published body still labelled
  `"perspective":"published"` — a caller counting drafts got the published
  number and no way to know. Honouring `raw` here would change a frozen shape
  AND widen an existence-count surface this design deliberately hides, so the
  endpoint says no instead of lying. FROZEN response shape, which the CLI slice
  consumes verbatim:

      {"ok": true, "dataset": "<ds>", "perspective": "published",
       "counts": {"<type>": N, ...}}

  Tenancy FAILS CLOSED: the aggregate pipes through
  `Scope.scope_to_workspace/3` (a `nil` workspace yields zero rows, never every
  tenant's counts) + project narrowing. An unscoped `GROUP BY` would be a
  cross-tenant existence-count leak — the exact class the batch-count helpers
  guard against. Auth mirrors a doc read: preview or a token, otherwise 404
  (existence-hiding, like `backlinks`) — a per-type census across ALL types
  must not surface private-type existence to an anonymous caller.
  """
  def counts(conn, %{"dataset" => dataset} = params) do
    cond do
      # Existence-hiding FIRST: an anonymous caller gets the same 404 whatever
      # perspective it names, so the refusal below never becomes a probe.
      not (preview?(conn) or authed?(conn)) ->
        {:error, :not_found}

      unsupported_perspective(params) ->
        refuse_perspective(conn, unsupported_perspective(params))

      true ->
        json(conn, %{
          ok: true,
          dataset: dataset,
          perspective: "published",
          counts: published_type_counts(conn, dataset)
        })
    end
  end

  # `nil` (absent) and "published" are the honoured inputs; anything else comes
  # back so the refusal can name the value the caller actually sent.
  defp unsupported_perspective(params) do
    case Map.get(params, "perspective") do
      nil -> nil
      "published" -> nil
      other -> other
    end
  end

  # Canonical 400 `malformed` envelope (code/hint/request_id owned by
  # Content.Errors), with a message that names the parameter and the one value
  # this endpoint honours — a refusal a caller can act on, unlike the silent
  # published body it used to get.
  defp refuse_perspective(conn, value) do
    ErrorResponse.emit_custom(
      conn,
      400,
      "malformed",
      "unsupported perspective #{inspect(value)} on /v1/data/counts — this endpoint " <>
        "counts the published perspective only; omit ?perspective or pass published",
      %{parameter: "perspective", supported: ["published"], received: value}
    )
  end

  # ONE grouped aggregate: published docs (drafts.-prefixed ids excluded, the
  # `apply_perspective(:published)` clause), scoped to the tenant + dataset,
  # grouped by type. Returns `%{type => count}`; an empty scope is `%{}`.
  defp published_type_counts(conn, dataset) do
    opts = scope_opts(conn)
    prefix = DraftId.drafts_prefix() <> "%"

    from(d in Document,
      where: not like(d.doc_id, ^prefix),
      group_by: d.type,
      select: {d.type, count(d.id)}
    )
    |> Scope.scope_to_workspace(
      Keyword.get(opts, :workspace_id),
      Keyword.get(opts, :project_id)
    )
    |> scope_counts_to_dataset(dataset, opts)
    |> Repo.all()
    |> Map.new()
  end

  # Same dataset discriminator `Content.Query.list_documents` applies (resolve
  # the dataset_id, else fall back to the dataset string), so counts see exactly
  # the rows a list read of the same dataset would.
  defp scope_counts_to_dataset(query, dataset, opts) do
    case Content.resolve_read_dataset_id(dataset, opts) do
      id when is_binary(id) ->
        where(query, [d], d.dataset_id == ^id or (is_nil(d.dataset_id) and d.dataset == ^dataset))

      _ ->
        where(query, [d], d.dataset == ^dataset)
    end
  end

  @doc """
  Tag-registry browse — per-tag per-type published-document counts
  (authoring-excellence ae-w10 / manifest `tag.browse`). Wraps
  `Content.TagDistribution.per_type/3` with the CALLER'S tenant scope
  (`scope_opts/1`) — NEVER the daily worker's `opts: []` global call shape,
  which here would be a cross-tenant existence-count leak (the exact class
  `data_counts_test.exs` guards). The SQL rows `{type, tag, count}` are
  regrouped in Elixir to per-tag rows `{tag, counts: {type => n}, total}`
  sorted total DESC (tag asc tie-break).

  Perspective is published-only BY DESIGN: draft and published copies are
  SEPARATE rows, so counting drafts would double-count every doc with an open
  draft twin — the registry counts the published vocabulary, the corpus the
  publish wall governs. NOT an extension of the FROZEN `/v1/data/counts`
  shape (per-TYPE census) — this is the per-TAG registry, a different read.
  Auth mirrors a doc read: preview or a token, otherwise 404
  (existence-hiding, like `backlinks`).
  """
  def tag_browse(conn, %{"dataset" => dataset} = params) do
    if preview?(conn) or authed?(conn) do
      rows =
        Content.TagDistribution.per_type(parse_types(params["type"]), dataset, scope_opts(conn))

      tags = regroup_tag_rows(rows)

      json(conn, %{
        result: %{tags: tags, count: length(tags)},
        syncTags: ["bp:ds:#{dataset}:tags"]
      })
    else
      {:error, :not_found}
    end
  end

  @doc """
  Tag detail — the documents carrying `:tag`, RANKED BY THAT TAG'S STRENGTH
  (authoring-excellence ae-w10 / manifest `tag.docs`). Wraps
  `Content.docs_with_tag/4` with `order: :strength`: a `desc_nulls_last`
  lateral over the `tags_meta` GENERATED column (NULLS LAST is mandatory —
  legacy unweighted carriers rank last, not first), tie-broken title asc,
  doc_id asc. Each entry projects `{doc_id, type, title, strength, rationale,
  main_tag_match}` — the title COLUMN, and the matched (strongest) entry's
  strength/rationale (NULL for a legacy flat carrier). The generic `order=`
  grammar cannot express a parameterized per-tag order — dedicated read only.

  Published-only (`published_only: true` — same by-design posture as
  `tag_browse`); tenancy threads `scope_opts/1` exactly like `backlinks/2`;
  auth mirrors a doc read: preview or a token, otherwise 404
  (existence-hiding).
  """
  def tag_docs(conn, %{"dataset" => dataset, "tag" => tag} = params) do
    if preview?(conn) or authed?(conn) do
      docs =
        Content.docs_with_tag(
          tag,
          parse_types(params["type"]),
          dataset,
          [order: :strength, published_only: true] ++ scope_opts(conn)
        )

      json(conn, %{
        result: %{tag: tag, documents: docs, count: length(docs)},
        syncTags: ["bp:ds:#{dataset}:tags:#{tag}"]
      })
    else
      {:error, :not_found}
    end
  end

  # The tag reads' `?type=` grammar: a comma list, default paper,task (the two
  # weighted-tag corpora). Blank/absent falls back to the default.
  @default_tag_types ~w(paper task)
  defp parse_types(nil), do: @default_tag_types

  defp parse_types(param) when is_binary(param) do
    case param |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> @default_tag_types
      types -> types
    end
  end

  defp parse_types(_), do: @default_tag_types

  # `{type, tag, count}` SQL rows → per-tag registry rows, biggest first.
  defp regroup_tag_rows(rows) do
    rows
    |> Enum.group_by(& &1.tag)
    |> Enum.map(fn {tag, tag_rows} ->
      %{
        tag: tag,
        counts: Map.new(tag_rows, &{&1.type, &1.count}),
        total: tag_rows |> Enum.map(& &1.count) |> Enum.sum()
      }
    end)
    |> Enum.sort_by(&{-&1.total, &1.tag})
  end

  def show(conn, %{"dataset" => dataset, "type" => type, "doc_id" => doc_id} = params) do
    cond do
      # NO anonymous caller may fetch a draft by id — neither a read-only
      # public share nor a plain tokenless read of a public schema (publish is
      # the act of making content public; a `drafts.` id is unpublished by
      # definition). Rejected as not-found BEFORE any get_document call — the
      # same 404 path the controller already returns for a missing doc. An
      # `:edit` share and any token/preview caller pass through unchanged.
      AnonPerspective.anon_pinned?(conn) and String.starts_with?(doc_id, "drafts.") ->
        {:error, :not_found}

      not (preview?(conn) or authed?(conn) or
               Content.schema_public?(type, dataset, scope_opts(conn))) ->
        {:error, :not_found}

      # AFTER the two existence-hiding 404s above, never before — otherwise the
      # refusal answers "this document exists but your perspective is wrong" to
      # a caller the endpoint is meant to tell nothing. Same ordering as counts/2.
      bad = unsupported_read_perspective(params) ->
        refuse_read_perspective(conn, bad)

      true ->
        show_doc(conn, dataset, type, doc_id, params)
    end
  end

  # `?perspective` on the two document read paths honours exactly the three
  # values the manifest advertises. Anything else USED TO BE SILENTLY ACCEPTED:
  # AnonPerspective.parse/1 has a catch-all that maps every unrecognised string
  # to :published, so `?perspective=bogus` returned 200 over the published set —
  # on doc-get with no echo at all, and on query with `"perspective":"published"`
  # in the body, actively telling the caller its typo had been honoured.
  #
  # /v1/data/counts has refused this since it learned to (refuse_perspective/2
  # below); these two endpoints are brought to the same model rather than the
  # catch-all being changed, because parse/1's fail-safe default is relied on by
  # every OTHER caller and narrowing it there would be a much wider blast radius
  # than this defect justifies.
  #
  # nil (absent) is fine. The value is returned so the refusal can name what the
  # caller actually sent.
  defp unsupported_read_perspective(params) do
    case Map.get(params, "perspective") do
      nil -> nil
      p when p in ["published", "drafts", "raw"] -> nil
      other -> other
    end
  end

  defp refuse_read_perspective(conn, value) do
    ErrorResponse.emit_custom(
      conn,
      400,
      "malformed",
      "unsupported perspective #{inspect(value)} — supported values are " <>
        "published, drafts and raw; omit ?perspective for published",
      %{parameter: "perspective", supported: ["published", "drafts", "raw"], received: value}
    )
  end

  defp show_doc(conn, dataset, type, doc_id, params) do
    t0 = System.monotonic_time(:microsecond)
    expand_spec = parse_expand(params["expand"])

    with {:ok, doc} <- get_document_for_perspective(conn, doc_id, type, dataset, params) do
      schema = fetch_schema(conn, type, dataset)
      caller_context = CallerContext.from_conn(conn)

      rendered =
        [Envelope.render(doc, schema, caller_context)]
        |> Expand.expand(
          expand_spec,
          dataset,
          [published_only: AnonPerspective.anon_pinned?(conn), caller_context: caller_context] ++
            scope_opts(conn)
        )
        |> project_fields(parse_fields(params["fields"]))
        |> maybe_resolve_tasks(conn, params)
        |> hd()

      schema_hash = Content.schema_hash_for_dataset(dataset, scope_opts(conn))
      etag = doc_etag(doc)
      sync_tags = doc_sync_tags(dataset, type, doc.doc_id)

      respond(
        conn,
        rendered,
        schema_hash,
        sync_tags,
        etag,
        cache_validator(etag, schema_hash),
        t0
      )
    end
  end

  # doc-get USED TO READ `?perspective` AND THROW IT AWAY. show_doc/5 did a bare
  # exact-id `get_document`, so a caller that asked for the draft got the
  # PUBLISHED row at 200 with `_draft: false` and no signal of any kind — while
  # the sibling `GET /v1/data/query/:dataset/:type?perspective=drafts` honoured
  # the same flag, on the same document, in the same instant. Two read paths
  # disagreeing about one document, and the by-id one silently answering a
  # question nobody asked. Both spellings declare the identical
  # `perspective` flag in `GET /v1/capabilities` (doc.get and doc.query), so the
  # divergence was a defect, not a design choice.
  #
  # `:drafts` prefers the draft twin and FALLS BACK to the published row. The
  # fallback is what matches the query endpoint: its drafts perspective returns
  # drafts where they exist and published rows where they do not, so a
  # published-only document must not start 404ing under `?perspective=drafts`.
  #
  # `:published` and `:raw` keep the exact-id lookup, and they genuinely coincide
  # here: doc-get addresses ONE row by id, so "raw" (no perspective filter) and
  # "published" resolve to the same row. A caller that spells `drafts.<id>`
  # still gets that row — the documented bare-`bp doc get` asymmetry, which is a
  # different thing from an explicit flag being ignored.
  #
  # NO NEW EXPOSURE, and this is the part worth checking rather than assuming.
  # `AnonPerspective.resolve/2` pins every anonymous and `public-read` caller to
  # `:published` before this runs, and show/2 already 404s an anon caller that
  # names a `drafts.` id. For an authed caller nothing widens either: doc-get
  # already served `GET /v1/data/doc/:ds/:type/drafts.<id>` to any read token, so
  # honouring the flag reaches the SAME row by a different spelling. Pinned both
  # ways in query_controller_perspective_test.exs.
  defp get_document_for_perspective(conn, doc_id, type, dataset, params) do
    case AnonPerspective.resolve(conn, params) do
      :drafts ->
        case Content.get_document(DraftId.draft_id(doc_id), type, dataset, scope_opts(conn)) do
          {:ok, draft} -> {:ok, draft}
          _ -> Content.get_document(doc_id, type, dataset, scope_opts(conn))
        end

      _ ->
        Content.get_document(doc_id, type, dataset, scope_opts(conn))
    end
  end

  # ─── ?resolve=tasks — the API resolve seam (p-resolve-seam) ────────────────
  #
  # Resolve-at-read for task blocks lived only in the LiveView reader
  # (BulldocsLive → Papers.resolve_tasks_in_blocks), so every API consumer —
  # Go pdrender, web portable-doc.tsx, exports — received RAW `query` blocks and
  # could not render live plans. Opt-in `?resolve=tasks` runs the SAME resolver
  # over each rendered doc's `blocks` before responding: query-carrying task
  # blocks become snapshot-carrying ones; author-pinned snapshots and every
  # other block pass through untouched. Off by default — the wire contract is
  # byte-identical unless a caller asks.
  #
  # Scope mirrors the public reader (BulldocsLive.reader_task_scope): the
  # request's own workspace/project scope wins; an unscoped caller falls back
  # to the seeded Default workspace — the exact tenant whose tasks the public
  # /papers reader already exposes on the same paper. Underneath, the fetcher
  # (Tasks.Query.rows_for_query → Scope.scope_to_workspace) stays fail-closed:
  # a nil workspace resolves to zero rows, never to a cross-tenant leak.
  defp maybe_resolve_tasks(rendered, conn, %{"resolve" => "tasks", "dataset" => dataset})
       when is_list(rendered) do
    scope = api_task_scope(conn)

    Enum.map(rendered, fn doc ->
      case doc do
        %{"blocks" => blocks} when is_list(blocks) ->
          Map.put(
            doc,
            "blocks",
            Barkpark.Content.Papers.resolve_tasks_in_blocks(blocks, scope, dataset)
          )

        _ ->
          doc
      end
    end)
  end

  defp maybe_resolve_tasks(rendered, _conn, _params), do: rendered

  defp api_task_scope(conn) do
    opts = scope_opts(conn)

    ws_id =
      Keyword.get(opts, :workspace_id) ||
        case Barkpark.Tenancy.get_default_workspace() do
          %{id: id} -> id
          _ -> nil
        end

    [workspace_id: ws_id, project_id: Keyword.get(opts, :project_id)]
  end

  # Query params that RESHAPE the body without moving the `(dataset, type,
  # _id:_rev)` tuple the ETag is folded from. `?fields=` projects (and
  # `project_fields/2` deliberately keeps every `_`-prefixed system key, so
  # `_id`/`_rev` survive the projection untouched); `?expand=` hydrates nested
  # references; `?resolve=tasks` swaps query blocks for snapshots. None of the
  # three reaches `list_etag/3` or `doc_etag/1`.
  @shaping_params ~w(fields expand resolve)

  # PRESENCE, not parsed effect — deliberate. `?expand=false` and `?fields=,,`
  # both parse to "no shaping", so keying on the parsed spec would keep the ETag
  # for them. Presence is chosen anyway for two reasons: it costs only a 304 on
  # a request nobody sends, and it cannot DRIFT — re-deriving the parse here
  # would fork `parse_expand/1` and `parse_fields/1`, and the day one of those
  # grows a value this copy does not know, the fork fails OPEN and hands back a
  # validator for a shaped body. A blank/absent param is still treated as
  # unshaped, which is the one case that matters for the anonymous fast path.

  # An ETag is a promise about a REPRESENTATION (RFC 9110 §8.8.1: a strong
  # validator must change whenever the representation changes). Two axes break
  # that promise here, so both suppress the header:
  #
  #   * SHAPING — proven live against prod: `/v1/data/doc/production/task/<id>`
  #     and the same URL with `?fields=title` returned the identical strong ETag
  #     `"b75c68f1…"` over a 10,174-byte and a 630-byte body, and replaying the
  #     first ETag against the `?fields=` URL answered 304. The server told the
  #     caller its full document was a valid answer to a projected request.
  #
  #   * PRINCIPAL — `Envelope.render/3` decides FIELD visibility from the
  #     `CallerContext` (an admin token sets `is_admin: true` and sees `private`
  #     / `readable_by` fields). The ETag folds only ids and revs, so the same
  #     validator spans an admin's body and an anonymous one. The ids/revs DO
  #     distinguish which documents each caller may see; it is which FIELDS of
  #     them get rendered that the validator is blind to.
  #
  # A third axis, SCHEMA, is handled by FOLDING rather than by suppression
  # (task-496f010fa8f4d9dc). `Envelope.render/3` picks the visible field set out
  # of the SCHEMA as well as the caller, and a schema edit moves no document
  # `_rev` — so on the one branch that still emits a validator (anonymous +
  # unshaped) an editor marking a field `private` left the ETag identical and a
  # replayed If-None-Match answered 304 with the pre-redaction body still cached
  # downstream. `cache_validator/2` now folds
  # `Content.schema_hash_for_dataset/2` — the same value the envelope already
  # carries as `schemaHash`, computed once per request and threaded down — on
  # top of the document token, so any schema change moves the HEADER. The
  # envelope BODY's `etag` is UNCHANGED: it is the SDK's `ifMatch` token, not a
  # cache validator (see `cache_validator/2`). Suppression was not the right tool:
  # the anonymous unshaped read is exactly the one this file works to keep
  # cacheable, and the schema axis, unlike shaping and principal, has a cheap
  # exact discriminator already in hand.
  #
  # Direction, per charter D1: this only ever WITHDRAWS a validator. It removes
  # cacheability, never grants it — a request that used to 304 now gets a full
  # 200, which is a cost, never a stale or cross-principal body. Folding an
  # extra input into the ETag has the same direction.
  defp conditional_safe?(conn) do
    unshaped? = Enum.all?(@shaping_params, fn p -> blank?(Map.get(conn.params, p)) end)
    unshaped? and anonymous_principal?(conn)
  end

  defp blank?(nil), do: true
  defp blank?(v) when is_binary(v), do: String.trim(v) == ""
  defp blank?(_), do: false

  # Anonymous means no bound principal at all: no token resolved by
  # OptionalToken/RequireToken, and no richer context installed by
  # RequireUserSession. Mirrors `CallerContext.from_conn/1`'s resolution order
  # so the two can never disagree about who is asking.
  defp anonymous_principal?(conn) do
    is_nil(Map.get(conn.assigns, :api_token)) and
      case Map.get(conn.assigns, :caller_context) do
        nil -> true
        %CallerContext{principal_type: :anonymous} -> true
        _ -> false
      end
  end

  # `Vary: Authorization` rides EVERY query response, including the ones that
  # keep their ETag: the body's field set is a function of the Authorization
  # header, so a shared cache must key on it.
  #
  # MERGED, never overwritten. Two `vary` writers are already known: DatasetCors
  # sets `Origin` in-app, and prod responses arrive carrying `accept-encoding`
  # from a hop OUTSIDE this app (nothing in api/lib writes it) — so a bare put
  # here would drop a directive this code cannot see. The reverse case is the
  # one tests cannot catch: if that outside hop SETS rather than APPENDS, it
  # drops ours instead, and only a post-deploy curl can tell. That check is the
  # slice's D2/D13 L1 transcript: assert prod `vary` carries BOTH tokens.
  defp put_vary_authorization(conn) do
    existing =
      conn
      |> get_resp_header("vary")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    merged =
      if Enum.any?(existing, &(String.downcase(&1) == "authorization")) do
        existing
      else
        existing ++ ["authorization"]
      end

    put_resp_header(conn, "vary", Enum.join(merged, ", "))
  end

  defp respond(conn, inner, schema_hash, sync_tags, etag, validator, t0) do
    elapsed_ms = div(System.monotonic_time(:microsecond) - t0, 1000)

    conn =
      conn
      |> put_vary_authorization()
      |> maybe_vendor_content_type()

    if conditional_safe?(conn) do
      entity_tag = ~s("#{validator}")
      conn = put_resp_header(conn, "etag", entity_tag)

      # Compare against the ENTITY-TAG we just emitted (quotes included), not
      # the bare validator: the old matcher stripped the quotes off the client's
      # entry, so a bare `abc123` — a token this server never sends — bought a
      # 304. It also read only the first header line.
      if IfNoneMatch.match?(conn, entity_tag) do
        conn |> send_resp(304, "") |> halt()
      else
        respond_json(conn, inner, sync_tags, etag, elapsed_ms, schema_hash)
      end
    else
      # No header, and therefore no 304 branch: a validator we would refuse to
      # honor must not be advertised either. The envelope's own `etag` field is
      # UNCHANGED — it is the SDK's change-detection token, not a cache
      # validator (the SDK never sends If-None-Match itself — see runFetch in
      # js/packages/nextjs/src/server/core.ts), so consumers keep working.
      respond_json(conn, inner, sync_tags, etag, elapsed_ms, schema_hash)
    end
  end

  defp respond_json(conn, inner, sync_tags, etag, elapsed_ms, schema_hash) do
    if Map.get(conn.assigns, :barkpark_filterresponse, true) do
      json(conn, envelope(inner, sync_tags, etag, elapsed_ms, schema_hash))
    else
      json(conn, inner)
    end
  end

  defp maybe_vendor_content_type(conn) do
    if conn.assigns[:barkpark_vendor_accept] do
      put_resp_content_type(conn, "application/vnd.barkpark+json", "utf-8")
    else
      conn
    end
  end

  # `schema_hash` arrives ALREADY COMPUTED from the action (one
  # `Content.schema_hash_for_dataset/2` read per request) because the same value
  # is now folded into the cache validator. Recomputing it here would be a
  # second identical DB read AND — worse — could disagree with the value the
  # ETag was built from if a schema landed in between.
  defp envelope(result, sync_tags, etag, ms, schema_hash) do
    %{
      result: result,
      syncTags: sync_tags,
      ms: ms,
      etag: etag,
      schemaHash: schema_hash
    }
  end

  # Fold each doc's `_id` AND `_rev` into the ETag IN LIST ORDER (not a sorted
  # set): an in-place edit (same id, new rev) or a reorder must change the ETag,
  # otherwise a conditional GET with If-None-Match returns a spurious 304 over
  # stale data. Genuinely-unchanged lists still hash identically → 304 fast-path.
  defp list_etag(dataset, type, rendered) do
    parts = Enum.map(rendered, fn d -> "#{d["_id"]}:#{d["_rev"] || ""}" end)
    payload = "#{dataset}|#{type}|" <> Enum.join(parts, ",")
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower) |> binary_part(0, 32)
  end

  defp doc_etag(%{rev: rev}) when is_binary(rev) and rev != "", do: rev
  defp doc_etag(_), do: "0"

  # THE CACHE VALIDATOR — deliberately NOT the body's `etag` (task-496f010fa8f4d9dc).
  #
  # Two different tokens ride one response and they answer different questions:
  #
  #   * the envelope BODY's `etag` answers "has this DOCUMENT changed?". It is a
  #     documented SDK contract — `js/packages/core/src/doc.ts` returns it as
  #     `DocResult.etag` ("Unquoted ETag ( = document _rev). Pass back as
  #     ifMatch on writes") and `Content.Mutations.if_rev/1` compares `ifMatch`
  #     to the stored rev. Folding anything into it turns every documented
  #     read-then-write into a 412, so it stays EXACTLY what it was.
  #
  #   * the HTTP `ETag` header answers "is the cached REPRESENTATION still
  #     valid?" (RFC 9110 §8.8.1). The representation is a function of the
  #     SCHEMA too: `Envelope.render/3` reads the schema's `private` /
  #     `visibility` / `readable_by` attributes per field, and
  #     `Content.Schema.upsert_schema/3` writes the SchemaDefinition row and
  #     touches NO document — so marking a field private moved no `_rev` and
  #     left the validator identical. An anonymous caller replaying its pre-edit
  #     ETag got a 304 and kept serving the field the schema now hides. So the
  #     header folds the schema hash on top of the document token.
  #
  # Adding an input can only ever WITHDRAW a 304 that used to be granted, never
  # grant a new one.
  defp cache_validator(etag, schema_hash) do
    :crypto.hash(:sha256, "#{etag}|#{schema_hash}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp list_sync_tags(dataset, type, rendered) do
    type_tag = "bp:ds:#{dataset}:type:#{type}"
    doc_tags = for d <- rendered, do: "bp:ds:#{dataset}:doc:#{Content.published_id(d["_id"])}"
    [type_tag | doc_tags]
  end

  defp doc_sync_tags(dataset, type, doc_id) do
    [
      "bp:ds:#{dataset}:doc:#{Content.published_id(doc_id)}",
      "bp:ds:#{dataset}:type:#{type}"
    ]
  end

  # Tenancy scope opts come from BarkparkWeb.ScopeHelpers.scope_opts/1, the
  # shared seam over the conn assigns set by ResolveWorkspace / ResolveProject
  # (scoped routes) or AssignDefaultScope (flat back-compat routes). Completes
  # the cross-dataset read-leak fix at the query layer: the route-level
  # membership gate decides WHETHER the caller reaches a workspace; this WHERE
  # workspace_id filter decides WHICH rows come back.

  # Resolve the type's schema (for field-visibility redaction in Envelope.render)
  # under the SAME tenant scope as the document read, with the GLOBAL-schema
  # fallback. The two-step lookup and its load-bearing tenancy guard now live in
  # ONE place — `Content.Schema.get_schema_for_redaction/3` (@canonical
  # capability:schema-resolution-for-redaction) — which every Envelope render
  # site shares. Nil on miss.
  defp fetch_schema(conn, type, dataset) do
    case Content.Schema.get_schema_for_redaction(type, dataset, scope_opts(conn)) do
      {:ok, schema} -> schema
      :error -> nil
    end
  end

  # WS-B MEDIUM-4 guard: the first filter/order field NOT readable by this
  # caller (per the type schema + CallerContext), or nil when every referenced
  # field is allowed. Internal/admin callers and undeclared/promoted fields pass
  # through `Envelope.field_readable?/3` unrestricted.
  defp forbidden_query_field(filter_map, order, schema, caller_context) do
    (Map.keys(filter_map) ++ order_fields(order))
    |> Enum.find(fn field -> not Envelope.field_readable?(schema, field, caller_context) end)
  end

  defp order_fields(specs) when is_list(specs), do: Enum.flat_map(specs, &order_fields/1)
  defp order_fields({:field, field, _dir}), do: [field]
  defp order_fields(_), do: []

  # The documented public filter operators (api-v1.md §4). An op outside this set
  # has no `apply_field_op/4` clause, so it must be rejected up front — otherwise
  # it hits the catch-all and the filter is silently a no-op (returns every row).
  # ONE OWNER for the PUBLIC operator list (gfr-w1-filter-door-validator-drift).
  # Derived at compile time from `Content.Query.valid_filter_ops/0` rather than
  # re-spelled, so adding a documented op to the builder cannot leave the door
  # silently refusing it — and so this module's "valid operators: …" message
  # cannot drift from the set the builder actually honours.
  #
  # DELIBERATELY NOT a delegation to `Content.Query.validate_filter_map/1`. The
  # builder is FIELD-AWARE and accepts `@doc_id_only_ops` (`starts_with`,
  # `not_starts_with`) on `doc_id`/`_id`, which `query.ex` records as
  # "builder-only spellings … no public wire form — QueryController's door
  # rejects them". The door is SUPPOSED to be narrower than the builder here;
  # delegating would put those spellings on the public wire. Pinned by
  # `filter_ops_test.exs`, "the door stays narrower than the builder".
  @valid_filter_ops Content.Query.valid_filter_ops()

  # `in`/`nin` bind a LIST (normalize_filter_op/1 splits their comma form into
  # one). EVERY OTHER op binds a SCALAR: array-bracket syntax
  # (`?filter[price][gt][]=1`, `?filter[title][eq][]=a`) delivers a list, which
  # `parse_number/1` can't read and Postgrex can't bind into a scalar SQL
  # compare. `gt/gte/lt/lte` were guarded; `eq`/`neq`/`contains`/… were NOT, so
  # `?filter[title][eq][]=a` raised an Ecto.Query.CastError and surfaced as a
  # 400 `internal_error` reading "unknown error (Ecto.Query.CastError)" with a
  # "Retry shortly" hint — a permanently malformed request dressed as a
  # transient server fault. The rule is now stated once, from the list side.
  @list_value_ops ~w(in nin)

  # Returns nil when every clause is honourable, or the FIRST offence as either
  #   * `{field, op}` — an operator outside @valid_filter_ops, rendered by
  #     `{:invalid_filter_op, …}` ("unknown filter operator …"), or
  #   * `{:clause, message, details}` — a documented operator whose VALUE or
  #     SHAPE this route cannot honour, rendered verbatim by
  #     `{:invalid_filter_clause, …}`.
  #
  # The split exists because one shared message was LYING. A malformed
  # `hasStrong` value was reported as `unknown filter operator "hasStrong"` by
  # a message that then listed hasStrong as valid, and `filter[$or][0][…]`
  # reported `"0"` as the offending operator on field `"$or"` — the caller was
  # told to fix the operator when the operator was fine (or when the whole
  # boolean-group spelling is unsupported). Every value/shape refusal now says
  # what is actually wrong and what to type instead.
  #
  # A bare `filter[field]=value` scalar carries no op (it's `eq` sugar) and is
  # accepted; a bare LIST/MAP value is not (same CastError family).
  defp invalid_filter_op(filter_map) do
    Enum.find_value(filter_map, fn
      # `$or`/`$and`: not fields, and this route has no boolean-group form. Checked
      # BEFORE the operator scan so the group INDEX is never reported as an operator.
      {"$" <> _ = field, _value} ->
        {:clause,
         "boolean filter groups are not supported on /v1/data/query: #{inspect(field)} " <>
           "is read as a document field, not an operator. Repeat the filter param " <>
           "(filter[]=a=1&filter[]=b=2) to AND conditions; there is no OR form.", %{field: field}}

      {field, %{} = ops} ->
        cond do
          op = Enum.find(Map.keys(ops), fn op -> op not in @valid_filter_ops end) ->
            {field, op}

          Map.has_key?(ops, "is") and Map.get(ops, "is") not in ["null", "notnull"] ->
            {:clause,
             "filter[#{field}][is] takes \"null\" or \"notnull\", got " <>
               "#{inspect(Map.get(ops, "is"))}; for equality use filter[#{field}][eq]",
             %{field: field, op: "is"}}

          # `hasStrong` needs its VALUE checked with the same grammar the SQL
          # arm parses (`<tag>:<min_strength>`, split at the LAST colon): a
          # malformed value hits the op's :error arm and would silently no-op
          # — the same fail-open the `is` guard above prevents. One parser,
          # two callers (`Content.Query.parse_has_strong/1`).
          Map.has_key?(ops, "hasStrong") and
              Content.Query.parse_has_strong(Map.get(ops, "hasStrong")) == :error ->
            {:clause,
             "filter[#{field}][hasStrong] takes \"<tag>:<min_strength>\" " <>
               "(e.g. \"epic:50\"), got #{inspect(Map.get(ops, "hasStrong"))}",
             %{field: field, op: "hasStrong"}}

          op = Enum.find(Map.keys(ops), &non_scalar_op_value?(ops, &1)) ->
            {:clause,
             "filter[#{field}][#{op}] takes a single value, not a list or object; " <>
               "the list form filter[#{field}][#{op}][]=… is only valid for in/nin",
             %{field: field, op: op}}

          op = Enum.find(@list_value_ops, &non_list_op_value?(ops, &1)) ->
            {:clause,
             "filter[#{field}][#{op}] takes a comma list (a,b) or the repeated form " <>
               "filter[#{field}][#{op}][]=a&filter[#{field}][#{op}][]=b, got " <>
               "#{inspect(Map.get(ops, op))}", %{field: field, op: op}}

          true ->
            nil
        end

      {field, value} when is_list(value) ->
        {:clause,
         "filter[#{field}] takes a single value; for membership use " <>
           "filter[#{field}][in]=a,b", %{field: field}}

      {_field, _scalar} ->
        nil
    end)
  end

  # True when `ops` carries `op` with a value the op cannot bind: a list/map for
  # a scalar op (array-bracket syntax or a nested container).
  defp non_scalar_op_value?(_ops, op) when op in @list_value_ops, do: false

  defp non_scalar_op_value?(ops, op) do
    case Map.fetch(ops, op) do
      {:ok, v} -> is_list(v) or is_map(v)
      :error -> false
    end
  end

  # True when a list-binding op (`in`/`nin`) carries something that isn't a list
  # — a nested object (`?filter[x][in][k]=v`), which `apply_field_op/4`'s
  # is_list-guarded clause would skip straight past into a silent no-op.
  defp non_list_op_value?(ops, op) do
    case Map.fetch(ops, op) do
      {:ok, v} -> not is_list(v)
      :error -> false
    end
  end

  @doc false
  # Thin public wrapper exposing the pure guard for unit tests (no ConnCase/DB).
  def invalid_filter_op_for_test(m), do: invalid_filter_op(m)

  defp preview?(conn), do: is_binary(conn.assigns[:forced_perspective])

  # "May this caller read at all" — a token or a preview JWT, EXCEPT the
  # public-read tier, which is treated exactly like an anonymous caller here.
  #
  # The parity partner of `DocumentsRetriever.restrict_anonymous_to_public_types/3`,
  # moved in the SAME commit: both used to key on "is authenticated"
  # (`not is_nil(:api_token)` / `principal_type in [:api_token, :user]`), and a
  # public-read token satisfies both. Tightening one alone reproduces the leak
  # one layer up, so they move together or not at all.
  #
  # STILL REACHABLE, which is why this is not cosmetic: the flat reads ride
  # `:api_grant_read` and the scoped `/v1/data/*` reads ride `:shared_docs_api`,
  # both of which mount `Plugs.PublicRead` — but the SCOPED PREVIEW block rides
  # bare `:scoped_api` with no PublicRead, so `authed?/1` was the ONLY thing
  # between a public-read token and `GET /w/:ws/p/:proj/v1/preview/query/:ds/:type`
  # on a private type (plus the five preview siblings). Post-clamp those fall to
  # the same 404 an anonymous caller gets — existence-hiding, not a 403, so the
  # refusal never becomes a probe. `index`/`show` keep their `schema_public?`
  # arm, so a public-read token still reads PUBLIC types normally.
  #
  # ONE definition of the tier: `Plugs.PublicRead.public_read_token?/1` is public
  # on purpose (its own comment: "a second copy in the controller is exactly how
  # a clamp and its downstream filter drift apart"). Never re-derive it here.
  defp authed?(conn) do
    not is_nil(conn.assigns[:api_token]) and
      not BarkparkWeb.Plugs.PublicRead.public_read_token?(conn)
  end

  # Perspective resolution + the anon/public-read pin live in ONE place —
  # `BarkparkWeb.AnonPerspective` (error-emitters-duplicated: this controller
  # carried private twins of resolve/anon_pinned? that drifted from the shared
  # chokepoint the search controllers use; stw7-backlog-drafts-clamp-gap
  # deleted them). `preview?/1` and `authed?/1` stay: they gate
  # backlinks/related/tag_browse/tag_docs above, a different question
  # ("may this caller read at all") from perspective pinning.

  defp parse_int(nil, d), do: d

  defp parse_int(s, d) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> d
    end
  end

  defp parse_int(n, _) when is_integer(n), do: n

  # Catch-all: a list param (`?limit[]=1` → Plug parses to `["1"]`) or any other
  # non-scalar falls back to the default instead of raising FunctionClauseError → 500.
  defp parse_int(_, default), do: default

  # Adds the total matching count (the paginator total) only when `?count=true` —
  # it's a second DB query (COUNT over the filtered set), so it stays opt-in.
  # The offset that reads the NEXT page, present only when one exists — so a
  # caller never has to re-derive it, and never derives one for a page with no
  # successor. Withheld past the 100_000 offset ceiling, where
  # `Content.Query.list_documents/3` clamps and a further read would re-serve
  # this same page rather than advance.
  defp maybe_put_next_offset(inner, false, _limit, _offset), do: inner

  defp maybe_put_next_offset(inner, true, limit, offset) do
    next = offset + limit

    if next > 100_000, do: inner, else: Map.put(inner, :nextOffset, next)
  end

  defp maybe_put_total(inner, conn, %{"count" => "true"}, type, dataset, perspective, filter_map) do
    total =
      Content.count_documents(
        type,
        dataset,
        [perspective: perspective, filter_map: filter_map] ++ scope_opts(conn)
      )

    Map.put(inner, :total, total)
  end

  defp maybe_put_total(inner, _conn, _params, _type, _dataset, _perspective, _filter_map),
    do: inner

  # Comma-separated specs → multi-field sort (`title:asc,price:desc` sorts by title,
  # then price as a tiebreak). A single spec stays a single parsed value (back-compat).
  # An ABSENT ?order= (nil, or "" after split/trim) keeps defaulting to
  # :updated_at_desc — that is the documented default, not a fallback. An
  # UNRECOGNISED non-empty spec is different: see parse_order/1 below.
  defp parse_order_param(s) when is_binary(s) do
    case String.split(s, ",", trim: true) do
      [] -> :updated_at_desc
      [single] -> parse_order(single)
      multi -> collect_order_specs(multi)
    end
  end

  defp parse_order_param(other), do: parse_order(other)

  # Parses every spec in a multi-field sort; the FIRST unrecognised spec wins
  # and short-circuits the rest, so the caller sees exactly the term it typo'd
  # rather than a rest-ignored partial sort.
  defp collect_order_specs(specs) do
    specs
    |> Enum.reduce_while([], fn spec, acc ->
      case parse_order(spec) do
        {:error, _} = error -> {:halt, error}
        parsed -> {:cont, [parsed | acc]}
      end
    end)
    |> case do
      {:error, _} = error -> error
      parsed -> Enum.reverse(parsed)
    end
  end

  defp parse_order("_updatedAt:asc"), do: :updated_at_asc
  defp parse_order("_updatedAt:desc"), do: :updated_at_desc
  defp parse_order("_createdAt:asc"), do: :created_at_asc
  defp parse_order("_createdAt:desc"), do: :created_at_desc

  # `<field>:asc` / `<field>:desc` — order by any document field, including a
  # dot-path into JSONB content (`price.amount:desc`). apply_order in
  # Content.Query resolves it against the promoted columns / nested JSONB content
  # (it already dot-splits via nested_segments). The dot-path group MUST match
  # the SDK's order validator — without it, `price.amount:desc` failed this regex
  # and used to silently fall back to :updated_at_desc, so nested-field sorts the
  # SDK advertised + sent were ignored.
  #
  # An UNRECOGNISED non-empty spec now fails LOUD instead of defaulting — the
  # `_ -> :updated_at_desc` arm this replaces is exactly the silent fallback
  # that swallowed `price.amount:desc` above before the regex grew the dot-path
  # group, and it would swallow the next typo the same way (Gyldendal S2
  # silent-failures class). `order_error/1` turns this into a 422 naming the
  # bad spec and the accepted grammar.
  defp parse_order(spec) when is_binary(spec) do
    case Regex.run(~r/^([a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+)*):(asc|desc)$/, spec) do
      [_, field, "asc"] -> {:field, field, :asc}
      [_, field, "desc"] -> {:field, field, :desc}
      _ -> {:error, {:invalid_order, spec}}
    end
  end

  defp parse_order(_), do: :updated_at_desc

  # Turns {:error, {:invalid_order, spec}} into the EXISTING Ecto.Changeset
  # validation-error envelope (FallbackController already renders any
  # %Ecto.Changeset{} as 422 `validation_failed`, details keyed by field) —
  # reusing that shape instead of inventing a new error code. The one message
  # carries both the rejected spec and the accepted grammar.
  defp order_error({:error, {:invalid_order, spec}}), do: {:error, invalid_order_changeset(spec)}

  defp invalid_order_changeset(spec) do
    {%{}, %{order: :string}}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(
      :order,
      "unrecognised order spec #{inspect(spec)}; expected <field>[.<path>]:asc|desc " <>
        "(dot-paths into JSONB content allowed), _updatedAt:asc|desc, or _createdAt:asc|desc"
    )
  end

  defp parse_expand(nil), do: []
  defp parse_expand(""), do: []
  defp parse_expand("false"), do: []
  defp parse_expand("true"), do: :all

  defp parse_expand(fields) when is_binary(fields) do
    fields
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Catch-all: a list param (`?expand[]=author` → Plug parses to `["author"]`) or
  # a map param (`?expand[k]=v` → `%{"k" => "v"}`) falls back to no expansion
  # instead of raising FunctionClauseError → 500.
  defp parse_expand(_), do: []

  # `?fields=title,slug` — projection. Returns the requested content field names, or
  # nil (no projection → whole document) when the param is absent/blank.
  defp parse_fields(s) when is_binary(s) do
    case s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> nil
      fields -> fields
    end
  end

  defp parse_fields(_), do: nil

  # Keep each rendered doc's system keys (`_id`, `_type`, `_rev`, …) plus the
  # selected content fields; drop the rest. nil/empty → no projection (pass through).
  defp project_fields(rendered, nil), do: rendered

  defp project_fields(rendered, fields) do
    # Match on the TOP-LEVEL segment of each selected field, so a dotted path
    # (`meta.seo`) keeps its parent object (`meta`) rather than silently dropping it.
    # Projection is top-level — a dotted select yields the whole parent, not a sub-slice.
    keep = fields |> Enum.map(&(&1 |> String.split(".") |> hd())) |> MapSet.new()

    Enum.map(rendered, fn doc ->
      Map.filter(doc, fn {k, _v} -> String.starts_with?(k, "_") or MapSet.member?(keep, k) end)
    end)
  end

  defp normalize_filter_map(map) when is_map(map) do
    Enum.into(map, %{}, fn
      {field, %{} = ops} -> {field, Enum.into(ops, %{}, &normalize_filter_op/1)}
      {field, value} -> {field, value}
    end)
  end

  # Accept a flat scalar string as a filter — the form both the CLI (`--filter
  # 'status=draft'`) and the TUI use without Plug's nested bracket syntax. Two
  # families, tried in order:
  #   1. operator forms — `=`/`==`/`!=`/`>`/`>=`/`<`/`<=` plus the CSS-selector
  #      shorthands `^=`/`$=`/`*=` (starts/ends/contains).
  #   2. keyword forms — `is null` / `is not null`, `hasStrong <tag>:<min>`,
  #      and `in` / `not in`.
  # Operators are tried FIRST so a value that itself contains ` is `/` in ` after
  # an operator is preserved (`notes=a in b` → eq value `a in b`, NOT an `in`
  # filter). Keyword forms only apply to an operator-less string.
  #
  # A non-empty string NEITHER family parses is an {:error, {:invalid_flat_filter,
  # raw}} sentinel, never %{} — the empty-map fall-through was a SILENT
  # passthrough (D75): the string was discarded as noise, the fail-closed
  # invalid_filter_op guard had nothing to inspect, and the caller got the
  # UNFILTERED set with exit 0. index/2 turns the sentinel into a 400 naming
  # the accepted grammar. Whitespace-only stays a no-filter no-op, like absent.
  defp normalize_filter_map(s) when is_binary(s) do
    case String.trim(s) do
      "" ->
        %{}

      trimmed ->
        parse_scalar_op(trimmed) || parse_scalar_keyword(trimmed) ||
          {:error, {:invalid_flat_filter, trimmed}}
    end
  end

  # A REPEATED filter param (`?filter[]=status=published&filter[]=title=Alpha`,
  # what a repeated `bp doc query --filter` now emits) arrives from Plug as a
  # LIST. It used to hit the `%{}` catch-all below and mean NO FILTER AT ALL —
  # the one HTTP shape that still answered 200 with the UNFILTERED set, and
  # structurally invisible to the invalid_filter_op guard because that guard
  # inspects an empty map and finds nothing wrong with it (Gyldendal #16).
  #
  # Every element runs through the SAME parsers a lone filter param uses, and
  # the results are AND-composed into one `field => ops` map — `apply_filter_map/2`
  # already reduces map keys with AND, so composition needs no query-builder
  # change. A single element that fails to parse fails the WHOLE request: half
  # a filter is the silent over-return this clause exists to end.
  #
  # CONFLICT RULE (explicit, not last-wins): clauses on the SAME field merge
  # when their operators differ (`price>10` + `price<20` → one field, two ops,
  # ANDed). The same field with the SAME operator twice is REFUSED — under AND
  # `title=a AND title=b` can never hold, so silently keeping either one would
  # answer a question the caller did not ask. The refusal names `in` as the
  # membership form they probably wanted. A bare scalar (eq sugar) is promoted
  # to `%{"eq" => value}` only when it has to merge, so the common single-clause
  # shape is byte-identical to before.
  defp normalize_filter_map(list) when is_list(list) do
    Enum.reduce_while(list, %{}, fn element, acc ->
      with %{} = one <- normalize_filter_map(element),
           %{} = merged <- merge_filter_clauses(acc, one) do
        {:cont, merged}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Sealed catch-all. It used to be `%{}` — an unrecognised filter param shape
  # silently meant "no filter", so a request that asked to narrow got every row
  # at 200 OK. Anything the clauses above don't recognise is now a 400 that
  # names the three accepted spellings.
  defp normalize_filter_map(other) do
    {:error,
     {:invalid_filter_clause,
      "unsupported filter param shape #{inspect(other)}; use filter=field<op>value, " <>
        "filter[field][op]=value, or a repeated filter[]=field<op>value (ANDed)",
      %{filter: inspect(other)}}}
  end

  # Merge one element's clauses into the accumulated filter map. See the
  # CONFLICT RULE above: differing ops on a field compose, a repeated op is a 400.
  defp merge_filter_clauses(acc, one) do
    Enum.reduce_while(one, acc, fn {field, clause}, acc ->
      case Map.fetch(acc, field) do
        :error ->
          {:cont, Map.put(acc, field, clause)}

        {:ok, existing} ->
          existing_ops = as_filter_ops(existing)
          new_ops = as_filter_ops(clause)

          case Enum.find(Map.keys(new_ops), &Map.has_key?(existing_ops, &1)) do
            nil ->
              {:cont, Map.put(acc, field, Map.merge(existing_ops, new_ops))}

            op ->
              {:halt,
               {:error,
                {:invalid_filter_clause,
                 "repeated filters are ANDed, so #{inspect(field)} cannot carry two " <>
                   "#{inspect(op)} clauses — no row satisfies both; use " <>
                   "filter=#{field} in a,b for membership", %{field: field, op: op}}}}
          end
      end
    end)
  end

  # A bare scalar filter is `eq` sugar (apply_filter_map/2 applies it as eq);
  # spell it out so two clauses on one field can be merged as ops.
  defp as_filter_ops(%{} = ops), do: ops
  defp as_filter_ops(scalar), do: %{"eq" => scalar}

  @doc false
  # Thin public wrapper exposing the pure flat-grammar parser for unit tests
  # (no ConnCase/DB) — same pattern as invalid_filter_op_for_test/1.
  def normalize_filter_map_for_test(s), do: normalize_filter_map(s)

  # Split on the LEFTMOST operator (2-char ops `^=`/`$=`/`*=`/`>=`/`<=`/`!=`/`==`
  # take precedence at a given index). The non-greedy field capture keeps the split
  # at the first operator, so a value that itself contains an operator char is
  # preserved (`notes=a>b` → field `notes`, eq, value `a>b`). `=`/`==` mean equality;
  # `^=`/`$=`/`*=` are prefix/suffix/substring; the rest map to the corresponding
  # nested op (`status!=archived` → `%{"status" => %{"neq" => "archived"}}`). Value
  # whitespace-trimmed, one pair of quotes stripped. Returns nil when no operator.
  defp parse_scalar_op(trimmed) do
    case Regex.run(~r/^(.+?)\s*(\^=|\$=|\*=|>=|<=|!=|==|>|<|=)\s*(.*)$/, trimmed) do
      [_, field, sym, value] ->
        v = unquote_filter_value(value)

        case scalar_op(sym) do
          "eq" -> %{String.trim(field) => v}
          op -> %{String.trim(field) => %{op => v}}
        end

      _ ->
        nil
    end
  end

  # Keyword forms (only reached for operator-less strings): `<field> is null` /
  # `is not null` (the scalar form of the SDK's eq/neq null), then
  # `hasStrong`, then `in` / `not in`.
  defp parse_scalar_keyword(trimmed) do
    case Regex.run(~r/^(.+?)\s+is\s+(not\s+)?null$/i, trimmed) do
      [_, field | rest] ->
        not? = String.trim(List.first(rest) || "") != ""
        %{String.trim(field) => %{"is" => if(not?, do: "notnull", else: "null")}}

      nil ->
        parse_scalar_has_strong(trimmed)
    end
  end

  # `<field> hasStrong <tag>:<min>` — the flat form of the weighted-tag
  # strength-floor op (D75: it had no flat spelling, only the nested
  # filter[field][hasStrong]=tag:min wire form). Keyword matched
  # case-insensitively, emitted as the canonical "hasStrong" nested op so ONE
  # value parser and ONE SQL arm serve both wire forms: the value is checked
  # up front by invalid_filter_op/1 via Content.Query.parse_has_strong/1, so a
  # malformed `<tag>:<min>` is a 400 here too, never a silent no-op. Tried
  # BEFORE `in`/`not in` so a hasStrong value containing ` in ` reads as a
  # (rejected) hasStrong value rather than a bogus membership filter.
  defp parse_scalar_has_strong(trimmed) do
    case Regex.run(~r/^(.+?)\s+hasStrong\s+(.+)$/i, trimmed) do
      [_, field, value] ->
        %{String.trim(field) => %{"hasStrong" => unquote_filter_value(value)}}

      nil ->
        parse_scalar_in(trimmed)
    end
  end

  # `<field> in a,b,c` / `<field> not in a,b,c` — membership against a comma list
  # (the scalar form of the SDK's `.in` / `.nin`). `not in` is matched first so the
  # leading `not` isn't folded into the field capture.
  defp parse_scalar_in(trimmed) do
    case Regex.run(~r/^(.+?)\s+not\s+in\s+(.+)$/i, trimmed) do
      [_, field, csv] ->
        %{String.trim(field) => %{"nin" => split_csv(csv)}}

      nil ->
        case Regex.run(~r/^(.+?)\s+in\s+(.+)$/i, trimmed) do
          [_, field, csv] -> %{String.trim(field) => %{"in" => split_csv(csv)}}
          nil -> nil
        end
    end
  end

  defp split_csv(s), do: s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp scalar_op(">="), do: "gte"
  defp scalar_op("<="), do: "lte"
  defp scalar_op("!="), do: "neq"
  defp scalar_op(">"), do: "gt"
  defp scalar_op("<"), do: "lt"
  defp scalar_op("^="), do: "startsWith"
  defp scalar_op("$="), do: "endsWith"
  defp scalar_op("*="), do: "contains"
  defp scalar_op(_), do: "eq"

  # Trim whitespace, then strip exactly ONE pair of surrounding double-quotes
  # when both ends carry one (`"published"` → `published`). Inner quotes are
  # kept (`say "hi"` unchanged); a lone quote char is not stripped.
  defp unquote_filter_value(v) do
    trimmed = String.trim(v)

    with <<?", rest::binary>> when byte_size(rest) >= 1 <- trimmed,
         true <- String.ends_with?(rest, "\"") do
      binary_part(rest, 0, byte_size(rest) - 1)
    else
      _ -> trimmed
    end
  end

  defp normalize_filter_op({op, csv}) when op in ["in", "nin"] and is_binary(csv) do
    {op, csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1)}
  end

  defp normalize_filter_op(pair), do: pair
end
