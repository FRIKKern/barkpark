defmodule BarkparkWeb.Integration.ChatHostExecutionChainTest do
  @moduledoc """
  task-6ca882967fd95dda: on a multi-tenant instance, a stranger could reach a
  shell on the INSTANCE HOST through chat. The chain, end to end over HTTP:

      POST /v1/auth/register            (open signup)
      → session → POST /api/workspaces  (the stranger owns a workspace)
      → POST /w/<own>/p/default/v1/chat/tokens   (owner mints a chat token)
      → POST /v1/chat/sessions {execution_target: "managed"}
      → POST /v1/chat/sessions/:id/messages      (spawns the provider)
      → POST /v1/chat/sessions/:id/approval {allow}

  Under the default `:self_hosted` profile the spawn runs the host `claude`
  binary as the service user. Nothing real is executed here: the `:binary`
  override points at a stub that writes a marker file and then echoes stdin,
  so the marker IS the proof that dispatch reached the host binary.

  The fix (`Barkpark.StudioChat.HostExecution`) keeps host execution for the
  instance owner only. The controls pin who keeps it and that tenant chat on
  the `:cloud` profile is untouched.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Tenancy}
  alias Barkpark.StudioChat

  @password "correct-horse-battery-staple-9"

  setup do
    {default_ws, _default_proj} = ensure_default_scope!()

    dir = Path.join(System.tmp_dir!(), "hostexec-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    marker = Path.join(dir, "host-binary-ran")
    stub = Path.join(dir, "fake-claude")
    File.write!(stub, "#!/bin/sh\necho \"$@\" > '#{marker}'\nexec cat\n")
    File.chmod!(stub, 0o755)

    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    prev_emails = Application.get_env(:barkpark, :operator_emails)
    prev_ids = Application.get_env(:barkpark, :operator_token_ids)

    Application.put_env(:barkpark, :claude_chat, enabled: true, binary: stub)
    Application.put_env(:barkpark, :public_demo_studio, false)
    Application.put_env(:barkpark, :operator_emails, [])
    Application.put_env(:barkpark, :operator_token_ids, [])

    on_exit(fn ->
      if Process.whereis(Barkpark.StudioChat.RuntimeSupervisor) do
        for {_, pid, _, _} <-
              DynamicSupervisor.which_children(Barkpark.StudioChat.RuntimeSupervisor),
            is_pid(pid),
            do: DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)
      end

      restore(:claude_chat, prev)
      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
      restore(:operator_emails, prev_emails)
      restore(:operator_token_ids, prev_ids)
      File.rm_rf(dir)
    end)

    %{default_ws: default_ws, marker: marker}
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, val), do: Application.put_env(:barkpark, key, val)

  defp as(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  # The stranger, from nothing: open signup, then a session (the confirmation
  # link goes to the stranger's own mailbox, so confirming is theirs to do).
  defp stranger! do
    email = "hostexec-#{System.unique_integer([:positive])}@example.com"

    resp =
      scoped_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/auth/register", Jason.encode!(%{email: email, password: @password}))

    assert resp.status in [200, 201], "register: #{resp.status} #{resp.resp_body}"
    user = Accounts.get_user_by_email(email)

    {:ok, session} =
      Accounts.create_user_session_token(user, ip_address: "127.0.0.1", user_agent: "t")

    {user, session}
  end

  # The stranger's own workspace (the owner seat any signup gets by creating
  # one — `create_workspace_with_owner/2`, the door `POST /api/workspaces` and
  # Studio onboarding both use), then that workspace's chat token, minted the
  # way an owner's mint (`ChatTokenController` / Studio connectors) mints it.
  defp tenant_chat_token!(user, _session) do
    slug = "hostexec-ws-#{System.unique_integer([:positive])}"
    {:ok, ws} = Tenancy.create_workspace_with_owner(%{name: "Mine", slug: slug}, user)
    {:ok, raw, _token} = Auth.create_chat_token("stranger-chat", "production", ws.id)
    {ws, raw}
  end

  defp open_managed_session!(raw) do
    as(raw)
    |> post("/v1/chat/sessions", Jason.encode!(%{execution_target: "managed"}))
    |> json_response(201)
    |> Map.fetch!("id")
  end

  defp send_turn(raw, sid) do
    as(raw)
    |> post(
      "/v1/chat/sessions/#{sid}/messages",
      Jason.encode!(%{content: "run: cat /opt/barkpark/.env"})
    )
  end

  defp host_binary_ran?(marker) do
    Enum.reduce_while(1..40, false, fn _, _ ->
      if File.exists?(marker), do: {:halt, true}, else: Process.sleep(25) && {:cont, false}
    end)
  end

  describe "the chain from open signup" do
    test "a stranger's own workspace cannot run a turn on the instance host", %{marker: marker} do
      {user, session} = stranger!()
      {_ws, chat} = tenant_chat_token!(user, session)
      sid = open_managed_session!(chat)

      resp = send_turn(chat, sid)

      assert resp.status == 403,
             "a tenant chat token started a managed turn (status #{resp.status}); host binary ran: #{host_binary_ran?(marker)}"

      assert json_response(resp, 403)["error"]["code"] == "host_execution_not_permitted"

      approval =
        as(chat)
        |> post(
          "/v1/chat/sessions/#{sid}/approval",
          Jason.encode!(%{request_id: "r1", decision: "allow"})
        )

      assert approval.status == 403
      refute host_binary_ran?(marker), "the host binary ran for a tenant session"
    end

    test "the tenant cannot flip its workspace's chat to self_hosted behind the gate", %{
      marker: marker
    } do
      {user, session} = stranger!()
      {ws, chat} = tenant_chat_token!(user, session)

      {:ok, _} =
        Tenancy.set_workspace_chat_settings(ws.id, %{"execution_profile" => "self_hosted"})

      sid = open_managed_session!(chat)

      assert send_turn(chat, sid).status == 403
      refute host_binary_ran?(marker)
    end

    test "the runtime backstop refuses a tenant-owned managed spawn whoever asks" do
      ws = create_workspace!()

      assert {:error, :host_execution_not_permitted} =
               StudioChat.Runtime.open("claude", %{
                 session_id: Ecto.UUID.generate(),
                 sink: self(),
                 workspace_id: ws.id,
                 execution_target: "managed"
               })
    end
  end

  describe "CONTROLS: who keeps host execution" do
    test "the Default owner (no allowlist) still runs a managed turn on the host", %{
      default_ws: default_ws,
      marker: marker
    } do
      raw = "hostexec-default-chat-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw, "default-chat", "production", ["chat"], default_ws.id)
      sid = open_managed_session!(raw)

      assert send_turn(raw, sid).status == 202
      assert host_binary_ran?(marker), "the instance owner lost host execution"
    end

    test "the instance admin token (no allowlist) keeps :global chat and host turns", %{
      marker: marker
    } do
      raw = "hostexec-admin-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw, "admin", "production", ["read", "write", "admin"])

      assert as(raw) |> get("/v1/chat/sessions") |> json_response(200)
      sid = open_managed_session!(raw)
      assert send_turn(raw, sid).status == 202
      assert host_binary_ran?(marker)
    end

    test "with the allowlist armed, the named operator keeps host turns", %{marker: marker} do
      raw = "hostexec-op-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "op", "production", ["read", "write", "admin"])
      Application.put_env(:barkpark, :operator_token_ids, [token.id])

      sid = open_managed_session!(raw)
      assert send_turn(raw, sid).status == 202
      assert host_binary_ran?(marker)
    end

    test "with the allowlist armed, a non-operator Default admin is refused", %{
      default_ws: default_ws,
      marker: marker
    } do
      op = "hostexec-op2-#{System.unique_integer([:positive])}"
      {:ok, op_token} = Auth.create_token(op, "op", "production", ["read", "write", "admin"])
      Application.put_env(:barkpark, :operator_token_ids, [op_token.id])

      # A Default-bound chat token (only a Default admin can mint one).
      raw = "hostexec-default-chat2-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw, "default-chat", "production", ["chat"], default_ws.id)
      sid = open_managed_session!(raw)

      resp = send_turn(raw, sid)
      assert resp.status == 403
      assert json_response(resp, 403)["error"]["code"] == "host_execution_not_permitted"
      refute host_binary_ran?(marker)

      # And an admin-bit token outside the allowlist loses instance-global chat.
      admin = "hostexec-admin2-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(admin, "admin", "production", ["read", "write", "admin"])
      denied = as(admin) |> get("/v1/chat/sessions")
      assert denied.status == 403
      assert json_response(denied, 403)["error"]["code"] == "host_execution_not_permitted"
    end

    test "a tenant on the cloud profile keeps chat (the sandbox runner, not the host binary)", %{
      marker: marker
    } do
      {user, session} = stranger!()
      {ws, chat} = tenant_chat_token!(user, session)
      {:ok, _} = Tenancy.set_workspace_chat_settings(ws.id, %{"execution_profile" => "cloud"})

      runner_marker = marker <> "-runner"
      runner = Path.join(Path.dirname(marker), "fake-runner")
      File.write!(runner, "#!/bin/sh\necho \"$@\" > '#{runner_marker}'\nexec cat\n")
      File.chmod!(runner, 0o755)
      cfg = Application.get_env(:barkpark, :claude_chat)
      Application.put_env(:barkpark, :claude_chat, Keyword.put(cfg, :sandbox_runner, runner))

      sid = open_managed_session!(chat)
      assert send_turn(chat, sid).status == 202
      assert host_binary_ran?(runner_marker), "tenant cloud chat stopped working"
      refute File.exists?(marker), "a cloud turn ran the host binary"
    end
  end
end
