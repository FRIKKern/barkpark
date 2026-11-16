defmodule BarkparkWeb.ChatNulTextTest do
  @moduledoc """
  Text holding U+0000 is refused as a 400 before anything is dispatched or
  stored (task-c663ef1789269e86).

  JSON carries `\\u0000` as a valid string, but Postgres refuses it in a text
  column or parameter (22021). Before this, a message holding it was
  dispatched and then failed to store: a 500 on main before #26632, and after
  it a retryable 503 on a registered host (that fails the same way every time)
  or a 202 with the row lost on a managed session. A title, a draft or an
  approval's request_id holding it answered 500. The same input fails every
  time, so it is the caller's 400.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  @moduletag :requires_plugins

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.{ExecutionLease, RegisteredHost}
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.ClaudeChat

  @dataset "production"
  @fixture Path.expand("../../support/fixtures/chat_host_go_capabilities.json", __DIR__)
  @nul "before\u0000after"

  setup do
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    prev_chat = Application.get_env(:barkpark, :claude_chat)
    Application.put_env(:barkpark, :public_demo_studio, false)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})

    on_exit(fn ->
      reap_recorders()
      Application.put_env(:barkpark, :public_demo_studio, prev_demo)

      if prev_chat,
        do: Application.put_env(:barkpark, :claude_chat, prev_chat),
        else: Application.delete_env(:barkpark, :claude_chat)
    end)

    admin = "nul-admin-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(admin, "nul-admin", @dataset, ["read", "write", "admin"])

    {:ok, session} =
      StudioChat.create_session(%{id: Ecto.UUID.generate(), cwd: ClaudeChat.cwd(), mode: "plan"})

    %{admin: admin, sid: session.id}
  end

  describe "message content" do
    test "a managed send holding NUL is a 400 that spawns nothing and stores nothing",
         %{admin: admin, sid: sid} do
      body = post_json(admin, "/v1/chat/sessions/#{sid}/messages", %{content: @nul}, 400)

      assert body["error"]["code"] == "invalid_request"
      assert body["error"]["message"] =~ "content"
      assert Recorder.whereis(sid) == nil
      assert StudioChat.list_messages(sid, :global) == []
    end

    test "a registered-host send holding NUL is a 400 that leases nothing and stores nothing" do
      suffix = System.unique_integer([:positive])
      {:ok, ws} = Tenancy.create_workspace(%{slug: "nul-#{suffix}", name: "NUL #{suffix}"})
      raw = "nul-member-#{suffix}"
      {:ok, _} = Auth.create_token(raw, "nul-member", @dataset, ["read", "write", "admin"], ws.id)
      host_id = enroll_host!(ws, "go-host-#{suffix}")

      sid =
        post_json(
          raw,
          "/v1/chat/sessions",
          %{provider: "claude", execution_target: "registered_host", execution_host_id: host_id},
          201
        )["id"]

      body = post_json(raw, "/v1/chat/sessions/#{sid}/messages", %{content: @nul}, 400)

      assert body["error"]["code"] == "invalid_request"
      assert Repo.aggregate(from(l in ExecutionLease, where: l.session_id == ^sid), :count) == 0
      assert ChatHosts.next_commands(Repo.get!(RegisteredHost, host_id)) == []
      assert StudioChat.list_messages(sid, :global) == []
    end
  end

  describe "session fields" do
    test "a title holding NUL is a 400 and the title is unchanged", %{admin: admin, sid: sid} do
      before = StudioChat.get_session(sid).title
      body = patch_json(admin, "/v1/chat/sessions/#{sid}", %{title: @nul}, 400)

      assert body["error"]["code"] == "invalid_request"
      assert StudioChat.get_session(sid).title == before
    end

    test "a draft holding NUL is a 400 and the draft is unchanged", %{admin: admin, sid: sid} do
      before = StudioChat.get_session(sid).draft
      body = patch_json(admin, "/v1/chat/sessions/#{sid}", %{draft: @nul}, 400)

      assert body["error"]["code"] == "invalid_request"
      assert StudioChat.get_session(sid).draft == before
    end
  end

  describe "approval" do
    test "a request_id holding NUL is a 400 with a live runtime", %{admin: admin, sid: sid} do
      {:ok, _} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})

      body =
        post_json(
          admin,
          "/v1/chat/sessions/#{sid}/approval",
          %{request_id: @nul, decision: "deny"},
          400
        )

      assert body["error"]["code"] == "invalid_request"
    end
  end

  defp post_json(raw, path, body, status),
    do: json_conn(raw) |> post(path, Jason.encode!(body)) |> json_response(status)

  defp patch_json(raw, path, body, status),
    do: json_conn(raw) |> patch(path, Jason.encode!(body)) |> json_response(status)

  defp json_conn(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp enroll_host!(ws, name) do
    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{name: name, approved_roots: [System.tmp_dir!()]})

    caps = @fixture |> File.read!() |> Jason.decode!()

    {:ok, %{credential: credential}} =
      ChatHosts.enroll(issued.enrollment_token, %{"protocol_version" => 1, "capabilities" => caps})

    {:ok, host} = ChatHosts.authenticate(credential)
    {:ok, _} = ChatHosts.heartbeat(host, %{"protocol_version" => 1, "capabilities" => caps})
    issued.host.id
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
