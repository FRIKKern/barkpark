defmodule BarkparkWeb.ChatHostTurnOwnerTest do
  @moduledoc """
  Two live leases of one session never make one reply row
  (task-b0cbddc9d0f2e2aa).

  The named failure mode: the Recorder keeps one turn's text and could not
  tell leases apart. Since #26812 an older lease's events are kept out while
  a newer turn is open, but two shapes still joined two replies into one row:

    * T1/T3: the older lease's text was taken BEFORE the newer lease's
      `turn_started`, which the Recorder took as the same turn going on:
      "Older-1.\\n\\nNewer.";
    * T7: the newer lease's host went silent, the expiry sweep ended it while
      the older lease was live (so its close was not projected), and the
      older text was appended with no break: "Newer-part.Older reply.".

  Each projected host event now names its lease (`Recorder.TurnOwner`), and an
  event from another lease while the turn is open stores the open text as its
  own row first. What stays as it was: one lease's own repeated
  `turn_started` (an older claude host sends one per message) joins its
  messages as paragraphs of one row, and an event with no lease (a managed
  runtime) changes nothing.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Ecto.Query

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.ExecutionLease
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.StudioChat.Runtime.{Command, Event}
  alias Barkpark.Tenancy

  @dead_close %{
    "kind" => "terminal",
    "terminal_state" => "error",
    "error" => %{"message" => "claude exited before turn completion"}
  }

  # The Go host's answer to a Stop when it runs no turn for the session
  # (internal/chathost/local_handler.go).
  @no_active_turn %{
    "kind" => "terminal",
    "terminal_state" => "error",
    "error" => %{"message" => "registered-host session has no active turn"}
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

  test "T1: older text taken before the newer turn_started is its own row", %{sid: sid} = ctx do
    old = lease!(ctx, "old")
    accept!(ctx, old, 1, %{"kind" => "turn_started", "turn_id" => "t-old"})
    accept!(ctx, old, 2, %{"kind" => "text_delta", "delta" => "Older-1."})
    new = lease!(ctx, "new")
    accept!(ctx, new, 1, %{"kind" => "turn_started", "turn_id" => "t-new"})
    accept!(ctx, old, 3, %{"kind" => "turn_completed", "terminal_state" => "completed"})
    assert StudioChat.get_session(sid).status == "working", "the newer turn is not ended"
    accept!(ctx, new, 2, %{"kind" => "text_delta", "delta" => "Newer."})
    accept!(ctx, new, 3, %{"kind" => "turn_completed", "terminal_state" => "completed"})

    assert replies(sid) == ["Older-1.", "Newer."]
    refute StudioChat.get_session(sid).status == "working"
  end

  test "T3: a stopped turn's text, its close after the next turn_started, is its own row",
       %{sid: sid} = ctx do
    old = lease!(ctx, "old")
    accept!(ctx, old, 1, %{"kind" => "turn_started", "turn_id" => "t-old"})
    accept!(ctx, old, 2, %{"kind" => "text_delta", "delta" => "Half"})
    stop = lease!(ctx, "stop", :interrupt)
    Recorder.note_interrupt_requested(sid)
    accept!(ctx, stop, 1, %{"kind" => "control_completed", "operation" => "interrupt"})
    new = lease!(ctx, "new")
    accept!(ctx, new, 1, %{"kind" => "turn_started", "turn_id" => "t-new"})
    accept!(ctx, old, 3, @dead_close)
    accept!(ctx, new, 2, %{"kind" => "text_delta", "delta" => "Next."})
    accept!(ctx, new, 3, %{"kind" => "turn_completed", "terminal_state" => "completed"})

    assert replies(sid) == ["Half", "Next."]
  end

  test "T7: older text after the sweep ended the newer lease is its own row", %{sid: sid} = ctx do
    old = lease!(ctx, "old")
    accept!(ctx, old, 1, %{"kind" => "turn_started", "turn_id" => "t-old"})
    new = lease!(ctx, "new")
    accept!(ctx, new, 1, %{"kind" => "turn_started", "turn_id" => "t-new"})
    accept!(ctx, new, 2, %{"kind" => "text_delta", "delta" => "Newer-part."})

    past = DateTime.add(DateTime.utc_now(), -600)

    Repo.update_all(from(l in ExecutionLease, where: l.id == ^new.lease_id),
      set: [expires_at: past]
    )

    assert ChatHosts.end_expired_turns(DateTime.utc_now(), ~U[2000-01-01 00:00:00Z]) == 1
    accept!(ctx, old, 2, %{"kind" => "text_delta", "delta" => "Older reply."})
    accept!(ctx, old, 3, %{"kind" => "turn_completed", "terminal_state" => "completed"})

    assert replies(sid) == ["Newer-part.", "Older reply."]
    refute StudioChat.get_session(sid).status == "working"
  end

  test "one lease's repeated turn_started still joins its messages into one row",
       %{sid: sid} = ctx do
    fence = lease!(ctx, "one")
    accept!(ctx, fence, 1, %{"kind" => "turn_started"})
    accept!(ctx, fence, 2, %{"kind" => "text_delta", "delta" => "First."})
    accept!(ctx, fence, 3, %{"kind" => "turn_started"})
    accept!(ctx, fence, 4, %{"kind" => "text_delta", "delta" => "Second."})
    accept!(ctx, fence, 5, %{"kind" => "turn_completed", "terminal_state" => "completed"})

    assert replies(sid) == ["First.\n\nSecond."]
  end

  # A Stop's lease is newer but starts no turn: its ack does not take the turn
  # over, so the stopped turn's late text stays in the same row.
  test "a Stop's ack mid-turn does not split the stopped turn's reply", %{sid: sid} = ctx do
    old = lease!(ctx, "old")
    accept!(ctx, old, 1, %{"kind" => "turn_started", "turn_id" => "t-old"})
    accept!(ctx, old, 2, %{"kind" => "text_delta", "delta" => "Half"})
    stop = lease!(ctx, "stop", :interrupt)
    Recorder.note_interrupt_requested(sid)
    accept!(ctx, stop, 1, %{"kind" => "control_completed", "operation" => "interrupt"})
    accept!(ctx, old, 3, %{"kind" => "text_delta", "delta" => " and late"})
    accept!(ctx, old, 4, %{"kind" => "turn_completed", "terminal_state" => "interrupted"})

    assert replies(sid) == ["Half and late"]
    refute StudioChat.get_session(sid).status == "working"
  end

  # task-e10a3e17759cdaab: the split row was stored with no turn_outcome, so a
  # reload showed the stopped reply as a normal one.
  test "a stopped turn's text, split off by the next lease's turn, is stored as interrupted",
       %{sid: sid} = ctx do
    old = lease!(ctx, "old")
    accept!(ctx, old, 1, %{"kind" => "turn_started", "turn_id" => "t-old"})
    accept!(ctx, old, 2, %{"kind" => "text_delta", "delta" => "Half"})
    stop = lease!(ctx, "stop", :interrupt)
    Recorder.note_interrupt_requested(sid)
    accept!(ctx, stop, 1, %{"kind" => "control_completed", "operation" => "interrupt"})
    new = lease!(ctx, "new")
    accept!(ctx, new, 1, %{"kind" => "turn_started", "turn_id" => "t-new"})
    accept!(ctx, new, 2, %{"kind" => "text_delta", "delta" => "Next."})
    accept!(ctx, new, 3, %{"kind" => "turn_completed", "terminal_state" => "completed"})

    assert outcomes(sid) == [{"Half", "interrupted"}, {"Next.", nil}],
           "the Stop belongs to the split-off turn, never to the next one"
  end

  # R1 (rev26735): a Stop asked after the newer lease was leased is aimed at
  # the newer run (the host routes control by session to its latest run), even
  # when the newer turn_started reaches the Recorder after it.
  test "R1: a Stop after the newer lease was leased does not mark the older split row",
       %{sid: sid} = ctx do
    old = lease!(ctx, "old")
    accept!(ctx, old, 1, %{"kind" => "turn_started", "turn_id" => "t-old"})
    accept!(ctx, old, 2, %{"kind" => "text_delta", "delta" => "Half"})
    new = lease!(ctx, "new")
    stop!(ctx)
    accept!(ctx, new, 1, %{"kind" => "turn_started", "turn_id" => "t-new"})
    accept!(ctx, new, 2, %{"kind" => "text_delta", "delta" => "Next."})
    accept!(ctx, new, 3, %{"kind" => "turn_completed", "terminal_state" => "interrupted"})

    assert outcomes(sid) == [{"Half", nil}, {"Next.", "interrupted"}]
  end

  test "R2: a Stop after the newer turn_started does not mark the older split row",
       %{sid: sid} = ctx do
    old = lease!(ctx, "old")
    accept!(ctx, old, 1, %{"kind" => "turn_started", "turn_id" => "t-old"})
    accept!(ctx, old, 2, %{"kind" => "text_delta", "delta" => "Half"})
    new = lease!(ctx, "new")
    accept!(ctx, new, 1, %{"kind" => "turn_started", "turn_id" => "t-new"})
    stop!(ctx)
    accept!(ctx, new, 2, %{"kind" => "text_delta", "delta" => "Next."})
    accept!(ctx, new, 3, %{"kind" => "turn_completed", "terminal_state" => "interrupted"})

    assert outcomes(sid) == [{"Half", nil}, {"Next.", "interrupted"}]
  end

  test "R3: a Stop during the older turn, split by the newer lease's text, marks that row",
       %{sid: sid} = ctx do
    new = lease!(ctx, "new")
    accept!(ctx, new, 1, %{"kind" => "turn_started", "turn_id" => "t-new"})
    accept!(ctx, new, 2, %{"kind" => "text_delta", "delta" => "Half"})
    stop!(ctx)
    old = lease!(ctx, "old")
    accept!(ctx, old, 1, %{"kind" => "text_delta", "delta" => "Next."})
    accept!(ctx, old, 2, %{"kind" => "turn_completed", "terminal_state" => "completed"})

    assert outcomes(sid) == [{"Half", "interrupted"}, {"Next.", nil}]
  end

  test "a split with no Stop stores no turn_outcome", %{sid: sid} = ctx do
    old = lease!(ctx, "old")
    accept!(ctx, old, 1, %{"kind" => "turn_started", "turn_id" => "t-old"})
    accept!(ctx, old, 2, %{"kind" => "text_delta", "delta" => "Older-1."})
    new = lease!(ctx, "new")
    accept!(ctx, new, 1, %{"kind" => "turn_started", "turn_id" => "t-new"})
    accept!(ctx, new, 2, %{"kind" => "text_delta", "delta" => "Newer."})
    accept!(ctx, new, 3, %{"kind" => "turn_completed", "terminal_state" => "completed"})

    assert outcomes(sid) == [{"Older-1.", nil}, {"Newer.", nil}]
  end

  # A Stop on an earlier turn that the host closed as interrupted does not
  # carry over to a later split.
  test "an earlier stopped turn does not mark a later split row interrupted",
       %{sid: sid} = ctx do
    first = lease!(ctx, "first")
    accept!(ctx, first, 1, %{"kind" => "turn_started", "turn_id" => "t-1"})
    accept!(ctx, first, 2, %{"kind" => "text_delta", "delta" => "Stopped."})
    Recorder.note_interrupt_requested(sid)
    accept!(ctx, first, 3, %{"kind" => "turn_completed", "terminal_state" => "interrupted"})

    old = lease!(ctx, "old")
    accept!(ctx, old, 1, %{"kind" => "turn_started", "turn_id" => "t-old"})
    accept!(ctx, old, 2, %{"kind" => "text_delta", "delta" => "Older-1."})
    new = lease!(ctx, "new")
    accept!(ctx, new, 1, %{"kind" => "turn_started", "turn_id" => "t-new"})
    accept!(ctx, new, 2, %{"kind" => "text_delta", "delta" => "Newer."})
    accept!(ctx, new, 3, %{"kind" => "turn_completed", "terminal_state" => "completed"})

    assert outcomes(sid) == [{"Stopped.", "interrupted"}, {"Older-1.", nil}, {"Newer.", nil}]
  end

  # task-bc312d78041663a8: an ask from the lease a newer turn displaced cannot
  # be answered by it. The answer is leased by session and approval id, and the
  # host routes it to the session's one run: the NEWER one, which does not know
  # the ask, and that answer lease's close then ends the newer turn. So at the
  # split the displaced ask is canceled in the store, and no card invites it.
  test "a newer lease's turn cancels the displaced lease's pending ask", %{sid: sid} = ctx do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))
    old = lease!(ctx, "old")
    accept!(ctx, old, 1, %{"kind" => "turn_started", "turn_id" => "t-old"})
    accept!(ctx, old, 2, ask("ap-1"))
    assert ask_status(sid) == "pending"
    assert StudioChat.get_session(sid).agent_state == "blocked"

    new = lease!(ctx, "new")
    accept!(ctx, new, 1, %{"kind" => "turn_started", "turn_id" => "t-new"})
    expire!(old)
    ChatHosts.end_expired_turns(DateTime.utc_now(), ~U[2000-01-01 00:00:00Z])
    accept!(ctx, new, 2, %{"kind" => "text_delta", "delta" => "Newer."})

    assert ask_status(sid) == "canceled", "no card may invite an answer the older run cannot get"
    assert ask_meta(sid)["cancel_reason"] == "superseded_by_newer_turn"
    assert StudioChat.get_session(sid).agent_state == "working"
    assert MapSet.size(:sys.get_state(Recorder.whereis(sid)).pending_asks) == 0
    assert_received {:chat_permission_resolved, _request_id, :canceled}
  end

  # The other split shape (rev26735): the newer lease's first event is text,
  # with no turn_started before it.
  test "the newer lease's text (no turn_started) cancels the displaced lease's pending ask",
       %{sid: sid} = ctx do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))
    old = lease!(ctx, "old")
    accept!(ctx, old, 1, %{"kind" => "turn_started", "turn_id" => "t-old"})
    accept!(ctx, old, 2, ask("ap-3"))
    assert ask_status(sid) == "pending"

    new = lease!(ctx, "new")
    accept!(ctx, new, 1, %{"kind" => "text_delta", "delta" => "Newer."})

    assert ask_status(sid) == "canceled", "no card may invite an answer the older run cannot get"
    assert ask_meta(sid)["cancel_reason"] == "superseded_by_newer_turn"
    assert StudioChat.get_session(sid).agent_state == "working"
    assert MapSet.size(:sys.get_state(Recorder.whereis(sid)).pending_asks) == 0
    assert_received {:chat_permission_resolved, _request_id, :canceled}
  end

  test "an ask stays pending while its own lease's turn goes on", %{sid: sid} = ctx do
    one = lease!(ctx, "one")
    accept!(ctx, one, 1, %{"kind" => "turn_started"})
    accept!(ctx, one, 2, ask("ap-2"))
    accept!(ctx, one, 3, %{"kind" => "turn_started"})
    accept!(ctx, one, 4, %{"kind" => "text_delta", "delta" => "More."})

    assert ask_status(sid) == "pending"
    assert StudioChat.get_session(sid).agent_state == "blocked"
  end

  # ── a turn's end cancels only its own run's asks (task-6b2fede385c12f8d) ─

  # rev26735 on #26941: the person sends again while run A waits on an ask;
  # the host refuses send_turn B ("already has an active turn"), and B's close
  # is its first event. B never owned the turn, and A's run is alive, so A's
  # ask must stay pending and answerable.
  test "a refused newer send_turn's close leaves the live run's ask pending", %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("ap-live"))
    b = lease!(ctx, "b")

    accept!(ctx, b, 1, %{
      "kind" => "terminal",
      "terminal_state" => "error",
      "error" => %{"message" => "session already has an active turn"}
    })

    assert ask_status(sid) == "pending"
    assert ask_meta(sid)["cancel_reason"] == nil
    assert StudioChat.get_session(sid).pending_approvals == 1
  end

  # task-fe4832b24ab1c40b: the refused close kept A's ask pending but stopped
  # tracking it, so A's own close, when it came, had nothing to cancel, and the
  # ask stayed a live card for a turn that had ended.
  test "a refused newer send_turn's close, then the asking run's own close, cancels the ask",
       %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("ap-later"))
    b = lease!(ctx, "b")

    accept!(ctx, b, 1, %{
      "kind" => "terminal",
      "terminal_state" => "error",
      "error" => %{"message" => "session already has an active turn"}
    })

    assert ask_status(sid) == "pending"
    accept!(ctx, a, 3, @dead_close)

    assert ask_status(sid) == "canceled"
    assert ask_meta(sid)["cancel_reason"] == "turn_ended"
    assert StudioChat.get_session(sid).pending_approvals == 0
  end

  test "the asking run's own close cancels its pending ask", %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("ap-own"))
    accept!(ctx, a, 3, @dead_close)

    assert ask_status(sid) == "canceled"
    assert ask_meta(sid)["cancel_reason"] == "turn_ended"
    assert StudioChat.get_session(sid).pending_approvals == 0
  end

  # The owner's lease is gone (expired), so its own close will not come: a
  # close from another lease ends the turn and its asks with it.
  test "a close while the asking run's lease is no longer live cancels its ask",
       %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("ap-gone"))
    expire!(a)
    b = lease!(ctx, "b")
    accept!(ctx, b, 1, @no_active_turn)

    assert ask_status(sid) == "canceled"
  end

  # A close projected without a lease names no other run: it is the turn's
  # own end (the managed path), even while the owner's lease is live.
  test "a close projected without a lease cancels the open turn's ask", %{sid: sid} = ctx do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, ask("ap-nolease"))
    project(sid, %{lease_id: nil}, :turn_completed, terminal_state: :completed)

    assert ask_status(sid) == "canceled"
  end

  # ── only the turn's own lease ends it (task-5d1f639852927c4e) ──────────

  # The superseded? race: the older close reaches the Recorder just after the
  # newer turn_started (projected here straight to the Recorder, which is what
  # the race delivers).
  test "an older lease's close projected after the newer turn_started does not end it",
       %{sid: sid} = ctx do
    old = lease!(ctx, "old")
    new = lease!(ctx, "new")
    project(sid, old, :turn_started)
    project(sid, new, :turn_started)
    project(sid, old, :turn_completed, terminal_state: :completed)
    project(sid, old, :error, terminal_state: :failed, error: %{"message" => "gone"})

    assert StudioChat.get_session(sid).status == "working"

    project(sid, new, :text_delta, native: %{"params" => %{"delta" => "Newer."}})
    project(sid, new, :turn_completed, terminal_state: :completed)

    assert replies(sid) == ["Newer."]
    assert StudioChat.get_session(sid).status == "active"
  end

  # The owner is gone (expired, unswept): nothing else will end the turn, so
  # the older close is taken.
  test "an older lease's close ends the turn when the owner's lease has expired",
       %{sid: sid} = ctx do
    old = lease!(ctx, "old")
    new = lease!(ctx, "new")
    project(sid, old, :turn_started)
    project(sid, new, :turn_started)
    expire!(new)
    project(sid, old, :turn_completed, terminal_state: :completed)

    refute StudioChat.get_session(sid).status == "working"
  end

  # P1: lease B fails before its turn_started (provider will not start, cwd
  # not approved, ...), so its first event is its close. B never owned a turn.
  test "P1: a turn whose lease closes before its turn_started ends", %{sid: sid} = ctx do
    finished_turn!(ctx)
    StudioChat.update_status(sid, "working")

    accept!(ctx, lease!(ctx, "b"), 1, @dead_close)

    refute StudioChat.get_session(sid).status == "working",
           "lease B's close was its only event; nothing else will end this turn"
  end

  test "P1, then a Stop: the Stop's answer ends the turn", %{sid: sid} = ctx do
    finished_turn!(ctx)
    StudioChat.update_status(sid, "working")
    accept!(ctx, lease!(ctx, "b"), 1, @dead_close)

    stop = lease!(ctx, "stop", :interrupt)
    Recorder.note_interrupt_requested(sid)
    accept!(ctx, stop, 1, @no_active_turn)

    refute StudioChat.get_session(sid).status == "working"
  end

  # P2: the owner's run is gone, but its lease stays `running`: a host built
  # before #26823 sends no held_leases, so every heartbeat renews it and the
  # sweep never ends it. The host's answer to a Stop is the only close.
  test "P2: a Stop on a dead owner ends the turn at once, with no sweep", %{sid: sid} = ctx do
    old = lease!(ctx, "old")
    accept!(ctx, old, 1, %{"kind" => "turn_started", "turn_id" => "t-old"})
    accept!(ctx, old, 2, %{"kind" => "text_delta", "delta" => "Half"})

    stop = lease!(ctx, "stop", :interrupt)
    Recorder.note_interrupt_requested(sid)
    accept!(ctx, stop, 1, @no_active_turn)

    assert Repo.get!(ExecutionLease, old.lease_id).status in ["leased", "running"]
    refute StudioChat.get_session(sid).status == "working"
  end

  # A managed runtime's events carry no lease: the projection without one is
  # the Recorder path it always was, including a second turn_started.
  test "events projected without a lease keep the turn they were in", %{sid: sid} do
    recorder = Recorder.whereis(sid)

    for {kind, extra} <- [
          {:turn_started, %{}},
          {:text_delta, %{native: %{"params" => %{"delta" => "A."}}}},
          {:turn_started, %{}},
          {:text_delta, %{native: %{"params" => %{"delta" => "B."}}}},
          {:turn_completed, %{terminal_state: :completed}}
        ] do
      event = struct(%Event{provider: "claude", session_id: sid, kind: kind}, extra)
      assert :ok = GenServer.call(recorder, {:project_runtime_event, event, nil})
    end

    assert replies(sid) == ["A.\n\nB."]
  end

  # rev26735 round 2: a pending Stop was ordered against a nil lease, and
  # ChatHosts.lease_inserted_at/1 had no clause for nil, so the Recorder crashed.
  test "a turn_started projected without a lease while a Stop is pending keeps the Recorder",
       %{sid: sid} do
    recorder = Recorder.whereis(sid)
    Recorder.note_interrupt_requested(sid)
    event = %Event{provider: "claude", session_id: sid, kind: :turn_started}

    assert :ok = GenServer.call(recorder, {:project_runtime_event, event, nil})
    assert Process.alive?(recorder)
    assert Recorder.whereis(sid) == recorder
    assert :sys.get_state(recorder).turn_interrupted?, "a Stop no lease can order stays pending"
  end

  # Turn 1 by lease A, from turn_started to its own close.
  defp finished_turn!(ctx) do
    a = lease!(ctx, "a")
    accept!(ctx, a, 1, %{"kind" => "turn_started", "turn_id" => "t-a"})
    accept!(ctx, a, 2, %{"kind" => "text_delta", "delta" => "One."})
    accept!(ctx, a, 3, %{"kind" => "turn_completed", "terminal_state" => "completed"})
    refute StudioChat.get_session(ctx.sid).status == "working"
  end

  defp project(sid, fence, kind, fields \\ []) do
    event = struct(%Event{provider: "claude", session_id: sid, kind: kind}, fields)

    assert :ok =
             GenServer.call(
               Recorder.whereis(sid),
               {:project_runtime_event, event, fence.lease_id}
             )
  end

  defp expire!(fence) do
    past = DateTime.add(DateTime.utc_now(), -600)

    Repo.update_all(from(l in ExecutionLease, where: l.id == ^fence.lease_id),
      set: [expires_at: past]
    )
  end

  defp accept!(%{host: host}, fence, cursor, event) do
    assert {:ok, :accepted} =
             ChatHosts.accept_event(host, %{
               lease_id: fence.lease_id,
               epoch: fence.epoch,
               cursor: cursor,
               idempotency_key: "#{fence.lease_id}:#{fence.epoch}:#{cursor}",
               event: event
             })
  end

  defp lease!(%{host: host, sid: sid, provider: provider}, tag, operation \\ :start) do
    payload =
      if operation == :start,
        do: %{cwd: System.tmp_dir!(), content: "hello #{tag}"},
        else: %{}

    command = %Command{
      operation: operation,
      provider: provider,
      session_id: sid,
      idempotency_key: "owner-#{tag}-#{System.unique_integer([:positive])}",
      payload: payload
    }

    {:ok, fence} = ChatHosts.lease_and_enqueue(host, command, [])
    fence
  end

  # A Stop as Studio sends it: the interrupt lease, the Recorder's note, the ack.
  defp stop!(%{sid: sid} = ctx) do
    stop = lease!(ctx, "stop", :interrupt)
    Recorder.note_interrupt_requested(sid)
    accept!(ctx, stop, 1, %{"kind" => "control_completed", "operation" => "interrupt"})
  end

  defp outcomes(sid) do
    sid
    |> StudioChat.list_messages(:global)
    |> Enum.filter(&(&1.role == "assistant"))
    |> Enum.map(&{&1.source_markdown, (&1.metadata || %{})["turn_outcome"]})
  end

  defp ask(approval_id) do
    %{
      "kind" => "approval_requested",
      "approval_id" => approval_id,
      "tool_name" => "Bash",
      "input" => %{"command" => "ls"},
      "title" => "Run ls"
    }
  end

  defp ask_meta(sid) do
    sid
    |> StudioChat.list_messages(:global)
    |> Enum.find(&(&1.role == "approval"))
    |> Map.fetch!(:metadata)
  end

  defp ask_status(sid), do: ask_meta(sid)["approval_status"]

  defp replies(sid) do
    sid
    |> StudioChat.list_messages(:global)
    |> Enum.filter(&(&1.role == "assistant"))
    |> Enum.map(& &1.source_markdown)
  end

  defp host_session do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "host-owner-#{suffix}", name: "Owner #{suffix}"})

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
    %{host: host, sid: sid, provider: "claude"}
  end

  defp capabilities do
    %{
      "protocol_version" => 1,
      "providers" => %{
        "claude" => %{"installed" => true, "auth_ready" => true},
        "codex" => %{"installed" => true, "auth_ready" => true}
      }
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
