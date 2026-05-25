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
  alias Barkpark.Search.Synonyms

  @asset_type "mediaAsset"
  @facet_fields ~w(kind tags mimeType status processing collection visibility)

  @doc """
  Search media assets. Returns `{files, total, facets}`.
  """
  @spec search(String.t(), keyword()) :: {[MediaFile.t()], non_neg_integer(), map()}
  def search(dataset, opts \\ []) when is_binary(dataset) do
    query = build_query(dataset, opts)

    total =
      query
      |> exclude(:order_by)
      |> exclude(:limit)
      |> exclude(:offset)
      |> select([m, _d], count(m.id, :distinct))
      |> Repo.one()

    page_ids = paginate_ids(query, opts)

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

    facets =
      case Keyword.get(opts, :facets, []) do
        [] -> %{}
        fields -> compute_facets(dataset, opts, fields)
      end

    {files, total || 0, facets}
  end

  @doc "Build the shared search query (used by list + search)."
  @spec build_query(String.t(), keyword()) :: Ecto.Query.t()
  def build_query(dataset, opts) when is_binary(dataset) do
    selections = Keyword.get(opts, :facet_selections, %{})
    opts = Keyword.put_new(opts, :dataset, dataset)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    MediaFile
    |> from(as: :media)
    |> join(:left, [m], d in Document,
      as: :asset,
      on:
        d.type == ^@asset_type and d.dataset == ^dataset and
          fragment("(?->>?)::uuid = ?", d.content, "mediaFileId", m.id)
    )
    |> where([m], m.dataset == ^dataset)
    |> scope_to_workspace(workspace_id, project_id)
    |> maybe_filter_mime(Keyword.get(opts, :mime_type))
    |> maybe_filter_mime(selections["mimeType"])
    |> maybe_filter_search(Keyword.get(opts, :q), dataset)
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

  defp paginate_ids(query, opts) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    fetch = limit + offset + 20

    query
    |> apply_sort(opts)
    |> limit(^fetch)
    |> select([m, _d], m.id)
    |> Repo.all()
    |> Enum.uniq()
    |> Enum.drop(offset)
    |> Enum.take(limit)
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
    {where_sql, params} = where_fragments(opts, skip_tags: true)

    sql = """
    SELECT tag, COUNT(DISTINCT m.id)
    FROM media_files m
    LEFT JOIN documents d
      ON d.type = $1
      AND d.dataset = $2
      AND (d.content->>'mediaFileId')::uuid = m.id
    CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(d.content->'tags', '[]'::jsonb)) AS tag
    WHERE m.dataset = $2
    #{where_sql}
    GROUP BY tag
    ORDER BY COUNT(DISTINCT m.id) DESC
    LIMIT 80
    """

    {@asset_type, dataset}
    |> Tuple.to_list()
    |> Kernel.++(params)
    |> then(&{sql, &1})
  end

  defp where_fragments(opts, extra) do
    parts = []
    params = []
    param_idx = 3

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
        case Keyword.get(opts, :q) do
          q when is_binary(q) and q != "" ->
            dataset = Keyword.fetch!(opts, :dataset)
            terms = Synonyms.search_terms("media", dataset, q)
            terms = if terms == [], do: [q], else: terms
            pattern = "%#{escape_like(hd(terms))}%"

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

  defp maybe_filter_search(query, nil, _dataset), do: query
  defp maybe_filter_search(query, "", _dataset), do: query

  defp maybe_filter_search(query, q, dataset) when is_binary(q) and is_binary(dataset) do
    terms = Synonyms.search_terms("media", dataset, q)
    terms = if terms == [], do: [q], else: terms
    patterns = Enum.map(terms, fn term -> "%#{escape_like(term)}%" end)

    dynamic =
      Enum.reduce(patterns, nil, fn pattern, dyn ->
        clause =
          dynamic(
            [m, d],
            ilike(m.original_name, ^pattern) or ilike(m.filename, ^pattern) or
              ilike(d.title, ^pattern) or
              fragment(
                "EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(?->'tags', '[]'::jsonb)) elem WHERE elem ILIKE ?)",
                d.content,
                ^pattern
              )
          )

        if dyn, do: dynamic([m, d], ^dyn or ^clause), else: clause
      end)

    where(query, ^dynamic)
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
