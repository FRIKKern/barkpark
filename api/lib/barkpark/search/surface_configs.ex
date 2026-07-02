defmodule Barkpark.Search.SurfaceConfigs do
  @moduledoc """
  Per-surface search tuning (Phase 6). Cached in a bounded, named ETS table
  (60s logical TTL).

  `get/2` is on the hot search read path (documents + media), keyed by
  `{surface, scope}` where `scope` is the caller-supplied dataset segment of
  anonymous-reachable search endpoints. ETS (not `:persistent_term`) because
  every distinct scope string mints a key and each `:persistent_term.put/2`
  triggers a BEAM-wide global GC (registry.ex:42 documents the same rule).
  ETS reads are lock-free and writes are GC-local; the table is clear-on-full
  bounded (`@max_cached_configs`) so an unauthenticated caller cannot grow it
  without limit. An evicted entry is re-derived on the next miss via the same
  cold path — behaviour-preserving.
  """

  alias Barkpark.Search.SurfaceConfig
  alias Barkpark.Repo

  @cache :barkpark_search_surface_config_cache
  @cache_ttl_ms 60_000

  # Bound the config cache. Keyed by {surface, scope}, it would otherwise grow
  # one entry per distinct (attacker-supplied) dataset string forever. See
  # store_config/2 — clear-on-full is behaviour-preserving (#792 precedent).
  @max_cached_configs 512

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
    # Below this hit count a positive-but-thin result set triggers a fuzzy widen
    # in the pipeline (kept only if it returns more hits). Distinct from the
    # zero-hit recovery path. See QueryPipeline.search_documents/5.
    "low_hit_threshold" => 3,
    "highlight_fields" => ["title"]
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
    "highlight_fields" => ["title", "original_name", "filename"]
  }

  @spec get(String.t(), String.t()) :: map()
  def get(surface, scope) when is_binary(surface) and is_binary(scope) do
    cache_key = {surface, scope}
    ensure_cache()

    case :ets.lookup(@cache, cache_key) do
      [{^cache_key, {config, expires_at}}] ->
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
    store_config(cache_key, config)
  end

  defp store_config(cache_key, config) do
    ensure_cache()
    # Clear-on-full memory bound (see @max_cached_configs). Safe: an evicted
    # config is re-derived on the next get/2 miss via the same cold path.
    if :ets.info(@cache, :size) >= @max_cached_configs do
      :ets.delete_all_objects(@cache)
    end

    expires_at = System.monotonic_time(:millisecond) + @cache_ttl_ms
    :ets.insert(@cache, {cache_key, {config, expires_at}})
    config
  end

  defp ensure_cache do
    case :ets.whereis(@cache) do
      :undefined ->
        try do
          :ets.new(@cache, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end
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
          defaults["highlight_fields"]
    }

    case Repo.get_by(SurfaceConfig, surface: surface, scope: scope) do
      nil ->
        %SurfaceConfig{surface: surface, scope: scope}
        |> SurfaceConfig.changeset(merged)
        |> Repo.insert()

      row ->
        row
        |> SurfaceConfig.changeset(merged)
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
            highlight_fields: defaults["highlight_fields"]
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
      "highlight_fields" => row.highlight_fields || []
    }
  end

  defp normalize_fields(fields) when is_list(fields), do: fields
  defp normalize_fields(_), do: []

  defp invalidate(surface, scope) do
    ensure_cache()
    :ets.delete(@cache, {surface, scope})
    :ok
  end

  @doc false
  # Test seam: insert a config under the given key using the real store_config
  # path (clear-on-full bound included), without touching the DB loader.
  def __store_config_for_test__(surface, scope, config),
    do: store_config({surface, scope}, config)

  @doc false
  # Test seam: current cache size (ensures the table exists first).
  def __cache_size_for_test__ do
    ensure_cache()
    :ets.info(@cache, :size)
  end

  @doc false
  # Test seam: drop all cached entries so a test starts from an empty table.
  def __reset_cache_for_test__ do
    ensure_cache()
    :ets.delete_all_objects(@cache)
    :ok
  end
end
