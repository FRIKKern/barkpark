defmodule Barkpark.Search.SurfaceConfigs do
  @moduledoc """
  Per-surface search tuning (Phase 6). Cached in a bounded, named ETS table
  (60s logical TTL).

  `get/3` is on the hot search read path (documents + media), keyed by
  `{workspace_id, surface, scope}` where `scope` is the caller-supplied dataset
  segment of anonymous-reachable search endpoints. ETS (not `:persistent_term`)
  because every distinct scope string mints a key and each `:persistent_term.put/2`
  triggers a BEAM-wide global GC (registry.ex:42 documents the same rule).
  ETS reads are lock-free and writes are GC-local; the table is clear-on-full
  bounded (`@max_cached_configs`) so an unauthenticated caller cannot grow it
  without limit. An evicted entry is re-derived on the next miss via the same
  cold path — behaviour-preserving.

  ## Per-workspace attribution (charter D45/D49)

  The physical row is keyed on `(workspace_id, surface, scope)`. `workspace_id`
  is OPTIONAL and defaults to `nil`:

    * `nil` → the workspace-agnostic global default row (what `seed_defaults!/0`
      writes, what the anonymous search read path reads). Preserves the
      pre-tenancy behaviour of every caller that does not resolve a workspace.
    * a real `workspace_id` → that tenant's own config. The admin
      GET/PUT controllers pass `conn.assigns.current_workspace.id`, so workspace
      A's write can no longer overwrite workspace B's config on a shared dataset
      slug (the LIVE cross-tenant bleed this closes). On a miss it FALLS THROUGH
      to the nil-workspace global row (the operator's admin-tuned default) before
      the hardcoded code default — see `load_or_default/3` (charter D64/D65).

  The scoped search READ path resolves this per-caller: `QueryPipeline.search/4`
  threads `Keyword.get(opts, :workspace_id)` (from `scope_opts/1`) into `get/3`,
  so a per-workspace admin's tuning actually reaches results rather than being
  attributed on write yet resolved workspace-blind on read (charter D63).
  """

  import Ecto.Query, only: [from: 2]

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
      "similarity_threshold" => 0.25,
      "similarity_threshold_relaxed" => 0.15
    },
    "zero_hit_strategy" => "drop_tokens",
    "highlight_fields" => ["title", "original_name", "filename"]
  }

  @spec get(String.t(), String.t(), binary() | nil) :: map()
  def get(surface, scope, workspace_id \\ nil) when is_binary(surface) and is_binary(scope) do
    # `:shared_only` is the request-side empty-scope sentinel
    # (task-3e2a70930c6df723): a REQUEST that resolved no workspace. For a
    # surface CONFIG that means exactly what `nil` already meant here — the
    # workspace-agnostic global config — so it collapses to nil.
    #
    # This function is a RAW consumer: it puts the value straight into a
    # `:binary_id` query, so an untranslated atom is an Ecto CastError (a 500),
    # not a scope. Translating here is the finding, not a tax — a consumer
    # reading `Keyword.get(opts, :workspace_id)` outside `Content.Scope` is the
    # same "the interpreter decides, not the producer" defect one layer out.
    workspace_id = if workspace_id == :shared_only, do: nil, else: workspace_id
    cache_key = {workspace_id, surface, scope}
    ensure_cache()

    case :ets.lookup(@cache, cache_key) do
      [{^cache_key, {config, expires_at}}] ->
        now = System.monotonic_time(:millisecond)

        if expires_at > now do
          config
        else
          cache_put(cache_key, surface, scope, workspace_id)
        end

      _ ->
        cache_put(cache_key, surface, scope, workspace_id)
    end
  end

  defp cache_put(cache_key, surface, scope, workspace_id) do
    config = load_or_default(surface, scope, workspace_id)
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

  @spec upsert(String.t(), String.t(), map(), binary() | nil) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def upsert(surface, scope, attrs, workspace_id \\ nil)
      when is_binary(surface) and is_binary(scope) do
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

    case get_row(surface, scope, workspace_id) do
      nil ->
        insert_config(surface, scope, merged, workspace_id)

      row ->
        row
        |> SurfaceConfig.changeset(merged)
        |> Repo.update()
    end
    |> case do
      {:ok, row} ->
        invalidate(surface, scope, workspace_id)
        {:ok, payload(row)}

      error ->
        error
    end
  end

  # Scoped single-row read. MUST filter on workspace_id (including nil →
  # `WHERE workspace_id IS NULL`) — a bare `get_by(surface, scope)` would raise
  # "expected at most one result" once a (surface, scope) has both a global
  # default row and one or more per-workspace rows. Ecto forbids `== nil`, so the
  # nil (global-default) case uses `is_nil/1`.
  defp get_row(surface, scope, nil) do
    Repo.one(
      from(c in SurfaceConfig,
        where: c.surface == ^surface and c.scope == ^scope and is_nil(c.workspace_id)
      )
    )
  end

  defp get_row(surface, scope, workspace_id) do
    Repo.get_by(SurfaceConfig, surface: surface, scope: scope, workspace_id: workspace_id)
  end

  # Concurrency-safe first-config insert. NAMED FAILURE MODE without on_conflict:
  # two concurrent PUTs for a (workspace_id, surface, scope) with no row yet both
  # have get_by return nil, both take this branch; the losing racer's plain
  # `Repo.insert/1` violates the unique index and raises an uncaught
  # Ecto.ConstraintError → HTTP 500. `on_conflict: {:replace_all_except, …}` +
  # a matching `conflict_target` turns that INSERT into an idempotent ON CONFLICT
  # DO UPDATE, so the loser cleanly upserts instead of crashing. Mirrors
  # Plugins.Settings.put/3 and Secrets.put/3. `:id`, `:workspace_id`, `:surface`,
  # `:scope`, `:inserted_at` are excluded so the winner's key columns and creation
  # timestamp survive the update.
  #
  # The conflict_target differs by domain (two partial indexes, charter D57):
  #   * nil workspace → the `(surface, scope) WHERE workspace_id IS NULL` partial
  #     index — targeted via an unsafe fragment carrying the predicate (Postgres
  #     cannot infer a partial index from a bare column list).
  #   * real workspace → the full `(workspace_id, surface, scope)` index, matched
  #     by the plain column list.
  @replace_except [:id, :workspace_id, :surface, :scope, :inserted_at]

  defp insert_config(surface, scope, merged, nil) do
    %SurfaceConfig{surface: surface, scope: scope, workspace_id: nil}
    |> SurfaceConfig.changeset(merged)
    |> Repo.insert(
      on_conflict: {:replace_all_except, @replace_except},
      conflict_target: {:unsafe_fragment, ~s|("surface", "scope") WHERE workspace_id IS NULL|}
    )
  end

  defp insert_config(surface, scope, merged, workspace_id) do
    %SurfaceConfig{surface: surface, scope: scope, workspace_id: workspace_id}
    |> SurfaceConfig.changeset(merged)
    |> Repo.insert(
      on_conflict: {:replace_all_except, @replace_except},
      conflict_target: [:workspace_id, :surface, :scope]
    )
  end

  # Workspace-agnostic global defaults (workspace_id = nil). The anonymous search
  # read path reads these; per-workspace rows are an overlay written by the admin
  # settings controllers.
  @spec seed_defaults!() :: :ok
  def seed_defaults! do
    for {surface, scope} <- [{"documents", "production"}, {"media", "production"}] do
      defaults = default_for(surface)

      case get_row(surface, scope, nil) do
        nil ->
          %SurfaceConfig{}
          |> Ecto.Changeset.change(%{
            surface: surface,
            scope: scope,
            workspace_id: nil,
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

  # Two-tier resolution (charter D64). A per-workspace read that misses falls
  # through to the nil-workspace GLOBAL row — the operator's admin-tuned default
  # — BEFORE the hardcoded code default, so a tenant that has not customised a
  # surface still inherits the instance-wide tuning (and an anonymous flat-route
  # caller, which resolves the seeded Default workspace's REAL id, reaches it the
  # same way — charter D65). The fallthrough MUST call the `is_nil` get_row/3
  # clause, never `Repo.get_by(workspace_id: nil)`: the latter raises "expected
  # at most one result" once a (surface, scope) has both a nil-global row and one
  # or more per-workspace rows.
  defp load_or_default(surface, scope, nil) do
    case get_row(surface, scope, nil) do
      nil -> default_for(surface)
      row -> payload(row)
    end
  end

  defp load_or_default(surface, scope, workspace_id) do
    case get_row(surface, scope, workspace_id) do
      nil -> load_or_default(surface, scope, nil)
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

  # A per-workspace upsert only touches its OWN key.
  defp invalidate(surface, scope, workspace_id) when not is_nil(workspace_id) do
    ensure_cache()
    :ets.delete(@cache, {workspace_id, surface, scope})
    :ok
  end

  # A nil-workspace (global-default) upsert retunes the row that EVERY untuned
  # workspace inherits via the D64 fallthrough (`load_or_default/3` caches the
  # inherited payload under the per-workspace key `{workspace_id, surface,
  # scope}`). Deleting only `{nil, surface, scope}` would leave those inherited
  # copies stale for up to the 60s ETS TTL — an untuned workspace would serve the
  # OLD global config. So evict every `{*, surface, scope}` entry (any workspace
  # key for this surface/scope may hold the fallthrough copy). `match_delete`
  # keeps unrelated surfaces/scopes cached; the evicted keys re-derive on the next
  # miss via the same cold path (behaviour-preserving, mirrors the clear-on-full
  # bound in `store_config/2`).
  defp invalidate(surface, scope, nil) do
    ensure_cache()
    :ets.match_delete(@cache, {{:_, surface, scope}, :_})
    :ok
  end

  @doc false
  # Test seam: insert a config under the given (nil-workspace) key using the real
  # store_config path (clear-on-full bound included), without touching the DB
  # loader.
  def __store_config_for_test__(surface, scope, config),
    do: store_config({nil, surface, scope}, config)

  @doc false
  # Test seam: current cache size (ensures the table exists first).
  def __cache_size_for_test__ do
    ensure_cache()
    :ets.info(@cache, :size)
  end

  @doc false
  # Test seam: run the REAL first-config insert branch (on_conflict + real opts)
  # directly, so a protective test can reproduce the losing racer deterministically
  # — its get_by already returned nil, so it hits an existing (surface, scope) row.
  def __insert_config_for_test__(surface, scope, merged, workspace_id \\ nil),
    do: insert_config(surface, scope, merged, workspace_id)

  @doc false
  # Test seam: drop all cached entries so a test starts from an empty table.
  def __reset_cache_for_test__ do
    ensure_cache()
    :ets.delete_all_objects(@cache)
    :ok
  end
end
