defmodule Barkpark.StudioChat.Runtime.CodexContractTest do
  use ExUnit.Case, async: false

  alias Barkpark.StudioChat.Runtime
  alias Barkpark.StudioChat.Runtime.Claude
  alias Barkpark.StudioChat.Runtime.Codex
  alias Barkpark.StudioChat.Runtime.Codex.Protocol
  alias Barkpark.StudioChat.Runtime.Event

  @fake_app_server Path.expand("../../../fixtures/codex_app_server/fake_app_server.py", __DIR__)

  test "Codex and Claude expose the same provider-neutral adapter callbacks" do
    Code.ensure_loaded!(Codex)
    Code.ensure_loaded!(Claude)
    callbacks = Runtime.Adapter.behaviour_info(:callbacks)

    assert Runtime.adapter(:codex) == Codex

    for {callback, arity} <- callbacks do
      assert function_exported?(Codex, callback, arity)
      assert function_exported?(Claude, callback, arity)
    end
  end

  test "native lifecycle events normalize without losing correlation or terminal truth" do
    context = %{session_id: "session-1", thread_id: "thread-1", turn_id: "turn-1", sequence: 7}

    messages = [
      %{
        "method" => "turn/started",
        "params" => %{
          "threadId" => "thread-1",
          "turn" => %{"id" => "turn-1", "status" => "inProgress"}
        }
      },
      %{
        "method" => "item/started",
        "params" => %{
          "threadId" => "thread-1",
          "turnId" => "turn-1",
          "item" => %{"id" => "item-1", "type" => "commandExecution"}
        }
      },
      %{
        "method" => "item/commandExecution/outputDelta",
        "params" => %{
          "threadId" => "thread-1",
          "turnId" => "turn-1",
          "itemId" => "item-1",
          "delta" => "ok"
        }
      },
      %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{
          "threadId" => "thread-1",
          "turnId" => "turn-1",
          "tokenUsage" => %{"inputTokens" => 3, "outputTokens" => 2}
        }
      },
      %{
        "method" => "turn/completed",
        "params" => %{
          "threadId" => "thread-1",
          "turn" => %{"id" => "turn-1", "status" => "completed"}
        }
      }
    ]

    events = Enum.map(messages, &Protocol.normalize(&1, context))

    assert Enum.map(events, & &1.kind) == [
             :turn_started,
             :item_started,
             :tool_delta,
             :usage,
             :turn_completed
           ]

    assert Enum.map(events, & &1.durability) == [
             :durable,
             :durable,
             :delta,
             :durable,
             :durable
           ]

    assert Enum.all?(events, fn %Event{} = event ->
             event.provider == "codex" and event.session_id == "session-1" and
               event.provider_session_id == "thread-1" and event.turn_id == "turn-1" and
               is_binary(event.idempotency_key) and event.native != %{}
           end)

    assert List.last(events).terminal_state == :completed
  end

  test "approval decisions match the pinned v2 command and file response vocabulary" do
    command = "item/commandExecution/requestApproval"
    file = "item/fileChange/requestApproval"

    assert {:ok, %{"decision" => "accept"}} = Protocol.approval_response(command, :allow)

    assert {:ok, %{"decision" => "acceptForSession"}} =
             Protocol.approval_response(command, :allow_session)

    assert {:ok, %{"decision" => "decline"}} = Protocol.approval_response(file, :deny)
    assert {:ok, %{"decision" => "cancel"}} = Protocol.approval_response(file, :cancel)
  end

  test "native envelopes and normalized errors remove credential-shaped fields" do
    event =
      Protocol.normalize(
        %{
          "method" => "error",
          "params" => %{
            "threadId" => "thread-1",
            "error" => %{
              "code" => "provider_error",
              "message" => "failed safely",
              "details" => %{"token" => "secret", "retryable" => false}
            },
            "authorization" => "Bearer secret"
          }
        },
        %{session_id: "session-1", thread_id: "thread-1", turn_id: nil, sequence: 1}
      )

    assert event.kind == :error
    assert event.terminal_state == :failed
    assert event.error["details"] == %{"retryable" => false}
    refute get_in(event.native, ["params", "authorization"])
    refute get_in(event.native, ["params", "error", "details", "token"])
  end

  test "readiness performs only version, initialize, and account/read against the fixture" do
    log =
      Path.join(System.tmp_dir!(), "codex_contract_readiness_#{System.unique_integer()}.jsonl")

    on_exit(fn -> File.rm(log) end)

    assert {:ok, readiness} =
             Codex.readiness(%{
               binary: @fake_app_server,
               args: ["--scenario", "normal", "--log", log],
               timeout_ms: 500
             })

    assert readiness.ready?
    assert readiness.authed?
    assert readiness.version == "0.144.1"

    wire = File.read!(log)
    assert wire =~ "initialize"
    assert wire =~ "initialized"
    assert wire =~ "account/read"
    refute wire =~ "thread/start"
    refute wire =~ "thread/resume"
    refute wire =~ "turn/start"
    refute wire =~ "auth.json"
  end
end
