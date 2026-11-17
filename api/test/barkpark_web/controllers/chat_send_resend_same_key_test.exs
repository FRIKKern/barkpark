defmodule BarkparkWeb.ChatSendResendSameKeyTest do
  @moduledoc """
  A chat send resent under the same Idempotency-Key runs its turn once
  (task-3c949e2977c56597).

  A send to a registered host leases the turn and puts it in the host's queue.
  When that queue call lands and then exits (a timeout), and the lease cannot
  be ended, the outcome is unknown: the answer is a 5xx, the Idempotency claim
  stays pending until it is stale, and the client sends again. Before this, the resend minted
  a fresh `command_key`, so the host got a second lease and ran the turn twice.
  Now the `command_key` is the claimed Idempotency hash, and a lease that
  already exists for it is not enqueued again:

    * same key, first lease still live: no new lease, no second enqueue, 202;
    * same key, first lease ended by the server as NOT SENT (the queue did not
      take it, the row could not be stored): the resend runs, on the next link
      of the key (`<hash>:2`);
    * a different key: a new turn, as before.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  @moduletag :requires_plugins

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.{ExecutionLease, RegisteredHost}
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.Tenancy

  @dataset "production"
  @fixture Path.expand("../../support/fixtures/chat_host_go_capabilities.json", __DIR__)
  @transport Barkpark.ChatHosts.Transport.Server

  setup do
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      reap_recorders()
      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "ssk-#{suffix}", name: "SSK #{suffix}"})
    raw = "ssk-member-#{suffix}"
    {:ok, _} = Auth.create_token(raw, "ssk-member", @dataset, ["read", "write", "admin"], ws.id)

    %{host_id: enroll_host!(ws, "go-host-#{suffix}"), raw: raw}
  end

  test "a send that enqueues and then times out, resent under the same key, enqueues once",
       %{host_id: host_id, raw: raw} do
    sid = create_host_session!(raw, host_id)
    key = "ssk-#{System.unique_integer([:positive])}"

    # The queue takes the command, the caller sees an exit, and the lease
    # cannot be ended (its close event cannot be written): outcome unknown.
    land_then_exit_next_transport_call!()
    fail_inserts!("chat_execution_events", "true")

    capture_log(fn ->
      assert_error_sent(500, fn -> send_message(raw, sid, "once", key) end)
    end)

    drop_fail_inserts!("chat_execution_events")
    # The crash left the Idempotency claim pending; a resend reclaims it once
    # it is older than pending_ttl_seconds (60 s). Age it instead of waiting.
    age_pending_claims!()
    host = Repo.get!(RegisteredHost, host_id)
    assert length(send_turns(host, sid)) == 1, "the first send did not land in the queue"

    # One lease, one queued command: the resend puts the unstarted lease back
    # on the queue, which is keyed by lease id (task-b1e2f61ca03df99b).
    resend = send_message(raw, sid, "once", key)

    assert resend.status == 202, resend.resp_body
    assert length(send_turns(host, sid)) == 1, "the resend enqueued the turn a second time"
    assert length(leases(sid)) == 1, "the resend made a second lease"

    rows = StudioChat.list_messages(sid, :global)

    assert match?([%{role: "user", source_markdown: "once"}], rows),
           "the user's turn must be stored once"
  end

  # The request died after the user's row was stored and before its answer was
  # recorded: the claim is pending, the lease live, the row there. The resend
  # takes the lease as its own and must not store the row a second time.
  test "a resend whose first turn was stored stores no second row",
       %{host_id: host_id, raw: raw} do
    sid = create_host_session!(raw, host_id)
    key = "ssk-#{System.unique_integer([:positive])}"
    assert send_message(raw, sid, "stored", key).status == 202
    reopen_completed_claims!()

    assert send_message(raw, sid, "stored", key).status == 202
    host = Repo.get!(RegisteredHost, host_id)
    assert [_] = send_turns(host, sid)
    assert [_] = leases(sid)

    rows = StudioChat.list_messages(sid, :global)
    assert match?([%{role: "user"}], rows), "the resend stored the user's turn a second time"
  end

  test "a resend after the queue did not take the turn runs it", %{host_id: host_id, raw: raw} do
    sid = create_host_session!(raw, host_id)
    key = "ssk-#{System.unique_integer([:positive])}"
    exit_next_transport_call!()

    capture_log(fn ->
      assert send_message(raw, sid, "again", key) |> json_response(503)
    end)

    host = Repo.get!(RegisteredHost, host_id)
    assert send_turns(host, sid) == []

    assert send_message(raw, sid, "again", key) |> json_response(202)
    assert [%{command: command}] = send_turns(host, sid)
    assert command.payload.content == "again"

    keys = sid |> leases() |> Enum.map(& &1.command_key) |> Enum.sort()
    assert [base, link2] = keys
    assert link2 == base <> ":2"
  end

  test "a resend after the row could not be stored (lease withdrawn) runs it",
       %{host_id: host_id, raw: raw} do
    sid = create_host_session!(raw, host_id)
    key = "ssk-#{System.unique_integer([:positive])}"
    fail_inserts!("chat_messages", "NEW.role = 'user'")

    capture_log(fn ->
      assert send_message(raw, sid, "stored later", key) |> json_response(503)
    end)

    drop_fail_inserts!("chat_messages")
    host = Repo.get!(RegisteredHost, host_id)
    assert send_turns(host, sid) == []

    assert send_message(raw, sid, "stored later", key) |> json_response(202)
    assert [_] = send_turns(host, sid)
    assert length(leases(sid)) == 2

    assert [%{role: "user", source_markdown: "stored later"}] =
             StudioChat.list_messages(sid, :global)
  end

  # The chain: link 1 not sent, link 2 lands and its answer is lost, then a
  # third send reuses link 2. It must not make link 3.
  test "a third send after a not-sent link and an ambiguous link reuses the live link",
       %{host_id: host_id, raw: raw} do
    sid = create_host_session!(raw, host_id)
    key = "ssk-#{System.unique_integer([:positive])}"

    exit_next_transport_call!()
    capture_log(fn -> assert send_message(raw, sid, "chain", key) |> json_response(503) end)

    land_then_exit_next_transport_call!()
    fail_inserts!("chat_execution_events", "true")

    capture_log(fn ->
      assert_error_sent(500, fn -> send_message(raw, sid, "chain", key) end)
    end)

    drop_fail_inserts!("chat_execution_events")
    # The crash left the Idempotency claim pending; a resend reclaims it once
    # it is older than pending_ttl_seconds (60 s). Age it instead of waiting.
    age_pending_claims!()

    assert send_message(raw, sid, "chain", key) |> json_response(202)
    host = Repo.get!(RegisteredHost, host_id)
    assert length(send_turns(host, sid)) == 1, "the third send enqueued again"
    assert length(leases(sid)) == 2, "the third send made a third lease"
  end

  # withdraw_turn must find the live link, not only the bare key: a resent turn
  # whose row cannot be stored is ended, never left for the host to run while
  # the client is told it was not sent.
  test "a resent link whose row cannot be stored is withdrawn", %{host_id: host_id, raw: raw} do
    sid = create_host_session!(raw, host_id)
    key = "ssk-#{System.unique_integer([:positive])}"

    exit_next_transport_call!()
    capture_log(fn -> assert send_message(raw, sid, "w", key) |> json_response(503) end)

    fail_inserts!("chat_messages", "NEW.role = 'user'")

    capture_log(fn ->
      body = send_message(raw, sid, "w", key) |> json_response(503)
      assert body["error"]["code"] == "runtime_unavailable"
    end)

    host = Repo.get!(RegisteredHost, host_id)
    assert send_turns(host, sid) == [], "the host was handed a turn the client was told failed"
    assert Enum.all?(leases(sid), &(&1.status == "completed"))
  end

  test "a different key is a new turn", %{host_id: host_id, raw: raw} do
    sid = create_host_session!(raw, host_id)

    assert send_message(raw, sid, "one", "ssk-a-#{System.unique_integer([:positive])}").status ==
             202

    assert send_message(raw, sid, "two", "ssk-b-#{System.unique_integer([:positive])}").status ==
             202

    host = Repo.get!(RegisteredHost, host_id)
    assert length(send_turns(host, sid)) == 2
    assert length(leases(sid)) == 2
  end

  # "Not sent" is a closed list of the server's own closes. A lease closed at
  # cursor 1 any other way may have been taken by the host, so a resend must
  # neither make link :2 nor call the queue.
  test "a resend after the host closed the lease at cursor 1 runs nothing",
       %{host_id: host_id, raw: raw} do
    sid = create_host_session!(raw, host_id)
    key = "ssk-#{System.unique_integer([:positive])}"
    assert send_message(raw, sid, "hosted", key).status == 202
    host = Repo.get!(RegisteredHost, host_id)
    [lease] = leases(sid)

    assert {:ok, :accepted} =
             ChatHosts.accept_event(host, %{
               lease_id: lease.id,
               epoch: lease.epoch,
               cursor: 1,
               idempotency_key: "host-close-1",
               event: %{"kind" => "terminal", "terminal_state" => "failed"}
             })

    assert %{status: "completed", last_cursor: 1} = Repo.get!(ExecutionLease, lease.id)
    assert_resend_runs_nothing!(raw, sid, "hosted", key)
  end

  test "a resend after the server expired the lease at cursor 1 runs nothing",
       %{host_id: host_id, raw: raw} do
    sid = create_host_session!(raw, host_id)
    key = "ssk-#{System.unique_integer([:positive])}"
    assert send_message(raw, sid, "expired", key).status == 202
    [lease] = leases(sid)

    {1, _} =
      from(l in ExecutionLease, where: l.id == ^lease.id)
      |> Repo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), -3600)])

    {1, _} =
      from(s in StudioChat.Session, where: s.id == ^sid)
      |> Repo.update_all(set: [status: "working"])

    assert ChatHosts.end_expired_turns(DateTime.utc_now(), ~U[2000-01-01 00:00:00Z]) >= 1
    assert %{status: "completed", last_cursor: 1} = Repo.get!(ExecutionLease, lease.id)

    assert Repo.exists?(
             from(e in Barkpark.ChatHosts.ExecutionEvent,
               where:
                 e.lease_id == ^lease.id and e.cursor == 1 and
                   e.idempotency_key == "server:lease_expired"
             )
           )

    assert_resend_runs_nothing!(raw, sid, "expired", key)
  end

  # The queue is in memory: a restart between a send and its resend empties
  # it. The resend reuses the lease, so it must put it back or the turn never
  # runs (task-b1e2f61ca03df99b).
  test "a resend after a server restart puts the reused lease back on the queue",
       %{host_id: host_id, raw: raw} do
    sid = create_host_session!(raw, host_id)
    key = "ssk-#{System.unique_integer([:positive])}"
    assert send_message(raw, sid, "restart", key).status == 202
    host = Repo.get!(RegisteredHost, host_id)
    restart_transport!()
    assert send_turns(host, sid) == []

    reopen_completed_claims!()
    assert send_message(raw, sid, "restart", key).status == 202
    assert length(send_turns(host, sid)) == 1, "the restart left the turn off the queue"
    assert length(leases(sid)) == 1, "the resend made a second lease"
    assert length(StudioChat.list_messages(sid, :global)) == 1
  end

  # A host may hold the lease the first send queued, so a requeue that exits
  # must not end it as "not sent": the next resend would run it on link :2.
  test "a requeue that exits leaves the lease live, and the next resend queues it",
       %{host_id: host_id, raw: raw} do
    sid = create_host_session!(raw, host_id)
    key = "ssk-#{System.unique_integer([:positive])}"
    assert send_message(raw, sid, "requeue", key).status == 202
    restart_transport!()
    reopen_completed_claims!()
    exit_next_transport_call!()

    capture_log(fn ->
      assert_error_sent(500, fn -> send_message(raw, sid, "requeue", key) end)
    end)

    assert [%{status: "leased", last_cursor: 0}] = leases(sid)
    age_pending_claims!()
    assert send_message(raw, sid, "requeue", key).status == 202
    host = Repo.get!(RegisteredHost, host_id)
    assert length(send_turns(host, sid)) == 1, "the turn is not back on the queue"
    assert length(leases(sid)) == 1, "the resend made a second lease"
  end

  test "a send with no key is unchanged: one lease, one enqueue", %{host_id: host_id, raw: raw} do
    sid = create_host_session!(raw, host_id)
    assert send_message(raw, sid, "plain", nil).status == 202
    host = Repo.get!(RegisteredHost, host_id)
    assert [_] = send_turns(host, sid)
    assert [_] = leases(sid)
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp fail_inserts!(table, condition) do
    name = "ssk_fail_#{table}"

    Repo.query!("""
    CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF #{condition} THEN RAISE EXCEPTION 'injected store fault on #{table}'; END IF;
      RETURN NEW;
    END $$
    """)

    Repo.query!(
      "CREATE TRIGGER #{name} BEFORE INSERT ON #{table} FOR EACH ROW EXECUTE FUNCTION #{name}()"
    )
  end

  # The first send's request died before its answer was recorded: its
  # completed claim goes back to a stale pending one, so the resend reaches the
  # controller instead of replaying the stored 202.
  defp reopen_completed_claims! do
    Repo.query!("""
    UPDATE idempotency_keys
    SET state = 'pending', status_code = NULL, response_body = NULL,
        inserted_at = inserted_at - interval '1 hour'
    WHERE state = 'completed'
    """)
  end

  # A same-key resend of a turn the host may have taken: 202, no new link,
  # and the host queue (armed to exit) is never called.
  defp assert_resend_runs_nothing!(raw, sid, content, key) do
    reopen_completed_claims!()
    stub = exit_next_transport_call!()
    resend = send_message(raw, sid, content, key)

    assert resend.status == 202, resend.resp_body
    assert Process.whereis(@transport) == stub, "the resend called the host queue"
    disarm_transport_stub!(stub)
    assert length(leases(sid)) == 1, "the resend made a second link"
  end

  defp age_pending_claims! do
    Repo.query!(
      "UPDATE idempotency_keys SET inserted_at = inserted_at - interval '1 hour' WHERE state = 'pending'"
    )
  end

  defp drop_fail_inserts!(table) do
    name = "ssk_fail_#{table}"
    Repo.query!("DROP TRIGGER #{name} ON #{table}")
    Repo.query!("DROP FUNCTION #{name}()")
  end

  # A server restart, as the queue sees it: the process and every command in
  # it are gone, and the next call starts an empty one.
  defp restart_transport! do
    _ = Barkpark.ChatHosts.Transport.commands(Ecto.UUID.generate())
    GenServer.stop(@transport)
  end

  # The next queue call exits the way a timed-out GenServer.call does, without
  # the command landing. The real queue is put back at once.
  defp exit_next_transport_call!, do: stub_next_transport_call!(false)

  # The next queue call LANDS in the real queue, and then the caller sees an
  # exit: the answer was lost, the command was not.
  defp land_then_exit_next_transport_call!, do: stub_next_transport_call!(true)

  # Put the real queue back under a stub that was never called.
  defp disarm_transport_stub!(stub) do
    real = Process.get(:ssk_real_transport)
    Process.unregister(@transport)
    Process.register(real, @transport)
    Process.exit(stub, :kill)
  end

  defp stub_next_transport_call!(land?) do
    _ = Barkpark.ChatHosts.Transport.commands(Ecto.UUID.generate())
    real = Process.whereis(@transport)
    Process.put(:ssk_real_transport, real)
    Process.unregister(@transport)

    stub =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, message} ->
            if land?, do: GenServer.call(real, message)
            Process.unregister(@transport)
            Process.register(real, @transport)
            exit(:injected_queue_exit)
        end
      end)

    Process.register(stub, @transport)

    on_exit(fn ->
      case Process.whereis(@transport) do
        ^real -> :ok
        nil -> if Process.alive?(real), do: Process.register(real, @transport)
        other -> Process.exit(other, :kill)
      end
    end)

    stub
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

  defp json_conn(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp create_host_session!(raw, host_id) do
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
    |> Map.fetch!("id")
  end

  defp send_message(raw, sid, content, nil) do
    json_conn(raw)
    |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(%{content: content}))
  end

  defp send_message(raw, sid, content, key) do
    json_conn(raw)
    |> put_req_header("idempotency-key", key)
    |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(%{content: content}))
  end

  defp send_turns(host, sid) do
    host
    |> ChatHosts.next_commands()
    |> Enum.filter(&(&1.command.operation == :send_turn and &1.command.session_id == sid))
  end

  defp leases(sid), do: Repo.all(from(l in ExecutionLease, where: l.session_id == ^sid))

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
