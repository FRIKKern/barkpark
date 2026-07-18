defmodule Barkpark.CycleFleet do
  @moduledoc """
  Profile-driven durable ledger for Codex Epic and Legendary cycles.

  A wave freezes inventory and experiment intent before fan-out. Legendary's
  capacity and build count are sealed later in an immutable post-pilot build
  plan. Assignments and terminal results reuse the append-only Epic ledger.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.Document
  alias Barkpark.CycleFleet.{AssignmentTask, BuildPlan, Profile, RuntimeAttempt, Wave}
  alias Barkpark.EpicFleet
  alias Barkpark.EpicFleet.{Assignment, Result}
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.{Recorder, Runtime}
  alias Barkpark.Tasks
  alias Barkpark.Tenancy.{Dataset, Project}

  @scope_fields [:workspace_id, :project_id, :epic_id, :wave_id]
  @experiment_rounds ~w(baseline diverge attack converge pilot)
  @outcome_keys %{
    shipped: :completed_unit_ids,
    stalled: :stalled_unit_ids,
    excluded: :excluded_unit_ids
  }

  @spec open_wave(map()) :: {:ok, Wave.t()} | {:error, Ecto.Changeset.t() | atom()}
  def open_wave(attrs) when is_map(attrs) do
    with {:ok, scope} <- normalize_scope(attrs),
         {:ok, profile} <- Profile.normalize(value(attrs, :profile, "epic")),
         {:ok, inventory} <- normalize_inventory(value(attrs, :inventory, [])),
         {:ok, plan} <- Profile.opening_plan(profile),
         {:ok, scale_contract} <-
           normalize_scale_contract(profile, value(attrs, :scale_contract), inventory),
         {:ok, experiment_contract} <-
           normalize_experiment_contract(profile, value(attrs, :experiment_contract)) do
      wave_attrs =
        Map.merge(scope, %{
          profile: profile,
          inventory: inventory,
          inventory_digest: digest(inventory),
          plan: stringify_keys(plan),
          plan_digest: digest(plan),
          experiment_contract: experiment_contract,
          scale_contract: scale_contract
        })

      wave_attrs
      |> Wave.insert_changeset()
      |> Repo.insert()
      |> reconcile_wave_insert(wave_attrs)
    end
  end

  @spec get_wave(map()) :: Wave.t() | nil
  def get_wave(scope) when is_map(scope) do
    case normalize_scope(scope) do
      {:ok, scope} -> get_wave_by_scope(scope)
      _ -> nil
    end
  end

  @spec seal_build_plan(map(), map()) ::
          {:ok, BuildPlan.t()} | {:error, Ecto.Changeset.t() | atom()}
  def seal_build_plan(scope, attrs) when is_map(scope) and is_map(attrs) do
    with %Wave{} = wave <- get_wave(scope),
         :ok <- validate_seal_ready(wave),
         capacity when is_integer(capacity) and capacity > 0 <-
           value(attrs, :proven_batch_capacity),
         failure_threshold when is_number(failure_threshold) <-
           value(attrs, :failure_threshold),
         true <- failure_threshold == value(wave.scale_contract, :failure_threshold),
         {:ok, golden_fixtures} <-
           normalize_golden_fixtures(value(attrs, :golden_fixtures)),
         {:ok, plan} <-
           Profile.plan(wave.profile, %{
             unit_count: length(wave.inventory),
             proven_batch_capacity: capacity
           }) do
      plan_attrs = %{
        wave_id: wave.id,
        proven_batch_capacity: capacity,
        plan: stringify_keys(plan),
        plan_digest: digest(plan),
        inventory_digest: wave.inventory_digest,
        chosen_format: value(attrs, :chosen_format),
        pilot_evidence: value(attrs, :pilot_evidence),
        pilot_evidence_revision: value(attrs, :pilot_evidence_revision),
        failure_rate: value(attrs, :failure_rate),
        failure_threshold: failure_threshold,
        golden_fixtures: golden_fixtures,
        quality_rubric: value(wave.scale_contract, :quality_rubric)
      }

      plan_attrs
      |> BuildPlan.insert_changeset()
      |> Repo.insert()
      |> reconcile_build_plan_insert(plan_attrs)
    else
      nil -> {:error, :wave_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_build_plan}
    end
  end

  @spec get_build_plan(Wave.t() | map()) :: BuildPlan.t() | nil
  def get_build_plan(%Wave{id: wave_id}), do: Repo.get_by(BuildPlan, wave_id: wave_id)

  def get_build_plan(scope) when is_map(scope) do
    case get_wave(scope) do
      %Wave{} = wave -> get_build_plan(wave)
      nil -> nil
    end
  end

  @spec create_assignment(map()) ::
          {:ok, Assignment.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_assignment(attrs) when is_map(attrs) do
    case get_wave(attrs) do
      nil ->
        {:error, :wave_not_found}

      %Wave{} = wave ->
        with {:ok, attrs} <- normalize_assignment_task_id(attrs),
             {:ok, attrs} <- resolve_replacement(attrs, wave),
             {:ok, plan} <- assignment_plan(attrs, wave),
             :ok <- validate_assignment_against_plan(attrs, plan, wave) do
          Repo.transaction(fn ->
            with {:ok, assignment, status} <-
                   attrs
                   |> put_attr(:cycle_wave_id, wave.id)
                   |> EpicFleet.create_assignment_with_status(),
                 {:ok, _binding} <-
                   preserve_assignment_task_binding(assignment, attrs, status) do
              assignment
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end)
          |> unwrap_assignment()
        end
    end
  end

  @doc "Freeze the server-owned Task bound to an existing CycleFleet assignment."
  @spec bind_assignment_task(Assignment.t() | Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, AssignmentTask.t()} | {:error, atom()}
  def bind_assignment_task(%Assignment{id: assignment_id}, task_id),
    do: bind_assignment_task(assignment_id, task_id)

  def bind_assignment_task(assignment_id, task_id)
      when is_binary(assignment_id) and is_binary(task_id) do
    with {:ok, task_id} <- cast_assignment_task_id(task_id) do
      Repo.transaction(fn ->
        authority =
          Repo.one(
            from(a in Assignment,
              join: w in Wave,
              on: w.id == a.cycle_wave_id and w.workspace_id == a.workspace_id,
              join: t in Document,
              on:
                t.id == ^task_id and t.type == "task" and
                  t.workspace_id == a.workspace_id and t.project_id == w.project_id,
              join: d in Dataset,
              on: d.id == t.dataset_id and d.project_id == w.project_id,
              where: a.id == ^assignment_id,
              lock: "FOR SHARE",
              select: %{assignment_id: a.id, task_id: t.id}
            )
          )

        case authority do
          nil ->
            Repo.rollback(:assignment_task_authority_not_found)

          attrs ->
            {inserted, _} =
              Repo.insert_all(AssignmentTask, [Map.put(attrs, :inserted_at, DateTime.utc_now())],
                on_conflict: :nothing
              )

            binding = Repo.get(AssignmentTask, assignment_id)

            cond do
              inserted == 1 -> binding
              binding && binding.task_id == task_id -> binding
              true -> Repo.rollback(:assignment_task_conflict)
            end
        end
      end)
    end
  end

  def bind_assignment_task(_assignment_id, _task_id),
    do: {:error, :assignment_task_authority_not_found}

  @doc """
  Authorize and start the one managed-Codex runtime attempt for a Task-bound
  assignment. Database authority is committed before Recorder opens a provider
  process, so a failed open is safely retryable against the same session.
  """
  @spec start_runtime_attempt(Assignment.t() | Ecto.UUID.t(), map(), map()) ::
          {:ok, %{attempt: RuntimeAttempt.t(), session: StudioChat.Session.t(), recorder: pid()}}
          | {:error, term()}
  def start_runtime_attempt(assignment, claim, opts \\ %{})

  def start_runtime_attempt(%Assignment{id: assignment_id}, claim, opts),
    do: start_runtime_attempt(assignment_id, claim, opts)

  def start_runtime_attempt(assignment_id, claim, opts)
      when is_binary(assignment_id) and is_map(claim) and is_map(opts) do
    recorder = value(opts, :recorder, Recorder)

    with {:ok, attempt} <- prepare_runtime_attempt(assignment_id, claim, opts),
         %StudioChat.Session{} = session <- StudioChat.get_session(attempt.session_id),
         {:ok, recorder_pid} <- recorder.ensure(recorder_opts(session, opts)) do
      {:ok, %{attempt: attempt, session: session, recorder: recorder_pid}}
    else
      nil -> {:error, :runtime_attempt_session_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def start_runtime_attempt(_assignment_id, _claim, _opts),
    do: {:error, :invalid_runtime_attempt}

  @doc """
  Freeze one assignment/session attempt after exact current-claim verification.
  Exact replays return the existing attempt without minting another session.
  """
  @spec prepare_runtime_attempt(Assignment.t() | Ecto.UUID.t(), map(), map()) ::
          {:ok, RuntimeAttempt.t()} | {:error, term()}
  def prepare_runtime_attempt(assignment, claim, opts \\ %{})

  def prepare_runtime_attempt(%Assignment{id: assignment_id}, claim, opts),
    do: prepare_runtime_attempt(assignment_id, claim, opts)

  def prepare_runtime_attempt(assignment_id, claim, opts)
      when is_binary(assignment_id) and is_map(claim) and is_map(opts) do
    with :ok <- managed_codex_attempt?(opts),
         {:ok, claim} <- normalize_attempt_claim(claim) do
      Repo.transaction(fn -> authorize_runtime_attempt(assignment_id, claim, opts) end)
      |> case do
        {:ok, %RuntimeAttempt{} = attempt} -> {:ok, attempt}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def prepare_runtime_attempt(_assignment_id, _claim, _opts),
    do: {:error, :invalid_runtime_attempt}

  @doc "Load the immutable runtime attempt bound to a Barkpark Studio session."
  @spec get_runtime_attempt_by_session(Ecto.UUID.t()) :: RuntimeAttempt.t() | nil
  def get_runtime_attempt_by_session(session_id) when is_binary(session_id),
    do: Repo.get_by(RuntimeAttempt, session_id: session_id)

  def get_runtime_attempt_by_session(_session_id), do: nil

  @doc "Derive the live Task claim authorized by an immutable runtime attempt."
  @spec current_runtime_attempt_attribution(RuntimeAttempt.t()) ::
          {:ok, map()} | {:error, term()}
  def current_runtime_attempt_attribution(%RuntimeAttempt{} = attempt) do
    with authority when not is_nil(authority) <-
           runtime_attempt_authority(attempt.assignment_id),
         true <- authority.task_id == attempt.task_id,
         claim when is_map(claim) <- get_in(authority.task_content || %{}, ["claim"]),
         epoch when is_integer(epoch) <- claim["epoch"],
         {:ok, fence} <-
           verify_runtime_attempt_claim(
             attempt,
             %{
               task_id: attempt.task_id,
               worker_id: attempt.task_worker_id,
               epoch: epoch,
               work_digest: attempt.task_work_digest
             },
             authority
           ) do
      {:ok,
       %{
         assignment_id: attempt.assignment_id,
         task: %{
           id: attempt.task_id,
           worker_id: fence.task_worker_id,
           epoch: fence.task_epoch,
           work_digest: fence.task_work_digest
         }
       }}
    else
      nil -> {:error, :runtime_attempt_authority_not_found}
      false -> {:error, :runtime_attempt_authority_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :task_not_claimed}
    end
  end

  def current_runtime_attempt_attribution(_attempt),
    do: {:error, :runtime_attempt_authority_not_found}

  @spec record_result(Assignment.t(), String.t(), map()) ::
          {:ok, Result.t()} | {:error, Ecto.Changeset.t() | atom()}
  def record_result(%Assignment{} = assignment, idempotency_key, attrs)
      when is_binary(idempotency_key) and is_map(attrs) do
    EpicFleet.record_result(assignment, idempotency_key, attrs)
  end

  @doc false
  @spec prepare_result_for_insert(Assignment.t(), map()) :: {:ok, map()} | {:error, atom()}
  def prepare_result_for_insert(%Assignment{} = assignment, attrs) when is_map(attrs) do
    case completed_build?(assignment, attrs) do
      true ->
        with :ok <- validate_completed_build_result(assignment, value(attrs, :payload)),
             {:ok, task} <- locked_semantic_task(assignment),
             {:ok, payload} <- semantic_build_payload(assignment, value(attrs, :payload), task) do
          {:ok, put_attr(attrs, :payload, payload)}
        end

      false ->
        with :ok <- validate_cycle_result(assignment, attrs), do: {:ok, attrs}
    end
  end

  @spec record_result(Assignment.t(), map()) ::
          {:ok, Result.t()} | {:error, Ecto.Changeset.t() | atom()}
  def record_result(%Assignment{} = assignment, attrs) when is_map(attrs) do
    case value(attrs, :idempotency_key) do
      key when is_binary(key) -> record_result(assignment, key, attrs)
      _ -> {:error, :idempotency_key_required}
    end
  end

  defdelegate get_assignment(id), to: EpicFleet
  defdelegate get_result(assignment), to: EpicFleet
  @spec list_assignments(map()) :: [Assignment.t()]
  def list_assignments(scope) when is_map(scope) do
    case get_wave(scope) do
      %Wave{id: wave_id} -> EpicFleet.list_cycle_assignments(wave_id)
      nil -> []
    end
  end

  @doc "Fetch one logical assignment id inside an exact cycle scope."
  @spec get_assignment(map(), String.t()) :: Assignment.t() | nil
  def get_assignment(scope, assignment_id) when is_map(scope) and is_binary(assignment_id) do
    Enum.find(list_assignments(scope), &(&1.assignment_id == assignment_id))
  end

  @spec reduce(map()) :: {:ok, map()} | {:error, atom()}
  def reduce(scope) when is_map(scope) do
    case get_wave(scope) do
      %Wave{} = wave -> EpicFleet.reduce_cycle(wave.id, effective_plan(wave))
      nil -> {:error, :wave_not_found}
    end
  end

  @doc "Reduce exact unit, experiment, shard, capacity, and retry accounting."
  @spec reconcile(map()) :: {:ok, map()} | {:error, atom()}
  def reconcile(scope) when is_map(scope) do
    with %Wave{} = wave <- get_wave(scope) do
      rows = scope |> list_assignments() |> Enum.map(&{&1, EpicFleet.get_result(&1)})
      live_rows = exclude_replaced_rows(rows)
      inventory_ids = wave.inventory |> Enum.map(&unit_id/1) |> MapSet.new()
      build_rows = Enum.filter(live_rows, fn {assignment, _} -> assignment.phase == "build" end)

      experiment_rows =
        Enum.filter(live_rows, fn {assignment, _} -> assignment.phase == "experiment" end)

      assigned_ids =
        Enum.flat_map(build_rows, fn {assignment, _} -> snapshot_units(assignment) end)

      assigned_set = MapSet.new(assigned_ids)
      duplicate_ids = duplicates(assigned_ids)
      unknown_assignments = MapSet.difference(assigned_set, inventory_ids)
      outcomes = outcome_sets(build_rows)
      accounted = outcomes |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)
      unknown_outcomes = MapSet.difference(accounted, inventory_ids)
      outcome_overlap = overlaps(outcomes)
      ownership_violations = outcome_ownership_violations(build_rows)
      build_plan = get_build_plan(wave)

      invalid_build_assignments =
        invalid_build_assignment_ids(build_rows, inventory_ids, build_plan)

      invalid_build_results = invalid_build_result_ids(build_rows)
      unassigned = MapSet.difference(inventory_ids, assigned_set)
      unaccounted = MapSet.difference(inventory_ids, accounted)
      experiment = experiment_reconciliation(experiment_rows, wave)
      {:ok, reduced} = EpicFleet.reduce_cycle(wave.id, effective_plan(wave))
      fleet_complete? = fleet_complete?(reduced.fleet)

      exact? =
        Enum.all?(
          [
            duplicate_ids,
            unknown_assignments,
            unknown_outcomes,
            outcome_overlap,
            ownership_violations,
            invalid_build_assignments,
            invalid_build_results,
            unassigned,
            unaccounted
          ],
          &MapSet.equal?(&1, MapSet.new())
        ) and experiment.complete? and fleet_complete? and
          (wave.profile == "epic" or not is_nil(build_plan))

      summary = %{
        profile: wave.profile,
        scope: Map.take(wave, @scope_fields),
        wave_revision: wave.id,
        inventory_digest: wave.inventory_digest,
        plan_digest: effective_plan_digest(wave),
        scale_contract: wave.scale_contract,
        inventory_count: MapSet.size(inventory_ids),
        planned_builders: get_in(effective_plan(wave), ["build", "planned"]),
        assigned_count: MapSet.size(MapSet.intersection(assigned_set, inventory_ids)),
        assigned_occurrences: length(assigned_ids),
        shipped_count: MapSet.size(outcomes.shipped),
        stalled_count: MapSet.size(outcomes.stalled),
        excluded_count: MapSet.size(outcomes.excluded),
        duplicate_assignment_unit_ids: sorted(duplicate_ids),
        unknown_assignment_unit_ids: sorted(unknown_assignments),
        unknown_outcome_unit_ids: sorted(unknown_outcomes),
        outcome_overlap_unit_ids: sorted(outcome_overlap),
        outcome_ownership_violation_unit_ids: sorted(ownership_violations),
        invalid_build_assignment_ids: sorted(invalid_build_assignments),
        invalid_build_result_assignment_ids: sorted(invalid_build_results),
        unassigned_unit_ids: sorted(unassigned),
        unaccounted_unit_ids: sorted(unaccounted),
        experiment: experiment,
        fleet_complete: fleet_complete?,
        fleet_counts: fleet_counts(reduced.fleet),
        capacity: %{
          sealed: not is_nil(build_plan),
          proven_batch_capacity: build_plan && build_plan.proven_batch_capacity,
          chosen_format: build_plan && build_plan.chosen_format,
          failure_rate: build_plan && build_plan.failure_rate,
          failure_threshold: build_plan && build_plan.failure_threshold,
          golden_fixtures: build_plan && build_plan.golden_fixtures,
          quality_rubric: build_plan && build_plan.quality_rubric
        },
        exact: exact?
      }

      {:ok, Map.put(summary, :reconciliation_digest, digest(summary))}
    else
      nil -> {:error, :wave_not_found}
    end
  end

  @doc "Return the canonical reader/validator projection for one cycle wave."
  @spec projection(map()) :: {:ok, map()} | {:error, atom()}
  def projection(scope) when is_map(scope) do
    with {:ok, reconciliation} <- reconcile(scope),
         {:ok, fleet} <- reduce(scope) do
      {:ok,
       %{
         cycle_ledger: reconciliation,
         fleet: fleet.fleet,
         assignment_attributions: assignment_attributions(scope),
         authority: %{
           kind: "barkpark_cycle_fleet",
           workspace_id: reconciliation.scope.workspace_id,
           project_id: reconciliation.scope.project_id,
           epic_id: reconciliation.scope.epic_id,
           wave_id: reconciliation.scope.wave_id,
           wave_revision: reconciliation.wave_revision
         }
       }}
    end
  end

  @doc "Project the immutable retrieval attribution seed for every assignment in one cycle wave."
  @spec assignment_attributions(map()) :: [map()]
  def assignment_attributions(scope) when is_map(scope) do
    scope
    |> list_assignments()
    |> Enum.sort_by(&{&1.inserted_at, &1.id})
    |> Enum.map(&assignment_attribution/1)
  end

  @doc "Project one cycle assignment's immutable retrieval attribution seed."
  @spec assignment_attribution(Assignment.t()) :: map()
  def assignment_attribution(%Assignment{} = assignment) do
    %{
      cycle_assignment_id: assignment.id,
      cycle_wave_id: assignment.cycle_wave_id,
      assignment_id: assignment.assignment_id,
      unit_ids: assignment.unit_ids,
      inventory_digest: assignment.inventory_digest,
      snapshot_digest: assignment.snapshot_digest
    }
  end

  @spec profile_plan(String.t() | atom(), map()) :: {:ok, map()} | {:error, atom()}
  def profile_plan(profile, inputs \\ %{}), do: Profile.plan(profile, inputs)

  @spec digest(term()) :: String.t()
  def digest(term), do: EpicFleet.digest(term)

  defp reconcile_wave_insert({:ok, wave}, _attrs), do: {:ok, wave}

  defp reconcile_wave_insert({:error, changeset}, attrs) do
    existing = get_wave_by_scope(Map.take(attrs, @scope_fields))

    cond do
      is_nil(existing) -> {:error, changeset}
      wave_replay?(existing, attrs) -> {:ok, existing}
      true -> {:error, :wave_conflict}
    end
  end

  defp get_wave_by_scope(%{project_id: project_id} = scope) when is_binary(project_id) do
    Repo.one(
      from w in Wave,
        where:
          w.workspace_id == ^scope.workspace_id and w.project_id == ^project_id and
            w.epic_id == ^scope.epic_id and w.wave_id == ^scope.wave_id
    )
  end

  defp get_wave_by_scope(%{project_id: nil} = scope) do
    Repo.one(
      from w in Wave,
        where:
          w.workspace_id == ^scope.workspace_id and is_nil(w.project_id) and
            w.epic_id == ^scope.epic_id and w.wave_id == ^scope.wave_id
    )
  end

  defp reconcile_build_plan_insert({:ok, plan}, _attrs), do: {:ok, plan}

  defp reconcile_build_plan_insert({:error, changeset}, attrs) do
    existing = Repo.get_by(BuildPlan, wave_id: attrs.wave_id)

    cond do
      is_nil(existing) -> {:error, changeset}
      build_plan_replay?(existing, attrs) -> {:ok, existing}
      true -> {:error, :build_plan_conflict}
    end
  end

  defp wave_replay?(wave, attrs) do
    wave.profile == attrs.profile and wave.inventory_digest == attrs.inventory_digest and
      wave.plan_digest == attrs.plan_digest and
      wave.experiment_contract == attrs.experiment_contract and
      wave.scale_contract == attrs.scale_contract
  end

  defp build_plan_replay?(plan, attrs) do
    Enum.all?(
      ~w(proven_batch_capacity plan_digest inventory_digest chosen_format pilot_evidence pilot_evidence_revision failure_rate failure_threshold golden_fixtures quality_rubric)a,
      &(Map.get(plan, &1) == Map.get(attrs, &1))
    )
  end

  defp assignment_plan(attrs, wave) do
    if value(attrs, :phase) == "build" and wave.profile == "legendary" do
      case get_build_plan(wave) do
        %BuildPlan{plan: plan} -> {:ok, plan}
        nil -> {:error, :build_plan_not_sealed}
      end
    else
      {:ok, effective_plan(wave)}
    end
  end

  defp validate_assignment_against_plan(attrs, plan, wave) do
    config = Map.get(plan, value(attrs, :phase))
    phase = value(attrs, :phase)
    build_plan = get_build_plan(wave)

    cond do
      not is_map(config) ->
        {:error, :phase_not_in_profile}

      value(attrs, :agent_type) != Map.get(config, "agent_type") ->
        {:error, :agent_type_not_in_profile}

      value(attrs, :effort) != Map.get(config, "effort") ->
        {:error, :effort_not_in_profile}

      phase == "experiment" and not is_nil(build_plan) ->
        {:error, :experiment_phase_sealed}

      is_nil(value(attrs, :replaces_assignment_id)) and
        not existing_logical_assignment?(wave, attrs) and
          live_phase_count(wave, phase) >= Map.fetch!(config, "planned") ->
        {:error, :phase_assignment_capacity_exhausted}

      phase == "build" and not is_nil(build_plan) ->
        validate_build_assignment(attrs, wave, build_plan.proven_batch_capacity)

      phase == "build" ->
        validate_build_assignment(attrs, wave, nil)

      true ->
        :ok
    end
  end

  defp validate_build_assignment(attrs, wave, capacity) do
    inventory_ids = wave.inventory |> Enum.map(&unit_id/1) |> MapSet.new()

    with {:ok, unit_ids} <- strict_string_list(value(value(attrs, :snapshot, %{}), :unit_ids)),
         true <- unit_ids != [] || {:error, :invalid_build_unit_ids},
         true <-
           length(unit_ids) == MapSet.size(MapSet.new(unit_ids)) ||
             {:error, :duplicate_build_unit_ids},
         true <-
           (is_nil(capacity) or length(unit_ids) <= capacity) ||
             {:error, :proven_batch_capacity_exceeded},
         true <-
           MapSet.subset?(MapSet.new(unit_ids), inventory_ids) ||
             {:error, :build_unit_not_in_inventory} do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_build_unit_ids}
    end
  end

  defp live_phase_count(wave, phase) do
    assignments = EpicFleet.list_cycle_assignments(wave.id)

    replaced_ids =
      assignments
      |> Enum.map(& &1.replaces_assignment_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.count(assignments, fn assignment ->
      assignment.phase == phase and not MapSet.member?(replaced_ids, assignment.id)
    end)
  end

  defp existing_logical_assignment?(wave, attrs) do
    assignment_id = value(attrs, :assignment_id)

    is_binary(assignment_id) and
      Repo.exists?(
        from assignment in Assignment,
          where:
            assignment.cycle_wave_id == ^wave.id and
              assignment.assignment_id == ^assignment_id
      )
  end

  defp normalize_scope(attrs) do
    scope = Map.new(@scope_fields, &{&1, value(attrs, &1)})

    required = Map.take(scope, [:workspace_id, :epic_id, :wave_id])
    project_id = scope.project_id

    cond do
      not Enum.all?(required, fn {_key, item} -> is_binary(item) and item != "" end) ->
        {:error, :invalid_scope}

      is_nil(project_id) ->
        {:ok, scope}

      not is_binary(project_id) or project_id == "" ->
        {:error, :invalid_scope}

      Repo.exists?(
        from p in Project, where: p.id == ^project_id and p.workspace_id == ^scope.workspace_id
      ) ->
        {:ok, scope}

      true ->
        {:error, :project_scope_mismatch}
    end
  end

  defp normalize_scale_contract("epic", nil, _inventory), do: {:ok, %{}}

  defp normalize_scale_contract("epic", contract, _inventory) when contract in [%{}, nil],
    do: {:ok, %{}}

  defp normalize_scale_contract("legendary", contract, inventory) when is_map(contract) do
    contract = stringify_keys(contract)
    target_surfaces = contract["target_surfaces"]
    exclusions = contract["excluded_inventory"]
    rubric = contract["quality_rubric"]
    threshold = contract["failure_threshold"]

    valid? =
      length(inventory) >= 15 and
        nonempty?(contract["unit_definition"]) and
        contract["unit_count"] == length(inventory) and
        nonempty?(contract["inventory_evidence"]) and
        is_list(target_surfaces) and target_surfaces != [] and
        Enum.all?(target_surfaces, &nonempty?/1) and
        is_integer(contract["concurrency_width"]) and contract["concurrency_width"] > 0 and
        contract["minimum_multiplier"] == 5 and
        contract["build_formula"] ==
          "max(15, ceil(unit_count / proven_batch_capacity))" and
        is_list(exclusions) and Enum.all?(exclusions, &valid_exclusion?/1) and
        is_map(rubric) and map_size(rubric) > 0 and
        is_number(threshold) and threshold >= 0

    if valid?, do: {:ok, contract}, else: {:error, :invalid_scale_contract}
  end

  defp normalize_scale_contract(_profile, _contract, _inventory),
    do: {:error, :invalid_scale_contract}

  defp normalize_golden_fixtures(fixtures) when is_list(fixtures) do
    if fixtures != [] and Enum.all?(fixtures, &nonempty?/1) do
      {:ok, fixtures |> Enum.uniq() |> Enum.sort()}
    else
      {:error, :invalid_golden_fixtures}
    end
  end

  defp normalize_golden_fixtures(_fixtures), do: {:error, :invalid_golden_fixtures}

  defp normalize_inventory(inventory) when is_list(inventory) do
    normalized =
      Enum.map(inventory, fn
        id when is_binary(id) -> %{"unit_id" => id}
        unit when is_map(unit) -> stringify_keys(unit)
        other -> other
      end)

    ids = Enum.map(normalized, &unit_id/1)

    cond do
      Enum.any?(ids, &(not strict_id?(&1))) -> {:error, :invalid_inventory}
      length(ids) != MapSet.size(MapSet.new(ids)) -> {:error, :duplicate_inventory_unit}
      true -> {:ok, Enum.sort_by(normalized, &unit_id/1)}
    end
  end

  defp normalize_inventory(_inventory), do: {:error, :invalid_inventory}

  defp default_experiment_contract("legendary") do
    %{
      "rounds" => @experiment_rounds,
      "required_results_per_round" => 3,
      "selection_required" => true
    }
  end

  defp default_experiment_contract(_profile), do: %{}

  defp normalize_experiment_contract(profile, nil),
    do: {:ok, default_experiment_contract(profile)}

  defp normalize_experiment_contract(profile, contract) do
    canonical = default_experiment_contract(profile)

    if stringify_keys(contract) == canonical,
      do: {:ok, canonical},
      else: {:error, :invalid_experiment_contract}
  end

  defp snapshot_units(assignment) do
    case strict_string_list(value(assignment.snapshot, :unit_ids)) do
      {:ok, unit_ids} -> unit_ids
      {:error, _} -> []
    end
  end

  defp outcome_sets(rows) do
    Enum.reduce(rows, %{shipped: MapSet.new(), stalled: MapSet.new(), excluded: MapSet.new()}, fn
      {_assignment, %Result{status: "completed", payload: payload}}, acc ->
        Enum.reduce(@outcome_keys, acc, fn {outcome, payload_key}, current ->
          ids =
            case strict_string_list(value(payload, payload_key)) do
              {:ok, unit_ids} -> MapSet.new(unit_ids)
              {:error, _} -> MapSet.new()
            end

          Map.update!(current, outcome, &MapSet.union(&1, ids))
        end)

      _, acc ->
        acc
    end)
  end

  defp experiment_reconciliation(_rows, %Wave{profile: "epic"}),
    do: %{required?: false, complete?: true, round_counts: %{}, missing_rounds: []}

  defp experiment_reconciliation(rows, %Wave{experiment_contract: contract}) do
    rounds = Map.fetch!(contract, "rounds")
    required = Map.fetch!(contract, "required_results_per_round")

    completed =
      Enum.flat_map(rows, fn
        {_assignment, %Result{status: "completed", payload: payload}} ->
          round = value(payload, :round)
          if round in rounds, do: [round], else: []

        _ ->
          []
      end)

    counts = Enum.frequencies(completed)
    missing = Enum.filter(rounds, &(Map.get(counts, &1, 0) != required))

    %{
      required?: true,
      complete?: missing == [],
      round_counts: Map.new(rounds, &{&1, Map.get(counts, &1, 0)}),
      missing_rounds: missing
    }
  end

  defp outcome_ownership_violations(rows) do
    Enum.reduce(rows, MapSet.new(), fn
      {assignment, %Result{status: "completed", payload: payload}}, violations ->
        owned = MapSet.new(snapshot_units(assignment))

        reported =
          @outcome_keys
          |> Map.values()
          |> Enum.flat_map(fn key ->
            case strict_string_list(value(payload, key)) do
              {:ok, unit_ids} -> unit_ids
              {:error, _} -> []
            end
          end)
          |> MapSet.new()

        MapSet.union(violations, MapSet.difference(reported, owned))

      _, violations ->
        violations
    end)
  end

  defp overlaps(outcomes) do
    MapSet.union(
      MapSet.intersection(outcomes.shipped, outcomes.stalled),
      MapSet.union(
        MapSet.intersection(outcomes.shipped, outcomes.excluded),
        MapSet.intersection(outcomes.stalled, outcomes.excluded)
      )
    )
  end

  defp exclude_replaced_rows(rows) do
    replaced_ids =
      rows
      |> Enum.map(fn {assignment, _result} -> assignment.replaces_assignment_id end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.reject(rows, fn {assignment, _result} -> MapSet.member?(replaced_ids, assignment.id) end)
  end

  defp validate_seal_ready(%Wave{profile: "legendary"} = wave) do
    rows = Enum.map(list_assignments(wave), &{&1, EpicFleet.get_result(&1)})
    experiment = experiment_reconciliation(exclude_replaced_rows(rows), wave)

    with {:ok, %{fleet: %{experiment: fleet}}} <-
           EpicFleet.reduce_cycle(wave.id, effective_plan(wave)) do
      if experiment.complete? and fleet.completed == fleet.planned and fleet.missing == 0 and
           fleet.invalid_assignments == 0 and fleet.terminal_counts.invalid == 0 and
           fleet.unresolved_failures == 0 and fleet.unresolved_missing == 0 do
        :ok
      else
        {:error, :experiment_assignments_incomplete}
      end
    end
  end

  defp validate_seal_ready(%Wave{}), do: {:error, :seal_not_supported}

  defp resolve_replacement(attrs, wave) do
    case value(attrs, :replaces_assignment_id) do
      nil ->
        {:ok, attrs}

      assignment_id when is_binary(assignment_id) ->
        case replacement_predecessor(wave, assignment_id) do
          %Assignment{} = predecessor ->
            with :ok <- validate_immutable_replacement(attrs, wave, predecessor) do
              {:ok, put_attr(attrs, :replaces_assignment_id, predecessor.id)}
            end

          nil ->
            {:error, :replacement_not_found}
        end

      _ ->
        {:error, :replacement_not_found}
    end
  end

  defp replacement_predecessor(wave, assignment_id) do
    Repo.get_by(Assignment, cycle_wave_id: wave.id, assignment_id: assignment_id) ||
      legacy_flat_predecessor(wave, assignment_id)
  end

  # A project-scoped request never searches outside its exact wave. The only
  # deliberate fallback is a projectless wave resolving a same-workspace legacy
  # predecessor, which makes the immutable contract mismatch observable without
  # leaking a predecessor from another project.
  defp legacy_flat_predecessor(%Wave{project_id: nil} = wave, assignment_id) do
    Repo.one(
      from assignment in Assignment,
        where:
          assignment.workspace_id == ^wave.workspace_id and
            assignment.epic_id == ^wave.epic_id and assignment.wave_id == ^wave.wave_id and
            assignment.assignment_id == ^assignment_id and is_nil(assignment.cycle_wave_id)
    )
  end

  defp legacy_flat_predecessor(_wave, _assignment_id), do: nil

  defp validate_immutable_replacement(attrs, wave, predecessor) do
    cond do
      value(attrs, :phase) != predecessor.phase ->
        {:error, :replacement_phase_mismatch}

      value(attrs, :agent_type) != predecessor.agent_type ->
        {:error, :replacement_agent_type_mismatch}

      predecessor.cycle_wave_id != wave.id ->
        {:error, :replacement_contract_mismatch}

      true ->
        :ok
    end
  end

  defp validate_cycle_result(%Assignment{phase: "build"} = assignment, attrs) do
    if value(attrs, :status) == "completed" do
      validate_completed_build_result(assignment, value(attrs, :payload))
    else
      :ok
    end
  end

  defp validate_cycle_result(%Assignment{}, _attrs), do: :ok

  defp completed_build?(%Assignment{phase: "build"}, attrs),
    do: value(attrs, :status) == "completed"

  defp completed_build?(%Assignment{}, _attrs), do: false

  defp locked_semantic_task(%Assignment{id: assignment_id}) do
    case Repo.get(AssignmentTask, assignment_id) do
      nil ->
        {:error, :semantic_receipt_task_not_bound}

      %AssignmentTask{task_id: task_id} ->
        case Repo.one(
               from(t in Document,
                 where: t.id == ^task_id and t.type == "task",
                 lock: "FOR UPDATE"
               )
             ) do
          nil -> {:error, :semantic_receipt_task_not_found}
          %Document{} = task -> {:ok, task}
        end
    end
  end

  defp semantic_task(%Assignment{id: assignment_id}) do
    with %AssignmentTask{task_id: task_id} <- Repo.get(AssignmentTask, assignment_id),
         %Document{} = task <- Repo.get_by(Document, id: task_id, type: "task") do
      {:ok, task}
    else
      nil -> {:error, :semantic_receipt_task_not_bound}
    end
  end

  defp semantic_build_payload(assignment, payload, task) when is_map(payload) do
    with :ok <- validate_completed_build_result(assignment, payload),
         {:ok, task_truth} <- semantic_task_truth(assignment, task),
         {:ok, outcomes} <- build_outcomes(payload) do
      receipts =
        assignment
        |> snapshot_units()
        |> Enum.sort()
        |> Enum.map(fn unit_id ->
          disposition = Map.fetch!(outcomes, unit_id)

          receipt =
            task_truth
            |> Map.merge(%{
              "unit_id" => unit_id,
              "disposition" => disposition
            })

          Map.put(receipt, "receipt_hash", EpicFleet.canonical_digest(receipt))
        end)

      with :ok <- validate_submitted_receipts(value(payload, :semantic_receipts), receipts) do
        canonical_payload =
          payload
          |> stringify_keys()
          |> Map.drop([
            "semantic_receipts",
            "semantic_receipt_version",
            "semantic_receipt_index_hash",
            "terminal_payload_digest"
          ])

        terminal_payload_digest = EpicFleet.canonical_digest(canonical_payload)
        receipt_hashes = Enum.map(receipts, &Map.fetch!(&1, "receipt_hash"))

        receipt_index_hash =
          EpicFleet.canonical_digest(%{
            "version" => "semantic_receipt-index-v1",
            "terminal_payload_digest" => terminal_payload_digest,
            "receipt_hashes" => receipt_hashes
          })

        {:ok,
         canonical_payload
         |> Map.merge(%{
           "semantic_receipt_version" => "semantic_receipt-v1",
           "semantic_receipts" => receipts,
           "semantic_receipt_index_hash" => receipt_index_hash,
           "terminal_payload_digest" => terminal_payload_digest
         })}
      end
    end
  end

  defp semantic_build_payload(_assignment, _payload, _task),
    do: {:error, :invalid_build_outcome_unit_ids}

  defp semantic_task_truth(assignment, %Document{} = task) do
    content = task.content || %{}
    criteria = Map.get(content, "acceptance_criteria")
    claim = Map.get(content, "claim") || %{}
    wave = Repo.get(Wave, assignment.cycle_wave_id)

    cond do
      is_nil(wave) or task.workspace_id != assignment.workspace_id or
          task.project_id != wave.project_id ->
        {:error, :semantic_receipt_foreign_task}

      Map.get(content, "lifecycle_status") != "done" ->
        {:error, :semantic_receipt_task_not_done}

      not (is_binary(task.rev) and String.trim(task.rev) != "") ->
        {:error, :semantic_receipt_task_revision_required}

      not (is_list(criteria) and criteria != []) ->
        {:error, :semantic_receipt_criteria_required}

      not Enum.all?(criteria, &valid_semantic_criterion?/1) ->
        {:error, :semantic_receipt_criteria_unmet}

      not (is_binary(Map.get(claim, "worker")) and
             String.trim(Map.get(claim, "worker")) != "" and
             is_integer(Map.get(claim, "epoch")) and Map.get(claim, "epoch") > 0) ->
        {:error, :semantic_receipt_claim_required}

      true ->
        {:ok,
         %{
           "assignment_id" => assignment.id,
           "ownership" => %{
             "assignment_id" => assignment.id,
             "assignment_key" => assignment.assignment_id,
             "cycle_wave_id" => assignment.cycle_wave_id,
             "snapshot_digest" => assignment.snapshot_digest,
             "workspace_id" => assignment.workspace_id,
             "project_id" => wave.project_id,
             "dataset_id" => task.dataset_id
           },
           "task_id" => task.id,
           "task_doc_id" => task.doc_id,
           "task_rev" => task.rev,
           "lifecycle_status" => "done",
           "criteria" => Enum.map(criteria, &semantic_criterion/1),
           "claim" => %{
             "worker" => Map.fetch!(claim, "worker"),
             "epoch" => Map.fetch!(claim, "epoch")
           }
         }}
    end
  end

  defp valid_semantic_criterion?(criterion) when is_map(criterion) do
    nonempty?(value(criterion, :criterion)) and value(criterion, :met) == true and
      nonempty?(value(criterion, :evidence))
  end

  defp valid_semantic_criterion?(_criterion), do: false

  defp semantic_criterion(criterion) do
    %{
      "criterion" => value(criterion, :criterion),
      "met" => true,
      "evidence" => value(criterion, :evidence)
    }
  end

  defp validate_submitted_receipts(receipts, expected) when is_list(receipts) do
    normalized = Enum.map(receipts, &stringify_keys/1)
    unit_ids = Enum.map(normalized, &value(&1, :unit_id))

    cond do
      length(unit_ids) != MapSet.size(MapSet.new(unit_ids)) ->
        {:error, :semantic_receipt_duplicate_unit}

      length(normalized) != length(expected) ->
        {:error, :semantic_receipt_count_mismatch}

      true ->
        expected_by_unit = Map.new(expected, &{Map.fetch!(&1, "unit_id"), &1})

        Enum.reduce_while(normalized, :ok, fn submitted, :ok ->
          submitted_claim = value(submitted, :claim, %{})

          case Map.fetch(expected_by_unit, value(submitted, :unit_id)) do
            :error ->
              {:halt, {:error, :semantic_receipt_foreign_unit}}

            {:ok, canonical} ->
              without_hash = Map.delete(canonical, "receipt_hash")
              submitted_hash = Map.get(submitted, "receipt_hash")

              cond do
                not is_map(submitted_claim) ->
                  {:halt, {:error, :semantic_receipt_invalid_claim}}

                value(submitted, :task_id) != Map.fetch!(canonical, "task_id") or
                  value(submitted, :task_doc_id) != Map.fetch!(canonical, "task_doc_id") or
                    value(submitted_claim, :worker) !=
                      get_in(canonical, ["claim", "worker"]) ->
                  {:halt, {:error, :semantic_receipt_foreign_task}}

                value(submitted, :task_rev) != Map.fetch!(canonical, "task_rev") or
                    value(submitted_claim, :epoch) !=
                      get_in(canonical, ["claim", "epoch"]) ->
                  {:halt, {:error, :semantic_receipt_stale_task}}

                Map.drop(submitted, ["receipt_hash"]) != without_hash ->
                  {:halt, {:error, :semantic_receipt_contradiction}}

                not is_nil(submitted_hash) and
                    submitted_hash != Map.fetch!(canonical, "receipt_hash") ->
                  {:halt, {:error, :semantic_receipt_hash_mismatch}}

                true ->
                  {:cont, :ok}
              end
          end
        end)
    end
  end

  defp validate_submitted_receipts(_receipts, _expected),
    do: {:error, :semantic_receipts_required}

  defp build_outcomes(payload) do
    with {:ok, shipped} <- strict_string_list(value(payload, :completed_unit_ids)),
         {:ok, stalled} <- strict_string_list(value(payload, :stalled_unit_ids)),
         {:ok, excluded} <- strict_string_list(value(payload, :excluded_unit_ids)) do
      {:ok,
       Enum.reduce(
         [shipped: shipped, stalled: stalled, excluded: excluded],
         %{},
         fn {disposition, ids}, acc ->
           Enum.reduce(ids, acc, &Map.put(&2, &1, Atom.to_string(disposition)))
         end
       )}
    end
  end

  defp validate_completed_build_result(assignment, payload) when is_map(payload) do
    owned = snapshot_units(assignment)

    with {:ok, shipped} <- strict_string_list(value(payload, :completed_unit_ids)),
         {:ok, stalled} <- strict_string_list(value(payload, :stalled_unit_ids)),
         {:ok, excluded} <- strict_string_list(value(payload, :excluded_unit_ids)),
         outcomes = shipped ++ stalled ++ excluded,
         true <-
           length(outcomes) == MapSet.size(MapSet.new(outcomes)) ||
             {:error, :build_outcome_overlap},
         true <-
           MapSet.new(outcomes) == MapSet.new(owned) ||
             {:error, :build_outcomes_do_not_partition_assignment} do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_build_outcome_unit_ids}
    end
  end

  defp validate_completed_build_result(_assignment, _payload),
    do: {:error, :invalid_build_outcome_unit_ids}

  defp invalid_build_assignment_ids(rows, inventory_ids, build_plan) do
    capacity = build_plan && build_plan.proven_batch_capacity

    Enum.reduce(rows, MapSet.new(), fn {assignment, _result}, invalid ->
      case strict_string_list(value(assignment.snapshot, :unit_ids)) do
        {:ok, unit_ids} ->
          valid? =
            unit_ids != [] and length(unit_ids) == MapSet.size(MapSet.new(unit_ids)) and
              (is_nil(capacity) or length(unit_ids) <= capacity) and
              MapSet.subset?(MapSet.new(unit_ids), inventory_ids)

          if valid?, do: invalid, else: MapSet.put(invalid, assignment.assignment_id)

        {:error, _} ->
          MapSet.put(invalid, assignment.assignment_id)
      end
    end)
  end

  defp invalid_build_result_ids(rows) do
    Enum.reduce(rows, MapSet.new(), fn
      {assignment, %Result{status: "completed", payload: payload}}, invalid ->
        with {:ok, task} <- semantic_task(assignment),
             {:ok, expected} <- semantic_build_payload(assignment, payload, task),
             true <- expected == stringify_keys(payload) do
          invalid
        else
          _ -> MapSet.put(invalid, assignment.assignment_id)
        end

      _, invalid ->
        invalid
    end)
  end

  defp fleet_complete?(fleet) when is_map(fleet) and map_size(fleet) > 0 do
    Enum.all?(fleet, fn {_phase, phase} ->
      phase.completed == phase.planned and phase.missing == 0 and
        phase.invalid_assignments == 0 and phase.terminal_counts.invalid == 0 and
        phase.unresolved_failures == 0 and phase.unresolved_missing == 0
    end)
  end

  defp fleet_complete?(_fleet), do: false

  defp fleet_counts(fleet) when is_map(fleet) do
    Enum.reduce(
      fleet,
      %{
        planned: 0,
        started: 0,
        completed: 0,
        failed: 0,
        missing: 0,
        invalid_assignments: 0,
        invalid_results: 0
      },
      fn {_phase, phase}, counts ->
        %{
          planned: counts.planned + phase.planned,
          started: counts.started + phase.started,
          completed: counts.completed + phase.completed,
          failed: counts.failed + phase.failed,
          missing: counts.missing + phase.missing,
          invalid_assignments: counts.invalid_assignments + phase.invalid_assignments,
          invalid_results: counts.invalid_results + phase.terminal_counts.invalid
        }
      end
    )
  end

  defp valid_exclusion?(exclusion) when is_map(exclusion) do
    nonempty?(value(exclusion, :unit_id)) and nonempty?(value(exclusion, :reason))
  end

  defp valid_exclusion?(_exclusion), do: false

  defp nonempty?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonempty?(_value), do: false

  defp duplicates(ids) do
    ids
    |> Enum.frequencies()
    |> Enum.reduce(MapSet.new(), fn
      {id, count}, acc when count > 1 -> MapSet.put(acc, id)
      _, acc -> acc
    end)
  end

  defp effective_plan(wave), do: (get_build_plan(wave) || wave).plan
  defp effective_plan_digest(wave), do: (get_build_plan(wave) || wave).plan_digest

  defp managed_codex_attempt?(opts) do
    case {value(opts, :provider, "codex"), value(opts, :execution_target, "managed"),
          value(opts, :runtime_surface, "studio_chat")} do
      {"codex", "managed", "studio_chat"} -> :ok
      _ -> {:error, :provider_capability_absent}
    end
  end

  defp normalize_attempt_claim(claim) do
    task_id = value(claim, :task_id, value(claim, :id))
    worker_id = value(claim, :worker_id)
    epoch = value(claim, :epoch)
    work_digest = value(claim, :work_digest)

    with {:ok, task_id} <- cast_assignment_task_id(task_id),
         true <- nonempty?(worker_id),
         true <- is_integer(epoch) and epoch > 0,
         true <- is_binary(work_digest) and Regex.match?(~r/^[0-9a-f]{16}$/, work_digest) do
      {:ok, %{task_id: task_id, worker_id: worker_id, epoch: epoch, work_digest: work_digest}}
    else
      _ -> {:error, :invalid_runtime_attempt_claim}
    end
  end

  defp authorize_runtime_attempt(assignment_id, claim, opts) do
    case runtime_attempt_authority(assignment_id) do
      nil ->
        Repo.rollback(:runtime_attempt_authority_not_found)

      authority ->
        case Repo.get(RuntimeAttempt, assignment_id) do
          %RuntimeAttempt{} = attempt ->
            reconcile_runtime_attempt(attempt, claim, authority)

          nil ->
            create_runtime_attempt(authority, claim, opts)
        end
    end
  end

  defp runtime_attempt_authority(assignment_id) do
    Repo.one(
      from(a in Assignment,
        join: w in Wave,
        on: w.id == a.cycle_wave_id and w.workspace_id == a.workspace_id,
        join: b in AssignmentTask,
        on: b.assignment_id == a.id,
        join: t in Document,
        on:
          t.id == b.task_id and t.type == "task" and t.workspace_id == a.workspace_id and
            t.project_id == w.project_id,
        join: d in Dataset,
        on: d.id == t.dataset_id and d.project_id == w.project_id,
        where: a.id == ^assignment_id,
        lock: "FOR UPDATE",
        select: %{
          assignment_id: a.id,
          task_id: t.id,
          task_doc_id: t.doc_id,
          workspace_id: a.workspace_id,
          project_id: w.project_id,
          dataset_id: d.id,
          task_content: t.content
        }
      )
    )
  end

  defp create_runtime_attempt(authority, claim, opts) do
    if claim.task_id != authority.task_id do
      Repo.rollback(:runtime_attempt_task_mismatch)
    end

    expected =
      claim
      |> Map.merge(Map.take(authority, [:workspace_id, :project_id, :dataset_id]))
      |> Map.put(:doc_id, authority.task_doc_id)

    with {:ok, fence} <- Tasks.verify_claim_fence(authority.task_id, expected),
         {:ok, session} <- create_attempt_session(authority, opts) do
      now = DateTime.utc_now()

      attrs = %{
        assignment_id: authority.assignment_id,
        task_id: authority.task_id,
        session_id: session.id,
        task_worker_id: fence.task_worker_id,
        task_epoch: fence.task_epoch,
        task_work_digest: fence.task_work_digest,
        provider: "codex",
        execution_target: "managed",
        inserted_at: now
      }

      {inserted, _} = Repo.insert_all(RuntimeAttempt, [attrs], on_conflict: :nothing)
      attempt = Repo.get(RuntimeAttempt, authority.assignment_id)

      cond do
        inserted == 1 -> attempt
        is_nil(attempt) -> Repo.rollback(:runtime_attempt_conflict)
        true -> reconcile_runtime_attempt(attempt, claim, authority)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp reconcile_runtime_attempt(%RuntimeAttempt{} = attempt, claim, authority) do
    case verify_runtime_attempt_claim(attempt, claim, authority) do
      {:ok, _fence} -> attempt
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp verify_runtime_attempt_claim(attempt, claim, authority) do
    cond do
      attempt.task_id != claim.task_id ->
        {:error, :runtime_attempt_conflict}

      attempt.task_worker_id != claim.worker_id ->
        {:error, :foreign_claim}

      attempt.task_work_digest != claim.work_digest ->
        {:error, :work_digest_mismatch}

      true ->
        Tasks.verify_claim_fence(
          attempt.task_id,
          claim
          |> Map.merge(Map.take(authority, [:workspace_id, :project_id, :dataset_id]))
          |> Map.put(:doc_id, authority.task_doc_id)
        )
    end
  end

  defp create_attempt_session(authority, opts) do
    attrs = %{
      id: Ecto.UUID.generate(),
      provider: "codex",
      execution_target: "managed",
      cwd: value(opts, :cwd, Runtime.cwd("codex")),
      mode: value(opts, :mode, "plan"),
      model: value(opts, :model)
    }

    StudioChat.create_session(attrs, {:workspace, authority.workspace_id})
  end

  defp recorder_opts(session, opts) do
    %{
      session_id: session.id,
      provider: session.provider,
      provider_session_id: session.provider_session_id,
      execution_target: session.execution_target,
      execution_host_id: session.execution_host_id,
      workspace_id: session.owner_workspace_id,
      cwd: session.cwd,
      mode: session.mode || "plan",
      resume: (session.message_count || 0) > 0,
      model: value(opts, :model),
      effort: value(opts, :effort),
      bypass_armed: false
    }
  end

  defp normalize_assignment_task_id(attrs) do
    case value(attrs, :task_id) do
      nil ->
        {:ok, attrs}

      task_id ->
        case cast_assignment_task_id(task_id) do
          {:ok, task_id} -> {:ok, put_attr(attrs, :task_id, task_id)}
          error -> error
        end
    end
  end

  defp cast_assignment_task_id(task_id) do
    case Ecto.UUID.cast(task_id) do
      {:ok, task_id} -> {:ok, task_id}
      :error -> {:error, :assignment_task_authority_not_found}
    end
  end

  defp preserve_assignment_task_binding(assignment, attrs, :created) do
    case value(attrs, :task_id) do
      nil -> {:ok, nil}
      task_id -> bind_assignment_task(assignment, task_id)
    end
  end

  defp preserve_assignment_task_binding(assignment, attrs, :replayed) do
    binding = Repo.get(AssignmentTask, assignment.id)

    case {binding, value(attrs, :task_id)} do
      {nil, nil} -> {:ok, nil}
      {%AssignmentTask{} = binding, nil} -> {:ok, binding}
      {%AssignmentTask{task_id: task_id} = binding, task_id} -> {:ok, binding}
      {_binding, _task_id} -> {:error, :assignment_task_conflict}
    end
  end

  defp unwrap_assignment({:ok, %Assignment{} = assignment}), do: {:ok, assignment}
  defp unwrap_assignment({:error, reason}), do: {:error, reason}

  defp unit_id(unit), do: value(unit, :unit_id)

  defp strict_string_list(value) when is_list(value) do
    if Enum.all?(value, &strict_id?/1),
      do: {:ok, value},
      else: {:error, :invalid_build_unit_ids}
  end

  defp strict_string_list(_value), do: {:error, :invalid_build_unit_ids}
  defp strict_id?(value) when is_binary(value), do: value != "" and value == String.trim(value)
  defp strict_id?(_value), do: false
  defp sorted(%MapSet{} = set), do: set |> MapSet.to_list() |> Enum.sort()

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp value(_map, _key, default), do: default

  defp put_attr(map, key, value) do
    map
    |> Map.delete(key)
    |> Map.delete(to_string(key))
    |> Map.put(key, value)
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
