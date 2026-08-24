defmodule Barkpark.Media.Delivery.Search do
  @moduledoc """
  Faceted search over `media_files` joined with linked `mediaAsset` documents.

  WoodWing-style query options:
    * `:q` — text search (filename, original name, asset title, tags)
    * `:kind`, `:mime_type`, `:status`, `:processing`, `:collection`, `:tags`
    * `:facet_selections` — map of active facet filters
    * `:facets` — list of facet fields to aggregate
    * `:sort` — `relevance`, `created-desc`, `created-asc`, `updated-desc`
    * `:limit`, `:offset`
  """

  import Ecto.Query
  import Barkpark.Content.Scope, only: [scope_to_workspace_or_global: 3]
  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Media.Delivery.Retriever, as: MediaRetriever
  alias Barkpark.Search.{QueryParser, QueryPipeline, SurfaceConfigs}

  @asset_type "mediaAsset"
  @facet_fields ~w(kind tags mimeType status processing collection visibility)

  @doc """
  Search media assets. Returns `{files, total, facets, meta}`.
  """
  @spec search(String.t(), keyword()) :: {[MediaFile.t()], non_neg_integer(), map(), map()}
  def search(dataset, opts \\ []) when is_binary(dataset) do
    # Thread the resolved workspace_id (rides in opts via scope_opts(conn) on the
    # scoped media search route) into the surface-config read so per-workspace
    # media tuning (typo_policy.similarity_threshold et al.) actually reaches
    # media RESULTS — not just the settings echo (charter D59/D63). A nil
    # workspace_id (flat/anonymous path) reads the documented global-legacy
    # default row, matching the SurfaceConfigs.get/3 contract.
    config = SurfaceConfigs.get("media", dataset, Keyword.get(opts, :workspace_id))

    # Resolve the dataset STRING → dataset_id ONCE per request and thread it
    # through opts. The dataset_id is INVARIANT within a search — without this,
    # every build_query call (count + page + each facet field) re-runs
    # resolve_dataset_id, hitting Tenancy.get_dataset + get_default_project
    # (~9 re-resolutions per search: 7 facets + count + page). build_query reads
    # opts[:dataset_id] when present and skips the roundtrips. Byte-identical to
    # the per-call path (same get_dataset → Dataset.id, same NULL-tolerant nil).
    opts = Keyword.put(opts, :dataset_id, resolve_dataset_id(dataset, opts))

    q = Keyword.get(opts, :q)

    parsed =
      case q do
        v when is_binary(v) and v != "" -> QueryParser.parse(v)
        _ -> QueryParser.parse("")
      end

    search_fn = fn p, relaxed ->
      inner_opts =
        opts
        |> Keyword.put(:parsed, p)
        |> Keyword.put(:pipeline_config, config)
        |> Keyword.put(:relaxed, relaxed)

      query = build_query(dataset, inner_opts)

      total =
        query
        |> exclude(:order_by)
        |> exclude(:limit)
        |> exclude(:offset)
        |> select([m, _d], count(m.id, :distinct))
        |> Repo.one()

      page_ids = paginate_ids(query, inner_opts)

      files =
        if page_ids == [] do
          []
        else
          files_by_id =
            MediaFile
            |> where([m], m.id in ^page_ids)
            |> Repo.all()
            |> Map.new(&{&1.id, &1})

          Enum.map(page_ids, &Map.fetch!(files_by_id, &1))
        end

      {files, total || 0}
    end

    {files, total, recovery} = QueryPipeline.media_recovery(parsed, config, search_fn)

    facets =
      case Keyword.get(opts, :facets, []) do
        [] -> %{}
        fields -> compute_facets(dataset, opts, fields)
      end

    docs = Barkpark.Media.asset_docs_for_files(files, dataset)

    highlights =
      Barkpark.Search.Highlighter.highlight_media(files, parsed, config, docs)

    meta = %{
      parsed: QueryParser.to_map(parsed),
      highlights: highlights,
      recovery: recovery
    }

    {files, total, facets, meta}
  end

  @spec search_legacy(String.t(), keyword()) :: {[MediaFile.t()], non_neg_integer(), map()}
  def search_legacy(dataset, opts \\ []) when is_binary(dataset) do
    {files, total, facets, _meta} = search(dataset, opts)
    {files, total, facets}
  end

  @doc "Build the shared search query (used by list + search)."
  @spec build_query(String.t(), keyword()) :: Ecto.Query.t()
  def build_query(dataset, opts) when is_binary(dataset) do
    selections = Keyword.get(opts, :facet_selections, %{})
    opts = Keyword.put_new(opts, :dataset, dataset)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    # W2 read-scope: resolve the dataset STRING → dataset_id within the read's
    # project (opts :project_id, else Default) and filter the blob table by
    # `m.dataset_id` authoritatively. Falls back to the legacy `m.dataset`
    # STRING filter when no dataset row resolves (back-compat). The left-join to
    # the linked asset Document keeps the `d.dataset` STRING mirror filter — the
    # mirror stays consistent with dataset_id on every write.
    #
    # Resolve-once: search/2 pre-resolves the (invariant) dataset_id and threads
    # it via opts[:dataset_id], so we skip the Tenancy.get_dataset +
    # get_default_project roundtrips on every build_query (facets + count + page).
    # has_key? distinguishes "threaded" (use as-is, including a resolved nil) from
    # "not threaded" (direct build_query/list callers → resolve here as before).
    dataset_id =
      if Keyword.has_key?(opts, :dataset_id) do
        Keyword.get(opts, :dataset_id)
      else
        resolve_dataset_id(dataset, opts)
      end

    MediaFile
    |> from(as: :media)
    |> join(:left, [m], d in ^asset_doc_join_query(dataset, dataset_id, workspace_id, project_id),
      as: :asset,
      on: fragment("(?->>?)::uuid = ?", d.content, "mediaFileId", m.id)
    )
    |> scope_media_to_dataset(dataset, dataset_id)
    |> scope_to_workspace_or_global(workspace_id, project_id)
    |> maybe_filter_mime(Keyword.get(opts, :mime_type))
    |> maybe_filter_mime(selections["mimeType"])
    |> maybe_filter_text(dataset, opts)
    |> maybe_filter_kind(Keyword.get(opts, :kind))
    |> maybe_filter_kind(selections["kind"])
    |> maybe_filter_status(Keyword.get(opts, :status))
    |> maybe_filter_status(selections["status"])
    |> maybe_filter_processing(Keyword.get(opts, :processing))
    |> maybe_filter_processing(selections["processing"])
    |> maybe_filter_collection(Keyword.get(opts, :collection))
    |> maybe_filter_collection(selections["collection"])
    |> maybe_filter_tags(Keyword.get(opts, :tags))
    |> maybe_filter_tags(selections["tags"])
    |> maybe_filter_visibility(Keyword.get(opts, :visibility))
    |> maybe_filter_visibility(selections["visibility"])
    |> maybe_clamp_visibility(Keyword.get(opts, :visibility_clamp))
  end

  # Pre-scoped Document subquery the search LEFT-JOINs against. Without scope on
  # the joined doc, a blob in workspace B (correctly scoped on the `media` side)
  # would join to workspace A's asset Document sharing the dataset STRING +
  # mediaFileId — feeding A's title/tags into B's text matching + facets
  # (the cross-workspace metadata leak, barkpark-vmv1). Scoping the joined doc
  # by type + dataset + a NULL-tolerant workspace envelope closes that.
  #
  #   * type: only mediaAsset docs.
  #   * dataset: dataset_id authoritative when resolved, NULL-tolerant string
  #     fallback for legacy/unstamped docs (mirror of scope_asset_dataset);
  #     bare string filter when no dataset_id resolves.
  #   * workspace: NULL-tolerant — newly-scoped docs are isolated to their
  #     workspace WHILE legacy NULL-workspace docs stay joinable in their own
  #     tenant (never-worse). A nil workspace_id (unscoped path) leaves the
  #     workspace filter off entirely (deliberate global read).
  defp asset_doc_join_query(dataset, dataset_id, workspace_id, project_id) do
    Document
    |> where([d], d.type == ^@asset_type)
    |> join_scope_dataset(dataset, dataset_id)
    |> join_scope_workspace(workspace_id, project_id)
  end

  defp join_scope_dataset(query, dataset, dataset_id) when is_binary(dataset_id) do
    where(
      query,
      [d],
      d.dataset_id == ^dataset_id or (is_nil(d.dataset_id) and d.dataset == ^dataset)
    )
  end

  defp join_scope_dataset(query, dataset, _dataset_id) do
    where(query, [d], d.dataset == ^dataset)
  end

  defp join_scope_workspace(query, nil, _project_id), do: query

  # `:shared_only` — the request-side empty-scope sentinel
  # (task-3e2a70930c6df723). A REQUEST that resolved no workspace sees the
  # SHARED layer, never every tenant. Placed above the is_binary/1 clauses,
  # which an atom matches none of: untranslated it is a FunctionClauseError (a
  # 500), which is exactly how this consumer announced itself.
  defp join_scope_workspace(query, :shared_only, _project_id),
    do: where(query, [d], is_nil(d.workspace_id))

  defp join_scope_workspace(query, workspace_id, nil) when is_binary(workspace_id) do
    where(query, [d], d.workspace_id == ^workspace_id or is_nil(d.workspace_id))
  end

  defp join_scope_workspace(query, workspace_id, project_id)
       when is_binary(workspace_id) and is_binary(project_id) do
    where(
      query,
      [d],
      is_nil(d.workspace_id) or
        (d.workspace_id == ^workspace_id and
           (is_nil(d.project_id) or d.project_id == ^project_id))
    )
  end

  # W2 read-scope. Resolve the dataset STRING → dataset_id within the read's
  # project scope (opts :project_id, else the seeded Default project). Read-only
  # — never creates a dataset on a search path. Returns nil when unresolvable,
  # so the caller keeps the legacy `m.dataset` STRING filter.
  defp resolve_dataset_id(dataset, opts) when is_binary(dataset) do
    project_id = Keyword.get(opts, :project_id) || default_project_id()

    case project_id && Barkpark.Tenancy.get_dataset(project_id, dataset) do
      %Barkpark.Tenancy.Dataset{id: id} -> id
      _ -> nil
    end
  end

  defp resolve_dataset_id(_dataset, _opts), do: nil

  defp default_project_id do
    case Barkpark.Tenancy.get_default_project() do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp scope_media_to_dataset(query, _dataset, dataset_id) when is_binary(dataset_id) do
    where(query, [m], m.dataset_id == ^dataset_id)
  end

  defp scope_media_to_dataset(query, dataset, _dataset_id) do
    where(query, [m], m.dataset == ^dataset)
  end

  defp paginate_ids(query, opts) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    cursor = Keyword.get(opts, :cursor)

    fetch = limit + offset + 20

    ordered =
      query
      |> apply_sort(opts)
      |> limit(^fetch)
      |> select([m, _d], {m.id, m.inserted_at})

    rows =
      if cursor do
        decode_cursor(cursor)
        |> case do
          {:ok, cursor_id, cursor_at} ->
            ordered
            |> where(
              [m, _d],
              m.inserted_at < ^cursor_at or (m.inserted_at == ^cursor_at and m.id < ^cursor_id)
            )
            |> Repo.all()

          _ ->
            Repo.all(ordered)
        end
      else
        Repo.all(ordered)
      end

    rows
    |> Enum.uniq_by(fn {id, _} -> id end)
    |> Enum.map(fn {id, _} -> id end)
    |> Enum.drop(offset)
    |> Enum.take(limit)
  end

  @doc false
  def encode_cursor(%MediaFile{} = file) do
    payload = Jason.encode!(%{id: file.id, at: DateTime.to_iso8601(file.inserted_at)})
    Base.url_encode64(payload, padding: false)
  end

  @doc false
  def next_cursor(files) do
    case List.last(files) do
      nil -> nil
      file -> encode_cursor(file)
    end
  end

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, bin} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"id" => id, "at" => at}} <- Jason.decode(bin),
         uuid when is_binary(uuid) <- Repo.uuid_or_nil(id),
         {:ok, dt, _} <- DateTime.from_iso8601(at) do
      {:ok, uuid, dt}
    else
      _ -> :error
    end
  end

  defp compute_facets(dataset, opts, fields) do
    Map.new(fields, fn field ->
      facet_opts = drop_facet_selection(opts, field)
      {field, aggregate_facet(dataset, facet_opts, field)}
    end)
  end

  # Field → top-level opt key. A facet must be computed with ITS OWN filter
  # removed so the drill-down shows every option, not just the selected value.
  # The selected value can arrive two ways: as `facet_selections[field]` OR as a
  # top-level opt (`?kind=image` → opts[:kind]). build_query applies BOTH
  # (`maybe_filter_kind(opts[:kind])` AND `maybe_filter_kind(selections["kind"])`),
  # so dropping only the selection collapses the facet whenever the filter came
  # in top-level. Drop both for the facet's own field; every OTHER field's
  # filter still applies (correct multi-facet drill-down).
  @facet_opt_keys %{
    "kind" => :kind,
    "mimeType" => :mime_type,
    "status" => :status,
    "processing" => :processing,
    "visibility" => :visibility,
    "collection" => :collection,
    "tags" => :tags
  }

  defp drop_facet_selection(opts, field) do
    selections =
      opts
      |> Keyword.get(:facet_selections, %{})
      |> Map.delete(field)

    opts
    |> Keyword.put(:facet_selections, selections)
    |> drop_top_level_opt(field)
  end

  defp drop_top_level_opt(opts, field) do
    case Map.fetch(@facet_opt_keys, field) do
      {:ok, key} -> Keyword.delete(opts, key)
      :error -> opts
    end
  end

  defp aggregate_facet(dataset, opts, "kind") do
    facet_group_query(dataset, opts, "bp_asset_kind")
  end

  defp aggregate_facet(dataset, opts, "processing") do
    facet_group_query(dataset, opts, "bp_processing_status")
  end

  defp aggregate_facet(dataset, opts, "collection") do
    facet_group_query(dataset, opts, "collection")
  end

  defp aggregate_facet(dataset, opts, "visibility") do
    facet_group_query(dataset, opts, "bp_visibility")
  end

  defp aggregate_facet(dataset, opts, "status") do
    query =
      build_query(dataset, opts)
      |> exclude(:order_by)
      |> exclude(:limit)
      |> exclude(:offset)
      |> group_by([_m, d], d.status)
      |> select([m, d], {d.status, count(m.id, :distinct)})

    query
    |> Repo.all()
    |> facet_values()
  end

  defp aggregate_facet(dataset, opts, "mimeType") do
    query =
      build_query(dataset, opts)
      |> exclude(:order_by)
      |> exclude(:limit)
      |> exclude(:offset)
      |> group_by([m, _d], m.mime_type)
      |> select([m, _d], {m.mime_type, count(m.id, :distinct)})

    query
    |> Repo.all()
    |> facet_values()
  end

  defp aggregate_facet(dataset, opts, "tags") do
    {sql, params} = tags_facet_sql(dataset, opts)

    sql
    |> run_tags_facet_sql(params)
    |> case do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.map(fn [value, count] -> %{value: value, count: count} end)
        |> Enum.reject(&is_nil(&1.value))
        |> Enum.sort_by(& &1.count, :desc)

      _ ->
        []
    end
  end

  defp aggregate_facet(_dataset, _opts, _unknown), do: []

  # The ONLY raw-SQL call in this module, deliberately extracted into a
  # SINGLE-CLAUSE function so this waiver has exactly one def to bind to.
  #
  # It was a line-anchored `.sobelow-skips` entry (`search.ex:406 SQL.Query`)
  # until an unrelated +8 above it slid the anchor. Re-anchoring the line was not
  # enough: `--skip` matches on the FINGERPRINT, which is position-coupled and
  # can only be recomputed by `sobelow-baseline-reconcile.sh` on the pinned CI
  # toolchain. An inline annotation has no fingerprint to go stale — which is why
  # the repo is migrating this direction (baseline 135 -> 51, inline 57 -> 123).
  #
  # EXTRACTED RATHER THAN ANNOTATED IN PLACE. `aggregate_facet/3` has three
  # clauses; Sobelow binds an annotation to ONE def, so annotating the "tags"
  # clause would leave its siblings unwaived, and annotating all three would add
  # waivers where no finding exists — silencing rather than accepting. One
  # single-clause function makes the waiver's scope exactly the raw-SQL call.
  #
  # The finding is ACCEPTED, not silenced: `tags_facet_sql/2` builds the query
  # text, and every caller-derived value it needs is a BOUND PARAMETER passed
  # separately as `params` — the dataset and opts never enter the SQL string.
  # sobelow_skip ["SQL.Query"]
  defp run_tags_facet_sql(sql, params), do: Repo.query(sql, params)

  defp facet_group_query(dataset, opts, "bp_asset_kind") do
    build_query(dataset, opts)
    |> exclude(:order_by)
    |> exclude(:limit)
    |> exclude(:offset)
    |> group_by([_m, d], fragment("?->>'bp_asset_kind'", d.content))
    |> select([m, d], {fragment("?->>'bp_asset_kind'", d.content), count(m.id, :distinct)})
    |> Repo.all()
    |> facet_values()
  end

  defp facet_group_query(dataset, opts, "bp_processing_status") do
    build_query(dataset, opts)
    |> exclude(:order_by)
    |> exclude(:limit)
    |> exclude(:offset)
    |> group_by([_m, d], fragment("?->>'bp_processing_status'", d.content))
    |> select([m, d], {fragment("?->>'bp_processing_status'", d.content), count(m.id, :distinct)})
    |> Repo.all()
    |> facet_values()
  end

  defp facet_group_query(dataset, opts, "collection") do
    build_query(dataset, opts)
    |> exclude(:order_by)
    |> exclude(:limit)
    |> exclude(:offset)
    |> group_by([_m, d], fragment("?->>'collection'", d.content))
    |> select([m, d], {fragment("?->>'collection'", d.content), count(m.id, :distinct)})
    |> Repo.all()
    |> facet_values()
  end

  defp facet_group_query(dataset, opts, "bp_visibility") do
    build_query(dataset, opts)
    |> exclude(:order_by)
    |> exclude(:limit)
    |> exclude(:offset)
    |> group_by([_m, d], fragment("?->>'bp_visibility'", d.content))
    |> select([m, d], {fragment("?->>'bp_visibility'", d.content), count(m.id, :distinct)})
    |> Repo.all()
    |> facet_values()
  end

  defp facet_values(rows) do
    rows
    |> Enum.map(fn {value, count} -> %{value: value, count: count} end)
    |> Enum.reject(fn %{value: v} -> v in [nil, ""] end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  defp tags_facet_sql(dataset, opts) do
    # BUG 2 fix: the raw-SQL tag-facet aggregation previously filtered on
    # `m.dataset = $2` ONLY — no tenant scope — so it leaked tag counts across
    # every workspace sharing the `dataset` STRING. Mirror the Ecto
    # `scope_to_workspace_or_global/3` envelope here — that is the helper the
    # Ecto results path calls (`build_query/2`), and the one whose nil arm is an
    # EXPLICIT global read. Bind workspace_id (and project_id when present) as
    # parameters $3.. ahead of the dynamic filters. Same nil-means-unscoped
    # back-compat as Content.Scope's `_or_global`. Do NOT read this as the
    # fail-closed `scope_to_workspace/3`: that one turns a nil workspace into
    # `where: false`, which is the opposite of what these fragments emit.
    #
    # The tags themselves come from the JOINED `documents d`, so `m`-scope alone
    # is not enough: a workspace-B document that references THIS workspace's
    # media file id (shared `mediaFileId` + `dataset`) would still feed B's tags
    # into A's facet. Scope the joined doc too (`doc_scope_sql`), mirroring the
    # null-tolerant Ecto `join_scope_workspace/3` on the primary `build_query`
    # path — otherwise the two implementations drift and the doc-join leaks.
    {m_scope_sql, doc_scope_sql, scope_params, next_idx} = scope_fragments(opts, 3)
    {where_sql, params} = where_fragments(opts, next_idx, skip_tags: true)

    sql = """
    SELECT tag, COUNT(DISTINCT m.id)
    FROM media_files m
    LEFT JOIN documents d
      ON d.type = $1
      AND d.dataset = $2
      AND (d.content->>'mediaFileId')::uuid = m.id
      #{doc_scope_sql}
    CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(d.content->'tags', '[]'::jsonb)) AS tag
    WHERE m.dataset = $2
    #{m_scope_sql}
    #{where_sql}
    GROUP BY tag
    ORDER BY COUNT(DISTINCT m.id) DESC
    LIMIT 80
    """

    {@asset_type, dataset}
    |> Tuple.to_list()
    |> Kernel.++(scope_params)
    |> Kernel.++(params)
    |> then(&{sql, &1})
  end

  # Build the workspace/project scope clauses for the raw-SQL facet path,
  # consuming parameter slots starting at `start_idx`. Returns
  # `{m_scope_sql, doc_scope_sql, params, next_idx}` — `m_scope_sql` filters the
  # primary `media_files m` (strict, like the Ecto results path) and
  # `doc_scope_sql` scopes the JOINED `documents d` (null-tolerant, mirroring
  # `join_scope_workspace/3`). Both clauses reuse the same bound params, so a
  # nil workspace_id is the unscoped back-compat path (no clauses emitted),
  # matching Barkpark.Content.Scope.scope_to_workspace_or_global/3 — NOT the
  # fail-closed `scope_to_workspace/3`, whose nil arm is `where: false`. The
  # name matters here precisely because a reader auditing this raw SQL for
  # fail-closedness would otherwise be told it has a property it does not.
  defp scope_fragments(opts, start_idx) do
    # `m.workspace_id` / `m.project_id` are :binary_id (uuid) columns. Raw
    # Postgrex needs the 16-byte binary, not the UUID string — the Ecto path
    # casts via the schema type, but `Repo.query/2` does not. Dump here; an
    # unparseable id falls back to the unscoped branch (caught by uuid_param).
    workspace_id = uuid_param(first_present([opts[:workspace_id]]))
    project_id = uuid_param(first_present([opts[:project_id]]))

    cond do
      is_nil(workspace_id) ->
        {"", "", [], start_idx}

      is_nil(project_id) ->
        {"AND m.workspace_id = $#{start_idx}",
         "AND (d.workspace_id = $#{start_idx} OR d.workspace_id IS NULL)", [workspace_id],
         start_idx + 1}

      true ->
        {"AND m.workspace_id = $#{start_idx} AND m.project_id = $#{start_idx + 1}",
         "AND (d.workspace_id IS NULL OR (d.workspace_id = $#{start_idx} AND " <>
           "(d.project_id IS NULL OR d.project_id = $#{start_idx + 1})))",
         [workspace_id, project_id], start_idx + 2}
    end
  end

  # Dump a UUID string to the raw 16-byte binary Postgrex expects for a
  # :binary_id column. Returns nil for a nil/invalid id (unscoped fallback).
  defp uuid_param(nil), do: nil

  defp uuid_param(id) when is_binary(id) do
    case Ecto.UUID.dump(id) do
      {:ok, bin} -> bin
      :error -> nil
    end
  end

  defp where_fragments(opts, param_idx, extra) do
    parts = []
    params = []

    {parts, params, _param_idx} =
      Enum.reduce(flat_filters(opts, extra), {parts, params, param_idx}, fn
        {:mime, value}, {parts, params, idx} ->
          {parts ++ ["AND m.mime_type LIKE $#{idx}"], params ++ ["#{value}%"], idx + 1}

        {:kind, value}, {parts, params, idx} ->
          {parts ++ ["AND d.content->>'bp_asset_kind' = $#{idx}"], params ++ [value], idx + 1}

        {:status, value}, {parts, params, idx} ->
          {parts ++ ["AND d.status = $#{idx}"], params ++ [value], idx + 1}

        {:processing, value}, {parts, params, idx} ->
          {parts ++ ["AND d.content->>'bp_processing_status' = $#{idx}"], params ++ [value],
           idx + 1}

        {:visibility, value}, {parts, params, idx} ->
          {parts ++ ["AND d.content->>'bp_visibility' = $#{idx}"], params ++ [value], idx + 1}

        {:collection, value}, {parts, params, idx} ->
          {parts ++ ["AND d.content->>'collection' = $#{idx}"], params ++ [value], idx + 1}

        {:q, value}, {parts, params, idx} ->
          pattern = "%#{escape_like(value)}%"

          {parts ++
             [
               "AND (m.original_name ILIKE $#{idx} OR m.filename ILIKE $#{idx} OR d.title ILIKE $#{idx} OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(d.content->'tags', '[]'::jsonb)) elem WHERE elem ILIKE $#{idx}))"
             ], params ++ [pattern], idx + 1}

        {:tags, value}, {parts, params, idx} ->
          tags = String.split(value, ",", trim: true)

          {parts ++
             [
               "AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(d.content->'tags', '[]'::jsonb)) elem WHERE elem = ANY($#{idx}::text[]))"
             ], params ++ [tags], idx + 1}
      end)

    {Enum.join(parts, " "), params}
  end

  defp flat_filters(opts, extra) do
    skip_tags? = Keyword.get(extra, :skip_tags, false)
    selections = Keyword.get(opts, :facet_selections, %{})

    []
    |> maybe_add(:mime, first_present([opts[:mime_type], selections["mimeType"]]))
    |> maybe_add(:kind, first_present([opts[:kind], selections["kind"]]))
    |> maybe_add(:status, first_present([opts[:status], selections["status"]]))
    |> maybe_add(:processing, first_present([opts[:processing], selections["processing"]]))
    |> maybe_add(:visibility, first_present([opts[:visibility], selections["visibility"]]))
    |> maybe_add(:collection, first_present([opts[:collection], selections["collection"]]))
    |> maybe_add(:q, opts[:q])
    |> maybe_add(
      :tags,
      if(skip_tags?, do: nil, else: first_present([opts[:tags], selections["tags"]]))
    )
  end

  defp maybe_add(list, _key, nil), do: list
  defp maybe_add(list, _key, ""), do: list
  defp maybe_add(list, key, value), do: list ++ [{key, value}]

  defp first_present(values) do
    Enum.find(values, fn v -> v not in [nil, ""] end)
  end

  defp apply_sort(query, opts) do
    case Keyword.get(opts, :sort, "created-desc") do
      "relevance" ->
        # The relevance sort now folds the admin-configured `searchable_fields`
        # per-field weights into the ordering (charter W7 /
        # bpb-searchable-fields-dead-config) — previously a hardcoded boolean
        # CASE (matched=1/0) that ignored the knob echoed in admin settings.
        # Each field contributes weight·similarity(field, query); the
        # max-weight-normalized sum reorders results when a weight changes.
        case relevance_query_text(opts) do
          "" ->
            # Zero-term relevance path (prefix-only / empty). `List.first/1`
            # returns nil on [], so we degrade to recency instead of 500ing on
            # `hd([])` (BUG 1, barkpark-4r7q).
            order_by(query, [m], desc: m.inserted_at)

          q_text ->
            relevance_order(query, q_text, Keyword.get(opts, :pipeline_config))
        end

      "created-asc" ->
        order_by(query, [m], asc: m.inserted_at)

      "updated-desc" ->
        order_by(query, [m, d], desc: d.updated_at, desc: m.inserted_at)

      _ ->
        order_by(query, [m], desc: m.inserted_at)
    end
  end

  # Primary query text for the relevance similarity signal — the first term/phrase
  # of a parsed query, else the raw `:q`. "" means no usable text (prefix-only or
  # empty), which the caller degrades to recency.
  defp relevance_query_text(opts) do
    case Keyword.get(opts, :parsed) || Keyword.get(opts, :q) do
      %{} = parsed when map_size(parsed) > 0 ->
        terms = Map.get(parsed, :terms, []) ++ Map.get(parsed, :phrases, [])
        List.first(terms) || Map.get(parsed, :raw, "") || ""

      q when is_binary(q) ->
        q

      _ ->
        ""
    end
  end

  # Weighted per-field relevance ORDER BY:
  #   Σ(weight_i · similarity(field_i, query)) / max(weight_i), desc
  # then inserted_at desc. Max-weight normalization keeps the highest-weighted
  # field on the raw similarity scale. Unknown/unsupported paths are skipped;
  # if none resolve, fall back to recency.
  defp relevance_order(query, q_text, config) do
    weighted_terms =
      config
      |> media_searchable_fields()
      |> Enum.map(fn %{path: path, weight: weight} ->
        {media_field_term(path, weight, q_text), weight}
      end)
      |> Enum.reject(fn {term, _weight} -> is_nil(term) end)

    case weighted_terms do
      [] ->
        order_by(query, [m], desc: m.inserted_at)

      terms ->
        max_weight = terms |> Enum.map(fn {_term, weight} -> weight end) |> Enum.max()

        sum =
          Enum.reduce(terms, nil, fn {term, _weight}, acc ->
            if acc, do: dynamic([m, d], fragment("? + ?", ^acc, ^term)), else: term
          end)

        relevance = dynamic([_m, _d], fragment("(?) / ?", ^sum, ^max_weight))

        order_by(query, ^[{:desc, relevance}, {:desc, dynamic([m, _d], m.inserted_at)}])
    end
  end

  # Per-field weighted trigram-similarity term over the media join bindings
  # [m (media_files), d (linked mediaAsset document)]. Returns nil for a path
  # this surface does not expose (skipped from the weighted sum).
  defp media_field_term("title", weight, q_text) do
    dynamic(
      [_m, d],
      fragment("? * similarity(coalesce(?, ''), ?)", ^(weight * 1.0), d.title, ^q_text)
    )
  end

  defp media_field_term("original_name", weight, q_text) do
    dynamic(
      [m, _d],
      fragment("? * similarity(coalesce(?, ''), ?)", ^(weight * 1.0), m.original_name, ^q_text)
    )
  end

  defp media_field_term("filename", weight, q_text) do
    dynamic(
      [m, _d],
      fragment("? * similarity(coalesce(?, ''), ?)", ^(weight * 1.0), m.filename, ^q_text)
    )
  end

  defp media_field_term("tags", weight, q_text) do
    dynamic(
      [_m, d],
      fragment(
        "? * COALESCE((SELECT max(similarity(elem, ?)) FROM jsonb_array_elements_text(COALESCE(?->'tags', '[]'::jsonb)) elem), 0)",
        ^(weight * 1.0),
        ^q_text,
        d.content
      )
    )
  end

  defp media_field_term(_unknown, _weight, _q_text), do: nil

  # Normalize the media `searchable_fields` config → [%{path, weight}]. Falls
  # back to the media default field set when nothing usable is configured.
  defp media_searchable_fields(config) do
    (config || %{})
    |> Map.get("searchable_fields", [])
    |> List.wrap()
    |> Enum.map(&normalize_media_field/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        SurfaceConfigs.default_for("media")
        |> Map.get("searchable_fields", [])
        |> Enum.map(&normalize_media_field/1)
        |> Enum.reject(&is_nil/1)

      fields ->
        fields
    end
  end

  defp normalize_media_field(%{"path" => path} = field)
       when is_binary(path) and path != "" do
    case media_field_weight(Map.get(field, "weight")) do
      weight when weight > 0 -> %{path: path, weight: weight}
      _ -> nil
    end
  end

  defp normalize_media_field(_), do: nil

  defp media_field_weight(weight) when is_number(weight), do: weight * 1.0

  defp media_field_weight(weight) when is_binary(weight) do
    case Float.parse(weight) do
      {parsed, _} -> parsed
      :error -> 0.0
    end
  end

  defp media_field_weight(nil), do: 1.0
  defp media_field_weight(_), do: 0.0

  defp maybe_filter_text(query, dataset, opts) do
    parsed = Keyword.get(opts, :parsed)
    # Default-arg trap: compute_facets re-fetches the config per facet field
    # because the facet opts never carry :pipeline_config (only search/2's inner
    # pass threads it). Thread workspace_id here too (charter D63) — else the
    # facet path stays workspace-blind while the primary results path (line 30)
    # is per-workspace, and the two diverge on a shared dataset slug.
    config =
      Keyword.get(
        opts,
        :pipeline_config,
        SurfaceConfigs.get("media", dataset, Keyword.get(opts, :workspace_id))
      )

    relaxed = Keyword.get(opts, :relaxed, false)

    # Thread the tenancy scope into the text-match retriever. Its inner
    # `m.id IN (SELECT …)` subquery builds its OWN LEFT JOIN to the asset
    # Document for `ilike(d.title, …)` / tag matching; without scope that join
    # matches another workspace's asset doc by bare dataset STRING + mediaFileId
    # — the search arm of the cross-workspace metadata leak (barkpark-vmv1).
    retriever_opts = [
      relaxed: relaxed,
      workspace_id: Keyword.get(opts, :workspace_id),
      project_id: Keyword.get(opts, :project_id)
    ]

    cond do
      is_map(parsed) and map_size(parsed) > 0 ->
        MediaRetriever.apply_to_query(query, dataset, parsed, config, retriever_opts)

      true ->
        q = Keyword.get(opts, :q)

        if q in [nil, ""] do
          query
        else
          parsed = QueryParser.parse(q)
          MediaRetriever.apply_to_query(query, dataset, parsed, config, retriever_opts)
        end
    end
  end

  defp maybe_filter_kind(query, nil), do: query
  defp maybe_filter_kind(query, ""), do: query

  defp maybe_filter_kind(query, kind) when is_binary(kind) do
    where(query, [_m, d], fragment("?->>? = ?", d.content, "bp_asset_kind", ^kind))
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, ""), do: query

  defp maybe_filter_status(query, status) when is_binary(status) do
    where(query, [_m, d], d.status == ^status)
  end

  defp maybe_filter_processing(query, nil), do: query
  defp maybe_filter_processing(query, ""), do: query

  defp maybe_filter_processing(query, status) when is_binary(status) do
    where(query, [_m, d], fragment("?->>? = ?", d.content, "bp_processing_status", ^status))
  end

  defp maybe_filter_collection(query, nil), do: query
  defp maybe_filter_collection(query, ""), do: query

  defp maybe_filter_collection(query, collection) when is_binary(collection) do
    encoded = Jason.encode!([collection])

    where(
      query,
      [_m, d],
      fragment("?->>? = ?", d.content, "collection", ^collection) or
        fragment("COALESCE(?->'collections', '[]'::jsonb) @> ?::jsonb", d.content, ^encoded)
    )
  end

  defp maybe_filter_tags(query, nil), do: query
  defp maybe_filter_tags(query, ""), do: query

  defp maybe_filter_tags(query, tags) when is_binary(tags) do
    tag_list = String.split(tags, ",", trim: true)

    where(
      query,
      [_m, d],
      fragment(
        "EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(?->'tags', '[]'::jsonb)) elem WHERE elem = ANY(?))",
        d.content,
        ^tag_list
      )
    )
  end

  defp maybe_filter_visibility(query, nil), do: query
  defp maybe_filter_visibility(query, ""), do: query

  defp maybe_filter_visibility(query, visibility) when is_binary(visibility) do
    where(query, [_m, d], fragment("?->>? = ?", d.content, "bp_visibility", ^visibility))
  end

  # Query-level ceiling for an UNAUTHENTICATED caller — the counterpart to
  # `maybe_filter_visibility/2` above, which filters to a CALLER-CHOSEN
  # visibility value and is no defense (an anonymous caller simply omits it).
  # `:visibility_clamp, :public` restricts every row (both the count query and
  # the page query, since both run through `build_query/2`) to assets whose
  # linked `mediaAsset` doc is absent (no doc → `Access.visibility(nil) ==
  # "public"`) or carries no/`"public"` `bp_visibility`. `nil` — the default —
  # is a no-op, so every existing caller that never threads `:visibility_clamp`
  # is byte-identical (task-0fcec595765a7b00).
  defp maybe_clamp_visibility(query, nil), do: query

  defp maybe_clamp_visibility(query, :public) do
    where(
      query,
      [_m, d],
      is_nil(d.content) or
        fragment("COALESCE(?->>?, 'public') = 'public'", d.content, "bp_visibility")
    )
  end

  defp maybe_filter_mime(query, nil), do: query
  defp maybe_filter_mime(query, ""), do: query

  defp maybe_filter_mime(query, mime_prefix) when is_binary(mime_prefix) do
    pattern = mime_pattern(mime_prefix)
    where(query, [m], like(m.mime_type, ^pattern))
  end

  @doc "Builds an escaped LIKE prefix pattern for a mime type. Pure — unit-gateable without a DB."
  def mime_pattern(prefix) when is_binary(prefix), do: "#{escape_like(prefix)}%"

  def escape_like(q),
    do:
      q
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

  @doc "Supported facet field names."
  @spec facet_fields() :: [String.t()]
  def facet_fields, do: @facet_fields
end
