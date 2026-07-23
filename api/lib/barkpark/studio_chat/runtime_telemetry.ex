defmodule Barkpark.StudioChat.RuntimeTelemetry do
  @moduledoc """
  Durable, idempotent projection of provider runtime observations.

  These fields are deliberately separate from the legacy Claude usage totals:
  Codex app-server reports cumulative snapshots and may replay them after a
  resume, while the legacy path increments per-result counters and treats a
  missing number as zero. Runtime observations preserve `nil` as unknown and a
  unique receipt makes an identical provider event safe to replay.

  Registered-host processes are outside this node. Their local PID, memory and
  CPU data therefore remain unavailable rather than being synthesized from the
  Barkpark dispatcher process. Managed-process memory, reductions and queue
  depth describe the local BEAM adapter, not the linked provider process.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Repo
  alias Barkpark.StudioChat.Runtime.Event
  alias Barkpark.StudioChat.Session

  defmodule Receipt do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "chat_runtime_telemetry_events" do
      field :session_id, Ecto.UUID, primary_key: true
      field :event_key, :string, primary_key: true
      field :kind, :string
      field :payload_hash, :string
      field :inserted_at, :utc_datetime_usec
    end
  end

  @usage_counter_fields [
    :observed_input_tokens,
    :observed_cached_input_tokens,
    :observed_output_tokens,
    :observed_reasoning_output_tokens,
    :observed_total_tokens
  ]
  @registered_host_limitations [
    "registered-host process identity is owned by the remote host",
    "registered-host CPU and memory telemetry are unavailable to this node"
  ]
  @managed_runtime_limitations [
    "memory_bytes, reductions, and message_queue_len describe the local BEAM adapter process",
    "provider-process CPU and memory telemetry are unavailable; os_pid is identity only"
  ]

  @type observation_result :: :recorded | :duplicate | :ignored | {:error, term()}

  @doc "Persist a normalized runtime event exactly once."
  @spec observe(String.t(), Event.t()) :: observation_result()
  def observe(session_id, %Event{kind: :usage, usage: usage} = event)
      when is_binary(session_id) and is_map(usage) do
    total = Map.get(usage, :total) || %{}

    persist_once(session_id, event_key(event), :usage, usage,
      observed_input_tokens: number(total, :input_tokens),
      observed_cached_input_tokens: number(total, :cached_input_tokens),
      observed_output_tokens: number(total, :output_tokens),
      observed_reasoning_output_tokens: number(total, :reasoning_output_tokens),
      observed_total_tokens: number(total, :total_tokens),
      observed_context_window: number(usage, :model_context_window)
    )
  end

  def observe(session_id, %Event{kind: :runtime_acknowledged} = event)
      when is_binary(session_id) do
    payload = %{model: event.observed_model, effort: event.observed_effort}

    persist_once(session_id, event_key(event), :runtime_acknowledged, payload,
      observed_model: text(event.observed_model),
      observed_effort: text(event.observed_effort)
    )
  end

  def observe(_session_id, %Event{}), do: :ignored

  @doc "Persist one safe runtime identity sample."
  @spec observe_identity(String.t(), map()) :: observation_result()
  def observe_identity(session_id, sample) when is_binary(session_id) and is_map(sample) do
    key = "runtime-identity:" <> (sample[:runtime_id] || sample["runtime_id"] || digest(sample))
    limitations = sample[:limitations] || sample["limitations"] || []

    persist_once(session_id, key, :runtime_identity, sample,
      runtime_identity: stringify_keys(sample),
      runtime_telemetry_limitations: Enum.map(limitations, &to_string/1)
    )
  end

  @doc "The explicit limitations persisted for registered-host sessions."
  def registered_host_limitations, do: @registered_host_limitations

  @doc "The metric provenance limitations persisted for managed sessions."
  def managed_runtime_limitations, do: @managed_runtime_limitations

  defp persist_once(session_id, event_key, kind, payload, fields) do
    now = DateTime.utc_now()
    payload_hash = digest(payload)

    Repo.transaction(fn ->
      # A locked existence pre-check BEFORE the receipt insert. The Receipt row
      # carries a real `session_id` FK (RESTRICT), and `on_conflict: :nothing`
      # does NOT suppress a foreign-key violation — so a `StudioChat.delete_session`
      # that COMMITS between this observe and the insert would surface the FK abort
      # as a raw `Postgrex.Error` escaping `Repo.transaction`, crashing the Recorder
      # GenServer. `FOR SHARE` takes a shared lock the concurrent delete's exclusive
      # lock must wait behind, and a missing row rolls back to an explicit
      # `:session_not_found` — mirroring `project_observation/3`'s guard below.
      Repo.one(from(s in Session, where: s.id == ^session_id, lock: "FOR SHARE")) ||
        Repo.rollback(:session_not_found)

      {inserted, _} =
        Repo.insert_all(
          Receipt,
          [
            %{
              session_id: session_id,
              event_key: event_key,
              kind: to_string(kind),
              payload_hash: payload_hash,
              inserted_at: now
            }
          ],
          on_conflict: :nothing,
          conflict_target: [:session_id, :event_key]
        )

      if inserted == 0 do
        resolve_replay(session_id, event_key, payload_hash)
      else
        project_observation(session_id, kind, fields)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_replay(session_id, event_key, payload_hash) do
    stored_hash =
      Repo.one(
        from(r in Receipt,
          where: r.session_id == ^session_id and r.event_key == ^event_key,
          select: r.payload_hash
        )
      )

    if stored_hash == payload_hash do
      :duplicate
    else
      Repo.rollback({:idempotency_conflict, event_key})
    end
  end

  defp project_observation(session_id, kind, fields) do
    session =
      Repo.one(from(s in Session, where: s.id == ^session_id, lock: "FOR UPDATE")) ||
        Repo.rollback(:session_not_found)

    fields = if kind == :usage, do: usage_high_water(session, fields), else: fields

    {1, _} = Repo.update_all(from(s in Session, where: s.id == ^session_id), set: fields)
    :recorded
  end

  defp usage_high_water(session, fields) do
    Enum.map(fields, fn
      {field, value} when field in @usage_counter_fields ->
        {field, high_water(Map.get(session, field), value)}

      {:observed_context_window = field, value} ->
        {field, value || Map.get(session, field)}
    end)
  end

  defp high_water(nil, nil), do: nil
  defp high_water(current, nil), do: current
  defp high_water(nil, value), do: value
  defp high_water(current, value), do: max(current, value)

  defp event_key(%Event{idempotency_key: key}) when is_binary(key) and key != "", do: key
  defp event_key(%Event{} = event), do: "runtime-event:" <> digest(event)

  defp number(map, key) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      value when is_integer(value) and value >= 0 -> value
      _ -> nil
    end
  end

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_), do: nil

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
