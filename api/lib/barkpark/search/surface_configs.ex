defmodule Barkpark.Search.SurfaceConfigs do
  @moduledoc """
  Per-surface search tuning (Phase 6). Cached via `:persistent_term` (60s logical TTL).
  """

  alias Barkpark.Search.SurfaceConfig
  alias Barkpark.Repo

  @cache_prefix :search_surface_config
  @cache_ttl_ms 60_000

  @default_documents %{
    "searchable_fields" => [
      %{"path" => "title", "weight" => 10},
      %{"path" => "content.slug", "weight" => 3}
    ],
    "typo_policy" => %{
      "enabled" => true,
      "min_len_1typo" => 5,
      "min_len_2typo" => 9,
      "similarity_threshold" => 0.25,
      "similarity_threshold_relaxed" => 0.15
    },
    "zero_hit_strategy" => "drop_tokens",
    "highlight_fields" => ["title"],
    "engine" => "postgres"
  }

  @default_media %{
    "searchable_fields" => [
      %{"path" => "title", "weight" => 10},
      %{"path" => "original_name", "weight" => 8},
      %{"path" => "filename", "weight" => 6},
      %{"path" => "tags", "weight" => 4}
    ],
    "typo_policy" => %{
      "enabled" => true,
      "min_len_1typo" => 5,
      "min_len_2typo" => 9,
      "similarity_threshold" => 0.25,
      "similarity_threshold_relaxed" => 0.15
    },
    "zero_hit_strategy" => "drop_tokens",
    "highlight_fields" => ["title", "original_name", "filename"],
    "engine" => "postgres"
  }

  @spec get(String.t(), String.t()) :: map()
  def get(surface, scope) when is_binary(surface) and is_binary(scope) do
    cache_key = {surface, scope}

    case :persistent_term.get({@cache_prefix, cache_key}, nil) do
      {config, expires_at} ->
        now = System.monotonic_time(:millisecond)

        if expires_at > now do
          config
        else
          cache_put(cache_key, surface, scope)
        end

      _ ->
        cache_put(cache_key, surface, scope)
    end
  end

  defp cache_put(cache_key, surface, scope) do
    config = load_or_default(surface, scope)
    expires_at = System.monotonic_time(:millisecond) + @cache_ttl_ms
    :persistent_term.put({@cache_prefix, cache_key}, {config, expires_at})
    config
  end

  @spec upsert(String.t(), String.t(), map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def upsert(surface, scope, attrs) when is_binary(surface) and is_binary(scope) do
    defaults = default_for(surface)

    merged = %{
      searchable_fields:
        Map.get(attrs, "searchableFields") || Map.get(attrs, :searchable_fields) ||
          defaults["searchable_fields"],
      typo_policy:
        Map.get(attrs, "typoPolicy") || Map.get(attrs, :typo_policy) || defaults["typo_policy"],
      zero_hit_strategy:
        Map.get(attrs, "zeroHitStrategy") || Map.get(attrs, :zero_hit_strategy) ||
          defaults["zero_hit_strategy"],
      highlight_fields:
        Map.get(attrs, "highlightFields") || Map.get(attrs, :highlight_fields) ||
          defaults["highlight_fields"],
      engine:
        Map.get(attrs, "engine") || Map.get(attrs, :engine) ||
          defaults["engine"] || "postgres"
    }

    case Repo.get_by(SurfaceConfig, surface: surface, scope: scope) do
      nil ->
        %SurfaceConfig{}
        |> Ecto.Changeset.change(Map.merge(%{surface: surface, scope: scope}, merged))
        |> Repo.insert()

      row ->
        row
        |> Ecto.Changeset.change(merged)
        |> Repo.update()
    end
    |> case do
      {:ok, row} ->
        invalidate(surface, scope)
        {:ok, payload(row)}

      error ->
        error
    end
  end

  @spec seed_defaults!() :: :ok
  def seed_defaults! do
    for {surface, scope} <- [{"documents", "production"}, {"media", "production"}] do
      defaults = default_for(surface)

      case Repo.get_by(SurfaceConfig, surface: surface, scope: scope) do
        nil ->
          %SurfaceConfig{}
          |> Ecto.Changeset.change(%{
            surface: surface,
            scope: scope,
            searchable_fields: defaults["searchable_fields"],
            typo_policy: defaults["typo_policy"],
            zero_hit_strategy: defaults["zero_hit_strategy"],
            highlight_fields: defaults["highlight_fields"],
            engine: defaults["engine"] || "postgres"
          })
          |> Repo.insert!()

        _ ->
          :ok
      end
    end

    :ok
  end

  @spec default_for(String.t()) :: map()
  def default_for("documents"), do: @default_documents
  def default_for("media"), do: @default_media
  def default_for(_), do: @default_documents

  defp load_or_default(surface, scope) do
    case Repo.get_by(SurfaceConfig, surface: surface, scope: scope) do
      nil -> default_for(surface)
      row -> payload(row)
    end
  end

  defp payload(%SurfaceConfig{} = row) do
    %{
      "surface" => row.surface,
      "scope" => row.scope,
      "searchable_fields" => normalize_fields(row.searchable_fields),
      "typo_policy" => row.typo_policy || %{},
      "zero_hit_strategy" => row.zero_hit_strategy || "drop_tokens",
      "highlight_fields" => row.highlight_fields || [],
      "engine" => row.engine || "postgres"
    }
  end

  defp normalize_fields(fields) when is_list(fields), do: fields
  defp normalize_fields(_), do: []

  defp invalidate(surface, scope) do
    :persistent_term.erase({@cache_prefix, {surface, scope}})
  rescue
    ArgumentError -> :ok
  end
end
