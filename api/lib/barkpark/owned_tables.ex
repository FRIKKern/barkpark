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

  A table listed here is dropped by the differential check
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
    # plugins. `paper_events_dataset_rescope_backup` is a Bulldocs migration's
    # side-table that nothing in api/lib reads.
    "paper_events_dataset_rescope_backup" => {:plugin, "bulldocs"},
    "github_sync_conflicts" => {:plugin, "github"}
  }

  # The two BEFORE DELETE triggers on CORE tables that call a cycle_fleet
  # function (migration 20260715000500), as {table, trigger}.
  @core_triggers [
    {"workspaces", "workspaces_teardown_cycle_ledger"},
    {"projects", "projects_teardown_cycle_ledger"}
  ]

  # SQL functions the fleet migrations install, as `to_regprocedure` signatures.
  # Every one is used only by an owned table's trigger or check, or by the
  # teardown path `Barkpark.Tenancy.delete_workspace/1` guards.
  @functions [
    "barkpark_prepare_workspace_cycle_teardown(uuid)",
    "barkpark_teardown_cycle_ledger()",
    "barkpark_cycle_correction_immutable()",
    "barkpark_epic_costs_valid(jsonb)",
    "barkpark_epic_ledger_immutable()",
    "barkpark_epic_replacement_ordinal_valid()",
    "barkpark_b1_document(uuid)",
    "barkpark_paper_has_cycle_authority(jsonb,uuid,uuid,text,text,uuid,text,text,text,text,jsonb)",
    "barkpark_reject_padded_cycle_assignment_unit_ids()",
    "barkpark_reject_padded_cycle_result_unit_ids()",
    "barkpark_reject_sealed_cycle_append()",
    "barkpark_release_gate_challenge_transition()",
    "barkpark_release_gate_immutable()",
    "barkpark_release_public_smoke_transition()",
    "barkpark_runtime_usage_receipts_immutable()",
    "barkpark_seal_cycle_correction_parent()",
    "barkpark_seed_cycle_retrieval_attribution()",
    "barkpark_unavailable_smoke_retry_allowed(uuid,uuid)",
    "barkpark_validate_cycle_assignment()",
    "barkpark_validate_cycle_build_result()",
    "barkpark_validate_cycle_correction()",
    "barkpark_validate_cycle_wave_inventory()",
    "barkpark_validate_cycle_wave_inventory_00600()",
    "barkpark_validate_release_gate()",
    "barkpark_canonical_jsonb(jsonb)",
    "barkpark_jsonb_canonical_digest(jsonb)"
  ]

  @doc "Every table a plugin or capability owns, sorted."
  @spec tables() :: [String.t()]
  def tables, do: @owners |> Map.keys() |> Enum.sort()

  @doc "The core-table triggers that call a fleet function, as `{table, trigger}`."
  @spec core_triggers() :: [{String.t(), String.t()}]
  def core_triggers, do: @core_triggers

  @doc "The fleet-installed SQL functions, as `to_regprocedure` signatures."
  @spec functions() :: [String.t()]
  def functions, do: @functions

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
