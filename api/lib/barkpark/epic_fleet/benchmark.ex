defmodule Barkpark.EpicFleet.Benchmark do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Barkpark.EpicFleet.{Attempt, CanonicalJSON, Experiment}
  alias Barkpark.Repo

  @format "barkpark-epic-benchmark-v1"
  @format_v2 "barkpark-epic-benchmark-v2"
  @attribution_schema_v2 "barkpark.epic-retrieval-attribution.v2"
  @attribution_schema_v3 "barkpark.epic-retrieval-attribution.v3"
  @contract_schema_v2 "barkpark.epic-retrieval-contract.v2"
  @contract_schema_v3 "barkpark.epic-retrieval-contract.v3"
  @manifest_schema_v2 "epic-cycle-concurrency-v2"
  @manifest_schema_v3 "epic-cycle-concurrency-v3"
  @experiment_fields ~w(
    workspace_id epic_id wave_id experiment_id phase protocol_version manifest artifact_format
    retrieval_attribution retrieval_attribution_digest
  )
  @attempt_fields ~w(attempt_id replaces_attempt_id ordinal treatment status costs provenance payload)
  @document_keys ~w(
    format experiment manifest manifest_digest attempts attempts_digest summary summary_digest ledger_digest
  )
  @experiment_document_keys ~w(workspace_id epic_id wave_id experiment_id phase protocol_version)
  @attempt_document_keys @attempt_fields ++ ["attempt_digest"]
  @v2_document_keys ~w(format ledger attribution attribution_digest ledger_digest)
  @contract_keys ~w(schema_version corpus assignments)
  @attribution_keys ~w(schema_version epic_id wave_id corpus assignments trials)
  @corpus_keys ~w(
    sha256 repo_commit schema_version unit_ids claim_domain claim_domain_digest
  )
  @cycle_attribution_keys_v2 ~w(
    epic_id wave_id cycle_assignment_uuid assignment_id unit_ids inventory_digest snapshot_digest task
  )
  @cycle_attribution_keys_v3 @cycle_attribution_keys_v2 ++ ["cycle_phase"]
  @cycle_phases ~w(survey verify experiment build review)
  @task_fence_keys ~w(doc_id worker_id claim_epoch work_digest)
  @trial_keys ~w(trial_id sensitivity_of assignments)
  @trial_assignment_keys ~w(assignment_id attribution usage vui)
  @sensitive_exact ~w(
    token api_token access_token refresh_token auth_token id_token session_token api_key apikey secret
    client_secret webhook_secret secret_key password authorization cookie set_cookie private_key
    signing_key bearer credential credentials dsn database_url database_uri connection_string
  )
  @sensitive_suffixes ~w(
    _api_token _access_token _refresh_token _auth_token _id_token _session_token _api_key _client_secret
    _webhook_secret _secret_key _secret _password _private_key _signing_key _credential _credentials
    _dsn _database_url _database_uri _connection_string
  )
  @sensitive_exact_compact Enum.map(@sensitive_exact, &String.replace(&1, "_", ""))
  @sensitive_suffixes_compact Enum.map(@sensitive_suffixes, &String.replace(&1, "_", ""))

  @spec create_experiment(map()) ::
          {:ok, Experiment.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_experiment(attrs) when is_map(attrs) do
    raw_attrs = attrs |> select_attrs(@experiment_fields) |> CanonicalJSON.stringify_keys()

    with {:ok, attrs} <- prepare_experiment_attrs(raw_attrs) do
      manifest = Map.get(attrs, "manifest", %{})
      attrs = Map.put(attrs, "manifest_digest", CanonicalJSON.digest(manifest))

      case Repo.insert(Experiment.insert_changeset(attrs),
             on_conflict: :nothing,
             conflict_target: [:workspace_id, :epic_id, :wave_id, :experiment_id]
           ) do
        {:ok, _candidate} -> reconcile_experiment(attrs)
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @spec record_attempt(Experiment.t() | Ecto.UUID.t(), map()) ::
          {:ok, Attempt.t()} | {:error, Ecto.Changeset.t() | atom()}
  def record_attempt(%Experiment{id: experiment_id}, attrs),
    do: record_attempt(experiment_id, attrs)

  def record_attempt(experiment_id, attrs) when is_binary(experiment_id) and is_map(attrs) do
    attrs =
      attrs
      |> select_attrs(@attempt_fields)
      |> sanitize_map()
      |> Map.put_new("replaces_attempt_id", nil)

    attrs =
      attrs
      |> Map.put("attempt_digest", CanonicalJSON.digest(attrs))
      |> Map.put("experiment_id", experiment_id)

    Repo.transaction(fn ->
      experiment =
        Experiment
        |> where([experiment], experiment.id == ^experiment_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      if experiment do
        with :ok <- validate_attempt_replacement(experiment_id, attrs) do
          reconcile_attempt(experiment_id, attrs)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        Repo.rollback(:experiment_not_found)
      end
    end)
    |> unwrap_attempt()
  end

  @spec list_attempts(Experiment.t() | Ecto.UUID.t()) :: [Attempt.t()]
  def list_attempts(%Experiment{id: id}), do: list_attempts(id)

  def list_attempts(experiment_id) do
    Attempt
    |> where([attempt], attempt.experiment_id == ^experiment_id)
    |> order_by([attempt], asc: attempt.ordinal, asc: attempt.attempt_id)
    |> Repo.all()
  end

  @spec export(Ecto.UUID.t() | Experiment.t()) :: {:ok, map()} | {:error, :experiment_not_found}
  def export(%Experiment{} = experiment),
    do: {:ok, document(experiment, list_attempts(experiment))}

  def export(experiment_id) when is_binary(experiment_id) do
    case Repo.get(Experiment, experiment_id) do
      nil -> {:error, :experiment_not_found}
      experiment -> export(experiment)
    end
  end

  @spec export_json(Ecto.UUID.t() | Experiment.t()) ::
          {:ok, binary()} | {:error, :experiment_not_found}
  def export_json(experiment) do
    with {:ok, document} <- export(experiment) do
      {:ok, CanonicalJSON.encode!(document)}
    end
  end

  @spec export_v2(Ecto.UUID.t() | Experiment.t()) ::
          {:ok, map()} | {:error, :experiment_not_found | :retrieval_attribution_missing}
  def export_v2(%Experiment{artifact_format: @format_v2} = experiment),
    do: {:ok, document_v2(experiment, list_attempts(experiment))}

  def export_v2(%Experiment{}), do: {:error, :retrieval_attribution_missing}

  def export_v2(experiment_id) when is_binary(experiment_id) do
    case Repo.get(Experiment, experiment_id) do
      nil -> {:error, :experiment_not_found}
      experiment -> export_v2(experiment)
    end
  end

  @spec export_v2_json(Ecto.UUID.t() | Experiment.t()) :: {:ok, binary()} | {:error, term()}
  def export_v2_json(experiment) do
    with {:ok, document} <- export_v2(experiment) do
      {:ok, CanonicalJSON.encode!(document)}
    end
  end

  @spec document(Experiment.t(), [Attempt.t() | map()]) :: map()
  def document(%Experiment{} = experiment, attempts) do
    manifest = sanitize_map(experiment.manifest)

    attempt_maps =
      attempts |> Enum.map(&attempt_map/1) |> Enum.sort_by(&{&1["ordinal"], &1["attempt_id"]})

    summary = summary(attempt_maps)

    base = %{
      "format" => @format,
      "experiment" => %{
        "workspace_id" => experiment.workspace_id,
        "epic_id" => experiment.epic_id,
        "wave_id" => experiment.wave_id,
        "experiment_id" => experiment.experiment_id,
        "phase" => experiment.phase,
        "protocol_version" => experiment.protocol_version
      },
      "manifest" => manifest,
      "manifest_digest" => CanonicalJSON.digest(manifest),
      "attempts" => attempt_maps,
      "attempts_digest" => CanonicalJSON.digest(attempt_maps),
      "summary" => summary,
      "summary_digest" => CanonicalJSON.digest(summary)
    }

    Map.put(base, "ledger_digest", CanonicalJSON.digest(base))
  end

  @spec document_v2(Experiment.t(), [Attempt.t() | map()]) :: map()
  def document_v2(%Experiment{} = experiment, attempts) do
    ledger = document(experiment, attempts)
    attribution = sanitize_map(experiment.retrieval_attribution)

    base = %{
      "format" => @format_v2,
      "ledger" => ledger,
      "attribution" => attribution,
      "attribution_digest" => CanonicalJSON.digest(attribution)
    }

    Map.put(base, "ledger_digest", CanonicalJSON.digest(base))
  end

  @spec import_json(binary()) :: {:ok, map()} | {:error, term()}
  def import_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, document} ->
        if json == CanonicalJSON.encode!(document) do
          case document["format"] do
            @format -> import_document(document)
            @format_v2 -> import_v2_document(document)
            _other -> {:error, :unsupported_format}
          end
        else
          {:error, :non_canonical_json}
        end

      {:error, _reason} ->
        {:error, :invalid_json}
    end
  end

  @doc "Atomically replace a benchmark artifact with exact canonical JSON bytes."
  @spec write_json_file(Path.t(), binary()) :: :ok | {:error, File.posix()}
  def write_json_file(path, json) when is_binary(path) and is_binary(json) do
    temporary_path =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.tmp-#{System.unique_integer([:positive, :monotonic])}"
      )

    case File.write(temporary_path, json, [:binary, :exclusive, :sync]) do
      :ok ->
        case File.rename(temporary_path, path) do
          :ok -> :ok
          {:error, _reason} = error -> cleanup_temporary_file(temporary_path, error)
        end

      {:error, _reason} = error ->
        cleanup_temporary_file(temporary_path, error)
    end
  end

  @spec import_document(map()) :: {:ok, map()} | {:error, term()}
  def import_document(document) when is_map(document) do
    with :ok <- verify_document(document),
         {:ok, stats} <- persist_document(document) do
      {:ok, stats}
    end
  end

  def import_document(_document), do: {:error, :invalid_document}

  @spec import_v2_document(map()) :: {:ok, map()} | {:error, term()}
  def import_v2_document(document) when is_map(document) do
    with :ok <- verify_v2_document(document),
         {:ok, stats} <- persist_v2_document(document) do
      {:ok, stats}
    end
  end

  def import_v2_document(_document), do: {:error, :invalid_document}

  @spec summary([map()]) :: map()
  def summary(attempts) do
    outcome_counts = counts(attempts, "status", Attempt.statuses())

    cost_state_counts =
      Enum.reduce(attempts, Map.new(Attempt.cost_states(), &{&1, 0}), fn attempt, acc ->
        Enum.reduce(attempt["costs"] || %{}, acc, fn {_metric, metric}, inner ->
          Map.update!(inner, metric["state"], &(&1 + 1))
        end)
      end)

    treatment_counts =
      attempts
      |> Enum.group_by(& &1["treatment"])
      |> Map.new(fn {treatment, rows} -> {treatment, length(rows)} end)

    %{
      "attempt_count" => length(attempts),
      "outcomes" => outcome_counts,
      "cost_states" => cost_state_counts,
      "treatments" => treatment_counts
    }
  end

  defp prepare_experiment_attrs(raw_attrs) do
    manifest = Map.get(raw_attrs, "manifest", %{})
    format = Map.get(raw_attrs, "artifact_format", @format)

    cond do
      not is_map(manifest) ->
        {:error, :invalid_manifest}

      format == @format ->
        {:ok,
         raw_attrs
         |> sanitize_map()
         |> Map.put("artifact_format", @format)
         |> Map.drop(["retrieval_attribution", "retrieval_attribution_digest"])}

      format == @format_v2 ->
        attribution = raw_attrs["retrieval_attribution"]
        safe_attribution = sanitize_map(attribution)

        ledger = %{
          "experiment" => Map.take(raw_attrs, @experiment_document_keys),
          "manifest" => manifest
        }

        cond do
          not is_map(attribution) ->
            {:error, :retrieval_attribution_missing}

          attribution != safe_attribution ->
            {:error, :attribution_secrets_not_redacted}

          true ->
            with :ok <- validate_retrieval_attribution(attribution, ledger) do
              {:ok,
               raw_attrs
               |> sanitize_map()
               |> Map.put("artifact_format", @format_v2)
               |> Map.put("retrieval_attribution_digest", CanonicalJSON.digest(attribution))}
            end
        end

      true ->
        {:error, :unsupported_format}
    end
  end

  defp verify_document(%{"format" => @format} = document) do
    manifest = document["manifest"]
    attempts = document["attempts"]
    summary = document["summary"]
    base = Map.delete(document, "ledger_digest")

    cond do
      not exact_keys?(document, @document_keys) ->
        {:error, :invalid_document_shape}

      not is_map(document["experiment"]) or
          not exact_keys?(document["experiment"], @experiment_document_keys) ->
        {:error, :invalid_experiment}

      not is_map(manifest) ->
        {:error, :invalid_manifest}

      not is_list(attempts) ->
        {:error, :invalid_attempts}

      not Enum.all?(attempts, &valid_attempt_map?/1) ->
        {:error, :invalid_attempt}

      not unique_attempt_ids?(attempts) ->
        {:error, :duplicate_attempt_id}

      attempts != Enum.sort_by(attempts, &{&1["ordinal"], &1["attempt_id"]}) ->
        {:error, :attempts_not_canonical}

      not valid_replacement_ancestry?(attempts) ->
        {:error, :invalid_replacement_ancestry}

      manifest != sanitize_map(manifest) or attempts != Enum.map(attempts, &sanitize_map/1) ->
        {:error, :secrets_not_redacted}

      document["manifest_digest"] != CanonicalJSON.digest(manifest) ->
        {:error, :manifest_digest_mismatch}

      document["attempts_digest"] != CanonicalJSON.digest(attempts) ->
        {:error, :attempts_digest_mismatch}

      summary != summary(attempts) ->
        {:error, :summary_mismatch}

      document["summary_digest"] != CanonicalJSON.digest(summary) ->
        {:error, :summary_digest_mismatch}

      document["ledger_digest"] != CanonicalJSON.digest(base) ->
        {:error, :ledger_digest_mismatch}

      true ->
        :ok
    end
  rescue
    _error -> {:error, :invalid_document}
  end

  defp verify_document(_document), do: {:error, :unsupported_format}

  defp verify_v2_document(%{"format" => @format_v2} = document) do
    attribution = document["attribution"]
    ledger = document["ledger"]
    base = Map.delete(document, "ledger_digest")

    cond do
      not exact_keys?(document, @v2_document_keys) ->
        {:error, :invalid_v2_document_shape}

      not is_map(ledger) ->
        {:error, :invalid_v1_ledger_bridge}

      verify_document(ledger) != :ok ->
        {:error, :invalid_v1_ledger_bridge}

      not is_map(attribution) or not exact_keys?(attribution, @attribution_keys) ->
        {:error, :invalid_attribution_shape}

      attribution != sanitize_map(attribution) ->
        {:error, :attribution_secrets_not_redacted}

      document["attribution_digest"] != CanonicalJSON.digest(attribution) ->
        {:error, :attribution_digest_mismatch}

      document["ledger_digest"] != CanonicalJSON.digest(base) ->
        {:error, :ledger_digest_mismatch}

      true ->
        validate_retrieval_attribution(attribution, ledger)
    end
  rescue
    _error -> {:error, :invalid_document}
  end

  defp verify_v2_document(_document), do: {:error, :unsupported_format}

  defp validate_retrieval_attribution(attribution, ledger) do
    experiment = ledger["experiment"] || %{}
    manifest = ledger["manifest"] || %{}
    contract = manifest["retrieval_attribution_contract"]

    with :ok <- validate_attribution_scope(attribution, experiment),
         {:ok, claim_domain} <-
           validate_attribution_contract(
             attribution,
             contract,
             experiment,
             manifest["schema_version"]
           ),
         :ok <- validate_attribution_trials(attribution, claim_domain) do
      :ok
    end
  end

  defp validate_attribution_scope(attribution, experiment) do
    if attribution["schema_version"] in [@attribution_schema_v2, @attribution_schema_v3] and
         attribution["epic_id"] == experiment["epic_id"] and
         attribution["wave_id"] == experiment["wave_id"] do
      :ok
    else
      {:error, :attribution_scope_mismatch}
    end
  end

  defp validate_attribution_contract(attribution, contract, experiment, manifest_schema) do
    contract_schema = is_map(contract) && contract["schema_version"]

    cond do
      not is_map(contract) or not exact_keys?(contract, @contract_keys) or
          contract_schema not in [@contract_schema_v2, @contract_schema_v3] ->
        {:error, :attribution_contract_missing}

      not matching_retrieval_schema_versions?(
        manifest_schema,
        contract_schema,
        attribution["schema_version"]
      ) ->
        {:error, :attribution_scope_mismatch}

      not valid_corpus?(contract["corpus"]) or attribution["corpus"] != contract["corpus"] ->
        {:error, :attribution_corpus_mismatch}

      not is_list(contract["assignments"]) or length(contract["assignments"]) != 6 or
          not Enum.all?(
            contract["assignments"],
            &valid_cycle_attribution?(&1, contract_schema)
          ) ->
        {:error, :attribution_contract_invalid}

      not assignments_match_scope?(contract["assignments"], experiment) or
          not assignments_match_scope?(attribution["assignments"], experiment) ->
        {:error, :attribution_assignment_scope_mismatch}

      attribution["assignments"] != contract["assignments"] ->
        {:error, :attribution_assignment_mismatch}

      not unique_contract_assignments?(
        contract["assignments"],
        contract["corpus"],
        contract_schema
      ) ->
        {:error, :duplicate_attribution}

      true ->
        {:ok, contract["corpus"]["claim_domain"]}
    end
  end

  defp validate_attribution_trials(attribution, claim_domain) do
    trials = attribution["trials"]
    expected = Map.new(attribution["assignments"], &{&1["assignment_id"], &1})

    cond do
      not is_list(trials) or trials == [] ->
        {:error, :attribution_trials_missing}

      not unique_strings?(Enum.map(trials, &(is_map(&1) && &1["trial_id"]))) ->
        {:error, :duplicate_attribution}

      true ->
        validate_trial_rows(trials, expected, claim_domain, MapSet.new())
    end
  end

  defp validate_trial_rows([], _expected, _claim_domain, _usage_ids), do: :ok

  defp validate_trial_rows([trial | rest], expected, claim_domain, usage_ids) do
    rows = is_map(trial) && trial["assignments"]

    cond do
      not is_map(trial) or not exact_keys?(trial, @trial_keys) or
        not is_binary(trial["trial_id"]) or trial["trial_id"] == "" or
          not (is_nil(trial["sensitivity_of"]) or
                   (is_binary(trial["sensitivity_of"]) and trial["sensitivity_of"] != "")) ->
        {:error, :invalid_attribution_trial}

      not is_list(rows) or length(rows) != map_size(expected) ->
        {:error, :incomplete_attribution_trial}

      true ->
        case validate_one_trial(rows, expected, claim_domain, usage_ids) do
          {:ok, updated_usage_ids} ->
            validate_trial_rows(rest, expected, claim_domain, updated_usage_ids)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp validate_one_trial(rows, expected, claim_domain, usage_ids) do
    ids = Enum.map(rows, &(is_map(&1) && &1["assignment_id"]))

    if not unique_strings?(ids) or MapSet.new(ids) != MapSet.new(Map.keys(expected)) do
      {:error, :duplicate_attribution}
    else
      Enum.reduce_while(rows, {:ok, usage_ids}, fn row, {:ok, seen_usage} ->
        assignment_id = row["assignment_id"]
        usage = row["usage"]

        cond do
          row != sanitize_map(row) ->
            {:halt, {:error, :attribution_secrets_not_redacted}}

          not exact_keys?(row, @trial_assignment_keys) ->
            {:halt, {:error, :invalid_attribution_trial}}

          row["attribution"] != expected[assignment_id] ->
            {:halt, {:error, :attribution_assignment_mismatch}}

          not valid_usage?(usage) ->
            {:halt, {:error, :attribution_usage_invalid}}

          not valid_vui?(row["vui"], claim_domain[assignment_id]) ->
            {:halt, {:error, :attribution_vui_invalid}}

          true ->
            case usage_identity(usage) do
              nil ->
                {:cont, {:ok, seen_usage}}

              identity ->
                if MapSet.member?(seen_usage, identity) do
                  {:halt, {:error, :duplicate_attribution}}
                else
                  {:cont, {:ok, MapSet.put(seen_usage, identity)}}
                end
            end
        end
      end)
    end
  end

  defp valid_corpus?(corpus) do
    claim_domain = is_map(corpus) && corpus["claim_domain"]

    is_map(corpus) and exact_keys?(corpus, @corpus_keys) and
      sha256?(corpus["sha256"]) and hex?(corpus["repo_commit"], 40) and
      is_binary(corpus["schema_version"]) and corpus["schema_version"] != "" and
      is_list(corpus["unit_ids"]) and length(corpus["unit_ids"]) == 6 and
      unique_strings?(corpus["unit_ids"]) and
      valid_claim_domain?(claim_domain, corpus["unit_ids"]) and
      corpus["claim_domain_digest"] == CanonicalJSON.digest(claim_domain)
  end

  defp valid_claim_domain?(claim_domain, unit_ids) when is_map(claim_domain) do
    MapSet.new(Map.keys(claim_domain)) == MapSet.new(unit_ids) and
      Enum.all?(claim_domain, fn {_assignment_id, claim_ids} ->
        is_list(claim_ids) and claim_ids != [] and unique_strings?(claim_ids)
      end)
  end

  defp valid_claim_domain?(_claim_domain, _unit_ids), do: false

  defp valid_cycle_attribution?(value, contract_schema) do
    task = is_map(value) && value["task"]
    expected_keys = cycle_attribution_keys(contract_schema)

    is_map(value) and exact_keys?(value, expected_keys) and
      is_binary(value["epic_id"]) and value["epic_id"] != "" and
      is_binary(value["wave_id"]) and value["wave_id"] != "" and
      match?({:ok, _}, Ecto.UUID.cast(value["cycle_assignment_uuid"])) and
      is_binary(value["assignment_id"]) and value["assignment_id"] != "" and
      valid_cycle_phase?(value, contract_schema) and
      valid_physical_unit_ids?(value, contract_schema) and
      sha256?(value["inventory_digest"]) and
      sha256?(value["snapshot_digest"]) and is_map(task) and
      exact_keys?(task, @task_fence_keys) and is_binary(task["doc_id"]) and
      task["doc_id"] != "" and is_binary(task["worker_id"]) and task["worker_id"] != "" and
      is_integer(task["claim_epoch"]) and task["claim_epoch"] > 0 and
      hex?(task["work_digest"], 16)
  end

  defp unique_contract_assignments?(assignments, corpus, contract_schema) do
    assignment_ids = Enum.map(assignments, & &1["assignment_id"])
    cycle_ids = Enum.map(assignments, & &1["cycle_assignment_uuid"])
    task_ids = Enum.map(assignments, & &1["task"]["doc_id"])

    unique_strings?(assignment_ids) and unique_strings?(cycle_ids) and unique_strings?(task_ids) and
      MapSet.new(assignment_ids) == MapSet.new(corpus["unit_ids"]) and
      Enum.all?(assignments, fn assignment ->
        valid_physical_unit_ids?(assignment, contract_schema) and
          assignment["epic_id"] != "" and assignment["wave_id"] != ""
      end)
  end

  defp matching_retrieval_schema_versions?(
         @manifest_schema_v2,
         @contract_schema_v2,
         @attribution_schema_v2
       ),
       do: true

  defp matching_retrieval_schema_versions?(
         @manifest_schema_v3,
         @contract_schema_v3,
         @attribution_schema_v3
       ),
       do: true

  defp matching_retrieval_schema_versions?(
         _manifest_schema,
         _contract_schema,
         _attribution_schema
       ),
       do: false

  defp cycle_attribution_keys(@contract_schema_v2), do: @cycle_attribution_keys_v2
  defp cycle_attribution_keys(@contract_schema_v3), do: @cycle_attribution_keys_v3

  defp valid_cycle_phase?(_assignment, @contract_schema_v2), do: true

  defp valid_cycle_phase?(assignment, @contract_schema_v3),
    do: assignment["cycle_phase"] in @cycle_phases

  defp valid_physical_unit_ids?(assignment, @contract_schema_v2) do
    assignment["unit_ids"] == [assignment["assignment_id"]]
  end

  defp valid_physical_unit_ids?(assignment, @contract_schema_v3) do
    case assignment["cycle_phase"] do
      "build" -> assignment["unit_ids"] == [assignment["assignment_id"]]
      phase when phase in @cycle_phases -> assignment["unit_ids"] == []
      _other -> false
    end
  end

  defp assignments_match_scope?(assignments, experiment) when is_list(assignments) do
    Enum.all?(assignments, fn assignment ->
      is_map(assignment) and assignment["epic_id"] == experiment["epic_id"] and
        assignment["wave_id"] == experiment["wave_id"]
    end)
  end

  defp assignments_match_scope?(_assignments, _experiment), do: false

  defp valid_usage?(%{"state" => "observed"} = usage) do
    expected = ~w(
      state provider_session_id provider_turn_id counter_domain baseline_tokens terminal_tokens
      token_count context_occupancy
    )
    token_count = usage["token_count"]
    baseline = usage["baseline_tokens"]
    terminal = usage["terminal_tokens"]

    exact_keys?(usage, expected) and opaque_id?(usage["provider_session_id"]) and
      opaque_id?(usage["provider_turn_id"]) and opaque_id?(usage["counter_domain"]) and
      is_integer(baseline) and baseline >= 0 and is_integer(terminal) and terminal >= baseline and
      token_count == %{"state" => "observed", "value" => terminal - baseline} and
      valid_context_occupancy?(usage["context_occupancy"])
  end

  defp valid_usage?(%{"state" => state, "reason" => reason, "unit" => "tokens"} = usage)
       when state in ~w(unsupported missing invalid) and is_binary(reason) and reason != "",
       do: exact_keys?(usage, ~w(state reason unit))

  defp valid_usage?(_usage), do: false

  defp valid_context_occupancy?(%{"state" => "observed", "value" => value}),
    do: is_integer(value) and value >= 0

  defp valid_context_occupancy?(%{"state" => state, "reason" => reason})
       when state in ~w(unsupported missing invalid),
       do: is_binary(reason) and reason != ""

  defp valid_context_occupancy?(_value), do: false

  defp valid_vui?(
         %{"state" => "observed", "value" => value, "unit" => "claims"} = vui,
         claim_ids
       ) do
    is_integer(value) and value >= 0 and
      exact_keys?(vui, ~w(
        state value unit verified_claim_ids missing_claim_ids contradicted_claim_ids unsupported_claim_ids
      )) and valid_claim_lists?(vui, claim_ids) and
      value == length(vui["verified_claim_ids"]) and
      Enum.all?(~w(missing_claim_ids contradicted_claim_ids unsupported_claim_ids), fn key ->
        vui[key] == []
      end)
  end

  defp valid_vui?(%{"state" => state, "reason" => reason, "unit" => "claims"} = vui, claim_ids)
       when state in ~w(unsupported missing invalid) and is_binary(reason) and reason != "" do
    allowed = [
      ~w(state reason unit),
      ~w(
        state reason unit verified_claim_ids missing_claim_ids contradicted_claim_ids unsupported_claim_ids
      )
    ]

    Enum.any?(allowed, &exact_keys?(vui, &1)) and
      (not Map.has_key?(vui, "verified_claim_ids") or valid_claim_lists?(vui, claim_ids))
  end

  defp valid_vui?(_vui, _claim_ids), do: false

  defp valid_claim_lists?(vui, claim_ids) when is_list(claim_ids) do
    classified_claim_ids =
      Enum.flat_map(
        ~w(verified_claim_ids missing_claim_ids contradicted_claim_ids unsupported_claim_ids),
        fn key -> if is_list(vui[key]), do: vui[key], else: [nil] end
      )

    unique_strings?(classified_claim_ids) and
      MapSet.new(classified_claim_ids) == MapSet.new(claim_ids)
  end

  defp valid_claim_lists?(_vui, _claim_ids), do: false

  defp usage_identity(%{"state" => "observed"} = usage),
    do: {usage["provider_session_id"], usage["provider_turn_id"]}

  defp usage_identity(_usage), do: nil

  defp unique_strings?(values) when is_list(values) do
    Enum.all?(values, &(is_binary(&1) and &1 != "")) and
      length(values) == MapSet.size(MapSet.new(values))
  end

  defp unique_strings?(_values), do: false

  defp opaque_id?(value) when is_binary(value) and byte_size(value) in 1..200,
    do: String.match?(value, ~r/^[A-Za-z0-9._:-]+$/)

  defp opaque_id?(_value), do: false

  defp sha256?(value), do: hex?(value, 64)

  defp hex?(value, size) when is_binary(value) and byte_size(value) == size,
    do: String.match?(value, ~r/^[0-9a-f]+$/)

  defp hex?(_value, _size), do: false

  defp persist_document(document), do: persist_ledger(document, %{})

  defp persist_v2_document(document) do
    persist_ledger(document["ledger"], %{
      "artifact_format" => @format_v2,
      "retrieval_attribution" => document["attribution"],
      "retrieval_attribution_digest" => document["attribution_digest"]
    })
  end

  defp persist_ledger(document, extra_experiment_attrs) do
    experiment_attrs =
      document["experiment"]
      |> Map.put("manifest", document["manifest"])
      |> Map.merge(extra_experiment_attrs)

    Repo.transaction(fn ->
      case create_experiment(experiment_attrs) do
        {:ok, experiment} ->
          Enum.reduce_while(
            Enum.sort_by(document["attempts"], &{&1["ordinal"], &1["attempt_id"]}),
            %{experiment: experiment, attempts: 0},
            fn row, stats ->
              attrs = Map.drop(row, ["attempt_digest"])

              case record_attempt(experiment, attrs) do
                {:ok, _attempt} -> {:cont, %{stats | attempts: stats.attempts + 1}}
                {:error, reason} -> Repo.rollback(reason)
              end
            end
          )

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp valid_attempt_map?(attempt) when is_map(attempt) do
    semantic = Map.drop(attempt, ["attempt_digest"])
    replacement_id = attempt["replaces_attempt_id"]

    exact_keys?(attempt, @attempt_document_keys) and is_binary(attempt["attempt_id"]) and
      attempt["attempt_id"] != "" and
      (is_nil(replacement_id) or (is_binary(replacement_id) and replacement_id != "")) and
      is_integer(attempt["ordinal"]) and attempt["ordinal"] > 0 and
      is_binary(attempt["treatment"]) and attempt["treatment"] != "" and
      attempt["status"] in Attempt.statuses() and Attempt.valid_costs?(attempt["costs"]) and
      is_map(attempt["provenance"]) and is_map(attempt["payload"]) and
      attempt["attempt_digest"] == CanonicalJSON.digest(semantic)
  end

  defp valid_attempt_map?(_attempt), do: false

  defp attempt_map(%Attempt{} = attempt) do
    semantic = %{
      "attempt_id" => attempt.attempt_id,
      "replaces_attempt_id" => attempt.replaces_attempt_id,
      "ordinal" => attempt.ordinal,
      "treatment" => attempt.treatment,
      "status" => attempt.status,
      "costs" => sanitize_map(attempt.costs),
      "provenance" => sanitize_map(attempt.provenance),
      "payload" => sanitize_map(attempt.payload)
    }

    Map.put(semantic, "attempt_digest", CanonicalJSON.digest(semantic))
  end

  defp attempt_map(attempt) when is_map(attempt) do
    semantic =
      attempt
      |> select_attrs(@attempt_fields)
      |> sanitize_map()
      |> Map.put_new("replaces_attempt_id", nil)

    Map.put(semantic, "attempt_digest", CanonicalJSON.digest(semantic))
  end

  defp counts(rows, field, vocabulary) do
    Enum.reduce(rows, Map.new(vocabulary, &{&1, 0}), fn row, acc ->
      Map.update!(acc, row[field], &(&1 + 1))
    end)
  end

  defp reconcile_experiment(attrs) do
    existing =
      Repo.get_by(Experiment,
        workspace_id: attrs["workspace_id"],
        epic_id: attrs["epic_id"],
        wave_id: attrs["wave_id"],
        experiment_id: attrs["experiment_id"]
      )

    cond do
      is_nil(existing) ->
        {:error, :experiment_insert_failed}

      existing.phase == attrs["phase"] and existing.protocol_version == attrs["protocol_version"] and
        existing.manifest_digest == attrs["manifest_digest"] and
        existing.artifact_format == Map.get(attrs, "artifact_format", @format) and
          existing.retrieval_attribution_digest == attrs["retrieval_attribution_digest"] ->
        {:ok, existing}

      true ->
        {:error, :experiment_conflict}
    end
  end

  defp reconcile_attempt(experiment_id, attrs) do
    case Repo.get_by(Attempt, experiment_id: experiment_id, attempt_id: attrs["attempt_id"]) do
      nil ->
        case Repo.insert(Attempt.insert_changeset(attrs)) do
          {:ok, attempt} -> attempt
          {:error, changeset} -> Repo.rollback(changeset)
        end

      %Attempt{attempt_digest: digest} = attempt ->
        if digest == attrs["attempt_digest"] do
          attempt
        else
          Repo.rollback(:attempt_conflict)
        end
    end
  end

  defp validate_attempt_replacement(_experiment_id, %{"replaces_attempt_id" => nil}), do: :ok

  defp validate_attempt_replacement(_experiment_id, %{
         "attempt_id" => attempt_id,
         "replaces_attempt_id" => attempt_id
       }),
       do: {:error, :attempt_cannot_replace_itself}

  defp validate_attempt_replacement(
         experiment_id,
         %{
           "ordinal" => ordinal,
           "replaces_attempt_id" => replacement_id
         } = attrs
       )
       when is_binary(replacement_id) do
    previous_ordinal =
      Repo.one(
        from attempt in Attempt,
          where:
            attempt.experiment_id == ^experiment_id and attempt.attempt_id == ^replacement_id,
          select: attempt.ordinal
      )

    cond do
      is_nil(previous_ordinal) ->
        {:error, :replacement_attempt_not_found}

      ordinal <= previous_ordinal ->
        {:error, :replacement_ordinal_invalid}

      replacement_already_exists?(experiment_id, replacement_id, attrs["attempt_id"]) ->
        {:error, :replacement_attempt_already_replaced}

      true ->
        :ok
    end
  end

  defp validate_attempt_replacement(_experiment_id, _attrs),
    do: {:error, :invalid_replacement_attempt_id}

  defp unwrap_attempt({:ok, %Attempt{} = attempt}), do: {:ok, attempt}
  defp unwrap_attempt({:error, reason}), do: {:error, reason}

  defp select_attrs(attrs, fields) do
    Map.new(fields, fn field ->
      {field, Map.get(attrs, field, Map.get(attrs, String.to_atom(field)))}
    end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp sanitize_map(term) do
    term
    |> CanonicalJSON.stringify_keys()
    |> sanitize()
  end

  defp sanitize(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(key), do: {key, "[REDACTED]"}, else: {key, sanitize(value)}
    end)
  end

  defp sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)
  defp sanitize(value), do: value

  defp sensitive_key?(key) do
    normalized = key |> String.downcase() |> String.replace(~r/[^a-z0-9]+/u, "_")
    compact = String.replace(normalized, "_", "")

    normalized in @sensitive_exact or
      Enum.any?(@sensitive_suffixes, &String.ends_with?(normalized, &1)) or
      compact in @sensitive_exact_compact or
      Enum.any?(@sensitive_suffixes_compact, &String.ends_with?(compact, &1))
  end

  defp valid_replacement_ancestry?(attempts) do
    attempts
    |> Enum.reduce_while({%{}, MapSet.new()}, fn attempt, {seen, replaced} ->
      ordinal = attempt["ordinal"]
      attempt_id = attempt["attempt_id"]

      case attempt["replaces_attempt_id"] do
        nil ->
          {:cont, {Map.put(seen, attempt_id, ordinal), replaced}}

        replacement_id ->
          cond do
            MapSet.member?(replaced, replacement_id) ->
              {:halt, :invalid}

            Map.get(seen, replacement_id, ordinal) >= ordinal ->
              {:halt, :invalid}

            true ->
              {:cont, {Map.put(seen, attempt_id, ordinal), MapSet.put(replaced, replacement_id)}}
          end
      end
    end)
    |> case do
      {_seen, _replaced} -> true
      :invalid -> false
    end
  end

  defp unique_attempt_ids?(attempts) do
    attempt_ids = Enum.map(attempts, & &1["attempt_id"])
    length(attempt_ids) == MapSet.size(MapSet.new(attempt_ids))
  end

  defp replacement_already_exists?(experiment_id, replacement_id, attempt_id) do
    Repo.exists?(
      from attempt in Attempt,
        where:
          attempt.experiment_id == ^experiment_id and
            attempt.replaces_attempt_id == ^replacement_id and
            attempt.attempt_id != ^attempt_id
    )
  end

  defp exact_keys?(map, expected) when is_map(map),
    do: Map.keys(map) |> Enum.sort() == Enum.sort(expected)

  defp cleanup_temporary_file(path, error) do
    _ = File.rm(path)
    error
  end
end
