defmodule Barkpark.Content.SchemaCatalogCache do
  @moduledoc """
  Keeps the inlined schema catalog (`Barkpark.Content.Schema.list_schemas/2`)
  across requests, per schema version.

  ## Why

  One Studio document open builds the catalog three times (the type labels,
  `Structure.build/2` and the desk filter checks each ask with their own
  scope opts), once in the dead render and again in the connected mount.
  `GET /v1/structure` builds it too. Each build reads every schema row of the
  scope and inlines the named object types, about 88 more row reads on the
  gyldendal-no copy (task-cca3c6d48e57097e). Between two schema writes every
  one of those builds returns the same list.

  ## The version

  An entry is served only while the schema table still has the version it was
  built under: the row count, the newest `updated_at` and the sum of the row
  `xmin` transaction ids over the WHOLE `schema_definitions` table. An insert,
  an update or a delete anywhere moves at least one of the three, through
  Ecto or raw SQL, on this node or another one. The whole table is
  fingerprinted, not the caller's workspace, because the inliner's last rung
  reads unscoped rows. A schema write costs every entry its next hit, which is
  cheap: schema writes are rare and a miss is what every read cost before.

  The version is read before the build. A write that lands during the build
  moves the version, so the entry stored under the old one is never served
  again. The version read is one aggregate over the schema table (0.5 ms for
  208 rows on the gyldendal-no copy) and runs once per request or Studio
  callback: it rides the same per-request memo as the schema reads, which a
  schema write resets.

  An update inside the transaction that inserted the row keeps its `xmin`.
  Only the Ecto sandbox runs a whole test in one transaction, and the cache is
  off there.

  ## What is never cached

    * A grant-scoped read (`grant_scoped: true`). Its catalog is narrowed by
      the caller's grants, which are not part of the schema version.
    * A read inside a transaction. It can see its own uncommitted schema
      writes, and the shared table must never hold rows other callers cannot
      see.

  ## The key

  The dataset, its resolved `dataset_id`, the PRESENCE and value of
  `:workspace_id` and `:project_id`, and `:include_global`. Those are the only
  opts the catalog read and the inliner look at, so two callers share an entry
  only when they would run the same queries. A workspace never reads another
  workspace's entry: the workspace id is part of the key.

  ## Disabled in `:test`

  `config/test.exs` turns it off: the Ecto sandbox rolls every test back, and
  a catalog that outlived its test could answer the next one. Tests that want
  the cache turn it on (see `schema_catalog_cache_test.exs`).
  """

  import Ecto.Query

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Repo

  @table :barkpark_schema_catalog_cache
  # Entries are per {workspace, dataset, opts shape}. A bound keeps a node
  # with many workspaces from holding a catalog for each forever; on overflow
  # the table is emptied and refills with what is still asked for.
  @max_entries 128

  @doc """
  The catalog for `dataset` and `opts`: the cached one when the schema version
  still matches, else `build.()`, stored under the version read before it ran.
  """
  @spec fetch(String.t(), keyword(), (-> list())) :: list()
  def fetch(dataset, opts, build) when is_function(build, 0) do
    if enabled?() and cacheable?(opts) and table?() do
      cached_fetch(dataset, opts, build)
    else
      build.()
    end
  end

  @doc "Drop every entry. Safe when the table was never created."
  @spec invalidate() :: :ok
  def invalidate do
    if table?(), do: safe(fn -> :ets.delete_all_objects(@table) end)
    :ok
  end

  @doc "Whether the cache is on (`config :barkpark, :schema_catalog_cache`, default true)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:barkpark, :schema_catalog_cache, true) == true

  @doc """
  Create the table, owned by the caller. `Barkpark.Application.start/2` calls
  it at boot so the table lives as long as the application. Idempotent.
  """
  @spec init_cache() :: :ok
  def init_cache do
    if table?() do
      :ok
    else
      try do
        _ = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok
      rescue
        ArgumentError -> :ok
      end
    end
  end

  @doc false
  # The schema version described in the moduledoc. Public for the tests.
  def version do
    from(s in SchemaDefinition,
      select: {count(s.id), max(s.updated_at), fragment("coalesce(sum(xmin::text::bigint), 0)")}
    )
    |> Repo.one()
  end

  defp cached_fetch(dataset, opts, build) do
    key = key(dataset, opts)

    version =
      Barkpark.Content.WriteScope.request_memo(opts, {:schema_catalog_version}, &version/0)

    case safe(fn -> :ets.lookup(@table, key) end) do
      [{^key, ^version, catalog}] ->
        catalog

      _ ->
        catalog = build.()
        store(key, version, catalog)
        catalog
    end
  end

  defp store(key, version, catalog) do
    safe(fn ->
      if :ets.info(@table, :size) >= @max_entries, do: :ets.delete_all_objects(@table)
      :ets.insert(@table, {key, version, catalog})
    end)
  end

  defp key(dataset, opts) do
    {dataset, Barkpark.Content.WriteScope.resolve_read_dataset_id(dataset, opts),
     Keyword.fetch(opts, :workspace_id), Keyword.fetch(opts, :project_id),
     Keyword.get(opts, :include_global, false)}
  end

  defp cacheable?(opts) do
    not Keyword.get(opts, :grant_scoped, false) and not Repo.in_transaction?()
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  # A table that vanished (a node without the application) is a cold cache.
  defp safe(fun) do
    fun.()
  rescue
    ArgumentError -> nil
  end
end
