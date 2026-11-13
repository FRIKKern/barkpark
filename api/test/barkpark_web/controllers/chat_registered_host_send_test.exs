defmodule BarkparkWeb.ChatRegisteredHostSendTest do
  @moduledoc """
  A message to a registered-host chat session reaches the host
  (task-ff4074ff3f85fcfb).

  Live on guerrilla: host online, enrolled, claude ready; session create 201;
  every `POST /v1/chat/sessions/:id/messages` answered 503
  `runtime_unavailable`. This drives the same public path end to end: the host
  is enrolled and heartbeated through `ChatHosts` with the Go binary's own
  capabilities fixture, the session is created over HTTP with exactly the
  BarkBot body (no cwd, mode or model), and the host then reads its commands
  the way `GET /v1/chat-host/commands` does (`ChatHosts.next_commands/1`).
  """
  use BarkparkWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  @moduletag :requires_plugins

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.RegisteredHost
  alias Barkpark.Repo
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.Tenancy
  alias BarkparkWeb.ChatController

  @dataset "production"
  @fixture Path.expand("../../support/fixtures/chat_host_go_capabilities.json", __DIR__)

  setup do
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      reap_recorders()
      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "rhs-#{suffix}", name: "RHS #{suffix}"})

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

    raw = "rhs-member-#{suffix}"
    {:ok, _} = Auth.create_token(raw, "rhs-member", @dataset, ["read", "write", "admin"], ws.id)

    %{ws: ws, host_id: issued.host.id, raw: raw}
  end

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

  test "a message to a registered-host session is accepted and leased to the host",
       %{host_id: host_id, raw: raw} do
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

    sid = session["id"]
    send_message!(raw, sid, "Say hi in one short sentence.")

    host = Repo.get!(RegisteredHost, host_id)

    assert [%{lease_id: lease_id, command: command}] = send_turns(host, sid)
    assert is_binary(lease_id)
    assert command.provider == "claude"
    assert command.payload.content == "Say hi in one short sentence."
    # No cwd was sent: the host's first approved root is the one it may run in.
    assert command.payload.cwd == System.tmp_dir!()

    # The Recorder survived its first turn, so the next one rides the same runtime.
    assert is_pid(Recorder.whereis(sid))
    send_message!(raw, sid, "And once more.")
    assert length(send_turns(host, sid)) == 2
  end

  test "a send to a revoked host is a permanent 422, not a retryable 503",
       %{ws: ws, host_id: host_id, raw: raw} do
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

    {:ok, _} = ChatHosts.revoke(ws.id, host_id)

    log =
      capture_log(fn ->
        body =
          json_conn(raw)
          |> post("/v1/chat/sessions/#{session["id"]}/messages", Jason.encode!(%{content: "hi"}))
          |> json_response(422)

        assert body["error"]["code"] == "chat_unsupported"
      end)

    assert log =~ "send failed: :host_not_found"
  end

  describe "send-failure seam (ChatController.send_failure_response/2)" do
    defp split(reason) do
      conn = ChatController.send_failure_response(scoped_conn(), reason)
      {conn.status, Jason.decode!(conn.resp_body)["error"]["code"]}
    end

    test "registered-host terms carry their real class" do
      assert split(:host_not_found) == {422, "chat_unsupported"}
      assert split(:host_offline) == {503, "runtime_unavailable"}
    end

    # The host lacks the attachments capability: retrying the same turn to the
    # same host can never succeed, so it is a permanent 422 with its own code,
    # never the retryable 503 an unknown term falls to.
    test "a host that cannot receive attachments is a permanent 422 with its own code" do
      assert split({:host_cannot_receive_attachments, "claude"}) ==
               {422, "host_cannot_receive_attachments"}
    end

    test "the existing classes keep their status and code" do
      assert split({:managed_runtime_capacity, :full}) == {503, "runtime_capacity"}
      assert split(:port_closed) == {503, "runtime_unavailable"}
      assert split({:provider_not_ready, "claude"}) == {422, "chat_unsupported"}
    end

    test "a crash term is logged by reason and arity, never by its arguments" do
      secret = "task-token-hash-#{System.unique_integer([:positive])}"
      stack = [{Some.Mod, :initialize, [%{task_token: secret}], [line: 1]}]

      log = capture_log(fn -> split({:function_clause, stack}) end)

      assert log =~ "function_clause"
      assert log =~ "Some.Mod, :initialize, 1"
      refute log =~ secret
    end
  end

  defp send_message!(raw, sid, content) do
    resp =
      json_conn(raw)
      |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(%{content: content}))

    assert resp.status == 202, "send answered #{resp.status}: #{resp.resp_body}"
  end

  # What `GET /v1/chat-host/commands` hands the host.
  defp send_turns(host, sid) do
    host
    |> ChatHosts.next_commands()
    |> Enum.filter(&(&1.command.operation == :send_turn and &1.command.session_id == sid))
  end
end
