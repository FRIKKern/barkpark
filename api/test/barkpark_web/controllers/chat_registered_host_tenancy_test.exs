defmodule BarkparkWeb.ChatRegisteredHostTenancyTest do
  @moduledoc """
  A registered-host chat session never leases a turn to a host of another
  workspace (task-eebe3ee34fe5971c).

  Create does not look the host up at all: `POST /v1/chat/sessions` takes any
  well-formed `execution_host_id` (`ChatController.validate_create/1` only casts
  it), so a host of workspace A, an id no host has, and a revoked host are all
  the same 201. Nothing about the named host is checked there, so nothing about
  it can leak there either.

  The check is at lease time. Every turn reaches a host through
  `ChatHosts.resolve(session.owner_workspace_id, host_id)` (`Runtime.open/2`
  and `Runtime.dispatch/4`, the only road to `ChatHosts.lease_and_enqueue/3`),
  and `ChatHosts.get_host/2` (`lib/barkpark/chat_hosts/context.ex`) matches
  `workspace_id AND id`. Dropping that workspace term reds 8 of these 11
  tests. The session's owner is
  stamped from the creator's scope, so a session of workspace B naming A's
  host resolves to `:host_not_found`, the same 422 as an unknown or revoked
  host, and no lease row or host command is ever made. Every test that ends on
  a refusal is paired with the positive control: A's own session on the same
  host is leased, so the fixture host can receive a turn.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Ecto.Query
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.{ExecutionLease, RegisteredHost}
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"
  @fixture Path.expand("../../support/fixtures/chat_host_go_capabilities.json", __DIR__)
  @env_keys [:claude_chat, :public_demo_studio, :operator_emails, :operator_token_ids]

  setup do
    {default_ws, _} = ensure_default_scope!()
    prev = Map.new(@env_keys, &{&1, Application.get_env(:barkpark, &1)})

    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)
    # Allowlist unset: the legacy instance operator is an admin token of the
    # Default workspace or of none (`RequireChatAccess.chat_scope/1`).
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

    ws_a = create_workspace!()
    ws_b = create_workspace!()

    %{
      default_ws: default_ws,
      ws_a: ws_a,
      ws_b: ws_b,
      host_a: enroll_host!(ws_a),
      a_raw: mint!(["read", "chat"], ws_a.id),
      b_raw: mint!(["read", "chat"], ws_b.id),
      b_admin_raw: mint!(["read", "write", "admin"], ws_b.id)
    }
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  # Every token here is seated OWNER of its own workspace: a member seat may
  # not create or drive a registered-host chat (task-7efaf895e8bc88e4), and
  # this file pins what happens past that gate, when the host belongs to
  # another workspace.
  defp mint!(perms, ws_id) do
    raw = "host-tenancy-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "host tenancy", @dataset, perms, ws_id) |> owner_seat!()
    raw
  end

  # Enrolled, heartbeated, claude ready: a host that takes a turn.
  defp enroll_host!(ws) do
    caps = @fixture |> File.read!() |> Jason.decode!()

    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{
        name: "tenancy-host-#{System.unique_integer([:positive])}",
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

  defp create(raw, host_id) do
    json_conn(raw)
    |> post(
      "/v1/chat/sessions",
      Jason.encode!(%{
        provider: "claude",
        execution_target: "registered_host",
        execution_host_id: host_id
      })
    )
  end

  defp send_hi(raw, sid),
    do:
      json_conn(raw) |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(%{content: "hi"}))

  # The refused send, its body without the per-request id, and the log line.
  defp refused_send(raw, sid) do
    log =
      capture_log(fn ->
        conn = send_hi(raw, sid)
        send(self(), {:refusal, conn.status, Jason.decode!(conn.resp_body)})
      end)

    assert_received {:refusal, status, body}
    {status, update_in(body, ["error"], &Map.delete(&1, "request_id")), log}
  end

  # What `GET /v1/chat-host/commands` would hand the host, for this session.
  defp commands_for(host_id, sid) do
    RegisteredHost
    |> Repo.get!(host_id)
    |> ChatHosts.next_commands()
    |> Enum.filter(&(&1.command.session_id == sid))
  end

  defp leases_for(sid),
    do: Repo.aggregate(from(l in ExecutionLease, where: l.session_id == ^sid), :count)

  defp assert_never_leased(host_id, sid) do
    assert leases_for(sid) == 0, "no lease row may exist for the session"
    assert commands_for(host_id, sid) == [], "the host must receive nothing for the session"
    assert StudioChat.list_messages(sid, :global) == [], "a refused send writes no row"
  end

  # The positive control: workspace A's own session on the same host is leased.
  defp assert_own_session_leased(a_raw, host_id) do
    sid = create(a_raw, host_id) |> json_response(201) |> Map.fetch!("id")
    assert send_hi(a_raw, sid).status == 202
    assert [%{command: %{operation: :send_turn}}] = commands_for(host_id, sid)
    assert leases_for(sid) == 1
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

  # ── HTTP: a workspace token naming another workspace's host ────────────────

  describe "a workspace-B token naming workspace A's host" do
    test "creates a B-owned row, but the send is the unknown-host 422 and A's host receives nothing",
         %{ws_b: ws_b, host_a: host_a, a_raw: a_raw, b_raw: b_raw} do
      created = create(b_raw, host_a) |> json_response(201)
      sid = created["id"]

      # The row exists, owned by the creator's workspace, carrying the id it named.
      row = StudioChat.get_session(sid, :global)
      assert row.owner_workspace_id == ws_b.id
      assert row.execution_host_id == host_a

      {status, body, log} = refused_send(b_raw, sid)
      assert {status, body["error"]["code"]} == {422, "chat_unsupported"}
      assert log =~ "send failed: :host_not_found"

      assert_never_leased(host_a, sid)
      assert_own_session_leased(a_raw, host_a)
    end

    test "is refused exactly as a host id that does not exist: same create, same send status and body",
         %{host_a: host_a, a_raw: a_raw, b_raw: b_raw} do
      foreign = create(b_raw, host_a)
      unknown = create(b_raw, Ecto.UUID.generate())

      # Create: the same status and the same keys, so create is no oracle.
      assert foreign.status == 201 and unknown.status == 201
      foreign_json = Jason.decode!(foreign.resp_body)
      unknown_json = Jason.decode!(unknown.resp_body)
      assert Map.keys(foreign_json) == Map.keys(unknown_json)

      {f_status, f_body, _} = refused_send(b_raw, foreign_json["id"])
      {u_status, u_body, _} = refused_send(b_raw, unknown_json["id"])

      assert {f_status, f_body} == {u_status, u_body}
      assert f_status == 422

      assert_never_leased(host_a, foreign_json["id"])
      assert_own_session_leased(a_raw, host_a)
    end

    test "after A's host is offline, the foreign send is still the unknown-host 422, not A's offline 503",
         %{ws_a: ws_a, host_a: host_a, b_raw: b_raw} do
      sid = create(b_raw, host_a) |> json_response(201) |> Map.fetch!("id")

      # A's own host went quiet: an A session would see `:host_offline`.
      Repo.update_all(from(h in RegisteredHost, where: h.id == ^host_a), set: [last_seen_at: nil])
      assert ChatHosts.resolve(ws_a.id, host_a) == {:error, :host_offline}

      {status, body, log} = refused_send(b_raw, sid)
      assert {status, body["error"]["code"]} == {422, "chat_unsupported"}
      assert log =~ ":host_not_found"
      assert leases_for(sid) == 0
    end

    test "a revoked host of A is the same 422 as an unknown one",
         %{ws_a: ws_a, host_a: host_a, b_raw: b_raw} do
      sid = create(b_raw, host_a) |> json_response(201) |> Map.fetch!("id")
      unknown_sid = create(b_raw, Ecto.UUID.generate()) |> json_response(201) |> Map.fetch!("id")
      {:ok, _} = ChatHosts.revoke(ws_a.id, host_a)

      {status, body, _} = refused_send(b_raw, sid)
      assert {status, body} == Tuple.delete_at(refused_send(b_raw, unknown_sid), 2)
      assert status == 422
      assert leases_for(sid) == 0
    end

    test "a workspace-B admin token is confined the same way",
         %{ws_b: ws_b, host_a: host_a, a_raw: a_raw, b_admin_raw: b_admin_raw} do
      sid = create(b_admin_raw, host_a) |> json_response(201) |> Map.fetch!("id")
      assert StudioChat.get_session(sid, :global).owner_workspace_id == ws_b.id

      {status, _body, log} = refused_send(b_admin_raw, sid)
      assert status == 422
      assert log =~ ":host_not_found"

      assert_never_leased(host_a, sid)
      assert_own_session_leased(a_raw, host_a)
    end

    test "PATCH cannot move a session onto another host: execution_host_id is an unknown key",
         %{host_a: host_a, b_raw: b_raw} do
      own_unknown = Ecto.UUID.generate()
      sid = create(b_raw, own_unknown) |> json_response(201) |> Map.fetch!("id")

      body =
        json_conn(b_raw)
        |> patch("/v1/chat/sessions/#{sid}", Jason.encode!(%{execution_host_id: host_a}))
        |> json_response(400)

      assert body["error"]["code"] == "invalid_request"
      assert StudioChat.get_session(sid, :global).execution_host_id == own_unknown

      for target <- [%{execution_target: "managed"}, %{owner_workspace_id: Ecto.UUID.generate()}] do
        assert json_conn(b_raw)
               |> patch("/v1/chat/sessions/#{sid}", Jason.encode!(target))
               |> json_response(400)
      end
    end
  end

  # ── HTTP: the instance operator ────────────────────────────────────────────

  describe "the instance operator's admin token (`:global` chat scope)" do
    test "its session is stamped to the Default workspace, so A's host is not its host either",
         %{default_ws: default_ws, host_a: host_a, a_raw: a_raw} do
      op_raw = mint!(["read", "write", "admin"], default_ws.id)

      sid = create(op_raw, host_a) |> json_response(201) |> Map.fetch!("id")
      assert StudioChat.get_session(sid, :global).owner_workspace_id == default_ws.id

      {status, _body, log} = refused_send(op_raw, sid)
      assert status == 422
      assert log =~ ":host_not_found"

      assert_never_leased(host_a, sid)
      assert_own_session_leased(a_raw, host_a)
    end

    # Charter D21 still lists every workspace's MANAGED sessions; a host session
    # is listed only where the token holds a seat (task-f44bbb6363d28e37). The
    # operator's admin seat is in Default, not in B.
    test "it lists B's managed row but not B's host row, and reads the host row as missing",
         %{default_ws: default_ws, host_a: host_a, b_raw: b_raw} do
      op_raw = mint!(["read", "write", "admin"], default_ws.id)
      host_sid = create(b_raw, host_a) |> json_response(201) |> Map.fetch!("id")

      managed_sid =
        json_conn(b_raw)
        |> post("/v1/chat/sessions", Jason.encode!(%{provider: "claude"}))
        |> json_response(201)
        |> Map.fetch!("id")

      ids =
        json_conn(op_raw)
        |> get("/v1/chat/sessions")
        |> json_response(200)
        |> Map.fetch!("sessions")
        |> Enum.map(& &1["id"])

      assert managed_sid in ids
      refute host_sid in ids
      assert json_conn(op_raw) |> get("/v1/chat/sessions/#{host_sid}") |> json_response(404)
    end
  end

  # ── the lease layer, directly ──────────────────────────────────────────────

  describe "the host directory every lease goes through" do
    test "resolves a host only inside its own workspace; outside it is the unknown-host answer",
         %{ws_a: ws_a, ws_b: ws_b, host_a: host_a} do
      assert {:ok, %{id: ^host_a}} = ChatHosts.resolve(ws_a.id, host_a)
      assert ChatHosts.resolve(ws_b.id, host_a) == {:error, :host_not_found}

      assert ChatHosts.resolve(ws_b.id, host_a) ==
               ChatHosts.resolve(ws_b.id, Ecto.UUID.generate())

      # A NULL-owned (legacy `:global`) session resolves no host at all.
      assert ChatHosts.resolve(nil, host_a) == {:error, :host_not_found}
    end

    test "a row written straight to the store, owned by B and naming A's host, never leases",
         %{ws_b: ws_b, host_a: host_a, a_raw: a_raw} do
      sid = Ecto.UUID.generate()

      {:ok, _} =
        StudioChat.create_session(
          %{
            id: sid,
            provider: "claude",
            execution_target: "registered_host",
            execution_host_id: host_a,
            cwd: System.tmp_dir!(),
            mode: "plan"
          },
          {:workspace, ws_b.id}
        )

      command = %Barkpark.StudioChat.Runtime.Command{
        operation: :send_turn,
        provider: "claude",
        session_id: sid,
        idempotency_key: Ecto.UUID.generate(),
        payload: %{content: "hi"}
      }

      assert Barkpark.StudioChat.Runtime.dispatch("registered_host", "claude", command,
               workspace_id: ws_b.id,
               execution_host_id: host_a,
               host_directory: Barkpark.ChatHosts,
               remote_dispatch: Barkpark.ChatHosts.RemoteDispatch
             ) == {:error, :host_not_found}

      assert_never_leased(host_a, sid)
      assert_own_session_leased(a_raw, host_a)
    end
  end

  # ── Studio: ChatLive's own create path ─────────────────────────────────────

  describe "Studio's create path (ChatHostGate.create_session/3)" do
    test "a B admin in B's scoped chat pushing A's host id gets a B row and A's host receives nothing",
         %{conn: conn, ws_b: ws_b, host_a: host_a, a_raw: a_raw} do
      # The scoped mount's admin, as `ChatLiveScopedAdminTest` mints it, seated
      # owner of B: the admin permission and B's owner seat.
      {:ok, _project} = Barkpark.Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})
      raw = "host-tenancy-studio-" <> Ecto.UUID.generate()

      {:ok, token} =
        Auth.create_token(raw, "studio b admin", @dataset, ["read", "write", "admin"])

      {:ok, _} = TenancyAuth.create_membership(ws_b.id, token.id, "owner")

      conn = init_test_session(conn, %{"api_token" => raw})
      {:ok, view, _html} = live(conn, "/w/#{ws_b.slug}/p/default/studio/chat")

      render_hook(view, "set-execution-target", %{"execution_target" => "registered_host"})
      # A's host is not in B's picker; a crafted event names it anyway.
      render_hook(view, "set-execution-host", %{"execution_host_id" => host_a})

      capture_log(fn ->
        render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})
        # The submit defers create + spawn to a `{:dispatch_send, ...}` the view
        # sends itself; a render is a call queued behind it.
        render(view)
      end)

      assert render(view) =~ "Failed to start the Claude session."

      [row] =
        Repo.all(
          from(s in StudioChat.Session,
            where: s.execution_host_id == ^host_a and s.owner_workspace_id == ^ws_b.id
          )
        )

      assert row.execution_target == "registered_host"
      assert leases_for(row.id) == 0
      assert commands_for(host_a, row.id) == []
      assert_own_session_leased(a_raw, host_a)
    end
  end
end
