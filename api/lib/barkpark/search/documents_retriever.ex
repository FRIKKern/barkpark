defmodule Barkpark.Search.DocumentsRetriever do
  @moduledoc false

  @behaviour Barkpark.Search.Retriever

  import Ecto.Query
  import Barkpark.Content.Scope, only: [scope_to_workspace_or_global: 3]
  alias Barkpark.Content.Document
  alias Barkpark.Repo

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

    base = if browse?, do: base, else: where_match(base, parsed, terms, config, relaxed)
    base = if type, do: where(base, [d], d.type == ^type), else: base
    base = perspective_filter(base, perspective)

    docs =
      base
      |> order_rank(terms, config)
      |> limit(^limit)
      |> offset(^offset)
      |> Repo.all()

    count = base |> exclude(:order_by) |> select([d], count(d.id)) |> Repo.one() || 0
    # Facet counts via GROUP BY over the matching set — Postgres's parity with
    # Indx's native facets, surfaced through the same `meta.facets` channel.
    {docs, count, %{facets: facet_counts(base)}}
  end

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
    include_dyn = include_dynamic(terms, config, relaxed)
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

  defp include_dynamic(terms, config, relaxed) do
    threshold = similarity_threshold(config, relaxed)

    Enum.reduce(terms, nil, fn term, dyn ->
      pattern = like_pattern(term)
      prefix_pattern = prefix_pattern(term)

      clause =
        dynamic(
          [d],
          fragment("?.search_vector @@ plainto_tsquery('english', ?)", d, ^term) or
            ilike(d.title, ^pattern) or
            ilike(coalesce(fragment("?->>'slug'", d.content), ""), ^pattern) or
            fragment("similarity(?, ?) > ?", d.title, ^term, ^threshold)
        )

      clause =
        if prefix_pattern do
          dynamic([d], ^clause or ilike(d.title, ^prefix_pattern))
        else
          clause
        end

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

  defp order_rank(queryable, terms, _config) when terms == [] do
    order_by(queryable, [d], desc: d.updated_at)
  end

  defp order_rank(queryable, terms, _config) do
    primary = hd(terms)

    order_by(queryable, [d],
      desc:
        fragment(
          "GREATEST(ts_rank(?.search_vector, plainto_tsquery('english', ?)), similarity(?, ?))",
          d,
          ^primary,
          d.title,
          ^primary
        ),
      desc: d.updated_at
    )
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
