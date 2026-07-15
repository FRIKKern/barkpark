defmodule Barkpark.StudioChat.RuntimeUsage do
  @moduledoc """
  Append-only, assignment-bound provider usage receipts.

  The attribution argument is the frozen handoff to the CycleFleet assignment
  spine. Until that integration lands, callers supply only the server-minted
  cycle and assignment UUIDs plus the exact Barkpark Task claim they observed.
  Provider-native envelopes are never accepted by this module: normalized
  `Runtime.Event` identity and allowlisted counters are the complete input.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Repo
  alias Barkpark.StudioChat.Runtime.Event
  alias Barkpark.StudioChat.Session
  alias Barkpark.Tasks

  @counter_domain "provider_thread_total_tokens_v1"
  @counter_fields ~w(
    total_tokens input_tokens cached_input_tokens output_tokens reasoning_output_tokens
  )a
  @boundaries ~w(baseline terminal)

  defmodule Receipt do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, Ecto.UUID, autogenerate: false}
    schema "chat_runtime_usage_receipts" do
      field :cycle_id, Ecto.UUID
      field :assignment_id, Ecto.UUID
      field :session_id, Ecto.UUID
      field :task_id, Ecto.UUID
      field :task_doc_id, :string
      field :task_worker_id, :string
      field :task_epoch, :integer
      field :task_work_digest, :string
      field :provider, :string
      field :provider_session_id, :string
      field :turn_id, :string
      field :boundary, :string
      field :observation_state, :string
      field :counter_domain, :string
      field :counters, :map
      field :reason_code, :string
      field :payload_hash, :string
      field :inserted_at, :utc_datetime_usec
    end
  end

  @type record_result ::
          {:ok, :recorded | :duplicate}
          | {:error,
             {:invalid,
              :invalid_attribution
              | :invalid_boundary
              | :invalid_event
              | :invalid_provider_identity
              | :invalid_counter
              | :session_not_found
              | :provider_mismatch
              | :provider_session_mismatch
              | :divergent_replay
              | Tasks.ClaimFence.reason()}}

  @doc "Record one normalized baseline or terminal observation exactly once."
  @spec observe(map(), atom() | String.t(), Event.t()) :: record_result()
  def observe(attribution, boundary, %Event{} = event) when is_map(attribution) do
    with {:ok, receipt} <- normalize(attribution, boundary, event) do
      Repo.transaction(fn -> record_once(receipt, attribution) end)
      |> unwrap_record()
    end
  end

  def observe(_attribution, _boundary, _event), do: {:error, {:invalid, :invalid_attribution}}

  @doc "Reduce the two immutable boundaries for one exact provider turn."
  @spec reduce(map()) :: map()
  def reduce(identity) when is_map(identity) do
    with {:ok, expected} <- normalize_identity(identity) do
      receipts =
        Repo.all(
          from(r in Receipt,
            where:
              r.provider == ^expected.provider and
                r.provider_session_id == ^expected.provider_session_id and
                r.turn_id == ^expected.turn_id,
            order_by: [asc: r.boundary]
          )
        )

      reduce_receipts(receipts, expected)
    else
      _ -> result(:invalid, "invalid_identity")
    end
  end

  def reduce(_identity), do: result(:invalid, "invalid_identity")

  @doc "The single counter domain accepted by the safe reducer."
  def counter_domain, do: @counter_domain

  defp record_once(receipt, attribution) do
    case existing(receipt) do
      %Receipt{} = stored ->
        replay_result(stored, receipt)

      nil ->
        with :ok <- verify_session(receipt),
             {:ok, fence} <- Tasks.verify_claim_fence(receipt.task_id, task_fence(attribution)) do
          receipt = receipt |> Map.merge(fence) |> put_payload_hash()

          {inserted, _} = Repo.insert_all(Receipt, [receipt], on_conflict: :nothing)

          if inserted == 1 do
            :recorded
          else
            receipt |> existing() |> replay_result(receipt)
          end
        else
          {:error, reason} -> Repo.rollback({:invalid, reason})
        end
    end
  end

  defp existing(receipt) do
    Repo.one(
      from(r in Receipt,
        where:
          r.provider == ^receipt.provider and
            r.provider_session_id == ^receipt.provider_session_id and
            r.turn_id == ^receipt.turn_id and r.boundary == ^receipt.boundary
      )
    )
  end

  defp replay_result(%Receipt{payload_hash: hash}, %{payload_hash: hash}), do: :duplicate
  defp replay_result(%Receipt{}, _receipt), do: Repo.rollback({:invalid, :divergent_replay})
  defp replay_result(nil, _receipt), do: Repo.rollback({:invalid, :divergent_replay})

  defp verify_session(receipt) do
    case Repo.one(from(s in Session, where: s.id == ^receipt.session_id, lock: "FOR SHARE")) do
      nil ->
        {:error, :session_not_found}

      %Session{provider: provider} when provider != receipt.provider ->
        {:error, :provider_mismatch}

      %Session{provider_session_id: id} when id != receipt.provider_session_id ->
        {:error, :provider_session_mismatch}

      %Session{} ->
        :ok
    end
  end

  defp normalize(attribution, boundary, %Event{} = event) do
    with {:ok, cycle_id} <- uuid(value(attribution, :cycle_id)),
         {:ok, assignment_id} <- uuid(value(attribution, :assignment_id)),
         {:ok, task_id} <- uuid(get_in_value(attribution, :task, :id)),
         boundary when boundary in @boundaries <- to_string(boundary),
         true <- event.kind == :usage,
         {:ok, session_id} <- uuid(event.session_id),
         {:ok, provider} <- opaque(event.provider),
         {:ok, provider_session_id} <- opaque(event.provider_session_id),
         {:ok, turn_id} <- opaque(event.turn_id),
         {:ok, observation} <- observation(event.usage) do
      safe =
        observation
        |> Map.merge(%{
          id: Ecto.UUID.generate(),
          cycle_id: cycle_id,
          assignment_id: assignment_id,
          session_id: session_id,
          task_id: task_id,
          task_doc_id: get_in_value(attribution, :task, :doc_id),
          task_worker_id: get_in_value(attribution, :task, :worker_id),
          task_epoch: get_in_value(attribution, :task, :epoch),
          task_work_digest: get_in_value(attribution, :task, :work_digest),
          provider: provider,
          provider_session_id: provider_session_id,
          turn_id: turn_id,
          boundary: boundary,
          inserted_at: DateTime.utc_now()
        })
        |> put_payload_hash()

      if valid_fence_shape?(safe),
        do: {:ok, safe},
        else: {:error, {:invalid, :invalid_attribution}}
    else
      boundary when is_binary(boundary) -> {:error, {:invalid, :invalid_boundary}}
      false -> {:error, {:invalid, :invalid_event}}
      {:error, :uuid} -> {:error, {:invalid, :invalid_attribution}}
      {:error, :opaque} -> {:error, {:invalid, :invalid_provider_identity}}
      {:error, :counter} -> {:error, {:invalid, :invalid_counter}}
      _ -> {:error, {:invalid, :invalid_attribution}}
    end
  end

  defp observation(nil) do
    {:ok,
     %{
       observation_state: "unsupported",
       counter_domain: nil,
       counters: %{},
       reason_code: "provider_capability_absent"
     }}
  end

  defp observation(%{} = usage) do
    total = value(usage, :total)

    if is_map(total) do
      counters =
        Map.new(@counter_fields, fn field -> {to_string(field), value(total, field)} end)
        |> Enum.reject(fn {_field, count} -> is_nil(count) end)
        |> Map.new()

      if valid_counters?(counters) and is_integer(counters["total_tokens"]) do
        {:ok,
         %{
           observation_state: "observed",
           counter_domain: @counter_domain,
           counters: counters,
           reason_code: nil
         }}
      else
        {:error, :counter}
      end
    else
      {:error, :counter}
    end
  end

  defp observation(_usage), do: {:error, :counter}

  defp normalize_identity(identity) do
    with {:ok, cycle_id} <- uuid(value(identity, :cycle_id)),
         {:ok, assignment_id} <- uuid(value(identity, :assignment_id)),
         {:ok, session_id} <- uuid(value(identity, :session_id)),
         {:ok, provider} <- opaque(value(identity, :provider)),
         {:ok, provider_session_id} <- opaque(value(identity, :provider_session_id)),
         {:ok, turn_id} <- opaque(value(identity, :turn_id)) do
      {:ok,
       %{
         cycle_id: cycle_id,
         assignment_id: assignment_id,
         session_id: session_id,
         provider: provider,
         provider_session_id: provider_session_id,
         turn_id: turn_id
       }}
    end
  end

  defp reduce_receipts([], _expected), do: result(:missing, "boundary_receipts_missing")

  defp reduce_receipts(receipts, expected) do
    with :ok <- same_identity(receipts, expected),
         :ok <- supported(receipts),
         %Receipt{} = baseline <- Enum.find(receipts, &(&1.boundary == "baseline")),
         %Receipt{} = terminal <- Enum.find(receipts, &(&1.boundary == "terminal")),
         true <- baseline.counter_domain == terminal.counter_domain,
         :ok <- monotonic(baseline.counters, terminal.counters) do
      token_count = terminal.counters["total_tokens"] - baseline.counters["total_tokens"]
      result(:observed, nil, token_count)
    else
      {:error, :unsupported} -> result(:unsupported, "provider_capability_absent")
      {:error, reason} -> result(:invalid, Atom.to_string(reason))
      nil -> missing_boundary(receipts)
      false -> result(:invalid, "counter_domain_mismatch")
    end
  end

  defp same_identity(receipts, expected) do
    Enum.reduce_while(receipts, :ok, fn receipt, :ok ->
      cond do
        receipt.cycle_id != expected.cycle_id -> {:halt, {:error, :cycle_mismatch}}
        receipt.assignment_id != expected.assignment_id -> {:halt, {:error, :assignment_mismatch}}
        receipt.session_id != expected.session_id -> {:halt, {:error, :session_mismatch}}
        true -> {:cont, :ok}
      end
    end)
  end

  defp supported(receipts) do
    if Enum.any?(receipts, &(&1.observation_state == "unsupported")),
      do: {:error, :unsupported},
      else: :ok
  end

  defp monotonic(baseline, terminal) do
    decreased? =
      Enum.any?(@counter_fields, fn field ->
        key = to_string(field)

        case {baseline[key], terminal[key]} do
          {left, right} when is_integer(left) and is_integer(right) -> right < left
          _ -> false
        end
      end)

    if decreased?, do: {:error, :counter_decreased}, else: :ok
  end

  defp missing_boundary(receipts) do
    if Enum.any?(receipts, &(&1.boundary == "baseline")),
      do: result(:missing, "terminal_missing"),
      else: result(:missing, "baseline_missing")
  end

  defp result(state, reason, value \\ nil) do
    token =
      if state == :observed do
        %{"state" => "observed", "value" => value, "unit" => "tokens"}
      else
        %{"state" => Atom.to_string(state), "reason" => reason}
      end

    %{
      "token_count" => token,
      "context_occupancy" => %{
        "state" => "unsupported",
        "reason" => "exact_context_occupancy_unavailable"
      }
    }
  end

  defp task_fence(attribution), do: value(attribution, :task) || %{}

  defp valid_fence_shape?(receipt) do
    is_binary(receipt.task_doc_id) and receipt.task_doc_id != "" and
      is_binary(receipt.task_worker_id) and receipt.task_worker_id != "" and
      is_integer(receipt.task_epoch) and receipt.task_epoch > 0 and
      is_binary(receipt.task_work_digest) and
      Regex.match?(~r/^[0-9a-f]{16}$/, receipt.task_work_digest)
  end

  defp valid_counters?(counters) do
    map_size(counters) > 0 and
      Enum.all?(counters, fn {key, value} ->
        key in Enum.map(@counter_fields, &to_string/1) and is_integer(value) and value >= 0
      end)
  end

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :uuid}
    end
  end

  defp opaque(value) when is_binary(value) do
    value = String.trim(value)
    if value != "" and byte_size(value) <= 255, do: {:ok, value}, else: {:error, :opaque}
  end

  defp opaque(_value), do: {:error, :opaque}

  defp put_payload_hash(receipt) do
    payload = Map.take(receipt, safe_payload_fields())
    Map.put(receipt, :payload_hash, digest(payload))
  end

  defp safe_payload_fields do
    ~w(
      cycle_id assignment_id session_id task_id task_doc_id task_worker_id task_epoch
      task_work_digest provider provider_session_id turn_id boundary observation_state
      counter_domain counters reason_code
    )a
  end

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp unwrap_record({:ok, result}), do: {:ok, result}
  defp unwrap_record({:error, {:invalid, reason}}), do: {:error, {:invalid, reason}}
  defp unwrap_record({:error, reason}), do: {:error, {:invalid, reason}}

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, to_string(key)))
  defp value(_map, _key), do: nil

  defp get_in_value(map, outer, inner), do: map |> value(outer) |> value(inner)
end
