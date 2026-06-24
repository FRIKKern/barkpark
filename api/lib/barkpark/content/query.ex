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
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    base =
      Document
      |> where([d], d.type == ^type)
      |> scope_to_dataset(dataset, opts)
      |> scope_to_workspace_or_global(workspace_id, project_id)
      |> apply_filter_map(filter_map)

    case perspective do
      :drafts -> list_with_drafts_merged(base, order, limit, offset)
      other -> list_linear(base, other, order, limit, offset)
    end
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

  defp apply_field_op(query, "title", "contains", v),
    do: where(query, [d], ilike(d.title, ^"%#{v}%"))

  defp apply_field_op(query, "title", "gt", v), do: where(query, [d], d.title > ^v)
  defp apply_field_op(query, "title", "gte", v), do: where(query, [d], d.title >= ^v)
  defp apply_field_op(query, "title", "lt", v), do: where(query, [d], d.title < ^v)
  defp apply_field_op(query, "title", "lte", v), do: where(query, [d], d.title <= ^v)

  defp apply_field_op(query, "status", "eq", v), do: where(query, [d], d.status == ^v)

  defp apply_field_op(query, "status", "in", vs) when is_list(vs),
    do: where(query, [d], d.status in ^vs)

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

  defp apply_field_op(query, field, "contains", v),
    do: where(query, [d], fragment("?->>? ILIKE ?", d.content, ^field, ^"%#{v}%"))

  defp apply_field_op(query, field, "gt", v),
    do: where(query, [d], fragment("?->>? > ?", d.content, ^field, ^v))

  defp apply_field_op(query, field, "gte", v),
    do: where(query, [d], fragment("?->>? >= ?", d.content, ^field, ^v))

  defp apply_field_op(query, field, "lt", v),
    do: where(query, [d], fragment("?->>? < ?", d.content, ^field, ^v))

  defp apply_field_op(query, field, "lte", v),
    do: where(query, [d], fragment("?->>? <= ?", d.content, ^field, ^v))

  defp apply_field_op(query, _field, _op, _value), do: query

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
