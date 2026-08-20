defmodule Barkpark.StudioChat.RuntimeTelemetryTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.StudioChat.Runtime
  alias Barkpark.StudioChat.Runtime.Codex.Session, as: CodexSession
  alias Barkpark.StudioChat.Runtime.Codex.Protocol
  alias Barkpark.StudioChat.Runtime.Event
  alias Barkpark.StudioChat.{RuntimeAdmission, RuntimeTelemetry}

  defmodule FakeCodex do
    @behaviour Runtime.Adapter

    def start(_opts), do: {:ok, %{runtime: spawn(fn -> receive_loop() end)}}
    def resume(opts), do: start(opts)
    def send_turn(_runtime, _content), do: :ok
    def steer(_runtime, _command), do: :ok
    def interrupt(_runtime), do: {:ok, "interrupt"}
    def answer_approval(_runtime, _approval_id, _decision), do: :ok

    def close(%{runtime: pid}) do
      send(pid, :stop)
      :ok
    end

    def readiness(_opts), do: %{ready?: true}
    def capabilities, do: %{modes: [], models: [], efforts: []}

    defp receive_loop do
      receive do
        :stop -> :ok
        _ -> receive_loop()
      end
    end
  end

  setup do
    previous = Application.get_env(:barkpark, :studio_chat_runtime_adapters)
    Application.put_env(:barkpark, :studio_chat_runtime_adapters, %{codex: FakeCodex})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :studio_chat_runtime_adapters, previous),
        else: Application.delete_env(:barkpark, :studio_chat_runtime_adapters)
    end)

    :ok
  end

  test "schema-real Codex usage stays nullable and duplicate-safe" do
    session_id = create_session()

    message = %{
      "method" => "thread/tokenUsage/updated",
      "params" => %{
        "threadId" => "thread-1",
        "turnId" => "turn-1",
        "tokenUsage" => %{
          "total" => %{
            "totalTokens" => 21,
            "inputTokens" => 12,
            "cachedInputTokens" => 4,
            "outputTokens" => 5,
            "reasoningOutputTokens" => 2
          },
          "last" => %{
            "totalTokens" => 9,
            "inputTokens" => 5,
            "cachedInputTokens" => 2,
            "outputTokens" => 2,
            "reasoningOutputTokens" => 1
          },
          "modelContextWindow" => nil
        }
      }
    }

    context = %{session_id: session_id, thread_id: "thread-1", turn_id: "turn-1", sequence: 4}
    event = Protocol.normalize(message, context)
    replay = Protocol.normalize(message, %{context | sequence: 99})

    assert event.idempotency_key == replay.idempotency_key
    assert event.usage.total.input_tokens == 12
    assert event.usage.last.reasoning_output_tokens == 1
    assert event.usage.model_context_window == nil

    assert :recorded = RuntimeTelemetry.observe(session_id, event)
    assert :duplicate = RuntimeTelemetry.observe(session_id, replay)

    session = StudioChat.get_session(session_id)
    assert session.observed_input_tokens == 12
    assert session.observed_cached_input_tokens == 4
    assert session.observed_output_tokens == 5
    assert session.observed_reasoning_output_tokens == 2
    assert session.observed_total_tokens == 21
    assert session.observed_context_window == nil
  end

  test "thread start emits and persists the app-server acknowledged model and effort" do
    session_id = create_session()
    binary = acknowledgement_fixture()

    assert {:ok, runtime} =
             CodexSession.start(%{
               binary: binary,
               args: [],
               sink: self(),
               session_id: session_id,
               timeout_ms: 500
             })

    assert_receive {:studio_chat_runtime_event,
                    %Event{
                      kind: :runtime_acknowledged,
                      observed_model: "gpt-observed",
                      observed_effort: "high"
                    } = event}

    assert :recorded = RuntimeTelemetry.observe(session_id, event)
    assert :duplicate = RuntimeTelemetry.observe(session_id, event)

    session = StudioChat.get_session(session_id)
    assert session.observed_model == "gpt-observed"
    assert session.observed_effort == "high"
    assert :ok = CodexSession.close(runtime)
  end

  test "Recorder projects normalized usage end to end" do
    session_id = create_session()
    {:ok, recorder} = Recorder.ensure(%{session_id: session_id, provider: "codex", mode: "plan"})

    event = %Event{
      provider: "codex",
      session_id: session_id,
      provider_session_id: "thread-1",
      turn_id: "turn-1",
      idempotency_key: "usage-e2e-1",
      durability: :durable,
      kind: :usage,
      usage: %{
        total: %{
          total_tokens: 8,
          input_tokens: 5,
          cached_input_tokens: nil,
          output_tokens: 3,
          reasoning_output_tokens: nil
        },
        last: %{},
        model_context_window: nil
      },
      native: %{}
    }

    send(recorder, {:studio_chat_runtime_event, event})
    :sys.get_state(recorder)

    session = StudioChat.get_session(session_id)
    assert session.observed_total_tokens == 8
    assert session.observed_cached_input_tokens == nil

    DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, recorder)
  end

  test "managed identity is opaque and registered-host limitations stay explicit" do
    registry = __MODULE__.IdentityRegistry
    start_supervised!({Registry, keys: :unique, name: registry})

    {:ok, lease} =
      RuntimeAdmission.acquire("identity-session", %{
        execution_target: "managed",
        admission_registry: registry,
        managed_runtime_limit: 1
      })

    managed = Runtime.runtime_identity(%{runtime: self()}, lease)
    assert managed.status == "observed"
    assert is_binary(managed.runtime_id)
    assert managed.beam_pid == inspect(self())
    assert is_integer(managed.memory_bytes)

    remote = %Runtime.RemoteRef{
      provider: "codex",
      session_id: "remote-session",
      workspace_id: Ecto.UUID.generate(),
      execution_host_id: Ecto.UUID.generate()
    }

    registered = Runtime.runtime_identity(remote, :not_managed)
    assert registered.status == "unsupported"
    assert registered.os_pid == nil
    assert registered.memory_bytes == nil
    assert registered.limitations == RuntimeTelemetry.registered_host_limitations()
  end

  test "a runtime event whose session was deleted mid-flight is an explicit error, not an FK crash" do
    session_id = create_session()

    # The delete-commits-first race: the session row is gone before the in-flight
    # telemetry event lands. The Receipt insert carries a real session_id FK and
    # `on_conflict: :nothing` does NOT suppress an FK violation, so without the
    # locked pre-check the insert_all would raise Postgrex.Error out of
    # Repo.transaction. The FOR SHARE guard turns it into a bounded result.
    assert {:ok, %StudioChat.Session{}} = StudioChat.delete_session(session_id)

    assert {:error, :session_not_found} =
             RuntimeTelemetry.observe(session_id, usage_event(session_id))
  end

  test "the Recorder survives a runtime event for a session deleted out from under it" do
    session_id = create_session()
    {:ok, recorder} = Recorder.ensure(%{session_id: session_id, provider: "codex", mode: "plan"})

    assert {:ok, %StudioChat.Session{}} = StudioChat.delete_session(session_id)

    # The Recorder fire-and-forgets observe/2's result, so a RAISED FK abort would
    # kill the GenServer. With the guard, observe returns {:error, :session_not_found}
    # and the Recorder stays alive (mutation: strip the pre-check → this exits).
    send(recorder, {:studio_chat_runtime_event, usage_event(session_id)})
    :sys.get_state(recorder)
    assert Process.alive?(recorder)

    DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, recorder)
  end

  defp usage_event(session_id) do
    %Event{
      provider: "codex",
      session_id: session_id,
      provider_session_id: "thread-race",
      turn_id: "turn-race",
      idempotency_key: "usage-race-#{System.unique_integer([:positive])}",
      durability: :durable,
      kind: :usage,
      usage: %{
        total: %{
          total_tokens: 5,
          input_tokens: 3,
          cached_input_tokens: nil,
          output_tokens: 2,
          reasoning_output_tokens: nil
        },
        last: %{},
        model_context_window: nil
      },
      native: %{}
    }
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

  defp acknowledgement_fixture do
    path =
      Path.join(
        System.tmp_dir!(),
        "codex_acknowledgement_#{System.unique_integer([:positive])}.py"
      )

    File.write!(path, """
    #!/usr/bin/env python3
    import json
    import sys

    for raw in sys.stdin:
        message = json.loads(raw)
        method = message.get("method")
        if method == "initialize":
            result = {"codexHome": "/tmp/codex", "platformFamily": "unix",
                      "platformOs": "linux", "userAgent": "codex-cli/test"}
        elif method == "account/read":
            result = {"account": {"type": "apiKey"}, "requiresOpenaiAuth": True}
        elif method == "thread/start":
            result = {"thread": {"id": "thread-ack"}, "model": "gpt-observed",
                      "reasoningEffort": "high"}
        else:
            continue
        print(json.dumps({"id": message["id"], "result": result}), flush=True)
    """)

    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
