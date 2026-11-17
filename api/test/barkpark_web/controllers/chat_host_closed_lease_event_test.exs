defmodule BarkparkWeb.ChatHostClosedLeaseEventTest do
  @moduledoc """
  A host event for a lease that is already closed (task-77353697aed3ffa4).

  The named failure mode: the fence checked host, epoch, revocation and
  expiry, never the lease's status, and a closed lease's `expires_at` is
  still up to 60 s ahead. An event at `last_cursor + 1` was taken, and its
  projection went to the session's Recorder, which cannot tell leases apart
  (a Runtime.Event carries no lease id). So a stray close from a lease the
  server had withdrawn ("not sent, send it again") ended the person's NEW
  turn and marked the session `exited`.

  Now a closed lease takes no new event: the answer is 409 `stale_fence`,
  final for the Go host (any 4xx but 408/429), nothing is written and nothing
  is projected. What stays as it was:

    * an exact retry of an event the lease already took is a duplicate, so a
      host retrying after a lost 2xx is not told it failed;
    * a host's close at the cursor the server's close took is the cursor
      conflict it always was;
    * a lease closed by a host `error` event still takes the turn's next
      event: codex app-server forwards a retrying error as kind `error` and
      the turn goes on (internal/chathost/local_handler.go, codexMessage).
      So does one closed by `control_completed`, a Stop's ack followed by the
      turn's own close (recorder_host_interrupt_test.exs). Either one is
      refused once the session has a newer lease (task-1eefeeb52ed19e73):
      Claude's `error` result is followed by the host's terminal after the
      provider exits, and a person can send again in that gap.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Ecto.Query

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.{ExecutionEvent, ExecutionLease}
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.StudioChat.Runtime.Command
  alias Barkpark.Tenancy

  @dead_close %{
    "kind" => "terminal",
    "terminal_state" => "error",
    "error" => %{"message" => "the turn's first event was not taken"}
  }

  setup do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      reap_recorders()

      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    host_session()
  end

  test "a close for a lease the server withdrew is refused and leaves the newer turn working",
       %{sid: sid} = ctx do
    old = lease!(ctx, "old")
    assert ChatHosts.withdraw_turn(sid, old.command_key) == :ok
    old_before = rows(old.lease_id)

    # The person sends again: a new lease, and its turn has started.
    new = lease!(ctx, "new")

    assert {:ok, :accepted} =
             event(ctx, new, 1, %{"kind" => "turn_started", "turn_id" => "t-new"})

    assert StudioChat.get_session(sid).status == "working"
    new_before = rows(new.lease_id)

    assert {:error, :stale_fence} = event(ctx, old, 2, @dead_close)

    assert rows(old.lease_id) == old_before, "the withdrawn lease takes no event"
    assert rows(new.lease_id) == new_before
    assert StudioChat.get_session(sid).status == "working", "the newer turn is not ended"
    assert ChatHosts.replay_unprojected(sid) == []
  end

  test "the refusal is a 409 stale_fence on the route, final for the Go host",
       %{sid: sid} = ctx do
    old = lease!(ctx, "old")
    assert ChatHosts.withdraw_turn(sid, old.command_key) == :ok

    conn = post_event(ctx, old, 2, @dead_close)
    assert %{"error" => %{"code" => "stale_fence"}} = json_response(conn, 409)
  end

  test "a host event after the lease's own close is refused, and the newer turn stays working",
       %{sid: sid} = ctx do
    old = lease!(ctx, "old")

    assert {:ok, :accepted} =
             event(ctx, old, 1, %{"kind" => "turn_started", "turn_id" => "t-old"})

    assert {:ok, :accepted} =
             event(ctx, old, 2, %{"kind" => "turn_completed", "terminal_state" => "completed"})

    new = lease!(ctx, "new")

    assert {:ok, :accepted} =
             event(ctx, new, 1, %{"kind" => "turn_started", "turn_id" => "t-new"})

    assert StudioChat.get_session(sid).status == "working"
    old_before = rows(old.lease_id)

    # Claude exits non-zero after its result: the host's terminal follows.
    assert {:error, :stale_fence} = event(ctx, old, 3, @dead_close)

    assert rows(old.lease_id) == old_before
    assert StudioChat.get_session(sid).status == "working"
  end

  test "a host close racing the server's close of the same lease writes nothing at either cursor",
       %{sid: sid} = ctx do
    old = lease!(ctx, "old")
    assert ChatHosts.withdraw_turn(sid, old.command_key) == :ok
    before = rows(old.lease_id)

    assert {:error, :cursor_conflict} = event(ctx, old, 1, @dead_close)
    assert {:error, :stale_fence} = event(ctx, old, 2, @dead_close)
    assert rows(old.lease_id) == before
  end

  test "an exact retry of the close a lease took is still a duplicate", ctx do
    lease = lease!(ctx, "one")

    assert {:ok, :accepted} =
             event(ctx, lease, 1, %{"kind" => "turn_started", "turn_id" => "t-1"})

    assert {:ok, :accepted} = event(ctx, lease, 2, @dead_close)
    before = rows(lease.lease_id)

    assert {:ok, :duplicate} = event(ctx, lease, 2, @dead_close)
    assert json_response(post_event(ctx, lease, 2, @dead_close), 200)["duplicate"] == true
    assert rows(lease.lease_id) == before
  end

  test "a turn that goes on after a host error event is still taken (codex retrying error)",
       %{sid: sid} = ctx do
    lease = lease!(ctx, "codex")

    assert {:ok, :accepted} =
             event(ctx, lease, 1, %{"kind" => "turn_started", "turn_id" => "t-1"})

    retrying = %{
      "kind" => "error",
      "error" => %{"willRetry" => true, "message" => "Reconnecting"}
    }

    assert {:ok, :accepted} = event(ctx, lease, 2, retrying)
    assert Repo.get!(ExecutionLease, lease.lease_id).status == "completed"

    assert {:ok, :accepted} = event(ctx, lease, 3, %{"kind" => "text_delta", "delta" => "back"})

    assert {:ok, :accepted} =
             event(ctx, lease, 4, %{"kind" => "turn_completed", "terminal_state" => "completed"})

    assert Repo.get!(ExecutionLease, lease.lease_id).last_cursor == 4
    refute StudioChat.get_session(sid).status == "working"
  end

  test "a host terminal after an error-closed lease is refused once a newer lease exists, and the session stays working",
       %{sid: sid} = ctx do
    old = lease!(ctx, "old")

    assert {:ok, :accepted} =
             event(ctx, old, 1, %{"kind" => "turn_started", "turn_id" => "t-old"})

    # Claude's error result; the provider has not exited yet.
    failed = %{"kind" => "error", "terminal_state" => "failed", "error" => %{"is_error" => true}}
    assert {:ok, :accepted} = event(ctx, old, 2, failed)

    new = lease!(ctx, "new")

    assert {:ok, :accepted} =
             event(ctx, new, 1, %{"kind" => "turn_started", "turn_id" => "t-new"})

    assert StudioChat.get_session(sid).status == "working"
    old_before = rows(old.lease_id)
    new_before = rows(new.lease_id)

    # The provider exits non-zero: the host's terminal follows its error.
    assert {:error, :stale_fence} = event(ctx, old, 3, @dead_close)

    assert rows(old.lease_id) == old_before, "the old lease takes no event"
    assert rows(new.lease_id) == new_before
    assert StudioChat.get_session(sid).status == "working", "the newer turn is not ended"
    assert ChatHosts.replay_unprojected(sid) == []
  end

  test "a codex turn's close after a retrying error is refused once a newer lease exists",
       %{sid: sid} = ctx do
    old = lease!(ctx, "old")

    assert {:ok, :accepted} =
             event(ctx, old, 1, %{"kind" => "turn_started", "turn_id" => "t-old"})

    retrying = %{
      "kind" => "error",
      "error" => %{"willRetry" => true, "message" => "Reconnecting"}
    }

    assert {:ok, :accepted} = event(ctx, old, 2, retrying)

    new = lease!(ctx, "new")

    assert {:ok, :accepted} =
             event(ctx, new, 1, %{"kind" => "turn_started", "turn_id" => "t-new"})

    old_before = rows(old.lease_id)

    assert {:error, :stale_fence} =
             event(ctx, old, 3, %{"kind" => "turn_completed", "terminal_state" => "completed"})

    assert rows(old.lease_id) == old_before
    assert StudioChat.get_session(sid).status == "working"
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp event(%{host: host}, fence, cursor, event) do
    ChatHosts.accept_event(host, %{
      lease_id: fence.lease_id,
      epoch: fence.epoch,
      cursor: cursor,
      idempotency_key: "#{fence.lease_id}:#{fence.epoch}:#{cursor}",
      event: event
    })
  end

  defp post_event(%{credential: credential}, fence, cursor, event) do
    build_conn()
    |> put_req_header("authorization", "Host #{credential}")
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/chat-host/events",
      Jason.encode!(%{
        lease_id: fence.lease_id,
        epoch: fence.epoch,
        cursor: cursor,
        idempotency_key: "#{fence.lease_id}:#{fence.epoch}:#{cursor}",
        event: event
      })
    )
  end

  defp lease!(%{host: host, sid: sid}, tag) do
    command = %Command{
      operation: :start,
      provider: "claude",
      session_id: sid,
      idempotency_key: "closed-#{tag}-#{System.unique_integer([:positive])}",
      payload: %{cwd: System.tmp_dir!(), content: "hello #{tag}"}
    }

    {:ok, fence} = ChatHosts.lease_and_enqueue(host, command, [])
    fence
  end

  defp rows(lease_id) do
    events =
      Repo.all(from(e in ExecutionEvent, where: e.lease_id == ^lease_id, order_by: e.cursor))

    {Repo.get!(ExecutionLease, lease_id), events}
  end

  # One registered-host Claude session with a live Recorder.
  defp host_session do
    suffix = System.unique_integer([:positive])

    {:ok, ws} =
      Tenancy.create_workspace(%{slug: "host-closed-#{suffix}", name: "Closed #{suffix}"})

    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{
        name: "laptop-#{suffix}",
        approved_roots: [System.tmp_dir!()],
        capabilities: capabilities()
      })

    {:ok, enrolled} = ChatHosts.enroll(issued.enrollment_token, %{capabilities: capabilities()})
    {:ok, host} = ChatHosts.authenticate(enrolled.credential)
    sid = Ecto.UUID.generate()

    {:ok, _} =
      StudioChat.create_session(
        %{
          id: sid,
          mode: "plan",
          provider: "claude",
          execution_target: "registered_host",
          execution_host_id: host.id
        },
        ws.id
      )

    {:ok, _recorder} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})
    %{host: host, credential: enrolled.credential, sid: sid}
  end

  defp capabilities do
    %{
      "protocol_version" => 1,
      "providers" => %{"claude" => %{"installed" => true, "auth_ready" => true}}
    }
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
