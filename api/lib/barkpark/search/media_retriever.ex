defmodule Barkpark.Search.MediaRetriever do
  @moduledoc false

  import Ecto.Query
  alias Barkpark.Content.Document
  alias Barkpark.Media.MediaFile
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

      base =
        MediaFile
        |> from(as: :media)
        |> join(:left, [m], d in Document,
          as: :asset,
          on:
            d.type == ^@asset_type and d.dataset == ^dataset and
              fragment("(?->>?)::uuid = ?", d.content, "mediaFileId", m.id)
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

  defp expanded_terms(dataset, parsed) do
    raw = Map.get(parsed, :raw, "")

    synonym_terms =
      if raw != "" do
        Synonyms.search_terms("media", dataset, raw)
      else
        []
      end

    local =
      (Map.get(parsed, :terms, []) ++ Map.get(parsed, :phrases, []) ++ Map.get(parsed, :prefixes, []))
      |> Enum.reject(&(&1 == ""))

    (synonym_terms ++ local)
    |> Enum.uniq()
  end

  defp include_dynamic(terms, config, relaxed) do
    threshold = similarity_threshold(config, relaxed)

    Enum.reduce(terms, nil, fn term, dyn ->
      pattern = like_pattern(term)

      clause =
        dynamic([m, d],
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
        dynamic([m, d],
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

  defp like_pattern(term) do
    escaped =
      term
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%" <> escaped <> "%"
  end
end
