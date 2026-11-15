defmodule BarkparkWeb.ChatHostLiveLimitTest do
  @moduledoc """
  A workspace may hold at most `:chat_host_live_limit` LIVE chat hosts
  (enrolled, not revoked), task-4abf105be723796a. Each live host has its own
  2400/min write bucket (#26083), so without a cap one owner with N hosts
  had N x 2400 event writes a minute.

  The cap is checked when an owner issues a token and again, under a
  per-workspace lock, when a host completes enrolment, so tokens issued
  while the workspace had room cannot all complete. Hosts that already
  exist are never touched: a workspace over the cap keeps every host and
  is refused only a new one.

  These tests set the app env, so the module is not async. The race test
  runs on real connections (`unboxed_run`): the sandbox puts every process
  on one connection, where a second enrolment would queue and pass with the
  lock deleted.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the studio_chat capability owns the chat-host routes.
  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.RegisteredHost
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  setup %{conn: conn} do
    ensure_default_scope!()
    previous = Application.fetch_env(:barkpark, :chat_host_live_limit)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:barkpark, :chat_host_live_limit, value)
        :error -> Application.delete_env(:barkpark, :chat_host_live_limit)
      end
    end)

    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "host-cap-#{suffix}", name: "Cap"})
    {:ok, _} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

    owner_raw = "host-cap-owner-#{suffix}"
    {:ok, owner} = Auth.create_token(owner_raw, "owner", "production", ["read", "write", "admin"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, owner.id, "owner")

    {:ok, conn: conn, ws: ws, owner_raw: owner_raw}
  end

  test "the default is 10 live hosts" do
    Application.delete_env(:barkpark, :chat_host_live_limit)
    ws = create_workspace!()
    for n <- 1..10, do: enrol!(ws, "machine-#{n}")

    assert {:error, {:host_limit_reached, 10}} =
             ChatHosts.issue_enrollment(ws.id, %{name: "machine-11"})
  end

  test "an owner at the cap is refused a new token: 409 host_limit_reached, no row written",
       %{conn: conn, ws: ws, owner_raw: raw} do
    limit(2)
    enrol!(ws, "laptop")
    enrol!(ws, "desktop")
    before = rows(ws)

    conn =
      post(bearer(conn, raw), "/w/#{ws.slug}/v1/chat-hosts/enrollments", %{"name" => "third"})

    assert %{
             "error" => %{
               "code" => "host_limit_reached",
               "details" => %{"limit" => 2},
               "message" => message
             }
           } = json_response(conn, 409)

    assert message =~ "revoke one to enroll another"
    assert rows(ws) == before
  end

  test "tokens issued while there was room cannot all complete; revoking a host frees a slot" do
    limit(2)
    ws = create_workspace!()
    tokens = for n <- 1..3, do: issue!(ws, "machine-#{n}")
    [first, second, third] = tokens

    assert enroll_http(first).status == 201
    assert enroll_http(second).status == 201

    conn = enroll_http(third)

    assert %{"error" => %{"code" => "host_limit_reached", "details" => %{"limit" => 2}}} =
             json_response(conn, 409)

    assert length(live_hosts(ws)) == 2

    # The refusal rolled back: the third token is still unused, so the same
    # machine can finish once the owner revokes one.
    [revoked | _] = live_hosts(ws)
    assert {:ok, _} = ChatHosts.revoke(ws.id, revoked.id)
    assert enroll_http(third).status == 201
    assert length(live_hosts(ws)) == 2
  end

  test "a workspace already over the cap keeps every host; only a new enrolment is refused" do
    limit(3)
    ws = create_workspace!()
    pending = issue!(ws, "pending")
    credentials = for n <- 1..3, do: enrol!(ws, "machine-#{n}")

    # The operator lowers the cap below what this workspace already holds.
    limit(1)
    before = rows(ws)

    assert {:error, {:host_limit_reached, 1}} = ChatHosts.issue_enrollment(ws.id, %{name: "x"})
    assert {:error, {:host_limit_reached, 1}} = ChatHosts.enroll(pending)
    assert rows(ws) == before

    # Every existing host still authenticates and still writes.
    for credential <- credentials do
      assert {:ok, host} = ChatHosts.authenticate(credential)
      assert {:ok, _} = ChatHosts.heartbeat(host, %{})
    end

    # Revoking one leaves 2, still over the cap of 1.
    [a, b, c] = live_hosts(ws)
    {:ok, _} = ChatHosts.revoke(ws.id, a.id)
    assert {:error, {:host_limit_reached, 1}} = ChatHosts.issue_enrollment(ws.id, %{name: "x"})
    {:ok, _} = ChatHosts.revoke(ws.id, b.id)
    assert {:error, {:host_limit_reached, 1}} = ChatHosts.issue_enrollment(ws.id, %{name: "x"})
    {:ok, _} = ChatHosts.revoke(ws.id, c.id)
    assert {:ok, _} = ChatHosts.issue_enrollment(ws.id, %{name: "x"})
  end

  test "another workspace's hosts do not count" do
    limit(1)
    full = create_workspace!()
    enrol!(full, "laptop")
    assert {:error, {:host_limit_reached, 1}} = ChatHosts.issue_enrollment(full.id, %{name: "x"})

    other = create_workspace!()
    assert {:ok, _} = ChatHosts.enroll(issue!(other, "laptop"))
  end

  test "pending and revoked rows hold no slot" do
    limit(1)
    ws = create_workspace!()
    _pending = issue!(ws, "pending")
    {:ok, %{host: %{id: id}}} = enrol_result(ws, "old")
    {:ok, _} = ChatHosts.revoke(ws.id, id)

    assert {:ok, _} = ChatHosts.enroll(issue!(ws, "new"))
  end

  test "an expired credential holds no slot and cannot come back past the cap" do
    limit(1)
    ws = create_workspace!()
    {:ok, %{host: %{id: old_id}, credential: old_credential}} = enrol_result(ws, "old")
    {:ok, old} = ChatHosts.authenticate(old_credential)

    # The old host's 30-day credential runs out; nobody revokes it.
    past = DateTime.add(DateTime.utc_now(), -1)

    {1, _} =
      Repo.update_all(from(h in RegisteredHost, where: h.id == ^old_id),
        set: [credential_expires_at: past]
      )

    # It cannot write, so its slot is free.
    assert {:ok, %{credential: new_credential}} = ChatHosts.enroll(issue!(ws, "new"))

    # It cannot come back: authenticate refuses it, and a rotation that was
    # authenticated just before the expiry is refused after it, so the
    # workspace never holds two live hosts under a cap of one.
    assert {:error, :invalid_credential} = ChatHosts.authenticate(old_credential)
    assert {:error, :invalid_credential} = ChatHosts.rotate_credential(old)
    assert DateTime.compare(Repo.get!(RegisteredHost, old_id).credential_expires_at, past) == :eq

    # A host that rotates before its expiry keeps its slot.
    {:ok, new} = ChatHosts.authenticate(new_credential)
    assert {:ok, _} = ChatHosts.rotate_credential(new)
    assert {:error, {:host_limit_reached, 1}} = ChatHosts.issue_enrollment(ws.id, %{name: "x"})
  end

  # From the review of #26408 (its straddle probe). A rotation waits on the
  # host row (held here as a heartbeat or a second rotation would hold it),
  # the credential expires while it waits, and a new host takes the freed
  # slot. When the rotation gets the row it must see the expiry, not the
  # clock it read before it waited.
  test "a rotation that waits past its credential's expiry cannot bring the host back" do
    limit(1)

    unboxed(fn ->
      ws = create_workspace!()

      try do
        token = issue!(ws, "new")
        {:ok, %{host: %{id: id}, credential: credential}} = enrol_result(ws, "old")

        {1, _} =
          Repo.update_all(from(h in RegisteredHost, where: h.id == ^id),
            set: [credential_expires_at: DateTime.add(DateTime.utc_now(), 1_000, :millisecond)]
          )

        {:ok, host} = ChatHosts.authenticate(credential)
        parent = self()

        holder =
          Task.async(fn ->
            unboxed(fn ->
              Repo.transaction(fn ->
                Repo.one!(from(h in RegisteredHost, where: h.id == ^id, lock: "FOR UPDATE"))
                send(parent, :held)

                receive do
                  :release -> :ok
                after
                  10_000 -> :timeout
                end
              end)
            end)
          end)

        assert_receive :held, 5_000
        rotor = Task.async(fn -> unboxed(fn -> ChatHosts.rotate_credential(host) end) end)
        Process.sleep(1_300)

        # Past the expiry the old host holds no slot, so the new one enrols.
        assert {:ok, _} = ChatHosts.enroll(token)

        send(holder.pid, :release)
        assert {:ok, :ok} = Task.await(holder, 10_000)
        assert {:error, :invalid_credential} = Task.await(rotor, 10_000)
        assert usable(ws) == 1
      after
        {:ok, _} = Tenancy.delete_workspace(ws)
      end
    end)
  end

  test "two enrolments at once: the second waits for the first and is refused" do
    limit(1)

    unboxed(fn ->
      ws = create_workspace!()

      try do
        token_a = issue!(ws, "a")
        token_b = issue!(ws, "b")
        parent = self()

        # Holder: completes enrolment A inside a transaction it has not
        # committed, so A's row is invisible to any other connection.
        holder =
          Task.async(fn ->
            unboxed(fn ->
              Repo.transaction(fn ->
                {:ok, _} = ChatHosts.enroll(token_a)
                send(parent, :held)

                receive do
                  :release -> :ok
                after
                  10_000 -> :timeout
                end
              end)
            end)
          end)

        assert_receive :held, 5_000

        racer =
          Task.async(fn ->
            unboxed(fn ->
              %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
              send(parent, {:racer_pid, pid})
              ChatHosts.enroll(token_b)
            end)
          end)

        assert_receive {:racer_pid, racer_pid}, 5_000

        # Without the lock B counts zero live hosts (A is uncommitted) and
        # enrols: two live hosts under a cap of one.
        await_lock_wait(racer_pid)

        send(holder.pid, :release)
        assert {:ok, :ok} = Task.await(holder, 10_000)
        assert {:error, {:host_limit_reached, 1}} = Task.await(racer, 10_000)
        assert [%{name: "a"}] = live_hosts(ws)
      after
        {:ok, _} = Tenancy.delete_workspace(ws)
      end
    end)
  end

  test "Studio shows the cap when the owner is refused a token", %{
    conn: conn,
    ws: ws,
    owner_raw: raw
  } do
    limit(1)
    enrol!(ws, "laptop")

    {:ok, view, _html} =
      live(
        init_test_session(conn, %{"api_token" => raw}),
        "/w/#{ws.slug}/p/default/studio/chat-hosts"
      )

    html =
      view
      |> form("form[phx-submit=enroll]", %{
        "host" => %{"name" => "desktop", "approved_roots" => [System.tmp_dir!()]}
      })
      |> render_submit()

    assert html =~ "reached its limit of 1 enrolled chat hosts. Revoke one to enroll another."
    refute html =~ "One-time enrollment token"
    assert [%{name: "laptop"}] = live_hosts(ws)
  end

  defp limit(n), do: Application.put_env(:barkpark, :chat_host_live_limit, n)

  defp issue!(ws, name) do
    {:ok, %{enrollment_token: token}} = ChatHosts.issue_enrollment(ws.id, %{name: name})
    token
  end

  defp enrol_result(ws, name), do: ChatHosts.enroll(issue!(ws, name))

  defp enrol!(ws, name) do
    {:ok, %{credential: credential}} = enrol_result(ws, name)
    credential
  end

  defp enroll_http(token) do
    scoped_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/v1/chat-host/enroll", Jason.encode!(%{"enrollment_token" => token}))
  end

  defp live_hosts(ws), do: ws.id |> ChatHosts.list_hosts() |> Enum.filter(& &1.enrolled)

  # Hosts that can authenticate right now: the quantity the cap bounds.
  defp usable(ws) do
    now = DateTime.utc_now()

    Repo.aggregate(
      from(h in RegisteredHost,
        where:
          h.workspace_id == ^ws.id and not is_nil(h.enrolled_at) and is_nil(h.revoked_at) and
            h.credential_expires_at > ^now
      ),
      :count
    )
  end

  defp rows(ws) do
    Repo.all(from h in RegisteredHost, where: h.workspace_id == ^ws.id, order_by: h.id)
  end

  defp bearer(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  defp await_lock_wait(pid, tries \\ 250) do
    %{rows: [[waiting]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock'",
        [pid]
      )

    cond do
      waiting == 1 ->
        :ok

      tries == 0 ->
        flunk("the second enrolment never waited on a lock")

      true ->
        Process.sleep(20)
        await_lock_wait(pid, tries - 1)
    end
  end
end
