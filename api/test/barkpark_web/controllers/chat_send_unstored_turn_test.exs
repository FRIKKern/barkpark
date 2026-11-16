defmodule BarkparkWeb.ChatSendUnstoredTurnTest do
  @moduledoc """
  A send that goes wrong AFTER the turn was dispatched answers what happened to
  it (task-583b6031c13b28ac).

  `POST /v1/chat/sessions/:id/messages` dispatches the turn first and stores
  the user's row after it. On a registered host the dispatch has already made
  the lease and put it in the host's queue. Before this, a store fault raised
  through to a 500 while the host went on to run the turn, so a client that
  sent again ran it twice. Now:

    * the row cannot be stored, the lease is ended with a server close: no host
      runs it and the answer is the retryable 503 `runtime_unavailable`;
    * the lease cannot be ended either: the host runs it, so the answer is 202;
    * a managed turn is already in the provider process: the answer is 202;
    * the host queue's call exits after the lease was made: the lease is ended
      and the answer is 503 `runtime_unavailable`.

  The faults are real database errors: a test trigger, created inside the
  test's sandbox transaction and rolled back with it, refuses the insert.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  @moduletag :requires_plugins

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.{ExecutionEvent, ExecutionLease, RegisteredHost}
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.ClaudeChat

  @dataset "production"
  @fixture Path.expand("../../support/fixtures/chat_host_go_capabilities.json", __DIR__)
  @transport Barkpark.ChatHosts.Transport.Server

  setup do
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    prev_chat = Application.get_env(:barkpark, :claude_chat)
    Application.put_env(:barkpark, :public_demo_studio, false)
    # A `cat` echo CLI brings a real managed runtime up without a real `claude`.
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})

    on_exit(fn ->
      reap_recorders()
      Application.put_env(:barkpark, :public_demo_studio, prev_demo)

      if prev_chat,
        do: Application.put_env(:barkpark, :claude_chat, prev_chat),
        else: Application.delete_env(:barkpark, :claude_chat)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "sut-#{suffix}", name: "SUT #{suffix}"})
    raw = "sut-member-#{suffix}"
    {:ok, _} = Auth.create_token(raw, "sut-member", @dataset, ["read", "write", "admin"], ws.id)

    %{host_id: enroll_host!(ws, "go-host-#{suffix}"), raw: raw}
  end

  describe "registered host" do
    test "a user row that cannot be stored ends the lease and answers runtime_unavailable",
         %{host_id: host_id, raw: raw} do
      sid = create_host_session!(raw, host_id)
      fail_inserts!("chat_messages", "NEW.role = 'user'")

      log =
        capture_log(fn ->
          body = send_message(raw, sid, "store me") |> json_response(503)
          assert body["error"]["code"] == "runtime_unavailable"
        end)

      assert log =~ "failed to persist user turn"

      host = Repo.get!(RegisteredHost, host_id)

      assert send_turns(host, sid) == [],
             "no host may be handed a turn the client was told failed"

      assert [%ExecutionLease{status: "completed"} = lease] = leases(sid)

      assert [%ExecutionEvent{cursor: 1, idempotency_key: "server:turn_not_stored"} = close] =
               events(lease.id)

      assert close.payload["kind"] == "terminal"
      assert close.payload["origin"] == "server"
      assert close.payload["reason"] == "turn_not_stored"
      assert StudioChat.list_messages(sid, :global) == []
    end

    test "a send the server cannot end after a store fault answers 202: the host runs it",
         %{host_id: host_id, raw: raw} do
      sid = create_host_session!(raw, host_id)
      fail_inserts!("chat_messages", "NEW.role = 'user'")
      fail_inserts!("chat_execution_events", "true")

      capture_log(fn ->
        assert send_message(raw, sid, "taken anyway") |> json_response(202)
      end)

      host = Repo.get!(RegisteredHost, host_id)
      assert [%{command: command}] = send_turns(host, sid)
      assert command.payload.content == "taken anyway"
    end

    test "a host queue call that exits after the lease was made ends the lease",
         %{host_id: host_id, raw: raw} do
      sid = create_host_session!(raw, host_id)
      exit_next_transport_call!()

      capture_log(fn ->
        body = send_message(raw, sid, "queue me") |> json_response(503)
        assert body["error"]["code"] == "runtime_unavailable"
      end)

      host = Repo.get!(RegisteredHost, host_id)
      assert send_turns(host, sid) == []
      assert [%ExecutionLease{status: "completed"} = lease] = leases(sid)

      assert [%ExecutionEvent{idempotency_key: "server:host_queue_unavailable"}] =
               events(lease.id)

      assert StudioChat.list_messages(sid, :global) == [],
             "a send refused before it was taken stores no user row"
    end

    test "a stored send is unchanged: 202, one live lease, one user row",
         %{host_id: host_id, raw: raw} do
      sid = create_host_session!(raw, host_id)
      assert send_message(raw, sid, "plain") |> json_response(202)

      host = Repo.get!(RegisteredHost, host_id)
      assert [%{command: command}] = send_turns(host, sid)
      assert command.payload.content == "plain"
      assert [%ExecutionLease{status: "leased"} = lease] = leases(sid)
      assert events(lease.id) == []
      assert [%{role: "user", source_markdown: "plain"}] = StudioChat.list_messages(sid, :global)
    end
  end

  describe "managed" do
    test "a user row that cannot be stored answers 202: the turn is already in the runtime" do
      admin = "sut-admin-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(admin, "sut-admin", @dataset, ["read", "write", "admin"])

      {:ok, session} =
        StudioChat.create_session(%{
          id: Ecto.UUID.generate(),
          cwd: ClaudeChat.cwd(),
          mode: "plan"
        })

      fail_inserts!("chat_messages", "NEW.role = 'user'")

      log =
        capture_log(fn ->
          assert send_message(admin, session.id, "managed") |> json_response(202)
        end)

      assert log =~ "failed to persist user turn"
      assert leases(session.id) == []
    end
  end

  # A BEFORE INSERT trigger that raises when `condition` holds. DDL runs inside
  # the sandbox transaction, so the rollback at the end of the test drops it.
  defp fail_inserts!(table, condition) do
    name = "sut_fail_#{table}"

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

  # The next call to the host queue exits the way a timed-out GenServer.call
  # does. The real queue is put back after the test.
  defp exit_next_transport_call! do
    _ = Barkpark.ChatHosts.Transport.commands(Ecto.UUID.generate())
    real = Process.whereis(@transport)
    Process.unregister(@transport)
    stub = spawn(fn -> receive do: (_ -> exit(:injected_queue_exit)) end)
    Process.register(stub, @transport)

    on_exit(fn ->
      case Process.whereis(@transport) do
        nil -> :ok
        ^real -> :ok
        other -> GenServer.stop(other)
      end

      if Process.alive?(real) and Process.whereis(@transport) == nil,
        do: Process.register(real, @transport)
    end)
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

  defp send_message(raw, sid, content) do
    json_conn(raw)
    |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(%{content: content}))
  end

  # What `GET /v1/chat-host/commands` hands the host.
  defp send_turns(host, sid) do
    host
    |> ChatHosts.next_commands()
    |> Enum.filter(&(&1.command.operation == :send_turn and &1.command.session_id == sid))
  end

  defp leases(sid), do: Repo.all(from(l in ExecutionLease, where: l.session_id == ^sid))

  defp events(lease_id),
    do: Repo.all(from(e in ExecutionEvent, where: e.lease_id == ^lease_id, order_by: e.cursor))

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
