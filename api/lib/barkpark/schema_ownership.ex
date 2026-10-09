defmodule Barkpark.SchemaOwnership do
  @moduledoc """
  The ownership manifest: every table, function, trigger, index, sequence,
  constraint, type and extension in a fully migrated database has exactly one
  owner (Barkspark phase 2, slice 3, task-097a1b8ed6d27a8b).

  The per-owner baselines of slice 4 are cut from this list, so an object
  nobody owns would land in no baseline, and an object two owners claim would
  land in two.

  ## Owners

  `:core`, `{:capability, :studio_chat | :cycle_fleet | :epic_fleet}` and
  `{:plugin, "bulldocs" | "github"}`, the same terms `Barkpark.OwnedTables`
  uses. Codelists are core (side ruling 2026-09-25). `task_edges`, the
  `paper_*` tables and the `pulse_*` tables are core under the 16:35Z rule
  written in `Barkpark.OwnedTables`, so `tasks` and `pulse` own nothing.

  ## What is listed and what follows

    * Tables, functions, types and extensions in `public` are listed by name.
      A new one that is not listed fails `Barkpark.SchemaOwnershipTest`.
    * A schema other than `public` must be in `@external_schemas`, which
      names the process that creates it. No baseline carries those.
    * Indexes, constraints and column-owned sequences belong to their table.
    * A trigger belongs to its table, unless it is in `@trigger_owners`: the
      migration that created it belongs to another owner, as with the cycle
      triggers on core and epic tables. A trigger's owner must be its table's
      owner or require it, and its function's owner must be the trigger's
      owner or one it requires (`Barkpark.Capability`: cycle_fleet requires
      epic_fleet, and everything requires core).

  `Barkpark.OwnedTables` reads its owned tables, functions and core triggers
  from here.
  """

  alias Barkpark.Capability

  @type owner :: :core | {:plugin, String.t()} | {:capability, Capability.name()}

  @studio_chat {:capability, :studio_chat}
  @cycle_fleet {:capability, :cycle_fleet}
  @epic_fleet {:capability, :epic_fleet}

  @core_tables ~w(
    access_grants api_tokens audit_events audit_export_sinks authoring_exemptions
    codelist_value_translations codelist_values codelists
    collapsed_schema_definitions_backup content_edges data_keys datasets documents
    idempotency_keys login_tickets media_files mutation_events oban_jobs oban_peers
    oidc_connections org_domains organizations paper_access_log paper_events
    plugin_doc_state plugin_settings plugin_settings_audit preview_links preview_token_jti projects
    pulse_counters pulse_events pulse_meters revisions role_permissions roles
    saml_assertion_replays saml_connections schema_definitions schema_migrations
    scim_groups scim_tokens search_intel_crystals search_intel_events
    search_intel_merge_patterns search_surface_config search_synonyms secrets
    secrets_audit share_links shares social_identities social_providers
    status_incidents sync_cursors sync_dead_letters sync_push_conflicts
    sync_push_cursors sync_push_doc_revs task_edges token_sessions user_email_tokens
    user_prefs user_sessions users webauthn_challenge_replays webauthn_credentials webhook_deliveries webhooks
    workspace_invitations workspace_memberships workspaces
  )

  @owned_tables %{
    "chat_execution_events" => @studio_chat,
    "chat_execution_leases" => @studio_chat,
    "chat_messages" => @studio_chat,
    "chat_runtime_telemetry_events" => @studio_chat,
    "chat_runtime_usage_receipts" => @studio_chat,
    "chat_sessions" => @studio_chat,
    "registered_chat_hosts" => @studio_chat,
    "cycle_build_plans" => @cycle_fleet,
    "cycle_correction_admissions" => @cycle_fleet,
    "cycle_correction_promotion_events" => @cycle_fleet,
    "cycle_correction_quarantines" => @cycle_fleet,
    "cycle_correction_roots" => @cycle_fleet,
    "cycle_correction_targets" => @cycle_fleet,
    "cycle_release_gate_admissions" => @cycle_fleet,
    "cycle_release_gate_captures" => @cycle_fleet,
    "cycle_release_gate_challenges" => @cycle_fleet,
    "cycle_release_gate_consumptions" => @cycle_fleet,
    "cycle_release_gate_migration_state_20260719020100" => @cycle_fleet,
    "cycle_release_paper_candidates" => @cycle_fleet,
    "cycle_release_public_smokes" => @cycle_fleet,
    "cycle_waves" => @cycle_fleet,
    "epic_assignment_results" => @epic_fleet,
    "epic_assignment_runtime_attempts" => @epic_fleet,
    "epic_assignment_tasks" => @epic_fleet,
    "epic_assignments" => @epic_fleet,
    "epic_benchmark_attempts" => @epic_fleet,
    "epic_benchmark_experiments" => @epic_fleet,
    # A Bulldocs migration's side-table that nothing in api/lib reads.
    "paper_events_dataset_rescope_backup" => {:plugin, "bulldocs"},
    "github_sync_conflicts" => {:plugin, "github"}
  }

  @core_functions [
    "barkpark_audit_events_immutable()",
    "barkpark_bind_document_revision()",
    "barkpark_revision_immutable()",
    "bp_documents_public_search_vector_trg()",
    "bp_public_search_vector(text,text,uuid,text,jsonb)",
    "bp_schema_public_search_reindex_trg()",
    "bp_search_field_restricted(jsonb)",
    "bp_search_item_field(jsonb)",
    "bp_search_redact(jsonb,jsonb,integer)",
    "bp_search_vector_of(text,jsonb)"
  ]

  # Signatures as `to_regprocedure` reads them. The order is the order
  # `mix test.core_without_owned_tables` drops them in, without cascade.
  @owned_functions [
    {"barkpark_prepare_workspace_cycle_teardown(uuid)", @cycle_fleet},
    {"barkpark_teardown_cycle_ledger()", @cycle_fleet},
    {"barkpark_cycle_correction_immutable()", @cycle_fleet},
    {"barkpark_epic_costs_valid(jsonb)", @epic_fleet},
    {"barkpark_epic_ledger_immutable()", @epic_fleet},
    {"barkpark_epic_replacement_ordinal_valid()", @epic_fleet},
    {"barkpark_b1_document(uuid)", @cycle_fleet},
    {"barkpark_paper_has_cycle_authority(jsonb,uuid,uuid,text,text,uuid,text,text,text,text,jsonb)",
     @cycle_fleet},
    {"barkpark_reject_padded_cycle_assignment_unit_ids()", @cycle_fleet},
    {"barkpark_reject_padded_cycle_result_unit_ids()", @cycle_fleet},
    {"barkpark_reject_sealed_cycle_append()", @cycle_fleet},
    {"barkpark_release_gate_challenge_transition()", @cycle_fleet},
    {"barkpark_release_gate_immutable()", @cycle_fleet},
    {"barkpark_release_public_smoke_transition()", @cycle_fleet},
    {"barkpark_runtime_usage_receipts_immutable()", @studio_chat},
    {"barkpark_seal_cycle_correction_parent()", @cycle_fleet},
    {"barkpark_seed_cycle_retrieval_attribution()", @cycle_fleet},
    {"barkpark_unavailable_smoke_retry_allowed(uuid,uuid)", @cycle_fleet},
    {"barkpark_validate_cycle_assignment()", @cycle_fleet},
    {"barkpark_validate_cycle_build_result()", @cycle_fleet},
    {"barkpark_validate_cycle_correction()", @cycle_fleet},
    {"barkpark_validate_cycle_wave_inventory()", @cycle_fleet},
    {"barkpark_validate_cycle_wave_inventory_00600()", @cycle_fleet},
    {"barkpark_validate_release_gate()", @cycle_fleet},
    {"barkpark_canonical_jsonb(jsonb)", @cycle_fleet},
    {"barkpark_jsonb_canonical_digest(jsonb)", @cycle_fleet}
  ]

  # Triggers whose owner is not their table's owner, as {table, trigger}. Each
  # was created by a cycle_fleet migration on a core or epic_fleet table.
  @trigger_owners %{
    # 20260715000500_create_cycle_waves
    {"workspaces", "workspaces_teardown_cycle_ledger"} => @cycle_fleet,
    {"projects", "projects_teardown_cycle_ledger"} => @cycle_fleet,
    {"epic_assignments", "epic_assignments_validate_cycle"} => @cycle_fleet,
    {"epic_assignment_results", "epic_assignment_results_validate_cycle_build"} => @cycle_fleet,
    # 20260715000600_reject_padded_cycle_unit_ids
    {"epic_assignments", "aa_epic_assignments_reject_padded_cycle_unit_ids"} => @cycle_fleet,
    {"epic_assignment_results", "aa_epic_assignment_results_reject_padded_cycle_unit_ids"} =>
      @cycle_fleet,
    # 20260715000700_seed_cycle_retrieval_attribution
    {"epic_assignments", "aa_epic_assignments_seed_cycle_retrieval_attribution"} => @cycle_fleet,
    # 20260718121000_add_cycle_wave_corrections
    {"epic_assignments", "epic_assignments_reject_sealed_append"} => @cycle_fleet,
    {"epic_assignment_results", "epic_assignment_results_reject_sealed_append"} => @cycle_fleet,
    {"epic_assignment_tasks", "epic_assignment_tasks_reject_sealed_append"} => @cycle_fleet
  }

  # Enum, domain and composite types that no table defines.
  @types %{"oban_job_state" => :core}

  @extensions %{
    "citext" => :core,
    "pg_trgm" => :core,
    "pgcrypto" => :core,
    "plpgsql" => :core
  }

  # Schemas no migration creates, so no baseline carries them. Each names who
  # creates it. The audit reads only `public` beyond this list.
  @external_schemas %{
    # The connectors bridge creates it at its own boot
    # (connectors/src/db/schema.ts); charter D28 forbids a migration doing so.
    # Barkpark.Connectors.Install reads it.
    "chat_bridge" => "connectors bridge"
  }

  @tables Map.merge(Map.new(@core_tables, &{&1, :core}), @owned_tables)
  @functions Map.merge(Map.new(@core_functions, &{&1, :core}), Map.new(@owned_functions))

  @doc "Every listed table and its owner."
  @spec tables() :: %{String.t() => owner()}
  def tables, do: @tables

  @doc "Every listed function signature and its owner."
  @spec functions() :: %{String.t() => owner()}
  def functions, do: @functions

  @doc "The triggers whose owner is not their table's owner."
  @spec trigger_owners() :: %{{String.t(), String.t()} => owner()}
  def trigger_owners, do: @trigger_owners

  @doc "Every listed free-standing type and its owner."
  @spec types() :: %{String.t() => owner()}
  def types, do: @types

  @doc "The schemas no migration creates, and who creates each."
  @spec external_schemas() :: %{String.t() => String.t()}
  def external_schemas, do: @external_schemas

  @doc "Every listed extension and its owner."
  @spec extensions() :: %{String.t() => owner()}
  def extensions, do: @extensions

  @doc "The tables a plugin or capability owns, as `%{table => owner}`."
  @spec owned_tables() :: %{String.t() => owner()}
  def owned_tables, do: @owned_tables

  @doc "The functions a plugin or capability owns, in drop order."
  @spec owned_functions() :: [String.t()]
  def owned_functions, do: Enum.map(@owned_functions, &elem(&1, 0))

  @doc "The triggers on core tables that a plugin or capability owns, as `{table, trigger}`."
  @spec owned_core_triggers() :: [{String.t(), String.t()}]
  def owned_core_triggers do
    for {{table, _} = key, _owner} <- @trigger_owners, Map.get(@tables, table) == :core do
      key
    end
    |> Enum.sort()
  end

  @doc """
  The owner of a trigger: its entry in `trigger_owners/0`, else its table's
  owner, else `:unowned`.
  """
  @spec trigger_owner(String.t(), String.t()) :: owner() | :unowned
  def trigger_owner(table, trigger) do
    Map.get_lazy(@trigger_owners, {table, trigger}, fn -> Map.get(@tables, table, :unowned) end)
  end

  @doc """
  True when `owner` is `required` or needs it switched on: every owner needs
  core, and a capability needs what `Barkpark.Capability` says it requires.
  """
  @spec depends_on?(owner(), owner()) :: boolean()
  def depends_on?(owner, owner), do: true
  def depends_on?(_owner, :core), do: true

  def depends_on?({:capability, name}, {:capability, required}),
    do: required in Capability.requires(name)

  def depends_on?(_owner, _required), do: false

  @schemas_sql """
  SELECT nspname FROM pg_namespace
  WHERE nspname NOT LIKE 'pg\\_%' AND nspname <> 'information_schema'
  """

  @tables_sql """
  SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
  """

  @functions_sql """
  SELECT p.proname || '(' || replace(oidvectortypes(p.proargtypes), ', ', ',') || ')'
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND NOT EXISTS (SELECT 1 FROM pg_depend d
                    WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
  """

  @types_sql """
  SELECT t.typname FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
  WHERE n.nspname = 'public' AND t.typtype IN ('e', 'd', 'c', 'r', 'm')
    AND NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.reltype = t.oid)
    AND NOT EXISTS (SELECT 1 FROM pg_depend d
                    WHERE d.classid = 'pg_type'::regclass AND d.objid = t.oid AND d.deptype = 'e')
  """

  @extensions_sql "SELECT extname FROM pg_extension"

  @free_sequences_sql """
  SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'S'
    AND NOT EXISTS (SELECT 1 FROM pg_depend d
                    WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid
                      AND d.deptype IN ('a', 'i'))
  """

  @triggers_sql """
  SELECT c.relname, t.tgname,
         p.proname || '(' || replace(oidvectortypes(p.proargtypes), ', ', ',') || ')'
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_proc p ON p.oid = t.tgfoid
  WHERE n.nspname = 'public' AND NOT t.tgisinternal
  """

  @doc """
  Reads the live catalog of `repo` and returns every object the manifest gives
  no owner, plus every trigger whose owners break the dependency rule in the
  moduledoc. `[]` means every object has exactly one owner.

  Extension members (the functions `pgcrypto` installs, say) belong to their
  extension. Indexes and constraints belong to their table, and a sequence
  that a column owns belongs to that column's table.
  """
  @spec audit(module()) :: [{atom(), String.t()}]
  def audit(repo) do
    unlisted(
      :unowned_schema,
      rows(repo, @schemas_sql),
      Map.put(@external_schemas, "public", :core)
    ) ++
      unlisted(:unowned_table, rows(repo, @tables_sql), @tables) ++
      unlisted(:unowned_function, rows(repo, @functions_sql), @functions) ++
      unlisted(:unowned_type, rows(repo, @types_sql), @types) ++
      unlisted(:unowned_extension, rows(repo, @extensions_sql), @extensions) ++
      unlisted(:unowned_sequence, rows(repo, @free_sequences_sql), %{}) ++
      trigger_problems(repo)
  end

  @doc """
  The listed objects `repo` does not have. On a database with every plugin
  and capability migrated this is `[]`; on one where an owner's objects were
  dropped it names them.
  """
  @spec missing(module()) :: [{atom(), String.t()}]
  def missing(repo) do
    absent(:table, @tables, rows(repo, @tables_sql)) ++
      absent(:function, @functions, rows(repo, @functions_sql)) ++
      absent(:type, @types, rows(repo, @types_sql)) ++
      absent(:extension, @extensions, rows(repo, @extensions_sql)) ++
      absent(
        :trigger,
        Map.new(@trigger_owners, fn {{t, g}, o} -> {t <> "." <> g, o} end),
        @triggers_sql
        |> repo.query!()
        |> Map.fetch!(:rows)
        |> Enum.map(fn [t, g, _] -> t <> "." <> g end)
      )
  end

  defp rows(repo, sql), do: sql |> repo.query!() |> Map.fetch!(:rows) |> Enum.map(&hd/1)

  defp unlisted(kind, names, listed) do
    names
    |> Enum.reject(&(&1 in listed or Map.has_key?(listed, &1)))
    |> Enum.sort()
    |> Enum.map(&{kind, &1})
  end

  defp absent(kind, listed, names) do
    present = MapSet.new(names)

    listed
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(present, &1))
    |> Enum.sort()
    |> Enum.map(&{kind, &1})
  end

  # A trigger on an unowned table is reported once, as that table.
  defp trigger_problems(repo) do
    for [table, trigger, function] <- repo.query!(@triggers_sql).rows,
        Map.has_key?(@tables, table),
        problem = trigger_problem(table, trigger, function),
        problem != nil do
      {problem, table <> "." <> trigger}
    end
    |> Enum.sort()
  end

  defp trigger_problem(table, trigger, function) do
    owner = trigger_owner(table, trigger)
    function_owner = Map.get(@functions, function)

    cond do
      not depends_on?(owner, Map.fetch!(@tables, table)) ->
        :trigger_outlives_table

      function_owner != nil and not depends_on?(owner, function_owner) ->
        :trigger_outlives_function

      true ->
        nil
    end
  end
end
