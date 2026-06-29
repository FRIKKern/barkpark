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
  alias Barkpark.Content.{Document, DraftId}

  import Barkpark.Content.Scope,
    only: [scope_to_workspace_or_global: 3]

  @doc """
  List documents by type and dataset.

  Options:
    - `:perspective`  — `:published`, `:drafts`, or `:raw` (default `:raw`)
    - `:filter_map`   — map of field=>value filters, e.g. `%{"status" => "draft"}`
    - `:limit`        — max rows returned (default 100, max 1000, min 1)
    - `:offset`       — rows to skip (default 0)
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
    perspective = Keyword.get(opts, :perspective, :raw)
    filter_map = Keyword.get(opts, :filter_map, %{})
    limit = opts |> Keyword.get(:limit, 100) |> min(1000) |> max(1)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    order = Keyword.get(opts, :order, :updated_at_desc)

    base = base_query(type, dataset, filter_map, opts)

    case perspective do
      :drafts -> list_with_drafts_merged(base, order, limit, offset)
      other -> list_linear(base, other, order, limit, offset)
    end
  end

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
    |> apply_filter_map(filter_map)
  end

  defp list_linear(query, perspective, order, limit, offset) do
    query
    |> apply_perspective(perspective)
    |> apply_order(order)
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
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  defp apply_perspective(query, :published) do
    prefix = DraftId.drafts_prefix() <> "%"
    where(query, [d], not like(d.doc_id, ^prefix))
  end

  defp apply_perspective(query, _), do: query

  defp apply_filter_map(query, map) when map_size(map) == 0, do: query

  defp apply_filter_map(query, map) do
    Enum.reduce(map, query, fn
      {field, %{} = ops}, q -> apply_field_ops(q, field, ops)
      {field, value}, q -> apply_field_op(q, field, "eq", value)
    end)
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

  defp apply_field_op(query, "title", "gt", v), do: where(query, [d], d.title > ^v)
  defp apply_field_op(query, "title", "gte", v), do: where(query, [d], d.title >= ^v)
  defp apply_field_op(query, "title", "lt", v), do: where(query, [d], d.title < ^v)
  defp apply_field_op(query, "title", "lte", v), do: where(query, [d], d.title <= ^v)
  defp apply_field_op(query, "title", "neq", v), do: where(query, [d], d.title != ^v)
  defp apply_field_op(query, "title", "is", "null"), do: where(query, [d], is_nil(d.title))

  defp apply_field_op(query, "title", "is", "notnull"),
    do: where(query, [d], not is_nil(d.title))

  defp apply_field_op(query, "status", "eq", v), do: where(query, [d], d.status == ^v)

  defp apply_field_op(query, "status", "in", vs) when is_list(vs),
    do: where(query, [d], d.status in ^vs)

  defp apply_field_op(query, "status", "nin", vs) when is_list(vs),
    do: where(query, [d], d.status not in ^vs)

  defp apply_field_op(query, "status", "neq", v), do: where(query, [d], d.status != ^v)
  defp apply_field_op(query, "status", "is", "null"), do: where(query, [d], is_nil(d.status))

  defp apply_field_op(query, "status", "is", "notnull"),
    do: where(query, [d], not is_nil(d.status))

  # doc_id operators — desk-group filters (e.g. drafts. prefix) need this.
  defp apply_field_op(query, "doc_id", "eq", v), do: where(query, [d], d.doc_id == ^v)

  defp apply_field_op(query, "doc_id", "starts_with", v),
    do: where(query, [d], like(d.doc_id, ^"#{v}%"))

  defp apply_field_op(query, "doc_id", "not_starts_with", v),
    do: where(query, [d], not like(d.doc_id, ^"#{v}%"))

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

  defp apply_field_op(query, field, "contains", v) do
    if nested_path?(field) do
      segs = nested_segments(field)

      where(
        query,
        [d],
        fragment(
          "jsonb_extract_path_text(?, VARIADIC ?) ILIKE ?",
          d.content,
          ^segs,
          ^like_contains(v)
        )
      )
    else
      where(query, [d], fragment("?->>? ILIKE ?", d.content, ^field, ^like_contains(v)))
    end
  end

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
  # as a Sanity-style `{_ref}` object (references) OR a plain scalar (string
  # arrays). The CASE guards non-array/absent fields so they no-match instead of
  # erroring. Extraction goes through `jsonb_extract_path` over the dot-split
  # segments, so a NESTED array (`meta.tags has tag-x`) works like a top-level one
  # — matching the other ops. Field + value ride as bound params (injection-safe).
  defp apply_field_op(query, field, "has", v) do
    segs = nested_segments(field)

    where(
      query,
      [d],
      fragment(
        "EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(jsonb_extract_path(?, VARIADIC ?)) = 'array' THEN jsonb_extract_path(?, VARIADIC ?) ELSE '[]'::jsonb END) AS e WHERE e->>'_ref' = ? OR e = to_jsonb(?::text))",
        d.content,
        ^segs,
        d.content,
        ^segs,
        ^v,
        ^v
      )
    )
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

  defp apply_field_op(query, _field, _op, _value), do: query

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

  # Build a `%substring%` ILIKE pattern with the user value's LIKE wildcards
  # escaped, so `contains`/search treat `%` and `_` as LITERALS (otherwise
  # `contains('title', '50%')` matches any "50…" and `'a_c'` matches "abc").
  # Backslash is escaped first (PostgreSQL's default ESCAPE char); the result
  # rides as a bound param, so the escapes are interpreted by ILIKE, not the shell.
  defp like_contains(v) do
    escaped =
      v
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%#{escaped}%"
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
    |> order_by(
      [d],
      asc: fragment("CASE WHEN lower(?) = lower(?) THEN 0 ELSE 1 END", d.title, ^target),
      asc: d.doc_id
    )
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Every document of `type` carrying `tag` in its `content["tags"]` array, scoped
  to `dataset` + the caller's tenant — the tag-index read.

  Tag membership is the scalar-membership JSONB containment
  `content->'tags' @> to_jsonb(tag::text)` (the same proven pattern as the alias
  read and the task-label query), so it matches a tag EXACTLY (Obsidian-parity).
  Results are title-ordered (then `doc_id` for a stable tie-break). Scoping is
  identical to `get_document/4` (the P0 leak guard).
  """
  @spec docs_with_tag(String.t(), String.t(), String.t(), keyword()) :: [Document.t()]
  def docs_with_tag(tag, type, dataset, opts \\ []) when is_binary(tag) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Document
    |> where([d], d.type == ^type)
    |> where([d], fragment("?->'tags' @> to_jsonb(?::text)", d.content, ^tag))
    |> scope_to_dataset(dataset, opts)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> order_by([d], asc: d.title, asc: d.doc_id)
    |> Repo.all()
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

  Implemented by unnesting each row's `content["tags"]` JSONB string array with
  `jsonb_array_elements_text`, filtering the unnested value by `ilike("%v%")`,
  and taking it `DISTINCT` — name-ordered, capped at `limit_n` (default 20) so
  an unbounded tag vocabulary can never flood a typeahead. Scoping is the same
  `get_document/4` P0 leak guard (dataset + tenant). A blank `query` yields the
  top distinct tags (no `ilike` filter); a no-match yields `[]`.
  """
  @spec search_tags_for_type(String.t(), String.t(), String.t(), keyword(), pos_integer()) ::
          [String.t()]
  def search_tags_for_type(query, type, dataset, opts \\ [], limit_n \\ 20)
      when is_binary(query) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    trimmed = String.trim(query)

    # The set-returning `jsonb_array_elements_text` is illegal in WHERE, so the
    # unnest happens in an inner subquery (scoped) and the ILIKE filter is applied
    # in the OUTER query against the materialised `tag` column.
    unnested =
      Document
      |> where([d], d.type == ^type)
      |> scope_to_dataset(dataset, opts)
      |> scope_to_workspace_or_global(workspace_id, project_id)
      |> select([d], %{tag: fragment("jsonb_array_elements_text(?->'tags')", d.content)})

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
    |> Repo.all()
    |> Map.new(fn d -> {d.doc_id, d} end)
  end

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
