defmodule Barkpark.EpicFleet do
  @moduledoc """
  Durable assignment and terminal-result ledger for Codex Epic Cycle fleets.

  The ledger freezes each dispatch snapshot, accepts exactly one typed terminal
  result per assignment, and reconciles retries by a server-computed digest.
  Reduction emits the fleet-contract counters plus digest-pinned evidence.
  """

  import Ecto.Query, warn: false

  alias Barkpark.EpicFleet.{Assignment, Benchmark, CanonicalJSON, Experiment, Result}
  alias Barkpark.Repo

  @default_plan %{
    survey: %{agent_type: "epic-surveyor", effort: "medium", planned: 12},
    verify: %{agent_type: "epic-verifier", effort: "medium", planned: 6},
    build: %{agent_type: "epic-builder", effort: "high", planned: 3},
    review: %{agent_type: "code-reviewer", effort: "high", planned: 3}
  }

  @phase_agent_types %{
    survey: "epic-surveyor",
    verify: "epic-verifier",
    experiment: "legendary-experimenter",
    build: "epic-builder",
    review: "code-reviewer"
  }

  @phase_efforts %{
    survey: "medium",
    verify: "medium",
    experiment: "medium",
    build: "high",
    review: "high"
  }

  @assignment_fields [
    :workspace_id,
    :epic_id,
    :wave_id,
    :assignment_id,
    :phase,
    :agent_type,
    :effort,
    :snapshot,
    :cycle_wave_id,
    :replaces_assignment_id
  ]

  @result_fields [
    :status,
    :summary,
    :evidence,
    :evidence_revision,
    :payload
  ]

  @scope_fields [:workspace_id, :epic_id, :wave_id]

  @doc "Create or replay one immutable assignment snapshot."
  @spec create_assignment(map()) ::
          {:ok, Assignment.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_assignment(attrs) when is_map(attrs) do
    case create_assignment_with_status(attrs) do
      {:ok, assignment, _status} -> {:ok, assignment}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec create_assignment_with_status(map()) ::
          {:ok, Assignment.t(), :created | :replayed}
          | {:error, Ecto.Changeset.t() | atom()}
  def create_assignment_with_status(attrs) when is_map(attrs) do
    attrs = select_attrs(attrs, @assignment_fields)
    snapshot = Map.get(attrs, :snapshot, %{})
    attrs = Map.merge(attrs, %{snapshot: snapshot, snapshot_digest: digest(snapshot)})

    with :ok <- validate_replacement(attrs) do
      case Repo.insert(Assignment.insert_changeset(attrs), on_conflict: :nothing) do
        {:ok, candidate} -> reconcile_assignment_with_status(candidate, attrs)
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc "Fetch an assignment by its durable UUID."
  @spec get_assignment(Ecto.UUID.t()) :: Assignment.t() | nil
  def get_assignment(id), do: Repo.get(Assignment, id)

  @doc "List the immutable assignments for one workspace/epic/wave scope."
  @spec list_assignments(map()) :: [Assignment.t()]
  def list_assignments(scope) when is_map(scope) do
    case normalize_scope(scope) do
      {:ok, normalized} -> Repo.all(assignments_query(normalized))
      {:error, :invalid_scope} -> []
    end
  end

  @doc "List assignments attached to one immutable CycleFleet wave."
  @spec list_cycle_assignments(Ecto.UUID.t()) :: [Assignment.t()]
  def list_cycle_assignments(cycle_wave_id) when is_binary(cycle_wave_id) do
    Repo.all(
      from a in Assignment, where: a.cycle_wave_id == ^cycle_wave_id, order_by: a.inserted_at
    )
  end

  @doc "Record or idempotently replay the terminal result for an assignment."
  @spec record_result(Assignment.t() | Ecto.UUID.t(), String.t(), map()) ::
          {:ok, Result.t()} | {:error, Ecto.Changeset.t() | atom()}
  def record_result(%Assignment{id: assignment_id}, idempotency_key, attrs),
    do: record_result(assignment_id, idempotency_key, attrs)

  def record_result(assignment_id, idempotency_key, attrs)
      when is_binary(assignment_id) and is_binary(idempotency_key) and is_map(attrs) do
    Repo.transaction(fn ->
      assignment =
        Assignment
        |> where([a], a.id == ^assignment_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      case assignment do
        nil ->
          Repo.rollback(:assignment_not_found)

        %Assignment{} ->
          with {:ok, prepared_attrs} <- prepare_result_for_insert(assignment, attrs) do
            prepared_attrs = result_attrs(assignment_id, idempotency_key, prepared_attrs)
            reconcile_result(assignment_id, idempotency_key, prepared_attrs)
          else
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
    |> unwrap_transaction()
  end

  @doc "Record a result using `idempotency_key` carried in the attribute map."
  @spec record_result(Assignment.t() | Ecto.UUID.t(), map()) ::
          {:ok, Result.t()} | {:error, Ecto.Changeset.t() | atom()}
  def record_result(assignment, attrs) when is_map(attrs) do
    case value(attrs, :idempotency_key) do
      key when is_binary(key) -> record_result(assignment, key, attrs)
      _ -> {:error, :idempotency_key_required}
    end
  end

  @doc "Fetch the single terminal result for an assignment, if it exists."
  @spec get_result(Assignment.t() | Ecto.UUID.t()) :: Result.t() | nil
  def get_result(%Assignment{id: assignment_id}), do: get_result(assignment_id)
  def get_result(assignment_id), do: Repo.get_by(Result, assignment_id: assignment_id)

  @doc "Reduce one wave into the canonical phase fleet counters."
  @spec reduce_fleet(map(), map()) :: {:ok, map()} | {:error, :invalid_scope | :invalid_plan}
  def reduce_fleet(scope, plan \\ @default_plan) when is_map(scope) and is_map(plan) do
    with {:ok, normalized_scope} <- normalize_scope(scope),
         {:ok, normalized_plan} <- normalize_plan(plan) do
      rows =
        normalized_scope
        |> assignments_query()
        |> join(:left, [a], r in Result, on: r.assignment_id == a.id)
        |> select([a, r], {a, r})
        |> Repo.all()

      fleet = reduce_rows(rows, normalized_plan)

      {:ok,
       %{
         source: if(rows == [], do: :legacy_absent, else: :ledger),
         ledger_present?: rows != [],
         scope: normalized_scope,
         fleet: fleet,
         ledger_digest: digest(%{scope: normalized_scope, fleet: fleet})
       }}
    end
  end

  @doc "Reduce only assignments attached to one CycleFleet wave."
  @spec reduce_cycle(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, :invalid_plan}
  def reduce_cycle(cycle_wave_id, plan) when is_binary(cycle_wave_id) and is_map(plan) do
    with {:ok, normalized_plan} <- normalize_plan(plan) do
      rows =
        Assignment
        |> where([a], a.cycle_wave_id == ^cycle_wave_id)
        |> join(:left, [a], r in Result, on: r.assignment_id == a.id)
        |> select([a, r], {a, r})
        |> Repo.all()

      fleet = reduce_rows(rows, normalized_plan)

      {:ok,
       %{
         source: :cycle_ledger,
         ledger_present?: rows != [],
         scope: %{cycle_wave_id: cycle_wave_id},
         fleet: fleet,
         ledger_digest: digest(%{cycle_wave_id: cycle_wave_id, fleet: fleet})
       }}
    end
  end

  @doc "Alias for `reduce_fleet/2` used by projection callers."
  @spec reduce(map(), map()) :: {:ok, map()} | {:error, :invalid_scope | :invalid_plan}
  def reduce(scope, plan \\ @default_plan), do: reduce_fleet(scope, plan)

  @doc "The baseline phase plan from the Epic Cycle fleet contract."
  @spec default_plan() :: map()
  def default_plan, do: @default_plan

  @doc "Create or replay an append-only Epic/Legendary benchmark experiment."
  @spec create_benchmark_experiment(map()) ::
          {:ok, Experiment.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_benchmark_experiment(attrs), do: Benchmark.create_experiment(attrs)

  @doc "Create or replay an append-only v2 retrieval-attributed benchmark experiment."
  def create_retrieval_benchmark_experiment(attrs, attribution) do
    attrs
    |> Map.put(:artifact_format, "barkpark-epic-benchmark-v2")
    |> Map.put(:retrieval_attribution, attribution)
    |> Benchmark.create_experiment()
  end

  @doc "Record or replay one immutable benchmark execution attempt."
  def record_benchmark_attempt(experiment, attrs), do: Benchmark.record_attempt(experiment, attrs)

  @doc "List benchmark attempts in deterministic ordinal/id order."
  def list_benchmark_attempts(experiment), do: Benchmark.list_attempts(experiment)

  @doc "Build the deterministic benchmark export document."
  def export_benchmark(experiment), do: Benchmark.export(experiment)

  @doc "Encode the deterministic benchmark export as canonical JSON bytes."
  def export_benchmark_json(experiment), do: Benchmark.export_json(experiment)

  @doc "Build the canonical v2 benchmark document with its v1 ledger bridge."
  def export_benchmark_v2(experiment), do: Benchmark.export_v2(experiment)

  @doc "Encode the canonical v2 benchmark document without changing v1 bytes."
  def export_benchmark_v2_json(experiment), do: Benchmark.export_v2_json(experiment)

  @doc "Verify and persist a canonical benchmark JSON artifact atomically."
  def import_benchmark_json(json), do: Benchmark.import_json(json)

  @doc "Atomically replace a file with exact canonical benchmark JSON bytes."
  def write_benchmark_json_file(path, json), do: Benchmark.write_json_file(path, json)

  @doc "Return a stable lowercase SHA-256 digest over canonical JSON bytes."
  @spec canonical_digest(term()) :: String.t()
  def canonical_digest(term), do: CanonicalJSON.digest(term)

  @doc "Encode a JSON-compatible term with recursively sorted object keys."
  @spec canonical_json(term()) :: binary()
  def canonical_json(term), do: CanonicalJSON.encode!(term)

  @doc "Return a stable lowercase SHA-256 digest for JSON-compatible terms."
  @spec digest(term()) :: String.t()
  def digest(term) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(normalize(term)))
    |> Base.encode16(case: :lower)
  end

  defp reconcile_assignment(attrs) do
    existing = existing_assignment(attrs)

    cond do
      is_nil(existing) and replacement_already_exists?(attrs) ->
        {:error, :assignment_already_replaced}

      is_nil(existing) ->
        {:error, :assignment_conflict}

      assignment_replay?(existing, attrs) ->
        {:ok, existing}

      true ->
        {:error, :assignment_conflict}
    end
  end

  defp replacement_already_exists?(%{replaces_assignment_id: replacement_id})
       when is_binary(replacement_id) do
    Repo.exists?(from a in Assignment, where: a.replaces_assignment_id == ^replacement_id)
  end

  defp replacement_already_exists?(_attrs), do: false

  defp reconcile_assignment_with_status(candidate, attrs) do
    case reconcile_assignment(attrs) do
      {:ok, assignment} ->
        status = if assignment.id == candidate.id, do: :created, else: :replayed
        {:ok, assignment, status}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp existing_assignment(%{cycle_wave_id: cycle_wave_id, assignment_id: assignment_id})
       when is_binary(cycle_wave_id) do
    Repo.get_by(Assignment, cycle_wave_id: cycle_wave_id, assignment_id: assignment_id)
  end

  defp existing_assignment(attrs) do
    Repo.get_by(Assignment,
      workspace_id: attrs[:workspace_id],
      epic_id: attrs[:epic_id],
      wave_id: attrs[:wave_id],
      assignment_id: attrs[:assignment_id]
    )
  end

  defp assignment_replay?(existing, attrs) do
    existing.assignment_id == attrs.assignment_id and
      existing.snapshot_digest == attrs.snapshot_digest and
      existing.phase == attrs.phase and
      existing.agent_type == attrs.agent_type and
      existing.effort == attrs.effort and
      existing.cycle_wave_id == Map.get(attrs, :cycle_wave_id) and
      existing.replaces_assignment_id == Map.get(attrs, :replaces_assignment_id)
  end

  defp validate_replacement(%{replaces_assignment_id: replacement_id} = attrs)
       when is_binary(replacement_id) do
    case Repo.get(Assignment, replacement_id) do
      %Assignment{} = previous ->
        existing_replacement =
          Repo.one(from a in Assignment, where: a.replaces_assignment_id == ^previous.id)

        predecessor_result = get_result(previous)

        cond do
          not Enum.all?(@scope_fields, &(Map.get(attrs, &1) == Map.get(previous, &1))) ->
            {:error, :replacement_scope_mismatch}

          Map.get(attrs, :phase) != previous.phase ->
            {:error, :replacement_phase_mismatch}

          Map.get(attrs, :agent_type) != previous.agent_type ->
            {:error, :replacement_agent_type_mismatch}

          Map.get(attrs, :cycle_wave_id) != previous.cycle_wave_id ->
            {:error, :replacement_contract_mismatch}

          is_nil(predecessor_result) ->
            {:error, :replacement_predecessor_pending}

          predecessor_result.status not in ["failed", "cancelled"] ->
            {:error, :replacement_predecessor_not_replaceable}

          not is_nil(existing_replacement) ->
            if assignment_replay?(existing_replacement, attrs),
              do: :ok,
              else: {:error, :assignment_already_replaced}

          true ->
            :ok
        end

      nil ->
        {:error, :replacement_not_found}
    end
  end

  defp validate_replacement(_attrs), do: :ok

  defp result_attrs(assignment_id, idempotency_key, attrs) do
    selected = select_attrs(attrs, @result_fields)
    {evidence, evidence_revision} = evidence_fields(selected)
    payload = Map.get(selected, :payload, %{})

    semantic = %{
      status: Map.get(selected, :status),
      summary: Map.get(selected, :summary),
      evidence: evidence,
      evidence_revision: evidence_revision,
      payload: payload
    }

    evidence_digest = digest(%{location: evidence, revision: evidence_revision})

    selected
    |> Map.merge(%{
      assignment_id: assignment_id,
      idempotency_key: idempotency_key,
      evidence: evidence,
      evidence_revision: evidence_revision,
      evidence_digest: evidence_digest,
      payload: payload,
      payload_digest: digest(Map.put(semantic, :evidence_digest, evidence_digest))
    })
  end

  defp prepare_result_for_insert(%Assignment{cycle_wave_id: cycle_wave_id} = assignment, attrs)
       when is_binary(cycle_wave_id),
       do: Barkpark.CycleFleet.prepare_result_for_insert(assignment, attrs)

  defp prepare_result_for_insert(%Assignment{}, attrs), do: {:ok, attrs}

  defp evidence_fields(%{evidence: evidence} = attrs) when is_map(evidence) do
    location = value(evidence, :location) || value(evidence, :ref)
    revision = value(evidence, :revision) || Map.get(attrs, :evidence_revision)
    {location, revision}
  end

  defp evidence_fields(attrs),
    do: {Map.get(attrs, :evidence), Map.get(attrs, :evidence_revision)}

  defp reconcile_result(assignment_id, idempotency_key, attrs) do
    case Repo.get_by(Result, assignment_id: assignment_id) do
      nil ->
        attrs
        |> Result.insert_changeset()
        |> Repo.insert()
        |> case do
          {:ok, result} -> result
          {:error, changeset} -> Repo.rollback(changeset)
        end

      %Result{idempotency_key: ^idempotency_key, payload_digest: digest} = result ->
        if digest == attrs.payload_digest do
          result
        else
          Repo.rollback(:idempotency_conflict)
        end

      %Result{} ->
        Repo.rollback(:terminal_result_conflict)
    end
  end

  defp unwrap_transaction({:ok, %Result{} = result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp normalize_scope(scope) do
    normalized = select_attrs(scope, @scope_fields)

    if Enum.all?(
         @scope_fields,
         &(is_binary(Map.get(normalized, &1)) and Map.get(normalized, &1) != "")
       ) do
      {:ok, normalized}
    else
      {:error, :invalid_scope}
    end
  end

  defp assignments_query(scope) do
    from a in Assignment,
      where:
        a.workspace_id == ^scope.workspace_id and a.epic_id == ^scope.epic_id and
          a.wave_id == ^scope.wave_id and is_nil(a.cycle_wave_id),
      order_by: [asc: a.inserted_at, asc: a.assignment_id]
  end

  defp normalize_plan(plan) do
    Enum.reduce_while(plan, {:ok, %{}}, fn {phase, config}, {:ok, acc} ->
      with {:ok, phase_key} <- phase_key(phase),
           {:ok, normalized_config} <- normalize_plan_config(phase_key, config) do
        {:cont, {:ok, Map.put(acc, phase_key, normalized_config)}}
      else
        _ -> {:halt, {:error, :invalid_plan}}
      end
    end)
  end

  defp normalize_plan_config(phase, planned) when is_integer(planned) and planned >= 0 do
    {:ok,
     %{agent_type: @phase_agent_types[phase], effort: @phase_efforts[phase], planned: planned}}
  end

  defp normalize_plan_config(phase, config) when is_map(config) do
    planned = value(config, :planned)
    agent_type = value(config, :agent_type) || @phase_agent_types[phase]
    effort = value(config, :effort) || @phase_efforts[phase]

    if is_integer(planned) and planned >= 0 and is_binary(agent_type) and agent_type != "" and
         effort in ["medium", "high"] do
      {:ok, %{agent_type: agent_type, effort: effort, planned: planned}}
    else
      {:error, :invalid_plan}
    end
  end

  defp normalize_plan_config(_phase, _config), do: {:error, :invalid_plan}

  defp phase_key(key) when key in [:survey, "survey"], do: {:ok, :survey}
  defp phase_key(key) when key in [:verify, "verify"], do: {:ok, :verify}
  defp phase_key(key) when key in [:experiment, "experiment"], do: {:ok, :experiment}
  defp phase_key(key) when key in [:build, "build"], do: {:ok, :build}
  defp phase_key(key) when key in [:review, "review"], do: {:ok, :review}
  defp phase_key(_key), do: {:error, :invalid_plan}

  defp reduce_rows(rows, plan) do
    Enum.into(plan, %{}, fn {phase, config} ->
      phase_rows =
        Enum.filter(rows, fn {assignment, _result} -> assignment.phase == to_string(phase) end)

      {phase, reduce_phase(phase_rows, config)}
    end)
  end

  defp reduce_phase(rows, config) do
    typed_rows =
      Enum.filter(rows, fn {assignment, _result} ->
        assignment.agent_type == config.agent_type and assignment.effort == config.effort
      end)

    replaced_ids =
      typed_rows
      |> Enum.map(fn {assignment, _result} -> assignment.replaces_assignment_id end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    verified_rows =
      Enum.map(typed_rows, fn {assignment, result} ->
        {assignment, result, verified_result?(result)}
      end)

    completed_rows =
      Enum.filter(verified_rows, fn {assignment, result, verified?} ->
        verified? and result.status == "completed" and
          not MapSet.member?(replaced_ids, assignment.id)
      end)

    live_rows =
      Enum.reject(verified_rows, fn {assignment, _result, _verified?} ->
        MapSet.member?(replaced_ids, assignment.id)
      end)

    unresolved_failures =
      Enum.count(live_rows, fn
        {_assignment, %Result{status: status}, true} when status in ["failed", "cancelled"] ->
          true

        _ ->
          false
      end)

    unresolved_missing =
      Enum.count(live_rows, fn
        {_assignment, nil, _verified?} -> true
        {_assignment, _result, false} -> true
        _ -> false
      end)

    state_counts =
      Enum.reduce(
        verified_rows,
        %{completed: 0, failed: 0, cancelled: 0, missing: 0, invalid: 0},
        fn
          {_assignment, nil, _verified?}, counts ->
            Map.update!(counts, :missing, &(&1 + 1))

          {_assignment, _result, false}, counts ->
            Map.update!(counts, :invalid, &(&1 + 1))

          {_assignment, %Result{status: "completed"}, true}, counts ->
            Map.update!(counts, :completed, &(&1 + 1))

          {_assignment, %Result{status: "failed"}, true}, counts ->
            Map.update!(counts, :failed, &(&1 + 1))

          {_assignment, %Result{status: "cancelled"}, true}, counts ->
            Map.update!(counts, :cancelled, &(&1 + 1))
        end
      )

    assignments =
      completed_rows
      |> Enum.map(fn {assignment, result, true} ->
        %{
          id: assignment.assignment_id,
          agent_type: assignment.agent_type,
          status: "completed",
          evidence: result.evidence
        }
      end)
      |> Enum.sort_by(& &1.id)

    evidence_proofs =
      completed_rows
      |> Enum.map(fn {assignment, result, true} ->
        %{
          assignment_id: assignment.assignment_id,
          result_id: result.id,
          revision: result.evidence_revision,
          digest: result.evidence_digest,
          payload_digest: result.payload_digest
        }
      end)
      |> Enum.sort_by(& &1.assignment_id)

    completed = length(assignments)

    %{
      agent_type: config.agent_type,
      effort: config.effort,
      planned: config.planned,
      started: length(typed_rows),
      completed: completed,
      failed: state_counts.failed + state_counts.cancelled,
      missing: max(0, config.planned - completed),
      assignments: assignments,
      evidence_proofs: evidence_proofs,
      terminal_counts: state_counts,
      unresolved_failures: unresolved_failures,
      unresolved_missing: unresolved_missing,
      invalid_assignments: length(rows) - length(typed_rows)
    }
  end

  defp verified_result?(nil), do: false

  defp verified_result?(%Result{} = result) do
    evidence_digest =
      digest(%{location: result.evidence, revision: result.evidence_revision})

    payload_digest =
      digest(%{
        status: result.status,
        summary: result.summary,
        evidence: result.evidence,
        evidence_revision: result.evidence_revision,
        evidence_digest: evidence_digest,
        payload: result.payload
      })

    result.status in Result.terminal_states() and result.evidence_digest == evidence_digest and
      result.payload_digest == payload_digest and
      (result.status != "completed" or
         (is_binary(result.evidence) and result.evidence != "" and
            is_binary(result.evidence_revision) and result.evidence_revision != ""))
  end

  defp select_attrs(attrs, fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      case fetch_value(attrs, field) do
        {:ok, value} -> Map.put(acc, field, value)
        :error -> acc
      end
    end)
  end

  defp fetch_value(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(field))
    end
  end

  defp value(map, field, default \\ nil) do
    case fetch_value(map, field) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp normalize(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), normalize(value)} end)
    |> Enum.sort()
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(other), do: other
end
