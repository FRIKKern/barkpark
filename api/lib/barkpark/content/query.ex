defmodule Barkpark.Content.Query do
  @moduledoc """
  Document read surface — list / fetch / filter / order / perspective.

  The heaviest read fan-in in `Barkpark.Content`: `list_documents/3`,
  `get_document/4`, `get_documents_by_ids/3`, and `fetch_doc_with_draft/4` plus
  the private filter-op / order / perspective query builders. All reads are
  scoped by the P0 leak guard — `scope_to_dataset/3` + `scope_to_workspace*` —
  so a query can never surface another workspace's row even when two workspaces
  share a dataset string.

  Extracted from `Barkpark.Content` (concern B); the parent keeps a thin
  delegating facade for the four public reads so every external caller still
  calls `Barkpark.Content.<fn>` unchanged.

  Reads `Repo` + `Document`. Scope resolution (`resolve_read_dataset_id/2`) is
  borrowed through the facade until the scope concern (K) is itself extracted —
  the private `scope_to_dataset/3` query helper below is byte-identical to the
  facade's private copy, so behaviour is unchanged.
  """

  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Content.{Document, DraftId, Schema}

  import Barkpark.Content.Scope,
    only: [
      scope_to_workspace_or_global: 3,
      scope_to_owner: 2,
      maybe_scope_to_grants: 2
    ]

  # The public page bounds, named so `list_documents/3`, `list_documents_page/3`
  # and the HTTP layer that echoes them back cannot drift apart.
  @max_limit 1000
  @max_offset 100_000

  @doc """
  List documents by type and dataset.

  Options:
    - `:perspective`  — `:published`, `:drafts`, or `:raw` (default `:raw`)
    - `:filter_map`   — map of field=>value filters, e.g. `%{"status" => "draft"}`
    - `:limit`        — max rows returned (default 100, max 1000, min 1)
    - `:offset`       — rows to skip (default 0, max 100_000 — beyond the cap the page is empty)
    - `:order`        — `:updated_at_desc` (default), `:updated_at_asc`,
                        `:created_at_desc`, `:created_at_asc`

  The `:drafts` perspective merges draft/published pairs at SQL level via
  `DISTINCT ON`, so `limit` and `offset` are applied after the merge.

  Tenancy scoping (Wave 1 hard boundary):
    - `:workspace_id` — scope reads to a single workspace (nil = unscoped /
                        pre-tenancy back-compat).
    - `:project_id`   — further narrow to a single project (requires
                        `:workspace_id`; nil = workspace-wide).

  The workspace/project filter is applied IN ADDITION TO the dataset-string
  filter via `Barkpark.Content.Scope.scope_to_workspace/3`.
  """
  def list_documents(type, dataset, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 100) |> min(@max_limit) |> max(1)

    run_page(type, dataset, opts, limit)
  end

  @doc """
  One page of `list_documents/3`, plus an EXACT answer to "is there more?".

  Returns `{documents, has_more}`. `documents` is the same page
  `list_documents/3` returns for the same opts; `has_more` is `true` when at
  least one further row exists past this page.

  WHY IT EXISTS. `list_documents/3` returns a bare list, so an exhausted page
  and a truncated one are indistinguishable — a caller reading `count == limit`
  cannot tell a type holding exactly `limit` rows from one holding a million.
  Since the default page is 100 rows, every type past 100 documents silently
  truncated for every consumer that did not know to ask for a separate count.

  HOW. It reads `limit + 1` rows and reports whether the extra one
  materialised, then drops it. That is an exact answer for the price of one
  extra row — no `COUNT` over the filtered set (`count_documents/3` remains the
  right call when the caller wants the actual total, which is strictly more
  expensive). The probe reads `limit + 1` through the internal path
  deliberately, so a caller can still ask for the full @max_limit page and get
  a truthful `has_more` — clamping the probe would pin `has_more` to false at
  exactly the page size where truncation is most likely.
  """
  @spec list_documents_page(String.t(), String.t(), keyword()) :: {[struct()], boolean()}
  def list_documents_page(type, dataset, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 100) |> min(@max_limit) |> max(1)

    rows = run_page(type, dataset, opts, limit + 1)

    {Enum.take(rows, limit), length(rows) > limit}
  end

  # The shared body of `list_documents/3` and `list_documents_page/3`. `limit`
  # arrives ALREADY resolved so the probe read can exceed the public @max_limit
  # by exactly one row; every other bound is applied here.
  defp run_page(type, dataset, opts, limit) do
    perspective = Keyword.get(opts, :perspective, :raw)
    filter_map = Keyword.get(opts, :filter_map, %{})
    offset = opts |> Keyword.get(:offset, 0) |> max(0) |> min(@max_offset)
    order = Keyword.get(opts, :order, :updated_at_desc)

    base = base_query(type, dataset, filter_map, opts)

    case perspective do
      :drafts -> list_with_drafts_merged(base, order, limit, offset)
      other -> list_linear(base, other, order, limit, offset)
    end
  end

  @doc """
  Walk EVERY document matching the query, paging past the 1000-row `:limit`
  cap that `list_documents/3` clamps to, and say out loud when the walk was
  cut short.

  `list_documents/3` clamps `:limit` to 1000 and returns a BARE LIST, so a
  caller holding 1000 rows cannot tell "that is the whole corpus" from "there
  are 3,000 more". Every corpus-walker that must see the WHOLE corpus — a
  rebuild, a backfill, an export, a graph fold — needs this instead.

  Returns `{documents, truncated}`:

    - `{docs, nil}`  — the walk terminated on a SHORT page: the corpus is
                       exhausted and `docs` is all of it.
    - `{docs, :cap}` — every page came back full and `:max_pages` stopped the
                       loop. `docs` is a PREFIX of the corpus, honestly
                       labelled; the caller must not report it as complete.

  Options are `list_documents/3`'s, plus:

    - `:page_size` — rows per page (default 1000, the server cap).
    - `:max_pages` — bound on the walk (default 1000 pages = 1M rows). The
                     loop is bounded on purpose: an unbounded walk over a
                     corpus that grows during the walk cannot terminate.

  THE LAW (mirrors `web/lib/paginate.ts` `collectAllPages`, the canonical
  remedy on the JS side — same shape, deliberately):

    - request pages of `page_size` rows, advancing `offset` by the RAW page
      length, so the cursor never stalls;
    - a SHORT page (fewer than `page_size` rows) terminates the walk — that is
      the honest end of the corpus;
    - the walk is BOUNDED by `max_pages`; if every page comes back full the cap
      stops the loop and `:cap` says so, rather than a silent prefix.

  Paging is sound to page over: both `list_linear/5` and
  `list_with_drafts_merged/4` append `asc: d.id` as a final unique tiebreaker,
  so the sort is TOTAL and LIMIT/OFFSET pages neither skip nor duplicate rows.
  """
  @spec collect_all_documents(String.t(), String.t(), keyword()) :: {[struct()], nil | :cap}
  def collect_all_documents(type, dataset, opts \\ []) do
    {page_size, opts} = Keyword.pop(opts, :page_size, @max_limit)
    {max_pages, opts} = Keyword.pop(opts, :max_pages, 1000)

    page_size = page_size |> min(@max_limit) |> max(1)
    list_opts = Keyword.drop(opts, [:limit, :offset])

    collect_pages(type, dataset, list_opts, page_size, max_pages, 0, 0, [])
  end

  # `list_documents/3` CLAMPS `:offset` to @max_offset (it does not error and it
  # does not return an empty page), so a walk that marched past the cap would
  # re-read the SAME page forever — full every time, so never short-circuiting —
  # and hand the caller duplicates. Stop at the cap instead and label it `:cap`:
  # ~101k rows is the real server ceiling for an offset walk, and a caller that
  # hits it must know its corpus is a prefix.

  defp collect_pages(_type, _dataset, _opts, _page_size, max_pages, page, _offset, acc)
       when page >= max_pages do
    {finish(acc), :cap}
  end

  defp collect_pages(type, dataset, opts, page_size, max_pages, page, offset, acc) do
    batch = list_documents(type, dataset, opts ++ [limit: page_size, offset: offset])
    acc = [batch | acc]
    next_offset = offset + length(batch)

    cond do
      # Short page — the honest end of the corpus.
      length(batch) < page_size -> {finish(acc), nil}
      # The next read would be clamped back onto a page we have already taken.
      next_offset > @max_offset -> {finish(acc), :cap}
      # RAW advance: never advance by a post-filtered count.
      true -> collect_pages(type, dataset, opts, page_size, max_pages, page + 1, next_offset, acc)
    end
  end

  defp finish(acc), do: acc |> Enum.reverse() |> Enum.concat()

  @doc """
  Count documents matching the same type / scope / filter / perspective as
  `list_documents`, ignoring `limit`/`offset` — the total a paginator needs.
  For `:drafts` the draft/published twins are merged (counted once), matching
  the list. Heavier than a page read (a `COUNT` over the filtered set), so the
  HTTP layer only runs it when the caller opts in via `?count=true`.
  """
  def count_documents(type, dataset, opts \\ []) do
    perspective = Keyword.get(opts, :perspective, :raw)
    filter_map = Keyword.get(opts, :filter_map, %{})
    base = base_query(type, dataset, filter_map, opts)

    case perspective do
      :drafts ->
        inner =
          from(d in base, distinct: fragment("regexp_replace(?, '^drafts\\.', '')", d.doc_id))

        Repo.aggregate(from(d in subquery(inner)), :count)

      other ->
        base |> apply_perspective(other) |> Repo.aggregate(:count)
    end
  end

  defp base_query(type, dataset, filter_map, opts) do
    Document
    |> where([d], d.type == ^type)
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(
      Keyword.get(opts, :workspace_id),
      Keyword.get(opts, :project_id)
    )
    |> maybe_scope_to_owner(type, dataset, opts)
    |> maybe_scope_to_grants(opts)
    |> apply_filter_map(filter_map)
  end

  # Row/ownership ACL (Phase 4, core-auth). Appends `scope_to_owner/2` ONLY when
  # the type opts into `owner_scoped` — a non-owner_scoped read is byte-identical
  # to today (no extra clause, no behavioural change). The caller_context is
  # threaded from the HTTP/LiveView surface via
  # `BarkparkWeb.ScopeHelpers.scope_opts/1`; a caller that omits it now FAILS
  # CLOSED — `scope_to_owner/2`'s nil clause restricts to unowned rows
  # (`owner_id IS NULL`) only, never another owner's rows. A trusted internal
  # caller that needs owned rows must pass an admin / api_token caller_context.
  defp maybe_scope_to_owner(query, type, dataset, opts) do
    if Barkpark.Content.owner_scoped?(type, dataset, opts) do
      scope_to_owner(query, Keyword.get(opts, :caller_context))
    else
      query
    end
  end

  defp list_linear(query, perspective, order, limit, offset) do
    query
    |> apply_perspective(perspective)
    |> apply_order(order)
    # Stable pagination: append the binary_id PK as a final unique tiebreaker so
    # the sort is TOTAL. Without it, rows that tie on the primary sort key (common
    # for low-cardinality sorts — status, a category, even title) have an
    # undefined relative order, so LIMIT/OFFSET pages can skip or duplicate rows
    # across page boundaries. order_by accumulates, so this runs after apply_order.
    |> order_by([d], asc: d.id)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  defp list_with_drafts_merged(query, order, limit, offset) do
    inner =
      from(d in query,
        distinct: fragment("regexp_replace(?, '^drafts\\.', '')", d.doc_id),
        order_by: [
          fragment("regexp_replace(?, '^drafts\\.', '')", d.doc_id),
          fragment("CASE WHEN ? LIKE 'drafts.%' THEN 0 ELSE 1 END", d.doc_id)
        ]
      )

    from(d in subquery(inner))
    |> apply_order(order)
    # Stable pagination — same total-order tiebreaker as list_linear. The inner
    # DISTINCT collapses each logical doc to a single row, so its `id` is unique
    # here; appending it makes the outer sort total so LIMIT/OFFSET pages never
    # skip or duplicate a row when the primary sort key ties.
    |> order_by([d], asc: d.id)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  defp apply_perspective(query, :published) do
    prefix = DraftId.drafts_prefix() <> "%"
    where(query, [d], not like(d.doc_id, ^prefix))
  end

  defp apply_perspective(query, _), do: query

  # The documented public filter operators (docs/api-v1.md §4).
  @valid_filter_ops ~w(eq neq in nin has hasStrong contains startsWith endsWith gt gte lt lte is)

  # Builder-only spellings: `apply_field_op/4` has clauses for these on the
  # `doc_id`/`_id` column ONLY (prefix matching for id-space queries). They have
  # no public wire form — `QueryController`'s door rejects them — but internal
  # callers and `Content.Query` tests use them, so validation must accept them
  # exactly where a clause exists and nowhere else. Accepting them field-wide
  # would let a desk chip pass write-validation and then raise at render.
  @doc_id_only_ops ~w(starts_with not_starts_with)

  # `in`/`nin` are the ONLY ops with an `is_list` clause in `apply_field_op/4`;
  # every other op binds a SCALAR param. Array-bracket syntax
  # (`?filter[price][gt][]=1`, `?filter[tags][has][]=x`) delivers a LIST, which
  # `parse_number/1` cannot read and Postgrex cannot bind into a scalar SQL
  # compare — a bare 500 rather than a refusal. Stating the rule from the LIST
  # side rather than enumerating the scalar ops is deliberate: an op added later
  # is scalar-checked by default, and enumerating gt/gte/lt/lte was exactly how
  # `has` kept its 500 after the range ops were fixed.
  @list_value_ops ~w(in nin)

  # The columns the prefix ops above are spelled against.
  @id_fields ~w(doc_id _id)

  # ── THE PER-FIELD CAPABILITY TABLE (gfr-w1-per-field-op-table) ────────────
  #
  # A PROMOTED COLUMN only supports the ops `apply_field_op/4` has a clause for.
  # Every other op used to fall through to the generic JSONB arm and read
  # `content->>'<name>'` — a key that does not exist on a column-backed field —
  # so the query ran happily and returned 0 rows at 200 OK. Strictness could
  # never catch it: the op IS in @valid_filter_ops and a legitimate generic
  # clause DOES exist. Only a per-field table can.
  #
  # THE BOUNDARY, STATED HERE BECAUSE GETTING IT WRONG BREAKS ONE SIDE OR THE
  # OTHER: this table is consulted ONLY for the names below. `content` is
  # schemaless JSONB, so "unknown field" can never be an error in general —
  # an arbitrary content field keeps running through the generic arm untouched.
  # Widen this table only alongside a real clause; the table and the clauses are
  # pinned to each other by `per_field_op_table_test.exs`, which drives EVERY
  # pair through a live query and reds if a declared pair reads the wrong
  # column.
  #
  # WIDENED vs REFUSED, per field:
  #   * `title`   — already carried the full string+comparison set; unchanged.
  #   * `status`  — WIDENED with contains/startsWith/endsWith (meaningful on a
  #     text column, and the customer-visible half of this defect). Comparison
  #     ops are REFUSED: lexicographic `status > "d"` is not a question anyone
  #     asked, and a refusal is honest where a silent 0 was not.
  #   * `doc_id`/`_id` — WIDENED with neq/contains/startsWith/endsWith. This is
  #     the worst case in the class: prefix filtering was unreachable by ANY
  #     spelling. Comparison ops and `is` are REFUSED (doc_id is NOT NULL by
  #     construction, so `is null` could only ever mean "no rows").
  #   * `_createdAt`/`_updatedAt` — comparison ops only. String ops on a
  #     timestamp column are REFUSED rather than widened: `contains` on a
  #     timestamp is a category error, not a missing feature.
  #   * `type`/`_type` — the LAST member of this class to be found
  #     (task-20c081f70cb8d85e), and the only one that had NO clause at all
  #     rather than a partial set. `type` is a promoted column
  #     (`documents.type`, NOT NULL by construction) that every response echoes
  #     back as `_type`, so `filter[_type][eq]=post` reads like the most
  #     ordinary query there is — and BOTH spellings fell to the generic JSONB
  #     arm, read `content->>'type'`, and returned 0 rows at 200 OK for every
  #     value including the correct one. Same op set as `doc_id`/`_id`:
  #     comparison ops are a category error on a type name, and `is` could only
  #     ever mean "no rows" on a NOT NULL column.
  @column_field_ops %{
    "title" => ~w(eq neq in nin contains startsWith endsWith gt gte lt lte is has hasStrong),
    "status" => ~w(eq neq in nin contains startsWith endsWith is),
    "doc_id" => ~w(eq neq in nin contains startsWith endsWith),
    "_id" => ~w(eq neq in nin contains startsWith endsWith),
    "type" => ~w(eq neq in nin contains startsWith endsWith),
    "_type" => ~w(eq neq in nin contains startsWith endsWith),
    "_createdAt" => ~w(eq neq gt gte lt lte),
    "_updatedAt" => ~w(eq neq gt gte lt lte)
  }

  @doc """
  The ops a COLUMN-BACKED field supports, or `nil` for a schemaless content
  field (which supports the whole documented set through the generic arm).

  One owner for the per-field answer: the refusal message, the door and any
  future reader all read it here rather than re-spelling it.
  """
  @spec supported_ops_for(String.t()) :: [String.t()] | nil
  def supported_ops_for(field), do: Map.get(@column_field_ops, field)

  # THE ENUMERATION QUESTION, DELIBERATELY LEFT SHUT. The row asked the refusal
  # message to name the supported ops FOR THAT FIELD. It must not: naming the
  # field (or printing a narrower, field-shaped list) tells an unauthorised
  # caller the field EXISTS. `query_test.exs` pins it — "The MESSAGE names the
  # op and the vocabulary, and NEVER the field ... at internal doors that gate
  # never ran at all" — and charter D13 Tier B lists this surface as
  # existence-hiding. So the TABLE decides accept-vs-refuse; the MESSAGE keeps
  # printing the documented global set. Settling D13 is a lead ruling, not a
  # builder's call.

  @doc """
  The documented public filter operators (docs/api-v1.md §4). An op outside this
  set has no `apply_field_op/4` clause.
  """
  @spec valid_filter_ops() :: [String.t()]
  def valid_filter_ops, do: @valid_filter_ops

  @doc """
  Check a filter map WITHOUT building a query — `:ok`, or `{:error, {field, op}}`
  naming the FIRST clause that has no SQL arm.

  Same knowledge, same answer as the refusal `apply_filter_map/2` raises; this is
  the LOOK-BEFORE-YOU-LEAP form, for callers that must not let an exception reach
  their surface. Two of them ship with this function:

    * `Barkpark.Content.SchemaDefinition.changeset/2` — a desk-group chip with a
      typo'd op is refused at schema WRITE, so it never reaches the DB to detonate
      later at render;
    * `BarkparkWeb.Studio.PaneBuilder` — a chip stored BEFORE that validation
      existed renders as an empty list plus an explicit pane notice, instead of
      crashing the Studio LiveView.

  A non-map filter is `{:error, {nil, :not_a_map}}` — fail closed, never `:ok`.
  """
  @spec validate_filter_map(term()) :: :ok | {:error, {term(), term()}}
  def validate_filter_map(map) when is_map(map) do
    case Enum.find_value(map, &offending_clause/1) do
      nil -> :ok
      {_field, _op} = bad -> {:error, bad}
    end
  end

  def validate_filter_map(_other), do: {:error, {nil, :not_a_map}}

  # THE CHOKEPOINT. Every read reaches this through `base_query/4`, so validating
  # here — before a single clause is applied — is what makes the refusal total:
  # a door added later inherits it by construction rather than having to remember
  # its own guard. `QueryController` still pre-guards so the HTTP surface keeps
  # its field-naming envelope (and its ordering behind `forbidden_query_field/4`);
  # this is the floor under every OTHER door.
  defp apply_filter_map(query, map) when map_size(map) == 0, do: query

  defp apply_filter_map(query, map) do
    case validate_filter_map(map) do
      :ok -> :ok
      {:error, {field, op}} -> raise Barkpark.Content.InvalidFilterError.new(field, op)
    end

    Enum.reduce(map, query, fn
      {field, %{} = ops}, q -> apply_field_ops(q, field, ops)
      {field, value}, q -> apply_field_op(q, field, "eq", value)
    end)
  end

  # `{field, ops}` -> the first {field, op} with no SQL arm, or nil.
  #
  # A bare `filter[field]=value` scalar carries no op (it is `eq` sugar) and is
  # always accepted. Two ops need their VALUE checked as well, because their
  # clauses are value-matched and a wrong value falls THROUGH to the catch-all:
  # `is` has clauses only for "null"/"notnull" (so `[is]=published`, a plausible
  # equality typo, would silently match everything), and `hasStrong` parses its
  # `<tag>:<min>` value with `parse_has_strong/1`.
  defp offending_clause({field, %{} = ops}) do
    cond do
      op = Enum.find(Map.keys(ops), fn op -> unsupported_op?(field, op) end) ->
        {field, op}

      Map.has_key?(ops, "is") and Map.get(ops, "is") not in ["null", "notnull"] ->
        {field, "is"}

      Map.has_key?(ops, "hasStrong") and parse_has_strong(Map.get(ops, "hasStrong")) == :error ->
        {field, "hasStrong"}

      op =
          Enum.find(Map.keys(ops), fn op ->
            op not in @list_value_ops and non_scalar_op_value?(ops, op)
          end) ->
        {field, op}

      # `in`/`nin` bind a LIST (the HTTP door splits its comma string into one
      # via `normalize_filter_op/1`); a scalar has no clause and would fall to
      # the catch-all.
      op = Enum.find(@list_value_ops, fn op -> non_list_op_value?(ops, op) end) ->
        {field, op}

      true ->
        nil
    end
  end

  defp offending_clause({_field, _scalar}), do: nil

  # An op is supported for THIS field when a clause exists for the pair. The
  # `doc_id`-only prefix ops are the one field-sensitive case; everything else is
  # field-generic.
  defp unsupported_op?(field, op) when is_binary(op) do
    cond do
      # The builder-only prefix spellings, on the id columns only. Checked FIRST
      # so the capability table below never has to carry a non-public spelling.
      op in @doc_id_only_ops ->
        field not in @id_fields

      # A promoted column answers from its own table, NOT from the global set:
      # an op with no clause for THIS column would otherwise read a JSONB key
      # that does not exist and return 0 rows at 200 OK.
      ops = Map.get(@column_field_ops, field) ->
        op not in ops

      # Schemaless content field — the generic arm handles the whole set.
      true ->
        op not in @valid_filter_ops
    end
  end

  defp unsupported_op?(_field, _op), do: true

  defp non_scalar_op_value?(ops, op) do
    case Map.fetch(ops, op) do
      {:ok, v} -> is_list(v) or is_map(v)
      :error -> false
    end
  end

  defp non_list_op_value?(ops, op) do
    case Map.fetch(ops, op) do
      {:ok, v} -> not is_list(v)
      :error -> false
    end
  end

  defp apply_field_ops(query, field, ops) do
    Enum.reduce(ops, query, fn {op, value}, q ->
      apply_field_op(q, field, op, value)
    end)
  end

  defp apply_field_op(query, "title", "eq", v), do: where(query, [d], d.title == ^v)

  defp apply_field_op(query, "title", "in", vs) when is_list(vs),
    do: where(query, [d], d.title in ^vs)

  defp apply_field_op(query, "title", "nin", vs) when is_list(vs),
    do: where(query, [d], d.title not in ^vs)

  defp apply_field_op(query, "title", "contains", v),
    do: where(query, [d], ilike(d.title, ^like_contains(v)))

  defp apply_field_op(query, "title", "startsWith", v),
    do: where(query, [d], ilike(d.title, ^like_starts_with(v)))

  defp apply_field_op(query, "title", "endsWith", v),
    do: where(query, [d], ilike(d.title, ^like_ends_with(v)))

  defp apply_field_op(query, "title", "gt", v), do: where(query, [d], d.title > ^v)
  defp apply_field_op(query, "title", "gte", v), do: where(query, [d], d.title >= ^v)
  defp apply_field_op(query, "title", "lt", v), do: where(query, [d], d.title < ^v)
  defp apply_field_op(query, "title", "lte", v), do: where(query, [d], d.title <= ^v)
  defp apply_field_op(query, "title", "neq", v), do: where(query, [d], d.title != ^v)
  defp apply_field_op(query, "title", "is", "null"), do: where(query, [d], is_nil(d.title))

  defp apply_field_op(query, "title", "is", "notnull"),
    do: where(query, [d], not is_nil(d.title))

  # `_createdAt` / `_updatedAt` filter on the timestamp COLUMNS (inserted_at /
  # updated_at). The response envelope exposes both reserved keys and `order`
  # already supports them, but filtering silently fell through to the generic
  # JSONB handler (no `content->>'_createdAt'` key → empty result). Map the
  # reserved key to its column and compare against the parsed ISO8601 value.
  # Comparison ops only; an unparseable value is a no-op so a bad date can never
  # raise. Must precede the generic `field` clauses below.
  defp apply_field_op(query, "_createdAt", op, v) when op in ~w(gt gte lt lte eq neq),
    do: apply_ts_op(query, :inserted_at, op, v)

  defp apply_field_op(query, "_updatedAt", op, v) when op in ~w(gt gte lt lte eq neq),
    do: apply_ts_op(query, :updated_at, op, v)

  defp apply_field_op(query, "status", "eq", v), do: where(query, [d], d.status == ^v)

  defp apply_field_op(query, "status", "in", vs) when is_list(vs),
    do: where(query, [d], d.status in ^vs)

  defp apply_field_op(query, "status", "nin", vs) when is_list(vs),
    do: where(query, [d], d.status not in ^vs)

  defp apply_field_op(query, "status", "neq", v), do: where(query, [d], d.status != ^v)
  defp apply_field_op(query, "status", "is", "null"), do: where(query, [d], is_nil(d.status))

  defp apply_field_op(query, "status", "is", "notnull"),
    do: where(query, [d], not is_nil(d.status))

  # WIDENED (gfr-w1-per-field-op-table). `status` is a PROMOTED COLUMN, so these
  # three fell through to the generic JSONB arm and read `content->>'status'` —
  # a key that does not exist on a column-backed field — returning 0 rows at
  # 200 OK. Same `ilike` idiom as `title`, which has carried the full set all
  # along; widening beats refusing here because the op is meaningful on the
  # column and a working filter is what the caller asked for.
  defp apply_field_op(query, "status", "contains", v),
    do: where(query, [d], ilike(d.status, ^like_contains(v)))

  defp apply_field_op(query, "status", "startsWith", v),
    do: where(query, [d], ilike(d.status, ^like_starts_with(v)))

  defp apply_field_op(query, "status", "endsWith", v),
    do: where(query, [d], ilike(d.status, ^like_ends_with(v)))

  # doc_id operators — desk-group filters (e.g. drafts. prefix) need this.
  defp apply_field_op(query, "doc_id", "eq", v), do: where(query, [d], d.doc_id == ^v)

  defp apply_field_op(query, "doc_id", "in", vs) when is_list(vs),
    do: where(query, [d], d.doc_id in ^vs)

  defp apply_field_op(query, "doc_id", "nin", vs) when is_list(vs),
    do: where(query, [d], d.doc_id not in ^vs)

  defp apply_field_op(query, "doc_id", "starts_with", v),
    do: where(query, [d], like(d.doc_id, ^like_starts_with(v)))

  defp apply_field_op(query, "doc_id", "not_starts_with", v),
    do: where(query, [d], not like(d.doc_id, ^like_starts_with(v)))

  # WIDENED (gfr-w1-per-field-op-table). The worst case of the class: doc_id
  # PREFIX filtering was unreachable by ANY spelling. The column clause is
  # `starts_with` (snake, builder-only, no public wire form), while the public
  # allowlist carries only `startsWith` (camel) — which fell through to JSONB
  # and matched nothing. `startsWith` now hits the column.
  #
  # This does NOT put `starts_with` on the wire. The snake spellings stay
  # builder-only exactly as `@doc_id_only_ops` documents, and
  # `filter_ops_test.exs` "the door stays narrower than the builder" reds if
  # that ever changes. What is fixed here is a DOCUMENTED op that silently lied.
  defp apply_field_op(query, "doc_id", "neq", v), do: where(query, [d], d.doc_id != ^v)

  defp apply_field_op(query, "doc_id", "contains", v),
    do: where(query, [d], ilike(d.doc_id, ^like_contains(v)))

  defp apply_field_op(query, "doc_id", "startsWith", v),
    do: where(query, [d], ilike(d.doc_id, ^like_starts_with(v)))

  defp apply_field_op(query, "doc_id", "endsWith", v),
    do: where(query, [d], ilike(d.doc_id, ^like_ends_with(v)))

  # `_id` is the id field clients SEE in responses (it carries the physical doc_id,
  # drafts. prefix and all). Filtering should use that same name, so alias every
  # `_id` op to the doc_id column — `.eq('_id', x)` / `.in('_id', ids)` now work
  # (batch-fetch a known id-list in one request) instead of silently matching none.
  defp apply_field_op(query, "_id", op, v), do: apply_field_op(query, "doc_id", op, v)

  # `type` operators — the last promoted column with NO clause at all, so BOTH
  # its spellings read `content->>'type'` and could only ever return 0 rows at
  # 200 OK (task-20c081f70cb8d85e). Measured on the unpatched tree, on a route
  # where every row matches: `filter[_type][eq]=post` -> 0 of 3. Worse than a
  # missing feature — a board audit reading that zero writes down "absent" for
  # a type that is fully present.
  #
  # WHY PROMOTING THE BARE SPELLING IS SAFE, and not the judgement call it looks
  # like: `type` is on `Barkpark.Content.Writer`'s `@reserved_in` list
  # (writer.ex:1291) and `Map.drop`ped from `content` on EVERY write
  # (writer.ex:1310), alongside `doc_id`, `title` and `status`. No document can
  # carry a `type` content key — verified by writing one and reading the row
  # back: `%{"_id" => "p1", "title" => "X", "type" => "park", "mood" => "sunny"}`
  # stores `content == %{"mood" => "sunny"}`. So there is no schemaless caller
  # whose working JSONB filter this could break; the only thing bare `type`
  # could match before was nothing at all.
  defp apply_field_op(query, "type", "eq", v), do: where(query, [d], d.type == ^v)

  defp apply_field_op(query, "type", "neq", v), do: where(query, [d], d.type != ^v)

  defp apply_field_op(query, "type", "in", vs) when is_list(vs),
    do: where(query, [d], d.type in ^vs)

  defp apply_field_op(query, "type", "nin", vs) when is_list(vs),
    do: where(query, [d], d.type not in ^vs)

  defp apply_field_op(query, "type", "contains", v),
    do: where(query, [d], ilike(d.type, ^like_contains(v)))

  defp apply_field_op(query, "type", "startsWith", v),
    do: where(query, [d], ilike(d.type, ^like_starts_with(v)))

  defp apply_field_op(query, "type", "endsWith", v),
    do: where(query, [d], ilike(d.type, ^like_ends_with(v)))

  # `_type` is the spelling clients SEE in every response body, so filtering
  # should use that same name — the exact argument the `_id` -> `doc_id` alias
  # above makes, for the sibling column.
  defp apply_field_op(query, "_type", op, v), do: apply_field_op(query, "type", op, v)

  defp apply_field_op(query, field, "eq", v) do
    if nested_path?(field) do
      segs = nested_segments(field)

      where(
        query,
        [d],
        fragment("jsonb_extract_path_text(?, VARIADIC ?) = ?", d.content, ^segs, ^v)
      )
    else
      where(query, [d], fragment("?->>? = ?", d.content, ^field, ^v))
    end
  end

  # `neq` uses strict SQL `<>`, so rows where the field is NULL/absent are
  # EXCLUDED (NULL <> v is NULL → false) — matching Sanity `!=` / Strapi `$ne`.
  defp apply_field_op(query, field, "neq", v) do
    if nested_path?(field) do
      segs = nested_segments(field)

      where(
        query,
        [d],
        fragment("jsonb_extract_path_text(?, VARIADIC ?) <> ?", d.content, ^segs, ^v)
      )
    else
      where(query, [d], fragment("?->>? <> ?", d.content, ^field, ^v))
    end
  end

  defp apply_field_op(query, field, "in", vs) when is_list(vs) do
    if nested_path?(field) do
      segs = nested_segments(field)

      where(
        query,
        [d],
        fragment(
          "jsonb_extract_path_text(?, VARIADIC ?) = ANY(?)",
          d.content,
          ^segs,
          ^vs
        )
      )
    else
      where(query, [d], fragment("?->>? = ANY(?)", d.content, ^field, ^vs))
    end
  end

  # `nin` = NOT IN. `<> ALL` excludes NULL/absent rows (NULL <> ALL → NULL →
  # false), consistent with `neq`. Matches Strapi `$notIn`.
  defp apply_field_op(query, field, "nin", vs) when is_list(vs) do
    if nested_path?(field) do
      segs = nested_segments(field)

      where(
        query,
        [d],
        fragment("jsonb_extract_path_text(?, VARIADIC ?) <> ALL(?)", d.content, ^segs, ^vs)
      )
    else
      where(query, [d], fragment("?->>? <> ALL(?)", d.content, ^field, ^vs))
    end
  end

  defp apply_field_op(query, field, "contains", v),
    do: apply_ilike(query, field, like_contains(v))

  defp apply_field_op(query, field, "startsWith", v),
    do: apply_ilike(query, field, like_starts_with(v))

  defp apply_field_op(query, field, "endsWith", v),
    do: apply_ilike(query, field, like_ends_with(v))

  # Range comparisons. A JSONB value pulled as TEXT compares LEXICALLY ("10" < "5"
  # → rank 10 wrongly excluded), so when the filter value parses as a number AND
  # the stored value is a JSON number, compare numerically (the parsed number
  # rides as a bound param so Postgrex encodes it as numeric); otherwise keep the
  # text compare so string-stored fields stay "stringly" (no regression).
  # Extraction goes through `jsonb_extract_path[_text]` over the dot-split
  # segments, so a NESTED path (`price.amount`) compares the same as a top-level
  # field — matching the `eq` op (previously the range ops looked up a literal key
  # named "price.amount" and silently matched nothing). The CASE guards the
  # `::numeric` cast, so non-number rows never raise. All inputs are bound params.
  defp apply_field_op(query, field, "gt", v) do
    segs = nested_segments(field)

    case parse_number(v) do
      {:ok, n} ->
        where(
          query,
          [d],
          fragment(
            "CASE WHEN jsonb_typeof(jsonb_extract_path(?, VARIADIC ?)) = 'number' THEN (jsonb_extract_path_text(?, VARIADIC ?))::numeric > ? ELSE jsonb_extract_path_text(?, VARIADIC ?) > ? END",
            d.content,
            ^segs,
            d.content,
            ^segs,
            ^n,
            d.content,
            ^segs,
            ^v
          )
        )

      :error ->
        where(
          query,
          [d],
          fragment("jsonb_extract_path_text(?, VARIADIC ?) > ?", d.content, ^segs, ^v)
        )
    end
  end

  defp apply_field_op(query, field, "gte", v) do
    segs = nested_segments(field)

    case parse_number(v) do
      {:ok, n} ->
        where(
          query,
          [d],
          fragment(
            "CASE WHEN jsonb_typeof(jsonb_extract_path(?, VARIADIC ?)) = 'number' THEN (jsonb_extract_path_text(?, VARIADIC ?))::numeric >= ? ELSE jsonb_extract_path_text(?, VARIADIC ?) >= ? END",
            d.content,
            ^segs,
            d.content,
            ^segs,
            ^n,
            d.content,
            ^segs,
            ^v
          )
        )

      :error ->
        where(
          query,
          [d],
          fragment("jsonb_extract_path_text(?, VARIADIC ?) >= ?", d.content, ^segs, ^v)
        )
    end
  end

  defp apply_field_op(query, field, "lt", v) do
    segs = nested_segments(field)

    case parse_number(v) do
      {:ok, n} ->
        where(
          query,
          [d],
          fragment(
            "CASE WHEN jsonb_typeof(jsonb_extract_path(?, VARIADIC ?)) = 'number' THEN (jsonb_extract_path_text(?, VARIADIC ?))::numeric < ? ELSE jsonb_extract_path_text(?, VARIADIC ?) < ? END",
            d.content,
            ^segs,
            d.content,
            ^segs,
            ^n,
            d.content,
            ^segs,
            ^v
          )
        )

      :error ->
        where(
          query,
          [d],
          fragment("jsonb_extract_path_text(?, VARIADIC ?) < ?", d.content, ^segs, ^v)
        )
    end
  end

  defp apply_field_op(query, field, "lte", v) do
    segs = nested_segments(field)

    case parse_number(v) do
      {:ok, n} ->
        where(
          query,
          [d],
          fragment(
            "CASE WHEN jsonb_typeof(jsonb_extract_path(?, VARIADIC ?)) = 'number' THEN (jsonb_extract_path_text(?, VARIADIC ?))::numeric <= ? ELSE jsonb_extract_path_text(?, VARIADIC ?) <= ? END",
            d.content,
            ^segs,
            d.content,
            ^segs,
            ^n,
            d.content,
            ^segs,
            ^v
          )
        )

      :error ->
        where(
          query,
          [d],
          fragment("jsonb_extract_path_text(?, VARIADIC ?) <= ?", d.content, ^segs, ^v)
        )
    end
  end

  # `has` — array-membership: matches docs whose array field contains the value,
  # as a Sanity-style `{_ref}` object (references) OR a plain scalar. The scalar
  # arm matches on the element's TEXT form (`e #>> '{}'` renders 2021 → "2021",
  # true → "true", "x" → "x"), so it covers every scalar the SDK's `has` accepts
  # — string | number | boolean. (The prior `e = to_jsonb(?::text)` only matched
  # JSON *string* elements, so `has(years, 2021)` over [2020, 2021] silently
  # missed.) The CASE guards non-array/absent fields so they no-match instead of
  # erroring. Extraction goes through `jsonb_extract_path` over the dot-split
  # segments, so a NESTED array (`meta.tags has tag-x`) works like a top-level one
  # — matching the other ops. Field + value ride as bound params (injection-safe).
  defp apply_field_op(query, field, "has", v) do
    segs = nested_segments(field)

    where(
      query,
      [d],
      fragment(
        "EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(jsonb_extract_path(?, VARIADIC ?)) = 'array' THEN jsonb_extract_path(?, VARIADIC ?) ELSE '[]'::jsonb END) AS e WHERE e->>'_ref' = ? OR e #>> '{}' = ?)",
        d.content,
        ^segs,
        d.content,
        ^segs,
        ^v,
        ^v
      )
    )
  end

  # `hasStrong` — weighted-tag membership with a strength floor (authoring-
  # excellence D20): matches docs whose array field contains a WEIGHTED entry
  # named `tag` with `strength >= min`. The wire value is ONE scalar
  # `<tag>:<min_strength>` split at the LAST colon (tag names may carry
  # colons; the strength never does). Legacy flat-string elements are ignored
  # by construction (`->>` on a scalar element is NULL) and a non-numeric
  # `strength` never casts (CASE-guarded), so a mixed-shape corpus can't
  # raise. The array CASE guard mirrors `has`. A value that doesn't parse is a
  # no-op here, matching the strict-parser convention (`parse_number`,
  # `parse_ts`) — the public wire is 400-guarded up front by the controller's
  # `invalid_filter` check, which calls `parse_has_strong/1` too.
  defp apply_field_op(query, field, "hasStrong", v) do
    case parse_has_strong(v) do
      {:ok, tag, min} ->
        segs = nested_segments(field)

        where(
          query,
          [d],
          fragment(
            "EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(jsonb_extract_path(?, VARIADIC ?)) = 'array' THEN jsonb_extract_path(?, VARIADIC ?) ELSE '[]'::jsonb END) AS e WHERE e->>'tag' = ? AND (CASE WHEN jsonb_typeof(e->'strength') = 'number' THEN (e->>'strength')::numeric ELSE NULL END) >= ?)",
            d.content,
            ^segs,
            d.content,
            ^segs,
            ^tag,
            ^min
          )
        )

      # A value that does not parse used to return the query UNCHANGED, so a
      # malformed `hasStrong` silently returned EVERY row. It is a refusal now —
      # `validate_filter_map/1` catches this shape up front at the chokepoint, so
      # reaching here means a caller built the clause past that check; either way
      # the answer is a 400, never a silent unfiltered set.
      :error ->
        raise Barkpark.Content.InvalidFilterError.new(field, "hasStrong")
    end
  end

  # `is` — null/absence on a content field. `eq(field, null)` → IS NULL (matches an
  # absent key OR an explicit JSON null, since `->>` of a JSON null is SQL NULL);
  # `neq(field, null)` → IS NOT NULL. Nested-aware via segs, like the other ops.
  defp apply_field_op(query, field, "is", "null") do
    segs = nested_segments(field)

    where(
      query,
      [d],
      fragment("jsonb_extract_path_text(?, VARIADIC ?) IS NULL", d.content, ^segs)
    )
  end

  defp apply_field_op(query, field, "is", "notnull") do
    segs = nested_segments(field)

    where(
      query,
      [d],
      fragment("jsonb_extract_path_text(?, VARIADIC ?) IS NOT NULL", d.content, ^segs)
    )
  end

  # THE CATCH-ALL, which used to `do: query` — an unsupported clause vanished and
  # the caller got the UNFILTERED set. It is a structural backstop now: with
  # `apply_filter_map/2` validating up front, nothing should reach here, and if a
  # future clause is deleted or a new op is documented without an arm, this
  # refuses loudly instead of over-returning silently.
  defp apply_field_op(_query, field, op, _value),
    do: raise(Barkpark.Content.InvalidFilterError.new(field, op))

  @doc """
  Parse a `hasStrong` filter value — `"<tag>:<min_strength>"`, split at the
  LAST colon — into `{:ok, tag, min}` | `:error`. Public so the HTTP layer can
  reject a malformed value up front (422 `invalid_filter`, fail-closed) with
  the SAME grammar the SQL arm uses; one parser, two callers.
  """
  @spec parse_has_strong(term()) :: {:ok, String.t(), integer()} | :error
  def parse_has_strong(v) when is_binary(v) do
    with [_, _ | _] = parts <- String.split(v, ":"),
         {min_s, tag_parts} <- List.pop_at(parts, -1),
         tag when tag != "" <- Enum.join(tag_parts, ":"),
         {min, ""} <- Integer.parse(min_s) do
      {:ok, tag, min}
    else
      _ -> :error
    end
  end

  def parse_has_strong(_), do: :error

  # Parse a range filter value into a number Postgrex encodes as `numeric`, so a
  # numeric `gt`/`lt` compares numerically while `gt('title', 'M')` stays text.
  # Strict: a trailing non-numeric tail (e.g. "5abc") is :error, not a partial 5.
  defp parse_number(v) when is_number(v), do: {:ok, v}

  defp parse_number(v) when is_binary(v) do
    case Decimal.parse(v) do
      {decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end

  defp parse_number(_), do: :error

  # `_createdAt` / `_updatedAt` timestamp-column comparison. Parse the ISO8601
  # value, then compare the chosen column with the given op. The column atom
  # (:inserted_at / :updated_at) is bound via `field/2`. An unparseable value
  # returns the query unchanged (no-op) rather than raising.
  defp apply_ts_op(query, col, op, v) do
    case parse_ts(v) do
      {:ok, dt} -> apply_ts_compare(query, col, op, dt)
      :error -> query
    end
  end

  defp apply_ts_compare(query, col, "gt", dt), do: where(query, [d], field(d, ^col) > ^dt)
  defp apply_ts_compare(query, col, "gte", dt), do: where(query, [d], field(d, ^col) >= ^dt)
  defp apply_ts_compare(query, col, "lt", dt), do: where(query, [d], field(d, ^col) < ^dt)
  defp apply_ts_compare(query, col, "lte", dt), do: where(query, [d], field(d, ^col) <= ^dt)
  defp apply_ts_compare(query, col, "eq", dt), do: where(query, [d], field(d, ^col) == ^dt)
  defp apply_ts_compare(query, col, "neq", dt), do: where(query, [d], field(d, ^col) != ^dt)

  # Accept a full ISO8601 datetime, or a bare date (→ midnight UTC) so
  # `_createdAt gte 2026-01-01` works without forcing a time component.
  defp parse_ts(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      _ ->
        case Date.from_iso8601(v) do
          {:ok, d} -> {:ok, DateTime.new!(d, ~T[00:00:00.000000])}
          _ -> :error
        end
    end
  end

  defp parse_ts(_), do: :error

  # Build a `%substring%` ILIKE pattern with the user value's LIKE wildcards
  # escaped, so `contains`/search treat `%` and `_` as LITERALS (otherwise
  # `contains('title', '50%')` matches any "50…" and `'a_c'` matches "abc").
  # Backslash is escaped first (PostgreSQL's default ESCAPE char); the result
  # rides as a bound param, so the escapes are interpreted by ILIKE, not the shell.
  defp escape_like(v) do
    v
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp like_contains(v), do: "%#{escape_like(v)}%"
  defp like_starts_with(v), do: "#{escape_like(v)}%"
  defp like_ends_with(v), do: "%#{escape_like(v)}"

  # ILIKE a content field against a pre-built pattern — contains/startsWith/endsWith
  # share the fragment; only the wildcard anchoring of the pattern differs. Nested-aware.
  defp apply_ilike(query, field, pattern) do
    if nested_path?(field) do
      segs = nested_segments(field)

      where(
        query,
        [d],
        fragment("jsonb_extract_path_text(?, VARIADIC ?) ILIKE ?", d.content, ^segs, ^pattern)
      )
    else
      where(query, [d], fragment("?->>? ILIKE ?", d.content, ^field, ^pattern))
    end
  end

  defp nested_path?(field) when is_binary(field), do: String.contains?(field, ".")
  defp nested_path?(_), do: false

  # Split a dot-delimited content path into segments for
  # `jsonb_extract_path_text(content, VARIADIC …)`. The `content.` prefix
  # is conventional (desk-group filters in schema JSON write e.g.
  # `"content.bp_export_status.state"`) but the JSONB column is already
  # `d.content`, so we strip it before splitting — otherwise we'd
  # descend into `content.content.…`.
  defp nested_segments(field) when is_binary(field) do
    field
    |> String.replace_prefix("content.", "")
    |> String.split(".")
  end

  # Multi-field sort: a list of specs applied in order. Ecto's order_by accumulates
  # across calls, so reducing builds primary, then secondary tiebreak, etc.
  defp apply_order(q, specs) when is_list(specs),
    do: Enum.reduce(specs, q, fn spec, acc -> apply_order(acc, spec) end)

  defp apply_order(q, :updated_at_desc), do: order_by(q, [d], desc: d.updated_at)
  defp apply_order(q, :updated_at_asc), do: order_by(q, [d], asc: d.updated_at)
  defp apply_order(q, :created_at_desc), do: order_by(q, [d], desc: d.inserted_at)
  defp apply_order(q, :created_at_asc), do: order_by(q, [d], asc: d.inserted_at)

  # Content-field ordering: `title`/`status` are promoted columns (mirroring the
  # filter ops above); every other field sorts by its JSONB value. `field` rides
  # as a bound parameter in the fragment, so it is injection-safe.
  defp apply_order(q, {:field, "title", dir}), do: order_by(q, [d], [{^dir, d.title}])
  defp apply_order(q, {:field, "status", dir}), do: order_by(q, [d], [{^dir, d.status}])

  # Numeric-aware: a JSONB `->>` value is TEXT, so ordering it sorts lexically
  # ("10" before "9"). The primary key casts JSON-number values to numeric (NULL
  # for non-numbers, via the typeof-guarded CASE — no cast errors), so number
  # fields sort numerically; the text secondary orders everything else (a string
  # field's primary key is all-NULL, so it falls through to text — no regression).
  defp apply_order(q, {:field, field, dir}) do
    segs = nested_segments(field)

    order_by(q, [d], [
      {^dir,
       fragment(
         "CASE WHEN jsonb_typeof(jsonb_extract_path(?, VARIADIC ?)) = 'number' THEN (jsonb_extract_path_text(?, VARIADIC ?))::numeric END",
         d.content,
         ^segs,
         d.content,
         ^segs
       )},
      {^dir, fragment("jsonb_extract_path_text(?, VARIADIC ?)", d.content, ^segs)}
    ])
  end

  defp apply_order(q, _), do: order_by(q, [d], desc: d.updated_at)

  @doc """
  Fetch a single document by `{doc_id, type, dataset}`.

  `opts` may carry tenancy scope:
    - `:workspace_id` — scope the read to a workspace (nil = unscoped /
                        pre-tenancy back-compat; used by internal mutation
                        lookups that resolve the workspace another way).
    - `:project_id`   — further narrow to a project (requires `:workspace_id`).

  The workspace/project filter is applied IN ADDITION TO the dataset-string
  filter via `Barkpark.Content.Scope.scope_to_workspace/3`.
  """
  def get_document(doc_id, type, dataset, opts \\ [])

  def get_document(doc_id, type, dataset, _opts)
      when is_nil(doc_id) or is_nil(type) or is_nil(dataset) do
    {:error, :not_found}
  end

  def get_document(doc_id, type, dataset, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Document
    |> where([d], d.doc_id == ^doc_id and d.type == ^type)
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> maybe_scope_to_owner(type, dataset, opts)
    |> maybe_scope_to_grants(opts)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  @doc """
  Resolve a wikilink `target` (a human title or alias string) to the single
  best-matching document of `type`, scoped to `dataset` + the caller's tenant.

  ONE scoped `Repo.one` (never two round-trips):

    * TITLE match is CASE-INSENSITIVE — `lower(title) = lower(target)`. The
      `title` column is matched directly (a real `Document` column, not under
      `content`).
    * ALIAS match is the scalar-membership JSONB containment
      `content->'aliases' @> to_jsonb(target::text)` — the proven pattern from
      the task-label query (`?->'labels' @> to_jsonb(?::text)`). Alias match is
      EXACT (the `@>` form cannot case-fold).
    * PRECEDENCE — a title match OUTRANKS an alias-only match on collision via a
      `CASE`-ranked `order_by` + `limit(1)`, so the function stays one query.
      Ties break deterministically by `doc_id`.

  Scoping is identical to `get_document/4` (`scope_to_dataset` +
  `scope_to_workspace_or_global` — the P0 leak guard), so a wikilink only
  resolves cross-workspace when the caller deliberately omits `:workspace_id`
  (a global read, as in `get_document/4`).

  Returns the `%Document{}` on a hit, `nil` on no match.
  """
  @spec resolve_doc_by_title_or_alias(String.t(), String.t(), String.t(), keyword()) ::
          Document.t() | nil
  def resolve_doc_by_title_or_alias(target, type, dataset, opts \\ []) when is_binary(target) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Document
    |> where([d], d.type == ^type)
    |> where(
      [d],
      fragment("lower(?) = lower(?)", d.title, ^target) or
        fragment("?->'aliases' @> to_jsonb(?::text)", d.content, ^target)
    )
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> maybe_scope_to_owner(type, dataset, opts)
    |> maybe_scope_to_grants(opts)
    |> order_by(
      [d],
      asc: fragment("CASE WHEN lower(?) = lower(?) THEN 0 ELSE 1 END", d.title, ^target),
      asc: d.doc_id
    )
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  BATCHED sibling of `resolve_doc_by_title_or_alias/4` for the wikilink
  pre-resolve pass (lvw-t7): ONE query per `type` returning EVERY candidate
  `%Document{}` of that type matching ANY of

    * `targets` — case-insensitive TITLE (`lower(title) = ANY(...)`) or EXACT
      alias membership (element-of over `content["aliases"]`, matching the
      single-target `@>` containment semantics), or
    * `doc_ids` — exact `doc_id` membership (the id-pinned picker path; the
      caller passes both the pinned spelling and its `drafts.` twin).

  The per-target pick (title-beats-alias precedence, `doc_id` tie-break) is the
  CALLER's job — this function only fetches the candidate rows, so N wikilink
  targets cost one query instead of N (`Papers.resolve_wikilinks_in_blocks/3`
  feeds the body render palette; N+1 is forbidden on that path).

  Scoping is identical to `resolve_doc_by_title_or_alias/4` (`scope_to_dataset`
  + `scope_to_workspace_or_global` + `maybe_scope_to_owner` — per-type, which
  is why this batches per type rather than across types).

  D5 (task chip): pass `published_only: true` in `opts` to restrict matches to
  PUBLISHED rows — the anonymous/public-surface gate. Any palette that feeds an
  anonymous render MUST set it; a draft-only doc then simply does not resolve
  (the wikilink degrades to its alias/children, leaking neither title nor
  state).
  """
  @spec resolve_docs_by_titles_or_aliases(
          [String.t()],
          [String.t()],
          String.t(),
          String.t(),
          keyword()
        ) :: [Document.t()]
  def resolve_docs_by_titles_or_aliases(targets, doc_ids, type, dataset, opts \\ [])
      when is_list(targets) and is_list(doc_ids) do
    targets = Enum.filter(targets, &(is_binary(&1) and &1 != ""))
    doc_ids = Enum.filter(doc_ids, &(is_binary(&1) and &1 != ""))

    if targets == [] and doc_ids == [] do
      []
    else
      workspace_id = Keyword.get(opts, :workspace_id)
      project_id = Keyword.get(opts, :project_id)
      lowered = Enum.map(targets, &String.downcase/1)

      Document
      |> where([d], d.type == ^type)
      |> where(
        [d],
        fragment("lower(?) = ANY(?::text[])", d.title, ^lowered) or
          fragment(
            "CASE WHEN jsonb_typeof(?->'aliases') = 'array' THEN EXISTS (SELECT 1 FROM jsonb_array_elements_text(?->'aliases') AS a(x) WHERE a.x = ANY(?::text[])) ELSE false END",
            d.content,
            d.content,
            ^targets
          ) or
          d.doc_id in ^doc_ids
      )
      |> scope_to_dataset(dataset, opts)
      |> scope_to_workspace_or_global(workspace_id, project_id)
      |> maybe_scope_to_owner(type, dataset, opts)
      |> maybe_scope_to_grants(opts)
      |> maybe_published_only(opts)
      |> order_by([d], asc: d.doc_id)
      |> Repo.all()
    end
  end

  @doc """
  BATCHED, TYPELESS candidate fetch for the valueref pre-resolve pass (lvw-t1,
  wire §5): ONE query returning every `%Document{}` — any type — whose `doc_id`
  matches any of `doc_ids`. The caller passes each target slug in both the
  published and `drafts.` spelling and picks per target with the published-row
  preference (D3), mirroring `Graph.resolve_doc/3` (the canonical slug-resolve)
  at batch cost: N valueref targets cost one query, never N
  (`Papers.resolve_values_in_blocks/3` feeds the body render palette; N+1 is
  forbidden on that path).

  Scoping fails CLOSED for a typeless read: `scope_to_dataset` +
  `scope_to_workspace_or_global` as everywhere, PLUS `scope_to_owner/2` applied
  UNCONDITIONALLY with the caller's `:caller_context` (nil ⇒ unowned rows only
  — the graph-hydration precedent for typeless reads, `Graph.docs_by_id/2`),
  and the D5 `published_only: true` gate for anonymous/public palettes.
  """
  @spec resolve_docs_by_ids([String.t()], String.t(), keyword()) :: [Document.t()]
  def resolve_docs_by_ids(doc_ids, dataset, opts \\ []) when is_list(doc_ids) do
    doc_ids = Enum.filter(doc_ids, &(is_binary(&1) and &1 != ""))

    if doc_ids == [] do
      []
    else
      Document
      |> where([d], d.doc_id in ^doc_ids)
      |> scope_to_dataset(dataset, opts)
      |> scope_to_workspace_or_global(
        Keyword.get(opts, :workspace_id),
        Keyword.get(opts, :project_id)
      )
      |> scope_to_owner(Keyword.get(opts, :caller_context))
      |> maybe_scope_to_grants(opts)
      |> maybe_published_only(opts)
      |> order_by([d], asc: d.doc_id)
      |> Repo.all()
    end
  end

  # D5 published-perspective gate for the wikilink batch resolver: with
  # `published_only: true` only published rows match (a `drafts.`-only doc is
  # invisible — the anonymous chip/link degrades instead of leaking draft
  # title/state). Absent/false ⇒ query untouched (the authorized Studio path).
  defp maybe_published_only(query, opts) do
    if Keyword.get(opts, :published_only, false) do
      # Prefix conjunct mirrors apply_perspective(:published): a `drafts.`-prefixed
      # row is never published, even if its status column reads "published" (an
      # incoherent state the write chokepoint now coerces away, belt-and-braces).
      prefix = DraftId.drafts_prefix() <> "%"
      where(query, [d], d.status == "published" and not like(d.doc_id, ^prefix))
    else
      query
    end
  end

  # The strongest weighted entry for ONE tag name on a row's `tags_meta`
  # GENERATED column (ae-w10 tag-detail read). ORDER BY … DESC LIMIT 1 IS the
  # MAX guarded-cast strength — expressed as a row (not a scalar MAX) so the
  # matched entry's `rationale` rides along in the same lateral. Shape guards
  # copied from `Search.DocumentsRetriever.tag_boost_key/1`
  # (`jsonb_typeof(e) = 'object'` + the strength digits regex — a non-integer
  # strength fails the guard instead of blowing up the `::int` cast) and the
  # name match is `lower() = lower()` like `Content.Related`'s tag leg. A
  # legacy flat-string element is `jsonb_typeof` "string" → no row → NULL
  # strength, which the caller's `desc_nulls_last` ranks LAST (Postgres DESC
  # defaults NULLS FIRST — legacy docs would otherwise rank on top).
  @strength_match_sql """
  (SELECT (e->>'strength')::int AS strength, e->>'rationale' AS rationale
     FROM jsonb_array_elements(?.tags_meta) AS e
    WHERE jsonb_typeof(e) = 'object'
      AND e->>'strength' ~ '^[0-9]+$'
      AND lower(e->>'tag') = lower(?)
    ORDER BY (e->>'strength')::int DESC
    LIMIT 1)
  """

  @doc """
  Every document of `type_or_types` carrying `tag` in its tags array, scoped
  to `dataset` + the caller's tenant — the tag-index read.

  DUAL-SHAPE (authoring-excellence D10/D19): `tags` elements are weighted
  objects `{tag, strength, rationale}` post-wall AND legacy flat strings under
  the exemption ratchet, so membership is an EXISTS over
  `jsonb_array_elements` matching `e->>'tag'` (weighted; NULL on a scalar
  element) OR `e #>> '{}'` (the flat element's own text — never matches a
  weighted object, whose `#>> '{}'` is its full JSON text). Exact match either
  way (Obsidian-parity). The unnest source is the `tags_meta` GENERATED
  column — byte-identical to the old inline `CASE WHEN jsonb_typeof(…)` guard
  (the generation expression materializes exactly that CASE, see
  `documents_retriever.ex` #4178) — so membership never DETOASTs `content`.
  Scoping is identical to `get_document/4` (the P0 leak guard); a LIST of
  types applies owner-scoping to the WHOLE query when ANY member type is
  owner-scoped (conservative fail-closed — never a leak, at worst a narrower
  mixed-type read). `published_only: true` narrows to the published
  perspective (the `maybe_published_only` gate; default off, so existing
  callers are untouched).

  Ordering (ae-w10 tag-browse reads):

    * default — title asc, `doc_id` asc (the historical tag-index order);
      returns `[Document.t()]`.
    * `order: :strength` — the tag-detail ranking: strongest carriers of
      `tag` first via a `desc_nulls_last` LEFT LATERAL over `tags_meta`
      (NULLS LAST is MANDATORY — see `@strength_match_sql`), tie-broken
      title asc then `doc_id` asc. Returns projection maps
      `%{doc_id, type, title, strength, rationale, main_tag_match}` — the
      title COLUMN, never `content->>'title'` (empty for 2117/2132 weighted
      docs, the D69 proven trap); `strength`/`rationale` are the matched
      (strongest) entry's, NULL for a legacy flat carrier; `main_tag_match`
      compares `content->>'main_tag'` case-insensitively (the one accepted
      `content` read, mirroring `Content.Related`'s main_tag bonus). The
      generic `order=` grammar structurally cannot express this
      parameterized per-tag order — it lives here as a dedicated option.
  """
  @spec docs_with_tag(String.t(), String.t() | [String.t()], String.t(), keyword()) ::
          [Document.t()] | [map()]
  def docs_with_tag(tag, type_or_types, dataset, opts \\ []) when is_binary(tag) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    types = List.wrap(type_or_types)

    base =
      Document
      |> where([d], d.type in ^types)
      |> where(
        [d],
        fragment(
          "EXISTS (SELECT 1 FROM jsonb_array_elements(?.tags_meta) AS e WHERE e->>'tag' = ? OR e #>> '{}' = ?)",
          d,
          ^tag,
          ^tag
        )
      )
      |> scope_to_dataset(dataset, opts)
      |> scope_to_workspace_or_global(workspace_id, project_id)
      |> maybe_scope_to_owner_any(types, dataset, opts)
      |> maybe_scope_to_grants(opts)
      |> maybe_published_only(opts)

    case Keyword.get(opts, :order) do
      :strength ->
        base
        |> join(:left_lateral, [d], m in fragment(@strength_match_sql, d, ^tag),
          on: true,
          as: :tag_match
        )
        |> order_by([d, tag_match: m],
          desc_nulls_last: m.strength,
          asc: d.title,
          asc: d.doc_id
        )
        |> select([d, tag_match: m], %{
          doc_id: d.doc_id,
          type: d.type,
          title: d.title,
          strength: m.strength,
          rationale: m.rationale,
          main_tag_match:
            fragment("lower(COALESCE(?->>'main_tag', '')) = lower(?)", d.content, ^tag)
        })
        |> Repo.all()

      _ ->
        base
        |> order_by([d], asc: d.title, asc: d.doc_id)
        |> Repo.all()
    end
  end

  # `maybe_scope_to_owner/4` for a type LIST: owner-scope the whole query when
  # ANY member type is owner-scoped. For a single type this is byte-identical
  # to the singular helper; for a mixed ask it is deliberately conservative
  # (fail-closed — an owner-scoped member narrows everything, never leaks).
  defp maybe_scope_to_owner_any(query, types, dataset, opts) do
    if Enum.any?(types, &Barkpark.Content.owner_scoped?(&1, dataset, opts)) do
      scope_to_owner(query, Keyword.get(opts, :caller_context))
    else
      query
    end
  end

  @doc """
  Documents of `type` whose TITLE matches `query` (case-insensitive substring) —
  the candidate read behind the `[[` autocomplete and the quick-switcher. Scoped
  + title-ordered, capped at `limit_n` (default 20) so an unbounded corpus can
  never flood a typeahead. A blank `query` yields `[]`.

  Title substring uses the established `ilike(title, "%v%")` filter pattern (the
  value is a bound parameter, not raw SQL). Scoping is the `get_document/4` P0
  leak guard.
  """
  @spec search_documents_by_title(String.t(), String.t(), String.t(), keyword(), pos_integer()) ::
          [Document.t()]
  def search_documents_by_title(query, type, dataset, opts \\ [], limit_n \\ 20)
      when is_binary(query) do
    case String.trim(query) do
      "" ->
        []

      q ->
        workspace_id = Keyword.get(opts, :workspace_id)
        project_id = Keyword.get(opts, :project_id)

        Document
        |> where([d], d.type == ^type)
        |> where([d], ilike(d.title, ^like_contains(q)))
        |> scope_to_dataset(dataset, opts)
        |> scope_to_workspace_or_global(workspace_id, project_id)
        |> maybe_scope_to_owner(type, dataset, opts)
        |> maybe_scope_to_grants(opts)
        |> order_by([d], asc: d.title, asc: d.doc_id)
        |> limit(^limit_n)
        |> Repo.all()
    end
  end

  @doc """
  DISTINCT tag VALUES of `type` whose name matches `query` (case-insensitive
  substring) — the inverse of `docs_with_tag/4`. Where `docs_with_tag` fans a
  tag OUT to the papers carrying it, this gathers the tag NAMES themselves
  across the corpus, for the `#tag` autocomplete popup.

  DUAL-SHAPE (authoring-excellence D10/D19): each row's `content["tags"]` is
  unnested through a LATERAL `jsonb_array_elements` selecting
  `COALESCE(e->>'tag', e #>> '{}')` — the weighted object's tag NAME when
  present (so strength/rationale text can neither surface as a "tag" nor
  ILIKE-false-positive the typeahead), else the legacy flat element's own
  text. The ILIKE filter + `DISTINCT` run in the OUTER query against the
  materialised name (a tag present in both shapes dedups to ONE row) —
  name-ordered, capped at `limit_n` (default 20) so an unbounded tag
  vocabulary can never flood a typeahead. The CASE guards a non-array/absent
  `tags` into zero rows. Scoping is the same `get_document/4` P0 leak guard
  (dataset + tenant). A blank `query` yields the top distinct tags (no `ilike`
  filter); a no-match yields `[]`.
  """
  @spec search_tags_for_type(String.t(), String.t(), String.t(), keyword(), pos_integer()) ::
          [String.t()]
  def search_tags_for_type(query, type, dataset, opts \\ [], limit_n \\ 20)
      when is_binary(query) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    trimmed = String.trim(query)

    # A set-returning function is illegal in WHERE, so the unnest is a LATERAL
    # join in an inner subquery (scoped) and the ILIKE filter is applied in the
    # OUTER query against the materialised `tag` column. Named binding: the
    # scope helpers may grow joins of their own, so the element source is
    # addressed as `:tag_elem`, never positionally.
    unnested =
      Document
      |> where([d], d.type == ^type)
      |> scope_to_dataset(dataset, opts)
      |> scope_to_workspace_or_global(workspace_id, project_id)
      |> maybe_scope_to_owner(type, dataset, opts)
      |> maybe_scope_to_grants(opts)
      |> join(
        :inner_lateral,
        [d],
        e in fragment(
          "(SELECT COALESCE(e->>'tag', e #>> '{}') AS tag FROM jsonb_array_elements(CASE WHEN jsonb_typeof(?->'tags') = 'array' THEN ?->'tags' ELSE '[]'::jsonb END) AS e)",
          d.content,
          d.content
        ),
        on: true,
        as: :tag_elem
      )
      |> select([tag_elem: e], %{tag: e.tag})

    outer =
      from(t in subquery(unnested),
        distinct: true,
        order_by: [asc: t.tag],
        limit: ^limit_n,
        select: t.tag
      )

    outer =
      case trimmed do
        "" -> outer
        q -> where(outer, [t], ilike(t.tag, ^like_contains(q)))
      end

    Repo.all(outer)
  end

  @doc """
  Batch sibling of `get_document/4`: load many documents by `doc_id` in ONE
  scoped query, returned as a `%{doc_id => %Document{}}` map.

  Applies the EXACT SAME tenant scoping as `get_document/4`
  (`scope_to_dataset` + `scope_to_workspace_or_global` — the P0 leak guard), so
  it can never surface another workspace's row even when two workspaces share a
  dataset string. Used by the search retrievers to hydrate a page of hits with a
  single round-trip instead of N per-hit reads. `doc_id` is the unique key; the
  caller re-associates `type` and preserves its own ordering.
  """
  @spec get_documents_by_ids([String.t()], String.t(), keyword()) ::
          %{optional(String.t()) => Document.t()}
  def get_documents_by_ids([], _dataset, _opts), do: %{}

  def get_documents_by_ids(doc_ids, dataset, opts) when is_list(doc_ids) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Document
    |> where([d], d.doc_id in ^doc_ids)
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    # Row/ownership ACL (Phase 4). This batch read is TYPELESS (a page of search
    # hits may span many types), so it can't gate on `owner_scoped?/3` per type.
    # `scope_to_owner/2` is applied UNCONDITIONALLY here — which is byte-identical
    # for non-owner_scoped types because their rows carry a NULL `owner_id`
    # (owner_id is stamped ONLY on owner_scoped writes), and a NULL owner always
    # satisfies the `owner_id == uid OR IS NULL` / `IS NULL` clauses. The net
    # effect: an owner_scoped hit owned by another user is dropped from a
    # non-owner's hydration, closing the leak through the search-expand path.
    |> scope_to_owner(Keyword.get(opts, :caller_context))
    |> maybe_scope_to_grants(opts)
    |> restrict_to_visible_types(dataset, opts)
    |> Repo.all()
    |> Map.new(fn d -> {d.doc_id, d} end)
  end

  @doc """
  Grant-narrowed COUNT companion to `get_documents_by_ids/3`: how many of the
  given `doc_ids` are visible to this caller under the EXACT SAME scoping stack
  (`scope_to_dataset` + `scope_to_workspace_or_global` + `scope_to_owner` +
  `maybe_scope_to_grants` — the same P0 leak + owner + grant guards). Fail-closed
  identically: a grant-derived caller (`opts[:grant_scoped]`) with no covering
  grant counts ZERO, never the whole candidate set.

  Used by the Indx retriever to report a `total` that never exceeds the
  grant-visible matches — the raw candidate-pool length would over-count
  out-of-grant hits the hydration read already drops.
  """
  @spec count_documents_by_ids([String.t()], String.t(), keyword()) :: non_neg_integer()
  def count_documents_by_ids([], _dataset, _opts), do: 0

  def count_documents_by_ids(doc_ids, dataset, opts) when is_list(doc_ids) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Document
    |> where([d], d.doc_id in ^doc_ids)
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> scope_to_owner(Keyword.get(opts, :caller_context))
    |> maybe_scope_to_grants(opts)
    |> restrict_to_visible_types(dataset, opts)
    |> exclude(:order_by)
    |> Repo.aggregate(:count)
  end

  # SCHEMA-VISIBILITY CLAMP — the second half of the tenancy stack above, and
  # the seat every reference/id hydration in this codebase already passes
  # through.
  #
  # NAMED FAILURE MODE it closes (task-38786b2edab15955): the query route gates
  # on the REQUESTED type only (`query_controller.ex:23-24` / `:407-408` —
  # `preview? or authed? or schema_public?`). `?expand=` then walks a reference
  # into a DIFFERENT type and hydrates it here, and `Envelope.render/3` redacts
  # on PER-FIELD attributes (`envelope.ex:325-334`) — it never reads the
  # schema's TOP-LEVEL visibility. So `GET /v1/data/query/production/post?expand=featuredAsset`
  # returned a full `mediaAsset` body to a caller whose DIRECT read of
  # `/v1/data/query/production/mediaAsset` 404s on the same gate. The pairing
  # ships in the seed data (`seeds/demo.ex:53-56`, `:110-113`). Same capability,
  # two doors, one clamped.
  #
  # WHY HERE AND NOT IN `Expand`. Three callers reach this function, and expand
  # is only one of them: the Indx retriever's hydration AND its reported total
  # (task-2b6aa2ae3fc3962f — the indx index is filtered at WRITE time only, with
  # no read-time backstop and no rebuild trigger on a public->private schema
  # flip) and the task-expectation reverse view. Clamping inside `Expand` would
  # fix one door and leave the shared function unclamped for the others.
  #
  # COUNT TOO, not just bodies: a total that includes private rows leaks their
  # EXISTENCE even when the bodies are withheld — the shape a sibling lane
  # proved live in search, where documents were withheld while the type facet
  # still named the private type. Bodies and counts clamp in the SAME seat.
  #
  # ONE PREDICATE, not a third copy: the tier test is
  # `Schema.bypasses_visibility_gate?/1` and the allowlist is
  # `Schema.public_type_names/2` — the same two the anonymous search allowlist
  # (`DocumentsRetriever.restrict_anonymous_to_public_types/3`) and the corpus
  # graph clamp (`Schema.visible_schemas/2`) read. ALLOWLIST, not denylist: a
  # type with no schema row is absent by construction (matching the query
  # route's live 404 for a schemaless type), `visibility: nil` / any future
  # value is NOT public, and an empty allowlist yields `d.type in []` ⇒ WHERE
  # false ⇒ nothing (fail closed, never everything).
  #
  # INERT for the callers that were already correct: the Postgres search
  # retriever clamps its own `base` upstream, so this clause is idempotent
  # there; an authenticated non-public-read principal skips it entirely and
  # pays no schema read at all.
  #
  # TOTAL over its inputs: `public_type_names/2` is guarded `when is_binary(dataset)`,
  # so a nil/malformed dataset would raise a FunctionClauseError — a 500 that
  # fires only for some inputs is itself a probe. A non-binary dataset is a
  # DENIAL (the empty allowlist) instead, never a crash oracle.
  defp restrict_to_visible_types(query, dataset, opts) do
    cond do
      Schema.bypasses_visibility_gate?(Keyword.get(opts, :caller_context)) ->
        query

      is_binary(dataset) ->
        where(query, [d], d.type in ^Schema.public_type_names(dataset, tenancy_opts(opts)))

      true ->
        where(query, [d], d.type in ^[])
    end
  end

  defp tenancy_opts(opts), do: Keyword.take(opts, [:workspace_id, :project_id])

  @doc """
  Fetch a document with draft-first preference. Returns the draft if it
  exists, otherwise falls back to the published row, plus flags for
  whether the returned doc is the draft and whether a published version
  exists. Used by StudioLive's native editor pane — consolidated in
  Task #11 WI3 from prior duplicates (the plugin LVs that originally
  shared this helper were removed in Goal `barkpark-zdy`).

      {doc | nil, is_draft :: boolean, has_published :: boolean}
  """
  @spec fetch_doc_with_draft(String.t(), String.t(), String.t(), keyword()) ::
          {Document.t() | nil, boolean(), boolean()}
  def fetch_doc_with_draft(type, doc_id, dataset, opts \\ []) do
    pub_id = DraftId.published_id(doc_id)
    draft_r = get_document(DraftId.draft_id(pub_id), type, dataset, opts)
    pub_r = get_document(pub_id, type, dataset, opts)

    {doc, is_draft} =
      case draft_r do
        {:ok, d} ->
          {d, true}

        _ ->
          case pub_r do
            {:ok, d} -> {d, false}
            _ -> {nil, false}
          end
      end

    {doc, is_draft, match?({:ok, _}, pub_r)}
  end

  # Byte-identical to `Barkpark.Content`'s private `scope_to_dataset/3` (concern
  # K, not yet extracted). Borrows the public `resolve_read_dataset_id/2`
  # through the facade so behaviour stays unchanged until K moves out.
  defp scope_to_dataset(query, dataset, opts) do
    case Barkpark.Content.resolve_read_dataset_id(dataset, opts) do
      id when is_binary(id) ->
        where(query, [x], x.dataset_id == ^id or (is_nil(x.dataset_id) and x.dataset == ^dataset))

      _ ->
        where(query, [x], x.dataset == ^dataset)
    end
  end
end
