defmodule BarkparkWeb.ChatRegisteredHostSeatTest do
  @moduledoc """
  A registered host is a person's own computer, enrolled by a workspace owner.
  Before task-7efaf895e8bc88e4 any workspace member with chat access could
  create a session on it and run turns there: `HostExecutionGate.authorize_turn/2`
  passed every `registered_host` session, and create took any host id.

  The rule now (owner ruling on #28693): a create or a turn on a
  registered-host session passes for an owner or admin seat in the session's
  workspace, or for an api token whose `owner_user_id` is a workspace owner.
  Everything else is a 403 `host_admin_required`. A token with no
  `owner_user_id` gets nothing from the second arm; a Connector (chat) token is
  minted with none today. Every session also records who created it (`created_by`).
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Ecto.Query
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Barkpark.AccountsFixtures, only: [register_user: 1]
  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.{ExecutionLease, RegisteredHost}
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Session
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.HostExecutionGate

  @dataset "production"
  @fixture Path.expand("../../support/fixtures/chat_host_go_capabilities.json", __DIR__)
  @env_keys [:claude_chat, :public_demo_studio, :operator_emails, :operator_token_ids]

  setup do
    ensure_default_scope!()
    prev = Map.new(@env_keys, &{&1, Application.get_env(:barkpark, &1)})

    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)
    Application.put_env(:barkpark, :operator_emails, [])
    Application.put_env(:barkpark, :operator_token_ids, [])

    on_exit(fn ->
      reap_recorders()

      for {key, val} <- prev do
        if is_nil(val),
          do: Application.delete_env(:barkpark, key),
          else: Application.put_env(:barkpark, key, val)
      end
    end)

    ws = create_workspace!()
    owner_user = user_seated!(ws, "owner")
    member_user = user_seated!(ws, "member")

    {member_raw, member} = mint!(["read", "chat"], ws.id)
    {admin_raw, admin} = mint!(["read", "write", "admin"], ws.id)
    {owner_raw, owner} = mint!(["read", "chat"], ws.id)
    owner_seat!(owner)

    %{
      ws: ws,
      host: enroll_host!(ws),
      owner_user: owner_user,
      member_user: member_user,
      member_raw: member_raw,
      member: member,
      admin_raw: admin_raw,
      admin: admin,
      owner_raw: owner_raw,
      owner: owner
    }
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp mint!(perms, ws_id, opts \\ []) do
    raw = "host-seat-" <> Ecto.UUID.generate()
    {:ok, token} = Auth.create_token(raw, "host seat", @dataset, perms, ws_id, opts)
    {raw, token}
  end

  defp user_seated!(ws, role) do
    user = register_user("host-seat-#{System.unique_integer([:positive])}@example.test")
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, role, "user")
    user
  end

  defp enroll_host!(ws) do
    caps = @fixture |> File.read!() |> Jason.decode!()

    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{
        name: "seat-host-#{System.unique_integer([:positive])}",
        approved_roots: [System.tmp_dir!()]
      })

    {:ok, %{credential: credential}} =
      ChatHosts.enroll(issued.enrollment_token, %{"protocol_version" => 1, "capabilities" => caps})

    {:ok, host} = ChatHosts.authenticate(credential)
    {:ok, _} = ChatHosts.heartbeat(host, %{"protocol_version" => 1, "capabilities" => caps})
    issued.host.id
  end

  defp json_conn(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp create(raw, body), do: json_conn(raw) |> post("/v1/chat/sessions", Jason.encode!(body))

  defp host_body(host_id),
    do: %{provider: "claude", execution_target: "registered_host", execution_host_id: host_id}

  defp send_hi(raw, sid),
    do:
      json_conn(raw) |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(%{content: "hi"}))

  defp leases_for(sid),
    do: Repo.aggregate(from(l in ExecutionLease, where: l.session_id == ^sid), :count)

  defp commands_for(host_id, sid) do
    RegisteredHost
    |> Repo.get!(host_id)
    |> ChatHosts.next_commands()
    |> Enum.filter(&(&1.command.session_id == sid))
  end

  defp sessions_on(host_id),
    do: Repo.aggregate(from(s in Session, where: s.execution_host_id == ^host_id), :count)

  defp refused?(conn),
    do: match?(%{"error" => %{"code" => "host_admin_required"}}, json_response(conn, 403))

  # Create and send as `raw`: the host gets the turn, and the row names its creator.
  defp assert_drives!(raw, token, host) do
    created = create(raw, host_body(host)) |> json_response(201)
    sid = created["id"]

    assert created["created_by"] == "api_token:" <> token.id
    assert StudioChat.get_session(sid, :global).created_by == "api_token:" <> token.id

    assert send_hi(raw, sid).status == 202
    assert [%{command: %{operation: :send_turn}}] = commands_for(host, sid)
    assert leases_for(sid) == 1
    sid
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

  # ── a member seat is refused ───────────────────────────────────────────────

  test "a member token's create on the workspace's host is a 403 and makes no row",
       %{host: host, member_raw: member_raw} do
    assert refused?(create(member_raw, host_body(host)))
    assert sessions_on(host) == 0
  end

  test "a member token's turn on an admin's session is a 403 and leases nothing",
       %{host: host, admin_raw: admin_raw, member_raw: member_raw} do
    sid = create(admin_raw, host_body(host)) |> json_response(201) |> Map.fetch!("id")

    assert refused?(send_hi(member_raw, sid))
    assert leases_for(sid) == 0
    assert commands_for(host, sid) == []
    assert StudioChat.list_messages(sid, :global) == []
  end

  test "a member token cannot change the mode of an admin's session either",
       %{host: host, admin_raw: admin_raw, member_raw: member_raw} do
    sid = create(admin_raw, host_body(host)) |> json_response(201) |> Map.fetch!("id")

    conn =
      json_conn(member_raw)
      |> patch("/v1/chat/sessions/#{sid}", Jason.encode!(%{mode: "acceptEdits"}))

    assert refused?(conn)
    assert StudioChat.get_session(sid, :global).mode == "plan"
  end

  # ── a member-seat token held for a user ────────────────────────────────────

  test "a member-seat token whose owner_user_id is a workspace owner creates and sends",
       %{ws: ws, host: host, owner_user: owner_user} do
    {raw, token} = mint!(["read", "chat"], ws.id, owner_user_id: owner_user.id)
    assert TenancyAuth.membership_role(token, ws.id) == "member"

    assert_drives!(raw, token, host)
  end

  test "a member-seat token whose owner_user_id is only a member is a 403",
       %{ws: ws, host: host, member_user: member_user, admin_raw: admin_raw} do
    {raw, _token} = mint!(["read", "chat"], ws.id, owner_user_id: member_user.id)

    assert refused?(create(raw, host_body(host)))

    sid = create(admin_raw, host_body(host)) |> json_response(201) |> Map.fetch!("id")
    assert refused?(send_hi(raw, sid))
    assert leases_for(sid) == 0
  end

  test "an owner's member-seat token passes only where that user is an owner",
       %{host: host, owner_user: owner_user} do
    other = create_workspace!()
    {raw, _token} = mint!(["read", "chat"], other.id, owner_user_id: owner_user.id)

    # The token's session is owned by `other`, where the user holds no seat.
    assert refused?(create(raw, host_body(host)))
  end

  # ── the seats that pass ────────────────────────────────────────────────────

  test "an admin-seat token creates and sends (BarkBot's token on guerrilla)",
       %{host: host, admin_raw: admin_raw, admin: admin} do
    assert TenancyAuth.membership_role(admin, admin.workspace_id) == "admin"
    assert_drives!(admin_raw, admin, host)
  end

  test "an owner-seat token creates and sends", %{host: host, owner_raw: raw, owner: owner} do
    assert_drives!(raw, owner, host)
  end

  test "a member's managed session is unchanged: created, and it records its creator",
       %{member_raw: member_raw, member: member} do
    created = create(member_raw, %{provider: "claude"}) |> json_response(201)

    assert created["execution_target"] == "managed"
    assert created["created_by"] == "api_token:" <> member.id

    # A managed turn takes only the instance-host rule, never the seat rule.
    row = StudioChat.get_session(created["id"], :global)
    refute HostExecutionGate.authorize_turn(member, row) == {:error, :host_admin_required}
    refute send_hi(member_raw, row.id).status == 403
  end

  # ── Studio: ChatLive's create path (ChatHostGate.create_session/3) ─────────

  test "CONTROL: the owner's own Studio session makes the row and names the owner",
       %{conn: conn, ws: ws, host: host, owner_user: owner_user} do
    {:ok, _} = Barkpark.Tenancy.create_project(ws, %{slug: "default", name: "Default"})
    {:ok, session} = Accounts.create_user_session_token(owner_user)

    {:ok, view, _html} =
      live(
        init_test_session(conn, %{"user_session" => session}),
        "/w/#{ws.slug}/p/default/studio/chat"
      )

    render_hook(view, "set-execution-target", %{"execution_target" => "registered_host"})
    render_hook(view, "set-execution-host", %{"execution_host_id" => host})

    capture_log(fn ->
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})
      render(view)
    end)

    refute render(view) =~ HostExecutionGate.host_admin_message()

    assert [%Session{} = row] = Repo.all(from(s in Session, where: s.execution_host_id == ^host))
    assert row.created_by == "user:" <> owner_user.id
  end
end
