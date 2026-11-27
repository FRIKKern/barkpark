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

  A write that opens its own transaction (`delete_workspace/1`, the bundle
  import, `create_project_with_dataset/2`, `do_create_owned_workspace/4`)
  opens it with `transaction/2`, which busts on every exit, a raise included.

  ## A load that straddles an invalidate

  A load reads the rows, then stores what it read. One that read before a
  write's COMMIT and stores after the write's `invalidate/0` would cache the
  old row for the TTL. `invalidate/0` bumps a generation counter before it
  drops the entries. A load notes the generation when it starts, stores, and
  then reads the generation again. If it moved, the load takes its own entry
  back out (`:ets.delete_object/2`, so a newer load's entry is left alone).
  It still returns what it read. Checking after the store covers an
  invalidate that lands between the check and the insert.

  ## Disabled in `:test`

  `config/test.exs` sets the TTL to `0`, which makes `fetch/2` a straight
  pass-through to the loader. The Ecto sandbox rolls every test back, so a
  cache that survived a test would hand the next one a `%Workspace{}` whose row
  no longer exists — an order-dependent, silently-wrong suite. Tests that want
  the cache turn it on explicitly (see
  `test/barkpark_web/capabilities_no_db_test.exs`).
  """

  @table :barkpark_tenancy_default_scope_cache
  @generation :__generation__
  @default_ttl_ms 60_000
  # This process's `transaction/2` nesting depth.
  @depth {__MODULE__, :transaction_depth}

  @doc """
  Read `key` through the cache, calling `loader` on a miss or an expired entry.

  A `nil` from `loader` is returned but NEVER stored — see the moduledoc. With
  a non-positive TTL the cache is off and this is exactly `loader.()`.
  """
  @spec fetch(atom(), (-> term())) :: term()
  # The generation counter's own key: an entry stored there would take the
  # counter's place, and the next `invalidate/0` would raise.
  def fetch(@generation, _loader),
    do: raise(ArgumentError, "#{inspect(@generation)} is the cache's generation counter")

  def fetch(key, loader) when is_atom(key) and is_function(loader, 0) do
    ttl = ttl_ms()

    if ttl <= 0 do
      loader.()
    else
      cached_fetch(key, loader, ttl)
    end
  end

  @doc """
  Drop every cached entry, and make a load already under way not store what
  it read (the moduledoc's generation). Safe to call when the table was never
  created.
  """
  @spec invalidate() :: :ok
  def invalidate do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _ref ->
        bump_generation()
        safe_delete_all()
    end
  end

  @doc """
  `Repo.transaction(fun, opts)`, with `invalidate/0` run on every exit from
  it: a COMMIT, a rollback, a raise.

  For a write that opens its own transaction. A bust inside it comes before
  COMMIT, and a raise skips one placed after the call; either way a load
  made in between keeps what it read, the old row or the row this process
  saw before a rollback took it away (task-2d336fb1b6c90c7a).

  Nested in another `transaction/2` of this process, its inner bust comes
  before the outer COMMIT, and the outer one's bust after it covers that.
  Nested in a plain `Repo.transaction/2` (or an `Ecto.Multi`), nothing
  busts after the outer COMMIT: a concurrent load between the inner bust and
  that COMMIT keeps the old seat for the TTL. That is refused with an
  `ArgumentError` before anything is written (task-5c41ef4f5b3f11b2): open
  the outer transaction with `transaction/2`.
  """
  @spec transaction((-> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def transaction(fun, opts \\ []) when is_function(fun, 0) do
    depth = Process.get(@depth, 0)

    if depth == 0 and Barkpark.Repo.in_transaction?() do
      raise ArgumentError,
            "DefaultScopeCache.transaction/2 nested in a plain Repo.transaction: " <>
              "its seat cache bust would come before the outer COMMIT. " <>
              "Open the outer transaction with DefaultScopeCache.transaction/2."
    end

    Process.put(@depth, depth + 1)

    try do
      Barkpark.Repo.transaction(fun, opts)
    after
      if depth == 0, do: Process.delete(@depth), else: Process.put(@depth, depth)
      invalidate()
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
    started = generation()

    case loader.() do
      nil ->
        nil

      value ->
        entry = {key, value, System.monotonic_time(:millisecond) + ttl}
        safe_insert(entry)
        if generation() != started, do: safe_delete_object(entry)
        value
    end
  end

  defp generation do
    case :ets.lookup(@table, @generation) do
      [{@generation, n}] -> n
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp bump_generation do
    :ets.update_counter(@table, @generation, 1, {@generation, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Fallback only: the table is created at boot by init_cache/0.
  defp ensure_table, do: init_cache()

  @doc """
  Create the cache table, owned by the CALLER. `Barkpark.Application.start/2`
  calls this at boot so the table lives as long as the application; a lazy
  create from a request, Task or test process would die with that process and
  make a sibling's next `:ets` call raise `ArgumentError`. Idempotent.
  """
  @spec init_cache() :: :ok
  def init_cache do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          _ = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end
  end

  # Booted nodes own the table from Application.start/2 (init_cache/0), but a
  # node without the application falls back to a caller-owned table that can
  # vanish. A missing table is a cold cache, which is always correct — never a
  # crash.
  defp safe_insert(entry) do
    :ets.insert(@table, entry)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # The entries only: the generation counter (a 2-tuple) stays.
  defp safe_delete_all do
    :ets.match_delete(@table, {:_, :_, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp safe_delete_object(entry) do
    :ets.delete_object(@table, entry)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
