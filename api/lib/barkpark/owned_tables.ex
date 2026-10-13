defmodule Barkpark.OwnedTables do
  @moduledoc """
  Which database tables belong to a plugin or a capability rather than to core,
  and whether that owner is switched on for this instance (Barkspark phase 2,
  slice 2, task-d3ecc509d4ea227d).

  ## The rule (main's ruling, 2026-09-25 16:35Z)

  A table is CORE when a core route, a core fence or a core module reads it
  with no `Barkpark.Capability.enabled?/1` gate. Only the tables that fail that
  test are listed here. Applying it moved four tables the phase-2 survey called
  plugin-owned into core, and they are deliberately absent from `@owners`:

    * `task_edges` — `/v1/tasks` is mounted by the core router, and the core
      mutate door's claim fence (`Barkpark.Tasks.Claim`) reads it.
    * `paper_access_log` — the core route `GET /v1/papers/:slug/access` and the
      core `PaperAccessSweeper` cron read it.
    * `paper_events` — the core-mounted `/v1/paperflow/intents` reads it and
      the core `Content.Papers.BlockOps` writes it.
    * `pulse_counters`, `pulse_events`, `pulse_meters` — `Barkpark.Pulse` is a
      core module by its own moduledoc, and the core endpoint mounts
      `PulseSocket`, whose channel join reads `pulse_counters`.

  The owned tables, functions and core triggers are read from
  `Barkpark.SchemaOwnership`, the manifest that gives every database object
  one owner. A table owned there is dropped by the differential check
  (`mix test.core_without_owned_tables`), which proves core runs without it.

  ## The two instance-level switches

    * `{:plugin, name}`: on when the plugin is registered in
      `Barkpark.Plugins.Registry` (`BARKPARK_PLUGINS`). Registration runs
      synchronously in `Barkpark.SchemaBootstrap.init/1`, before Oban and the
      endpoint start.
    * `{:capability, name}`: `Barkpark.Capability.enabled?/1`
      (`BARKPARK_CAPABILITIES_OFF`).

  Not per-workspace enablement (`Barkpark.Plugins.Enablement`): the tables are
  instance-wide.

  ## Off does not mean absent

  Turning an owner off does not drop its tables. A caller that must still clean
  up rows (workspace teardown) uses `present?/1`, which answers `true` for an
  enabled owner without a database round trip and checks the live catalog only
  when the owner is off.
  """

  alias Barkpark.Capability
  alias Barkpark.Repo
  alias Barkpark.SchemaOwnership

  @type owner :: {:plugin, String.t()} | {:capability, Capability.name()}

  # The lists live in the ownership manifest (slice 3, task-097a1b8ed6d27a8b).
  @owners SchemaOwnership.owned_tables()

  @doc "Every table a plugin or capability owns, sorted."
  @spec tables() :: [String.t()]
  def tables, do: @owners |> Map.keys() |> Enum.sort()

  @doc "The core-table triggers that call a fleet function, as `{table, trigger}`."
  @spec core_triggers() :: [{String.t(), String.t()}]
  def core_triggers, do: SchemaOwnership.owned_core_triggers()

  @doc "The fleet-installed SQL functions, as `to_regprocedure` signatures."
  @spec functions() :: [String.t()]
  def functions, do: SchemaOwnership.owned_functions()

  @doc "The owner of `table`, or `:core` for a table no plugin or capability owns."
  @spec owner(String.t()) :: owner() | :core
  def owner(table) when is_binary(table), do: Map.get(@owners, table, :core)

  @doc """
  True when `table` is core, or its owner is switched on for this instance.
  """
  @spec enabled?(String.t()) :: boolean()
  def enabled?(table) when is_binary(table), do: owner_enabled?(owner(table))

  @doc "True when `owner` is switched on for this instance. `:core` is always on."
  @spec owner_enabled?(owner() | :core) :: boolean()
  def owner_enabled?(:core), do: true
  def owner_enabled?({:capability, name}), do: Capability.enabled?(name)

  def owner_enabled?({:plugin, name}) when is_binary(name) do
    Enum.any?(Barkpark.Plugins.Registry.all(), &(&1.name == name))
  end

  @doc """
  True when `table` can be read and written: its owner is on (no database
  round trip), or its owner is off but the table still exists.

  An enabled owner whose table is missing answers `true`, so the caller's
  query fails loudly instead of silently skipping data it was expected to
  handle.
  """
  @spec present?(String.t()) :: boolean()
  def present?(table) when is_binary(table) do
    enabled?(table) or relation_exists?(table)
  end

  @doc "The subset of `tables` that `present?/1` accepts, order kept."
  @spec present([String.t()]) :: [String.t()]
  def present(tables) when is_list(tables), do: Enum.filter(tables, &present?/1)

  @doc """
  True when the SQL function `signature` (e.g. `"my_fn(uuid)"`) exists in the
  `public` schema. For owner-installed functions that core calls when the
  owner is off (see `Barkpark.Tenancy.delete_workspace/1`).
  """
  @spec function_exists?(String.t()) :: boolean()
  def function_exists?(signature) when is_binary(signature) do
    %{rows: [[exists?]]} =
      Repo.query!("SELECT to_regprocedure($1) IS NOT NULL", ["public." <> signature])

    exists?
  end

  defp relation_exists?(table) do
    %{rows: [[exists?]]} =
      Repo.query!("SELECT to_regclass($1) IS NOT NULL", ["public." <> table])

    exists?
  end
end
