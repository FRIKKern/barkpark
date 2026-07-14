defmodule Barkpark.StudioChat.RuntimeTelemetryRegressionTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Runtime
  alias Barkpark.StudioChat.Runtime.Event
  alias Barkpark.StudioChat.{RuntimeAdmission, RuntimeTelemetry}

  test "same-key divergent usage conflicts without changing the first projection" do
    session_id = create_session()
    first = usage_event("usage-conflict", 21, 12, 4, 5, 2)
    divergent = usage_event("usage-conflict", 99, 60, 10, 29, 8)

    assert :recorded = RuntimeTelemetry.observe(session_id, first)
    assert :duplicate = RuntimeTelemetry.observe(session_id, first)

    assert {:error, {:idempotency_conflict, "usage-conflict"}} =
             RuntimeTelemetry.observe(session_id, divergent)

    session = StudioChat.get_session(session_id)
    assert session.observed_total_tokens == 21
    assert session.observed_input_tokens == 12
    assert session.observed_cached_input_tokens == 4
    assert session.observed_output_tokens == 5
    assert session.observed_reasoning_output_tokens == 2
  end

  test "late cumulative usage snapshots cannot rewind any observed counter" do
    session_id = create_session()

    assert :recorded =
             RuntimeTelemetry.observe(
               session_id,
               usage_event("usage-high", 160, 100, 40, 60, 20)
             )

    assert :recorded =
             RuntimeTelemetry.observe(
               session_id,
               usage_event("usage-stale", 30, 20, nil, 10, 5)
             )

    session = StudioChat.get_session(session_id)
    assert session.observed_total_tokens == 160
    assert session.observed_input_tokens == 100
    assert session.observed_cached_input_tokens == 40
    assert session.observed_output_tokens == 60
    assert session.observed_reasoning_output_tokens == 20
  end

  test "managed identity distinguishes BEAM adapter metrics from provider metrics" do
    session_id = create_session()
    registry = __MODULE__.IdentityRegistry
    start_supervised!({Registry, keys: :unique, name: registry})

    {:ok, lease} =
      RuntimeAdmission.acquire(session_id, %{
        execution_target: "managed",
        admission_registry: registry,
        managed_runtime_limit: 1
      })

    identity = Runtime.runtime_identity(%{runtime: self()}, lease)

    assert identity.metric_provenance.memory_bytes == "beam_adapter_process"
    assert identity.metric_provenance.reductions == "beam_adapter_process"
    assert identity.metric_provenance.message_queue_len == "beam_adapter_process"
    assert identity.metric_provenance.os_pid == "provider_process"
    assert identity.provider_memory_bytes == nil
    assert identity.provider_cpu_percent == nil
    assert RuntimeTelemetry.managed_runtime_limitations() == identity.limitations

    assert Enum.any?(identity.limitations, &String.contains?(&1, "local BEAM adapter"))
    assert Enum.any?(identity.limitations, &String.contains?(&1, "provider-process CPU"))

    assert :recorded = RuntimeTelemetry.observe_identity(session_id, identity)
    session = StudioChat.get_session(session_id)

    assert session.runtime_identity["metric_provenance"]["memory_bytes"] ==
             "beam_adapter_process"

    assert session.runtime_telemetry_limitations == identity.limitations
  end

  defp create_session do
    id = Ecto.UUID.generate()

    {:ok, _} =
      StudioChat.create_session(%{
        id: id,
        provider: "codex",
        execution_target: "managed",
        mode: "plan"
      })

    id
  end

  defp usage_event(key, total, input, cached, output, reasoning) do
    %Event{
      provider: "codex",
      idempotency_key: key,
      durability: :durable,
      kind: :usage,
      usage: %{
        total: %{
          total_tokens: total,
          input_tokens: input,
          cached_input_tokens: cached,
          output_tokens: output,
          reasoning_output_tokens: reasoning
        },
        last: %{},
        model_context_window: nil
      },
      native: %{}
    }
  end
end
