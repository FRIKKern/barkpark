defmodule BarkparkWeb.Integration.ChatAnswerHostGateTest do
  @moduledoc """
  task-b03e470c315a6664: `POST /v1/chat/sessions/:id/answer` hands the runtime
  `{:allow, updated}` exactly as `/approval` does with `decision: "allow"`, so it
  must pass the same `HostExecutionGate.authorize_turn/2` check
  (task-6ca882967fd95dda). Before the fix, a principal that could see a
  managed host-exec session but was not an instance principal got 204 from
  `/answer` and the turn went on, where `/approval` allow answered 403.

  The non-instance principal here is a Default-bound chat token while the
  operator allowlist is armed with another token. The session is a `codex`
  one owned by the Default workspace (a codex turn always runs on the host).
  A test adapter echoes every `answer_approval/3` delivery to the test pid,
  so "the runtime got nothing" is observable.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, ChatHosts}
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.{Recorder, RuntimeAdmission}
  alias BarkparkWeb.Studio.ClaudeChat

  defmodule EchoCodex do
    @moduledoc false
    def capabilities, do: %{modes: ["default"], models: ["gpt-5.6"], efforts: ["high"]}
    def cwd, do: "/tmp/codex-managed"

    def answer_approval(_ref, request_id, decision) do
      case Application.get_env(:barkpark, :chat_answer_test_pid) do
        pid when is_pid(pid) -> send(pid, {:answered, request_id, decision})
        _ -> :ok
      end

      :ok
    end
  end

  @ask %{
    "questions" => [
      %{"question" => "Which color?", "options" => [%{"label" => "Blue"}, %{"label" => "Red"}]}
    ]
  }

  setup do
    {default_ws, _} = ensure_default_scope!()

    keys = [
      :claude_chat,
      :public_demo_studio,
      :studio_chat_runtime_adapters,
      :operator_emails,
      :operator_token_ids,
      :chat_answer_test_pid
    ]

    prev = Map.new(keys, &{&1, Application.get_env(:barkpark, &1)})

    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    Application.put_env(
      :barkpark,
      :studio_chat_runtime_adapters,
      Map.put(prev.studio_chat_runtime_adapters || %{}, :codex, EchoCodex)
    )

    Application.put_env(:barkpark, :chat_answer_test_pid, self())

    # The operator allowlist, armed: only `op` is an instance principal.
    op = "answergate-op-#{System.unique_integer([:positive])}"
    {:ok, op_token} = Auth.create_token(op, "op", "production", ["read", "write", "admin"])
    Application.put_env(:barkpark, :operator_emails, [])
    Application.put_env(:barkpark, :operator_token_ids, [op_token.id])

    # A Default-bound chat token: sees Default-owned sessions, is not on the list.
    seat = "answergate-seat-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(seat, "seat", "production", ["chat"], default_ws.id)

    on_exit(fn ->
      if Process.whereis(Barkpark.StudioChat.RuntimeSupervisor) do
        for {_, pid, _, _} <-
              DynamicSupervisor.which_children(Barkpark.StudioChat.RuntimeSupervisor),
            is_pid(pid),
            do: DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)
      end

      for {key, val} <- prev do
        if is_nil(val),
          do: Application.delete_env(:barkpark, key),
          else: Application.put_env(:barkpark, key, val)
      end
    end)

    %{default_ws: default_ws, op: op, seat: seat}
  end

  defp as(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp pending_question!(sid, request_id) do
    {:ok, _} =
      StudioChat.append_message(StudioChat.get_session(sid), %{
        role: "question",
        source_markdown: "AskUserQuestion",
        metadata: %{
          "request_id" => request_id,
          "tool_name" => "AskUserQuestion",
          "input" => @ask,
          "approval_status" => "pending"
        }
      })
  end

  # A managed codex session owned by the Default workspace, a pending question
  # on it and a live runtime to deliver an answer to.
  defp host_exec_session!(ws, request_id) do
    sid = Ecto.UUID.generate()

    {:ok, _} =
      StudioChat.create_session(
        %{
          id: sid,
          cwd: ClaudeChat.cwd(),
          mode: "plan",
          provider: "codex",
          execution_target: "managed"
        },
        {:workspace, ws.id}
      )

    pending_question!(sid, request_id)
    {:ok, _} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})
    sid
  end

  defp answer(raw, sid, request_id) do
    as(raw)
    |> post(
      "/v1/chat/sessions/#{sid}/answer",
      Jason.encode!(%{request_id: request_id, answers: %{"Which color?" => "Blue"}})
    )
  end

  defp status_of(sid) do
    [row] = StudioChat.list_messages(sid, :global)
    row.metadata["approval_status"]
  end

  test "a non-instance principal's /answer on a host-exec session is refused like /approval allow",
       %{default_ws: ws, seat: seat} do
    sid = host_exec_session!(ws, "q-1")
    leases = RuntimeAdmission.active_count()

    approval =
      as(seat)
      |> post(
        "/v1/chat/sessions/#{sid}/approval",
        Jason.encode!(%{request_id: "q-1", decision: "allow"})
      )

    assert approval.status == 403
    assert json_response(approval, 403)["error"]["code"] == "host_execution_not_permitted"

    resp = answer(seat, sid, "q-1")

    assert resp.status == 403, "/answer answered #{resp.status} where /approval allow is 403"
    assert json_response(resp, 403)["error"]["code"] == "host_execution_not_permitted"

    refute_receive {:answered, "q-1", _}, 200
    assert status_of(sid) == "pending"
    assert RuntimeAdmission.active_count() == leases
  end

  test "CONTROL: the instance principal still answers a host-exec session (204)",
       %{default_ws: ws, op: op} do
    sid = host_exec_session!(ws, "q-2")

    assert answer(op, sid, "q-2").status == 204

    assert_receive {:answered, "q-2", {:allow, %{"answers" => %{"Which color?" => "Blue"}}}},
                   1_000

    assert status_of(sid) == "allowed"
  end

  test "CONTROL: a registered-host session is not gated (204 for the same principal)",
       %{default_ws: ws, seat: seat} do
    {:ok, %{enrollment_token: t}} = ChatHosts.issue_enrollment(ws.id, %{name: "answergate"})
    {:ok, %{credential: credential}} = ChatHosts.enroll(t)
    {:ok, host} = ChatHosts.authenticate(credential)

    sid = Ecto.UUID.generate()

    {:ok, _} =
      StudioChat.create_session(
        %{
          id: sid,
          mode: "plan",
          provider: "claude",
          execution_target: "registered_host",
          execution_host_id: host.id
        },
        {:workspace, ws.id}
      )

    pending_question!(sid, "q-3")

    assert answer(seat, sid, "q-3").status == 204
    assert status_of(sid) == "allowed"
  end
end
