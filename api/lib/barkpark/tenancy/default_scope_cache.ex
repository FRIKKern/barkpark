defmodule Barkpark.Tenancy.DefaultScopeCache do
  @moduledoc """
  A tiny, TTL-bounded, explicitly-invalidated cache for the two singleton rows
  `BarkparkWeb.Plugs.AssignDefaultScope` reads on EVERY flat `/v1/*` request:
  the seeded Default Workspace and the Default Project under it.

  ## Why

  `AssignDefaultScope` sits in `pipeline :api` (`BarkparkWeb.Router`), so a
  request that needs no tenancy at all still took a pool checkout before doing
  any work. `GET /v1/capabilities` is the extreme case — the controller reads
  `conn.assigns[:api_token]` and assembles an in-memory manifest, touching the
  database exactly zero times — yet on one production box it was 32% of all
  requests over a 5-day window (166,039 of ~519k). Every query it issued was
  pipeline overhead on a static payload.

  ## What this is NOT

  It is not a fix for the 500 class those requests sometimes land in. That is
  pool starvation (`POOL_SIZE` unset, shared with 29 Oban slots) and is owned
  elsewhere. This makes a hot route cheaper; it does not make a starved pool
  healthy. It also buys an authenticated `bp` caller nothing: `Plugs.OptionalToken`
  runs BEFORE `AssignDefaultScope` and `Auth.verify_token/1`'s `Repo.one` is
  still a checkout on the same starved pool.

  ## Invalidation is the work; the cache is not the work

  Two failure modes make a naive `persistent_term` pin unsafe here, and this
  module is shaped around both.

  **A pinned `nil`.** A fresh database before the tenancy backfill legitimately
  has no Default Workspace, and `AssignDefaultScope`'s own moduledoc treats that
  as a supported state. The seat also goes vacant in NORMAL operation: the
  support provisioner's `SupportResetDefaultWorkspaceStep` deletes the row and
  the following `SupportAdminTokenStep` re-mints it, so there is a window where
  the answer is `nil` and then abruptly is not. **`nil` is therefore never
  cached at all** — a miss on an unseeded instance costs exactly what it costs
  today, and the first request after the seat is filled sees the new row.

  **A pinned STALE row.** The cached value is a full `%Workspace{}` /
  `%Project{}` struct, `settings` jsonb included, and downstream code reads that
  bag (theme, plugin surfacing, chat settings, pull provenance). So every write
  path that can change either row calls `invalidate/0`, and a TTL bounds
  anything that reaches the rows without passing through `Barkpark.Tenancy`
  (a migration, a `psql` session, a second node).

  The write paths hooked, all of them in `Barkpark.Tenancy` because nothing
  else in `lib/` inserts, updates or deletes a `Workspace` or `Project` row
  (`WorkspaceBundle` imports and `PlaygroundReaper` both route through
  `Tenancy.delete_workspace/1`):

    * `create_workspace/1` — the slug is a claimable seat; a new row can BECOME
      the default while the seat is vacant.
    * `create_project/2` — likewise for the `default`-slugged project, and the
      chokepoint `create_project_with_dataset/2` and
      `do_create_owned_workspace/4` both funnel through.
    * `assign_workspace_to_organization/2` — writes the workspace row.
    * `set_workspace_theme/2`, `set_workspace_plugin_settings/2`,
      `set_workspace_chat_settings/2`, `set_pull_provenance/3` — all four
      rewrite the `settings` bag on the workspace row.
    * `delete_workspace/1` — invalidated AFTER the transaction returns, not
      inside it: clearing mid-transaction lets a concurrent reader repopulate
      from the still-visible old row.

  ## Disabled in `:test`

  `config/test.exs` sets the TTL to `0`, which makes `fetch/2` a straight
  pass-through to the loader. The Ecto sandbox rolls every test back, so a
  cache that survived a test would hand the next one a `%Workspace{}` whose row
  no longer exists — an order-dependent, silently-wrong suite. Tests that want
  the cache turn it on explicitly (see
  `test/barkpark_web/capabilities_no_db_test.exs`).
  """

  @table :barkpark_tenancy_default_scope_cache
  @default_ttl_ms 60_000

  @doc """
  Read `key` through the cache, calling `loader` on a miss or an expired entry.

  A `nil` from `loader` is returned but NEVER stored — see the moduledoc. With
  a non-positive TTL the cache is off and this is exactly `loader.()`.
  """
  @spec fetch(atom(), (-> term())) :: term()
  def fetch(key, loader) when is_atom(key) and is_function(loader, 0) do
    ttl = ttl_ms()

    if ttl <= 0 do
      loader.()
    else
      cached_fetch(key, loader, ttl)
    end
  end

  @doc "Drop every cached entry. Safe to call when the table was never created."
  @spec invalidate() :: :ok
  def invalidate do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ref -> safe_delete_all()
    end
  end

  @doc "Cache lifetime in milliseconds; `0` (or less) disables the cache."
  @spec ttl_ms() :: integer()
  def ttl_ms do
    Application.get_env(:barkpark, :tenancy_default_scope_cache_ttl_ms, @default_ttl_ms)
  end

  defp cached_fetch(key, loader, ttl) do
    ensure_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        value

      _ ->
        load_and_store(key, loader, ttl)
    end
  end

  defp load_and_store(key, loader, ttl) do
    case loader.() do
      nil ->
        nil

      value ->
        expires_at = System.monotonic_time(:millisecond) + ttl
        safe_insert({key, value, expires_at})
        value
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          # Lost the create race to another process; the table exists either way.
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end

    :ok
  end

  # The table is unowned (created by whichever process got there first), so a
  # concurrent `invalidate/0` deleting it is a live possibility. A missing table
  # is a cold cache, which is always correct — never a crash.
  defp safe_insert(entry) do
    :ets.insert(@table, entry)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp safe_delete_all do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
