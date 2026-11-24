defmodule BarkparkWeb.ChatRegisteredHostOwnerTest do
  @moduledoc """
  A registered host is a person's own computer, and only a workspace owner can
  enroll one (`ChatHostController.create_enrollment/2`). Before
  task-7efaf895e8bc88e4 any workspace member with chat access could create a
  session on it and run turns there: `HostExecutionGate.authorize_turn/2`
  passed every `registered_host` session, and create took any host id. Now a
  create or a turn on a registered-host session needs the owner seat of the
  session's workspace, and every session records who created it.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Ecto.Query
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.{ExecutionLease, RegisteredHost}
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Session
  alias Barkpark.Tenancy.Membership

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
    {owner_raw, owner} = mint!(["read", "chat"], ws.id)
    seat!(owner, "owner")
    {member_raw, member} = mint!(["read", "chat"], ws.id)
    {admin_raw, _admin} = mint!(["read", "write", "admin"], ws.id)

    %{
      ws: ws,
      host: enroll_host!(ws),
      owner_raw: owner_raw,
      owner: owner,
      member_raw: member_raw,
      member: member,
      admin_raw: admin_raw
    }
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp mint!(perms, ws_id) do
    raw = "host-owner-" <> Ecto.UUID.generate()
    {:ok, token} = Auth.create_token(raw, "host owner", @dataset, perms, ws_id)
    {raw, token}
  end

  defp seat!(token, role) do
    {1, _} =
      Repo.update_all(
        from(m in Membership,
          where: m.principal_id == ^token.id and m.principal_type == "api_token"
        ),
        set: [role: role]
      )
  end

  defp enroll_host!(ws) do
    caps = @fixture |> File.read!() |> Jason.decode!()

    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{
        name: "owner-host-#{System.unique_integer([:positive])}",
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

  defp reap_recorders do
    if pid = Process.whereis(Barkpark.StudioChat.RuntimeSupervisor) do
      for {_, child, _, _} <- DynamicSupervisor.which_children(pid), is_pid(child) do
        DynamicSupervisor.terminate_child(pid, child)
      end
    end
  catch
    :exit, _ -> :ok
  end

  # ── the refusals ───────────────────────────────────────────────────────────

  test "a member's create on the owner's host is a 403 and makes no row",
       %{host: host, member_raw: member_raw} do
    conn = create(member_raw, host_body(host))

    assert %{"error" => %{"code" => "host_owner_required"}} = json_response(conn, 403)
    assert sessions_on(host) == 0
  end

  test "a workspace admin who is not an owner is refused the same way",
       %{host: host, admin_raw: admin_raw} do
    conn = create(admin_raw, host_body(host))

    assert %{"error" => %{"code" => "host_owner_required"}} = json_response(conn, 403)
    assert sessions_on(host) == 0
  end

  test "a member's turn on the owner's session is a 403 and leases nothing",
       %{host: host, owner_raw: owner_raw, member_raw: member_raw} do
    sid = create(owner_raw, host_body(host)) |> json_response(201) |> Map.fetch!("id")

    conn = send_hi(member_raw, sid)

    assert %{"error" => %{"code" => "host_owner_required"}} = json_response(conn, 403)
    assert leases_for(sid) == 0
    assert commands_for(host, sid) == []
    assert StudioChat.list_messages(sid, :global) == []
  end

  test "a member cannot change the mode of the owner's session either",
       %{host: host, owner_raw: owner_raw, member_raw: member_raw} do
    sid = create(owner_raw, host_body(host)) |> json_response(201) |> Map.fetch!("id")

    conn =
      json_conn(member_raw)
      |> patch("/v1/chat/sessions/#{sid}", Jason.encode!(%{mode: "acceptEdits"}))

    assert %{"error" => %{"code" => "host_owner_required"}} = json_response(conn, 403)
    assert StudioChat.get_session(sid, :global).mode == "plan"
  end

  # ── the controls ───────────────────────────────────────────────────────────

  test "the owner creates and sends: the host gets the turn, and the row names its creator",
       %{host: host, owner_raw: owner_raw, owner: owner} do
    created = create(owner_raw, host_body(host)) |> json_response(201)
    sid = created["id"]

    assert created["created_by"] == "api_token:" <> owner.id
    assert StudioChat.get_session(sid, :global).created_by == "api_token:" <> owner.id

    assert send_hi(owner_raw, sid).status == 202
    assert [%{command: %{operation: :send_turn}}] = commands_for(host, sid)
    assert leases_for(sid) == 1
  end

  test "a member's managed session is unchanged: created, and it records its creator",
       %{member_raw: member_raw, member: member} do
    created = create(member_raw, %{provider: "claude"}) |> json_response(201)

    assert created["execution_target"] == "managed"
    assert created["created_by"] == "api_token:" <> member.id

    # The managed turn takes only the instance-host rule, never the owner seat.
    row = StudioChat.get_session(created["id"], :global)

    refute BarkparkWeb.HostExecutionGate.authorize_turn(member, row) ==
             {:error, :host_owner_required}

    refute send_hi(member_raw, row.id).status == 403
  end
end
