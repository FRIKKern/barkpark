defmodule Barkpark.Search.DocumentsRetriever do
  @moduledoc false

  @behaviour Barkpark.Search.Retriever

  import Ecto.Query
  import Barkpark.Content.Scope, only: [scope_to_workspace_or_global: 3]
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @impl Barkpark.Search.Retriever
  @spec search(String.t(), map(), map(), keyword()) ::
          {[struct()], non_neg_integer()}
  def search(scope, parsed, config, opts) when is_binary(scope) do
    terms = search_terms(parsed)
    type = Keyword.get(opts, :type)
    perspective = Keyword.get(opts, :perspective, :published)
    limit = Keyword.get(opts, :limit, 50) |> min(200)
    offset = Keyword.get(opts, :offset, 0)
    relaxed = Keyword.get(opts, :relaxed, false)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    if terms == [] and Map.get(parsed, :phrases, []) == [] and
         Map.get(parsed, :prefixes, []) == [] do
      {[], 0}
    else
      base =
        Document
        |> scope_to_dataset(scope, project_id)
        |> scope_to_workspace_or_global(workspace_id, project_id)
        |> where_match(parsed, terms, config, relaxed)

      base = if type, do: where(base, [d], d.type == ^type), else: base
      base = perspective_filter(base, perspective)

      docs =
        base
        |> order_rank(terms, config)
        |> limit(^limit)
        |> offset(^offset)
        |> Repo.all()

      count = base |> select([d], count(d.id)) |> Repo.one() || 0
      {docs, count}
    end
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
