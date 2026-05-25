defmodule Barkpark.Media.Search do
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
  import Barkpark.Content.Scope, only: [scope_to_workspace: 3]
  alias Barkpark.Content.Document
  alias Barkpark.Media.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Search.{MediaRetriever, QueryParser, QueryPipeline, SurfaceConfigs}

  @asset_type "mediaAsset"
  @facet_fields ~w(kind tags mimeType status processing collection visibility)

  @doc """
  Search media assets. Returns `{files, total, facets, meta}`.
  """
  @spec search(String.t(), keyword()) :: {[MediaFile.t()], non_neg_integer(), map(), map()}
  def search(dataset, opts \\ []) when is_binary(dataset) do
    config = SurfaceConfigs.get("media", dataset)
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
    dataset_id = resolve_dataset_id(dataset, opts)

    MediaFile
    |> from(as: :media)
    |> join(:left, [m], d in Document,
      as: :asset,
      on:
        d.type == ^@asset_type and d.dataset == ^dataset and
          fragment("(?->>?)::uuid = ?", d.content, "mediaFileId", m.id)
    )
    |> scope_media_to_dataset(dataset, dataset_id)
    |> scope_to_workspace(workspace_id, project_id)
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
            |> where([m, _d], m.inserted_at < ^cursor_at or (m.inserted_at == ^cursor_at and m.id < ^cursor_id))
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
         {:ok, uuid} <- Ecto.UUID.cast(id),
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

  defp drop_facet_selection(opts, field) do
    selections =
      opts
      |> Keyword.get(:facet_selections, %{})
      |> Map.delete(field)

    Keyword.put(opts, :facet_selections, selections)
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

    params
    |> then(&Repo.query(sql, &1))
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
    # `scope_to_workspace/3` envelope here: bind workspace_id (and project_id
    # when present) as parameters $3.. ahead of the dynamic filters. Same
    # nil-means-unscoped back-compat as Content.Scope.
    {scope_sql, scope_params, next_idx} = scope_fragments(opts, 3)
    {where_sql, params} = where_fragments(opts, next_idx, skip_tags: true)

    sql = """
    SELECT tag, COUNT(DISTINCT m.id)
    FROM media_files m
    LEFT JOIN documents d
      ON d.type = $1
      AND d.dataset = $2
      AND (d.content->>'mediaFileId')::uuid = m.id
    CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(d.content->'tags', '[]'::jsonb)) AS tag
    WHERE m.dataset = $2
    #{scope_sql}
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

  # Build the workspace/project scope clause for the raw-SQL facet path,
  # consuming parameter slots starting at `start_idx`. Returns
  # `{sql_fragment, params, next_idx}` so the caller's dynamic filters pick up
  # where this leaves off. A nil workspace_id is the unscoped back-compat path
  # (no clause emitted), matching Barkpark.Content.Scope.scope_to_workspace/3.
  defp scope_fragments(opts, start_idx) do
    # `m.workspace_id` / `m.project_id` are :binary_id (uuid) columns. Raw
    # Postgrex needs the 16-byte binary, not the UUID string — the Ecto path
    # casts via the schema type, but `Repo.query/2` does not. Dump here; an
    # unparseable id falls back to the unscoped branch (caught by uuid_param).
    workspace_id = uuid_param(first_present([opts[:workspace_id]]))
    project_id = uuid_param(first_present([opts[:project_id]]))

    cond do
      is_nil(workspace_id) ->
        {"", [], start_idx}

      is_nil(project_id) ->
        {"AND m.workspace_id = $#{start_idx}", [workspace_id], start_idx + 1}

      true ->
        {"AND m.workspace_id = $#{start_idx} AND m.project_id = $#{start_idx + 1}",
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
        case Keyword.get(opts, :parsed) || Keyword.get(opts, :q) do
          %{} = parsed when map_size(parsed) > 0 ->
            terms = parsed.terms ++ parsed.phrases
            # BUG 1 guard: `hd([])` raises ArgumentError, 500ing the whole
            # search on the zero-term media-recovery path. `List.first/1`
            # returns nil on [], so we fall through to :raw / "" cleanly.
            primary = List.first(terms) || Map.get(parsed, :raw, "")
            pattern = if primary != "", do: "%#{escape_like(primary)}%", else: "%"

            order_by(query, [m, d],
              desc:
                fragment(
                  "CASE WHEN ? ILIKE ? OR ? ILIKE ? OR ? ILIKE ? OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(?->'tags', '[]'::jsonb)) elem WHERE elem ILIKE ?) THEN 1 ELSE 0 END",
                  d.title,
                  ^pattern,
                  m.original_name,
                  ^pattern,
                  m.filename,
                  ^pattern,
                  d.content,
                  ^pattern
                ),
              desc: m.inserted_at
            )

          q when is_binary(q) and q != "" ->
            pattern = "%#{escape_like(q)}%"

            order_by(query, [m, d],
              desc:
                fragment(
                  "CASE WHEN ? ILIKE ? OR ? ILIKE ? OR ? ILIKE ? OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(?->'tags', '[]'::jsonb)) elem WHERE elem ILIKE ?) THEN 1 ELSE 0 END",
                  d.title,
                  ^pattern,
                  m.original_name,
                  ^pattern,
                  m.filename,
                  ^pattern,
                  d.content,
                  ^pattern
                ),
              desc: m.inserted_at
            )

          _ ->
            order_by(query, [m], desc: m.inserted_at)
        end

      "created-asc" ->
        order_by(query, [m], asc: m.inserted_at)

      "updated-desc" ->
        order_by(query, [m, d], desc: d.updated_at, desc: m.inserted_at)

      _ ->
        order_by(query, [m], desc: m.inserted_at)
    end
  end

  defp maybe_filter_text(query, dataset, opts) do
    parsed = Keyword.get(opts, :parsed)
    config = Keyword.get(opts, :pipeline_config, SurfaceConfigs.get("media", dataset))
    relaxed = Keyword.get(opts, :relaxed, false)

    cond do
      is_map(parsed) and map_size(parsed) > 0 ->
        MediaRetriever.apply_to_query(query, dataset, parsed, config, relaxed: relaxed)

      true ->
        q = Keyword.get(opts, :q)

        if q in [nil, ""] do
          query
        else
          parsed = QueryParser.parse(q)
          MediaRetriever.apply_to_query(query, dataset, parsed, config, relaxed: relaxed)
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

  defp maybe_filter_mime(query, nil), do: query
  defp maybe_filter_mime(query, ""), do: query

  defp maybe_filter_mime(query, mime_prefix) when is_binary(mime_prefix) do
    pattern = "#{mime_prefix}%"
    where(query, [m], like(m.mime_type, ^pattern))
  end

  defp escape_like(q), do: q |> String.replace("%", "\\%") |> String.replace("_", "\\_")

  @doc "Supported facet field names."
  @spec facet_fields() :: [String.t()]
  def facet_fields, do: @facet_fields
end
