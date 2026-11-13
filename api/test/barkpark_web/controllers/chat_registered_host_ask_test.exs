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
