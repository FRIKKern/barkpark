defmodule Barkpark.EpicFleet.Benchmark do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Barkpark.EpicFleet.{Attempt, CanonicalJSON, Experiment}
  alias Barkpark.Repo

  @format "barkpark-epic-benchmark-v1"
  @experiment_fields ~w(workspace_id epic_id wave_id experiment_id phase protocol_version manifest)
  @attempt_fields ~w(attempt_id replaces_attempt_id ordinal treatment status costs provenance payload)
  @document_keys ~w(
    format experiment manifest manifest_digest attempts attempts_digest summary summary_digest ledger_digest
  )
  @experiment_document_keys ~w(workspace_id epic_id wave_id experiment_id phase protocol_version)
  @attempt_document_keys @attempt_fields ++ ["attempt_digest"]
  @sensitive_exact ~w(
    token access_token refresh_token auth_token id_token session_token api_key apikey secret
    client_secret webhook_secret secret_key password authorization cookie set_cookie private_key
    signing_key bearer credential credentials dsn database_url database_uri connection_string
  )
  @sensitive_suffixes ~w(
    _access_token _refresh_token _auth_token _id_token _session_token _api_key _client_secret
    _webhook_secret _secret_key _password _private_key _signing_key _credential _credentials
  )

  @spec create_experiment(map()) ::
          {:ok, Experiment.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_experiment(attrs) when is_map(attrs) do
    attrs = attrs |> select_attrs(@experiment_fields) |> sanitize_map()
    manifest = Map.get(attrs, "manifest", %{})

    if is_map(manifest) do
      attrs = Map.put(attrs, "manifest_digest", CanonicalJSON.digest(manifest))

      case Repo.insert(Experiment.insert_changeset(attrs),
             on_conflict: :nothing,
             conflict_target: [:workspace_id, :epic_id, :wave_id, :experiment_id]
           ) do
        {:ok, _candidate} -> reconcile_experiment(attrs)
        {:error, changeset} -> {:error, changeset}
      end
    else
      {:error, :invalid_manifest}
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

  @spec import_json(binary()) :: {:ok, map()} | {:error, term()}
  def import_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, document} ->
        if json == CanonicalJSON.encode!(document) do
          import_document(document)
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

  defp persist_document(document) do
    experiment_attrs = Map.put(document["experiment"], "manifest", document["manifest"])

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
          existing.manifest_digest == attrs["manifest_digest"] ->
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

  defp validate_attempt_replacement(experiment_id, %{
         "ordinal" => ordinal,
         "replaces_attempt_id" => replacement_id
       })
       when is_binary(replacement_id) do
    previous_ordinal =
      Repo.one(
        from attempt in Attempt,
          where:
            attempt.experiment_id == ^experiment_id and attempt.attempt_id == ^replacement_id,
          select: attempt.ordinal
      )

    cond do
      is_nil(previous_ordinal) -> {:error, :replacement_attempt_not_found}
      ordinal <= previous_ordinal -> {:error, :replacement_ordinal_invalid}
      true -> :ok
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
    key = key |> String.downcase() |> String.replace("-", "_")

    key in @sensitive_exact or
      Enum.any?(@sensitive_suffixes, &String.ends_with?(key, &1))
  end

  defp valid_replacement_ancestry?(attempts) do
    attempts
    |> Enum.reduce_while(%{}, fn attempt, seen ->
      ordinal = attempt["ordinal"]

      case attempt["replaces_attempt_id"] do
        nil ->
          {:cont, Map.put(seen, attempt["attempt_id"], ordinal)}

        replacement_id ->
          case Map.fetch(seen, replacement_id) do
            {:ok, previous_ordinal} when previous_ordinal < ordinal ->
              {:cont, Map.put(seen, attempt["attempt_id"], ordinal)}

            _ ->
              {:halt, :invalid}
          end
      end
    end)
    |> is_map()
  end

  defp exact_keys?(map, expected) when is_map(map),
    do: Map.keys(map) |> Enum.sort() == Enum.sort(expected)

  defp cleanup_temporary_file(path, error) do
    _ = File.rm(path)
    error
  end
end
