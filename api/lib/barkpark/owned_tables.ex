defmodule Barkpark.OwnedTables do
  @moduledoc """
  Which database tables belong to a plugin or a capability, and whether that
  owner is switched on for this instance (Barkspark phase 2, slice 2,
  task-d3ecc509d4ea227d).

  Core must run with every plugin and fleet table ABSENT. Where core code
  touches one of these tables, it asks `enabled?/1` first and skips the work
  when the owner is off.

  ## The two instance-level switches

  An owner is either a plugin or a capability, and each has one existing
  switch. This module reads those switches; it adds no switch of its own.

    * `{:plugin, name}`: on when the plugin is registered in
      `Barkpark.Plugins.Registry` (`BARKPARK_PLUGINS`: unset registers every
      bundled plugin, `""` registers none, `"a,b"` registers those).
      Registration runs synchronously in `Barkpark.SchemaBootstrap.init/1`,
      before Oban and the endpoint start, so no request or job sees a
      half-filled registry.
    * `{:capability, name}`: `Barkpark.Capability.enabled?/1`
      (`BARKPARK_CAPABILITIES_OFF`).

  This is not per-workspace enablement (`Barkpark.Plugins.Enablement`). The
  tables are instance-wide, so only the instance-level switch decides whether
  they can be relied on.

  ## Off does not mean absent

  Turning an owner off does not drop its tables: an instance that ran every
  migration and later set `BARKPARK_CAPABILITIES_OFF=cycle_fleet` still has
  the cycle tables and their rows. So a caller that must clean up rows (for
  example workspace teardown) cannot simply skip an off owner's table. It uses
  `present?/1` to decide, which answers `true` for an enabled owner without
  touching the database and checks the live catalog only when the owner is
  off.
  """

  alias Barkpark.Capability
  alias Barkpark.Repo

  @type owner :: {:plugin, String.t()} | {:capability, Capability.name()}

  @owners %{
    # studio_chat
    "chat_execution_events" => {:capability, :studio_chat},
    "chat_execution_leases" => {:capability, :studio_chat},
    "chat_messages" => {:capability, :studio_chat},
    "chat_runtime_telemetry_events" => {:capability, :studio_chat},
    "chat_runtime_usage_receipts" => {:capability, :studio_chat},
    "chat_sessions" => {:capability, :studio_chat},
    "registered_chat_hosts" => {:capability, :studio_chat},
    # cycle_fleet
    "cycle_build_plans" => {:capability, :cycle_fleet},
    "cycle_correction_admissions" => {:capability, :cycle_fleet},
    "cycle_correction_promotion_events" => {:capability, :cycle_fleet},
    "cycle_correction_quarantines" => {:capability, :cycle_fleet},
    "cycle_correction_roots" => {:capability, :cycle_fleet},
    "cycle_correction_targets" => {:capability, :cycle_fleet},
    "cycle_release_gate_admissions" => {:capability, :cycle_fleet},
    "cycle_release_gate_captures" => {:capability, :cycle_fleet},
    "cycle_release_gate_challenges" => {:capability, :cycle_fleet},
    "cycle_release_gate_consumptions" => {:capability, :cycle_fleet},
    "cycle_release_gate_migration_state_20260719020100" => {:capability, :cycle_fleet},
    "cycle_release_paper_candidates" => {:capability, :cycle_fleet},
    "cycle_release_public_smokes" => {:capability, :cycle_fleet},
    "cycle_waves" => {:capability, :cycle_fleet},
    # epic_fleet
    "epic_assignment_results" => {:capability, :epic_fleet},
    "epic_assignment_runtime_attempts" => {:capability, :epic_fleet},
    "epic_assignment_tasks" => {:capability, :epic_fleet},
    "epic_assignments" => {:capability, :epic_fleet},
    "epic_benchmark_attempts" => {:capability, :epic_fleet},
    "epic_benchmark_experiments" => {:capability, :epic_fleet},
    # plugins
    "paper_access_log" => {:plugin, "bulldocs"},
    "paper_events" => {:plugin, "bulldocs"},
    "paper_events_dataset_rescope_backup" => {:plugin, "bulldocs"},
    "pulse_counters" => {:plugin, "pulse"},
    "pulse_events" => {:plugin, "pulse"},
    "pulse_meters" => {:plugin, "pulse"},
    "github_sync_conflicts" => {:plugin, "github"},
    "task_edges" => {:plugin, "tasks"}
  }

  @doc "Every table a plugin or capability owns, sorted."
  @spec tables() :: [String.t()]
  def tables, do: @owners |> Map.keys() |> Enum.sort()

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
