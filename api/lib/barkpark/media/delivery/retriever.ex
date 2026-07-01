defmodule Barkpark.Media.Delivery.Retriever do
  @moduledoc false

  import Ecto.Query
  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Search.Synonyms

  @asset_type "mediaAsset"

  @spec build_text_filter(String.t(), map(), map(), keyword()) :: Ecto.Query.t() | nil
  def build_text_filter(dataset, parsed, config, opts \\ []) do
    relaxed = Keyword.get(opts, :relaxed, false)
    terms = expanded_terms(dataset, parsed)

    if terms == [] and Map.get(parsed, :excludes, []) == [] do
      nil
    else
      include_dyn = include_dynamic(terms, config, relaxed)
      exclude_dyn = exclude_dynamic(Map.get(parsed, :excludes, []), relaxed)

      workspace_id = Keyword.get(opts, :workspace_id)
      project_id = Keyword.get(opts, :project_id)

      base =
        MediaFile
        |> from(as: :media)
        |> join(
          :left,
          [m],
          d in ^asset_doc_join_query(dataset, workspace_id, project_id),
          as: :asset,
          on: fragment("(?->>?)::uuid = ?", d.content, "mediaFileId", m.id)
        )

      base =
        if include_dyn,
          do: where(base, ^include_dyn),
          else: base

      if exclude_dyn do
        where(base, ^dynamic([m, d], not (^exclude_dyn)))
      else
        base
      end
    end
  end

  @spec apply_to_query(Ecto.Query.t(), String.t(), map(), map(), keyword()) :: Ecto.Query.t()
  def apply_to_query(query, dataset, parsed, config, opts \\ []) do
    case build_text_filter(dataset, parsed, config, opts) do
      nil ->
        query

      filter_query ->
        ids_subquery =
          filter_query
          |> exclude(:order_by)
          |> select([m], m.id)

        where(query, [m], m.id in subquery(ids_subquery))
    end
  end

  # Pre-scoped Document subquery the text-match LEFT-JOIN binds against. Mirrors
  # Barkpark.Media.Delivery.Search.asset_doc_join_query/4: type + NULL-tolerant dataset
  # (dataset_id authoritative, string fallback) + NULL-tolerant workspace
  # envelope. Closes the search arm of the cross-workspace metadata leak — the
  # `ilike(d.title, …)` / tag match can no longer attach another workspace's
  # asset doc to this workspace's blob (barkpark-vmv1). A nil workspace_id
  # (unscoped path) leaves the workspace filter off (deliberate global read).
  defp asset_doc_join_query(dataset, workspace_id, project_id) do
    dataset_id = Barkpark.Content.resolve_read_dataset_id(dataset, project_id: project_id)

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

  defp expanded_terms(dataset, parsed) do
    raw = Map.get(parsed, :raw, "")

    synonym_terms =
      if raw != "" do
        Synonyms.search_terms("media", dataset, raw)
      else
        []
      end

    local =
      (Map.get(parsed, :terms, []) ++
         Map.get(parsed, :phrases, []) ++ Map.get(parsed, :prefixes, []))
      |> Enum.reject(&(&1 == ""))

    (synonym_terms ++ local)
    |> Enum.uniq()
  end

  defp include_dynamic(terms, config, relaxed) do
    threshold = similarity_threshold(config, relaxed)

    Enum.reduce(terms, nil, fn term, dyn ->
      pattern = like_pattern(term)

      clause =
        dynamic(
          [m, d],
          ilike(m.original_name, ^pattern) or ilike(m.filename, ^pattern) or
            ilike(d.title, ^pattern) or
            fragment("similarity(?, ?) > ?", m.original_name, ^term, ^threshold) or
            fragment("similarity(?, ?) > ?", m.filename, ^term, ^threshold) or
            fragment(
              "EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(?->'tags', '[]'::jsonb)) elem WHERE elem ILIKE ?)",
              d.content,
              ^pattern
            )
        )

      if dyn, do: dynamic([m, d], ^dyn or ^clause), else: clause
    end)
  end

  defp exclude_dynamic(excludes, relaxed) do
    threshold = similarity_threshold(%{}, relaxed)

    Enum.reduce(excludes, nil, fn term, dyn ->
      pattern = like_pattern(term)

      clause =
        dynamic(
          [m, d],
          ilike(m.original_name, ^pattern) or ilike(m.filename, ^pattern) or
            ilike(d.title, ^pattern) or
            fragment("similarity(?, ?) > ?", m.original_name, ^term, ^threshold) or
            fragment(
              "EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(?->'tags', '[]'::jsonb)) elem WHERE elem ILIKE ?)",
              d.content,
              ^pattern
            )
        )

      if dyn, do: dynamic([m, d], ^dyn or ^clause), else: clause
    end)
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

  def like_pattern(term) do
    escaped =
      term
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%" <> escaped <> "%"
  end
end
