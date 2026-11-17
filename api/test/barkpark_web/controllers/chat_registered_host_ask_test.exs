defmodule BarkparkWeb.ChatRegisteredHostAskTest do
  @moduledoc """
  A registered Claude host's ask reaches the store, the stream and `/answer`
  with its real tool, input and title (task-1c727b482160ddbc).

  Live on guerrilla: claude on a registered Go host called AskUserQuestion; the
  permission frame said `{input: {}, title: null, tool_name: "Approval"}`, the
  stored row was role approval with text "Approval", and `POST /answer` 404d
  because no question row existed. These tests drive the public path: a session
  created over HTTP, a message sent so the Recorder holds a `RemoteRef`, the
  host's own `approval_requested` payload posted through `ChatHosts.accept_event/2`
  (what `POST /v1/chat-host/events` calls), and the host's commands read back
  the way `GET /v1/chat-host/commands` does.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.RegisteredHost
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.Tenancy
  alias BarkparkWeb.ChatController

  @dataset "production"
  @fixture Path.expand("../../support/fixtures/chat_host_go_capabilities.json", __DIR__)

  @question "Which database should we use?"
  @multi "Which features do you want?"

  # What Claude puts in a can_use_tool request for AskUserQuestion.
  @ask_input %{
    "questions" => [
      %{
        "header" => "Database",
        "multiSelect" => false,
        "question" => @question,
        "options" => [
          %{"label" => "Postgres", "description" => "Relational"},
          %{"label" => "SQLite", "description" => "Embedded"},
          %{"label" => "Mongo", "description" => "Documents"}
        ]
      },
      %{
        "header" => "Features",
        "multiSelect" => true,
        "question" => @multi,
        "options" => [%{"label" => "Auth"}, %{"label" => "Search"}, %{"label" => "Billing"}]
      }
    ]
  }

  setup do
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      reap_recorders()
      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "rha-#{suffix}", name: "RHA #{suffix}"})

    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{
        name: "go-host-#{suffix}",
        approved_roots: [System.tmp_dir!()]
      })

    caps = @fixture |> File.read!() |> Jason.decode!()

    {:ok, %{credential: credential}} =
      ChatHosts.enroll(issued.enrollment_token, %{"protocol_version" => 1, "capabilities" => caps})

    {:ok, host} = ChatHosts.authenticate(credential)
    {:ok, _} = ChatHosts.heartbeat(host, %{"protocol_version" => 1, "capabilities" => caps})

    raw = "rha-member-#{suffix}"
    {:ok, _} = Auth.create_token(raw, "rha-member", @dataset, ["read", "write", "admin"], ws.id)

    sid = start_host_turn(raw, issued.host.id)
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))

    %{raw: raw, sid: sid, host: Repo.get!(RegisteredHost, issued.host.id)}
  end

  describe "a registered Claude host's approval_requested" do
    test "AskUserQuestion is a question row carrying the questions, and the frame names the tool",
         %{sid: sid, host: host} do
      post_ask!(host, sid, "ask-q1", "AskUserQuestion", @ask_input)

      assert_receive {:claude_chat_permission, ask}, 1_000

      assert ask == %{
               request_id: "ask-q1",
               tool_name: "AskUserQuestion",
               input: @ask_input,
               title: nil
             }

      frame = ChatController.sse_permission_frame(ask)
      assert frame =~ ~s("tool_name":"AskUserQuestion")
      assert frame =~ @question

      assert [row] = rows(sid, "question")
      assert row.metadata["request_id"] == "ask-q1"
      assert row.metadata["tool_name"] == "AskUserQuestion"
      assert row.metadata["input"] == @ask_input
      assert row.metadata["approval_status"] == "pending"
      assert rows(sid, "approval") == []
    end

    test "ExitPlanMode is a plan row carrying the plan", %{sid: sid, host: host} do
      plan = "1. Add the table\n2. Wire the endpoint"
      post_ask!(host, sid, "ask-p1", "ExitPlanMode", %{"plan" => plan})

      assert_receive {:claude_chat_permission, %{tool_name: "ExitPlanMode"}}, 1_000
      assert [row] = rows(sid, "plan")
      assert row.metadata["input"] == %{"plan" => plan}
    end

    test "a tool ask is an approval row naming the tool, its input and the host's title",
         %{sid: sid, host: host} do
      input = %{"file_path" => "/tmp/a.txt", "content" => "hello"}
      post_ask!(host, sid, "ask-w1", "Write", input, "Claude wants to write a.txt")

      assert_receive {:claude_chat_permission, ask}, 1_000
      assert ask.tool_name == "Write"
      assert ask.input == input
      assert ask.title == "Claude wants to write a.txt"

      assert [row] = rows(sid, "approval")
      assert row.metadata["tool_name"] == "Write"
      assert row.metadata["input"] == input
      assert row.source_markdown == "Claude wants to write a.txt"
    end
  end

  describe "POST /v1/chat/sessions/:id/answer on a registered-host question" do
    test "a valid selection is 204 and leases the host an allow carrying the rebuilt input",
         %{raw: raw, sid: sid, host: host} do
      post_ask!(host, sid, "ask-q2", "AskUserQuestion", @ask_input)
      assert_receive {:claude_chat_permission, _}, 1_000

      resp =
        json_conn(raw)
        |> post(
          "/v1/chat/sessions/#{sid}/answer",
          Jason.encode!(%{
            request_id: "ask-q2",
            answers: %{@question => "Postgres", @multi => ["Auth", "Search"]}
          })
        )

      assert resp.status == 204, "answer answered #{resp.status}: #{resp.resp_body}"

      assert [%{command: command}] = host_commands(host, sid, :answer_approval)
      assert command.approval_id == "ask-q2"

      assert command.payload.decision == %{
               "kind" => "allow",
               "value" =>
                 Map.put(@ask_input, "answers", %{
                   @question => "Postgres",
                   @multi => "Auth, Search"
                 })
             }

      assert [row] = rows(sid, "question")
      assert row.metadata["approval_status"] == "allowed"
    end

    test "a label the ask does not offer is a 400 and leases nothing",
         %{raw: raw, sid: sid, host: host} do
      post_ask!(host, sid, "ask-q3", "AskUserQuestion", @ask_input)
      assert_receive {:claude_chat_permission, _}, 1_000

      body =
        json_conn(raw)
        |> post(
          "/v1/chat/sessions/#{sid}/answer",
          Jason.encode!(%{request_id: "ask-q3", answers: %{@question => "Oracle"}})
        )
        |> json_response(400)

      assert body["error"]["message"] =~ "not one of the options"
      assert host_commands(host, sid, :answer_approval) == []
      assert [%{metadata: %{"approval_status" => "pending"}}] = rows(sid, "question")
    end
  end

  # task-035d3495dae536cf: the route delivered an answer to the host before it
  # read the stored ask, so an answer to an ask the server had canceled (a newer
  # lease's turn, a teardown) reached the newer run as an unknown approval.
  describe "POST /v1/chat/sessions/:id/approval on a registered-host ask" do
    test "an answer to a canceled ask is a 409 naming the status and leases nothing",
         %{raw: raw, sid: sid, host: host} do
      post_ask!(host, sid, "ask-c1", "Write", %{"file_path" => "/tmp/c.txt"})
      assert_receive {:claude_chat_permission, _}, 1_000
      assert [%{lease_id: turn_lease}] = host_commands(host, sid, :send_turn)
      assert {:ok, _} = StudioChat.update_approval_status(sid, "ask-c1", "canceled")

      for decision <- ["allow", "deny"] do
        resp = approve(raw, sid, "ask-c1", decision)
        assert resp.status == 409, "#{decision} answered #{resp.status}: #{resp.resp_body}"
        error = Jason.decode!(resp.resp_body)["error"]
        assert error["code"] == "conflict"
        assert error["details"] == %{"approval_status" => "canceled"}
      end

      assert host_commands(host, sid, :answer_approval) == []
      assert [%{metadata: %{"approval_status" => "canceled"}}] = rows(sid, "approval")
      assert ChatHosts.lease_live?(turn_lease), "the running turn's lease is untouched"
    end

    test "a pending ask is answered once; a repeat, an opposite or an unknown answer stays a 204 and leases nothing",
         %{raw: raw, sid: sid, host: host} do
      post_ask!(host, sid, "ask-a1", "Write", %{"file_path" => "/tmp/a.txt"})
      assert_receive {:claude_chat_permission, _}, 1_000

      assert approve(raw, sid, "ask-a1", "allow").status == 204
      assert [%{command: command}] = host_commands(host, sid, :answer_approval)
      assert command.approval_id == "ask-a1"

      for {request_id, decision} <- [{"ask-a1", "allow"}, {"ask-a1", "deny"}, {"nope", "allow"}] do
        resp = approve(raw, sid, request_id, decision)
        assert resp.status == 204, "#{request_id}/#{decision} answered #{resp.status}"
      end

      assert [_only_the_first] = host_commands(host, sid, :answer_approval)
      assert [%{metadata: %{"approval_status" => "allowed"}}] = rows(sid, "approval")
    end
  end

  # task-dc4980982da790c9, rev26731 on #26937: "no local Recorder" and "the
  # Recorder did not answer" are not "no runtime". The host's turn is still
  # blocked on the ask, so an answer must leave it pending (503), never cancel it.
  describe "an answer while the host's lease is live but no Recorder answers" do
    test "after a restart (no Recorder, lease live) both routes 503 and keep the asks; after a send they deliver once",
         %{raw: raw, sid: sid, host: host} do
      asks!(host, sid)
      [%{lease_id: turn_lease}] = host_commands(host, sid, :send_turn)
      kill_recorder!(sid)

      assert_unavailable(approve(raw, sid, "ask-b1", "allow"))
      assert_unavailable(answer(raw, sid, "ask-b1q"))
      assert_pending_and_unleased(host, sid)
      assert ChatHosts.lease_live?(turn_lease)

      send_resp =
        json_conn(raw)
        |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(%{content: "still there?"}))

      assert send_resp.status == 202
      assert_delivered_once(raw, host, sid)
    end

    test "a Recorder that does not answer in time is a 503 on both routes; after it resumes they deliver once",
         %{raw: raw, sid: sid, host: host} do
      asks!(host, sid)
      recorder = Recorder.whereis(sid)
      :ok = :sys.suspend(recorder)

      try do
        assert_unavailable(approve(raw, sid, "ask-b1", "allow"))
        assert_unavailable(answer(raw, sid, "ask-b1q"))
      after
        :sys.resume(recorder)
      end

      assert_pending_and_unleased(host, sid)
      assert_delivered_once(raw, host, sid)
    end

    # rev26731 round 2, H3: past `expires_at` but inside `end_expired_turns`'
    # grace the lease is still `running`, and the host's next heartbeat renews
    # it. The turn is still blocked on the ask, so it must not be canceled.
    test "a lease past expires_at but inside the sweep's grace keeps the asks: both routes 503",
         %{raw: raw, sid: sid, host: host} do
      asks!(host, sid)
      [%{lease_id: turn_lease}] = host_commands(host, sid, :send_turn)
      kill_recorder!(sid)
      expire!(turn_lease, -30)

      assert_unavailable(approve(raw, sid, "ask-b1", "allow"))
      assert_unavailable(answer(raw, sid, "ask-b1q"))
      assert_pending_and_unleased(host, sid)
      assert ChatHosts.end_expired_turns() == 0
    end

    test "a lease past the sweep's grace no longer holds the turn: both routes cancel the asks",
         %{raw: raw, sid: sid, host: host} do
      asks!(host, sid)
      [%{lease_id: turn_lease}] = host_commands(host, sid, :send_turn)
      kill_recorder!(sid)
      expire!(turn_lease, -120)

      assert approve(raw, sid, "ask-b1", "allow").status == 409
      assert answer(raw, sid, "ask-b1q").status == 404
      assert host_commands(host, sid, :answer_approval) == []
      assert [%{metadata: %{"approval_status" => "canceled"}}] = rows(sid, "approval")
      assert [%{metadata: %{"approval_status" => "canceled"}}] = rows(sid, "question")
    end
  end

  # Move the lease's expiry `seconds` from now, as a host that stopped
  # heartbeating would leave it; its status stays `leased`/`running`.
  defp expire!(lease_id, seconds) do
    at = DateTime.add(DateTime.utc_now(), seconds)

    {1, _} =
      Repo.update_all(
        from(l in Barkpark.ChatHosts.ExecutionLease, where: l.id == ^lease_id),
        set: [expires_at: at]
      )

    refute ChatHosts.lease_live?(lease_id)
  end

  defp asks!(host, sid) do
    post_ask!(host, sid, "ask-b1", "Write", %{"file_path" => "/tmp/b1.txt"})
    assert_receive {:claude_chat_permission, %{request_id: "ask-b1"}}, 1_000
    post_ask!(host, sid, "ask-b1q", "AskUserQuestion", @ask_input)
    assert_receive {:claude_chat_permission, %{request_id: "ask-b1q"}}, 1_000
  end

  # As on a deploy: the Recorder dies with no teardown, the host's lease lives on.
  defp kill_recorder!(sid) do
    recorder = Recorder.whereis(sid)
    ref = Process.monitor(recorder)
    Process.exit(recorder, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}, 1_000
    await_unregistered(sid)
  end

  # A Registry drops a dead owner's name asynchronously.
  defp await_unregistered(sid, tries \\ 100) do
    cond do
      Recorder.whereis(sid) == nil -> :ok
      tries == 0 -> flunk("the killed Recorder stayed registered")
      true -> Process.sleep(10) && await_unregistered(sid, tries - 1)
    end
  end

  defp assert_unavailable(resp) do
    assert resp.status == 503, "answered #{resp.status}: #{resp.resp_body}"
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "runtime_unavailable"
  end

  defp assert_pending_and_unleased(host, sid) do
    assert host_commands(host, sid, :answer_approval) == []
    assert [%{metadata: %{"approval_status" => "pending"}}] = rows(sid, "approval")
    assert [%{metadata: %{"approval_status" => "pending"}}] = rows(sid, "question")
  end

  defp assert_delivered_once(raw, host, sid) do
    assert approve(raw, sid, "ask-b1", "allow").status == 204
    assert answer(raw, sid, "ask-b1q").status == 204

    leased = host |> host_commands(sid, :answer_approval) |> Enum.map(& &1.command.approval_id)
    assert Enum.sort(leased) == ["ask-b1", "ask-b1q"]

    assert [%{metadata: %{"approval_status" => "allowed"}}] = rows(sid, "approval")
    assert [%{metadata: %{"approval_status" => "allowed"}}] = rows(sid, "question")
  end

  defp answer(raw, sid, request_id) do
    json_conn(raw)
    |> post(
      "/v1/chat/sessions/#{sid}/answer",
      Jason.encode!(%{
        request_id: request_id,
        answers: %{@question => "Postgres", @multi => ["Auth"]}
      })
    )
  end

  defp approve(raw, sid, request_id, decision) do
    json_conn(raw)
    |> post(
      "/v1/chat/sessions/#{sid}/approval",
      Jason.encode!(%{request_id: request_id, decision: decision})
    )
  end

  # A registered-host session with a live Recorder (holding a RemoteRef) and one
  # leased send_turn, reached through the same HTTP calls a client makes.
  defp start_host_turn(raw, host_id) do
    session =
      json_conn(raw)
      |> post(
        "/v1/chat/sessions",
        Jason.encode!(%{
          provider: "claude",
          execution_target: "registered_host",
          execution_host_id: host_id
        })
      )
      |> json_response(201)

    resp =
      json_conn(raw)
      |> post(
        "/v1/chat/sessions/#{session["id"]}/messages",
        Jason.encode!(%{content: "Ask me something"})
      )

    assert resp.status == 202, "send answered #{resp.status}: #{resp.resp_body}"
    session["id"]
  end

  # The Go host's approval_requested event for a Claude can_use_tool request,
  # posted on the send_turn lease at the next cursor.
  defp post_ask!(host, sid, approval_id, tool_name, input, title \\ nil) do
    assert [%{lease_id: lease_id, epoch: epoch, last_cursor: last}] =
             host_commands(host, sid, :send_turn)

    cursor = (last || 0) + 1

    assert {:ok, :accepted} =
             ChatHosts.accept_event(host, %{
               lease_id: lease_id,
               epoch: epoch,
               cursor: cursor,
               idempotency_key: "#{approval_id}-#{cursor}",
               event: %{
                 "kind" => "approval_requested",
                 "approval_id" => approval_id,
                 "tool_name" => tool_name,
                 "input" => input,
                 "title" => title
               }
             })
  end

  defp host_commands(host, sid, operation) do
    host
    |> ChatHosts.next_commands()
    |> Enum.filter(&(&1.command.operation == operation and &1.command.session_id == sid))
  end

  defp rows(sid, role),
    do: sid |> StudioChat.list_messages(:global) |> Enum.filter(&(&1.role == role))

  defp json_conn(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp reap_recorders do
    if pid = Process.whereis(Barkpark.StudioChat.RuntimeSupervisor) do
      for {_, child, _, _} <- DynamicSupervisor.which_children(pid), is_pid(child) do
        DynamicSupervisor.terminate_child(pid, child)
      end
    end
  catch
    :exit, _ -> :ok
  end
end
