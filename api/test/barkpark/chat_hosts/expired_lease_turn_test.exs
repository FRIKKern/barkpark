defmodule Barkpark.ChatHosts.ExpiredLeaseTurnTest do
  @moduledoc """
  A turn whose host lease expired is ended by the server
  (task-1e98bcc0f1c64067). The host marks a close the server refuses as
  `lease_expired` done and never sends it again (PR #26064), and a host that
  dies for good sends nothing at all, so the server is the only side that can
  take the session out of `working`.
  """
  use Barkpark.DataCase, async: false

  # Plugins-off: the studio_chat capability owns the chat supervisors and registries
  @moduletag :requires_plugins

  import Ecto.Query

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.ExecutionLease
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.StudioChat.Runtime.{Command, Event}
  alias Barkpark.StudioChat.Session
  alias Barkpark.Tenancy

  @floor_key :chat_host_expired_turn_floor

  # The shipped floor is a fixed instant at merge time; every lease these tests
  # make is newer than a floor a day back, unless a test moves the floor.
  setup do
    previous = Application.fetch_env(:barkpark, @floor_key)
    put_floor!(-86_400)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:barkpark, @floor_key, value)
        :error -> Application.delete_env(:barkpark, @floor_key)
      end
    end)

    :ok
  end

  test "a close on a lease that expired before the floor leaves lease, events and session as they were" do
    %{host: host, session_id: session_id, lease_id: lease_id, epoch: epoch} = running_turn()
    created!(lease_id, -7200)
    put_floor!(-600)
    expire!(lease_id, -3600)
    before = rows(session_id, lease_id)

    assert {:error, :lease_expired} =
             ChatHosts.accept_event(host, %{
               lease_id: lease_id,
               epoch: epoch,
               cursor: 2,
               idempotency_key: "close-1",
               event: %{"kind" => "terminal", "terminal_state" => "failed"}
             })

    assert rows(session_id, lease_id) == before
  end

  test "a lease created before the floor and renewed past it by a heartbeat is left as it was" do
    # A heartbeat moves expires_at on every live lease, so a lease that existed
    # before deploy can carry an expiry past the floor. The floor is on when
    # the lease was created, which nothing ever moves.
    %{host: host, session_id: session_id, lease_id: lease_id, epoch: epoch} = running_turn()
    created!(lease_id, -3600)
    put_floor!(-600)
    assert {:ok, _} = ChatHosts.heartbeat(host, %{})
    expire!(lease_id, -200)
    before = rows(session_id, lease_id)

    assert 0 = ChatHosts.end_expired_turns(DateTime.utc_now())

    assert {:error, :lease_expired} =
             ChatHosts.accept_event(host, %{
               lease_id: lease_id,
               epoch: epoch,
               cursor: 2,
               idempotency_key: "close-1",
               event: %{"kind" => "terminal", "terminal_state" => "failed"}
             })

    assert rows(session_id, lease_id) == before
  end

  test "the sweep ends a turn that expired 800 s ago, after the floor" do
    %{session_id: session_id, lease_id: lease_id} = running_turn()
    expire!(lease_id, -800)

    assert 1 = ChatHosts.end_expired_turns(DateTime.utc_now())
    assert StudioChat.get_session(session_id).status == "exited"
  end

  test "a close refused as lease_expired ends the turn: the session leaves working" do
    %{host: host, session_id: session_id, lease_id: lease_id, epoch: epoch} = running_turn()

    expire!(lease_id, -1)

    close = %{
      lease_id: lease_id,
      epoch: epoch,
      cursor: 2,
      idempotency_key: "close-1",
      event: %{"kind" => "terminal", "terminal_state" => "failed", "error" => %{"message" => "x"}}
    }

    # The refusal itself stays: the fence answers 409 to a write on an expired lease.
    assert {:error, :lease_expired} = ChatHosts.accept_event(host, close)

    assert StudioChat.get_session(session_id).status == "exited"
    assert Repo.get!(ExecutionLease, lease_id).status == "completed"
    assert [] = ChatHosts.next_commands(host)

    # The turn closes for the recorder too: a terminal error waits for replay.
    assert [_turn_started, {_id, %Event{kind: :error, sequence: 2}}] =
             ChatHosts.replay_unprojected(session_id)

    # A heartbeat no longer brings the ended lease back to life.
    assert {:ok, _} = ChatHosts.heartbeat(host, %{})
    assert is_nil(ChatHosts.live_report_fence(session_id))

    # A second refused close does not end the turn twice.
    assert {:error, :lease_expired} =
             ChatHosts.accept_event(host, %{close | idempotency_key: "close-2"})

    assert length(ChatHosts.replay_unprojected(session_id)) == 2
  end

  test "a non-terminal event refused as lease_expired leaves the turn to its close" do
    %{host: host, session_id: session_id, lease_id: lease_id, epoch: epoch} = running_turn()

    expire!(lease_id, -1)

    delta = %{
      lease_id: lease_id,
      epoch: epoch,
      cursor: 2,
      idempotency_key: "delta-1",
      event: %{"kind" => "text_delta", "delta" => "late"}
    }

    assert {:error, :lease_expired} = ChatHosts.accept_event(host, delta)
    assert StudioChat.get_session(session_id).status == "working"
    assert Repo.get!(ExecutionLease, lease_id).status == "running"
  end

  test "the sweep ends the turn of a host that went silent for good, and only after the grace" do
    %{session_id: session_id, lease_id: lease_id} = running_turn()
    now = DateTime.utc_now()

    # Expired, but inside the grace: a host back from a short gap keeps its turn.
    expire!(lease_id, -30)
    assert 0 = ChatHosts.end_expired_turns(now)
    assert StudioChat.get_session(session_id).status == "working"

    expire!(lease_id, -120)
    assert 1 = ChatHosts.end_expired_turns(now)
    assert StudioChat.get_session(session_id).status == "exited"
    assert Repo.get!(ExecutionLease, lease_id).status == "completed"

    # Idempotent: a second sweep (the other blue/green slot) finds nothing.
    assert 0 = ChatHosts.end_expired_turns(now)
  end

  test "the agent-state sweeper runs the expired-turn sweep" do
    %{session_id: session_id, lease_id: lease_id} = running_turn()
    expire!(lease_id, -120)

    Barkpark.StudioChat.AgentStateSweeper.sweep()

    assert StudioChat.get_session(session_id).status == "exited"
  end

  test "ending a turn never flips a session that is not working" do
    %{host: host, session_id: session_id, lease_id: lease_id, epoch: epoch} = running_turn()
    {:ok, _} = StudioChat.update_status(session_id, "active")
    expire!(lease_id, -1)

    assert {:error, :lease_expired} =
             ChatHosts.accept_event(host, %{
               lease_id: lease_id,
               epoch: epoch,
               cursor: 2,
               idempotency_key: "close-1",
               event: %{"kind" => "terminal", "terminal_state" => "failed"}
             })

    assert StudioChat.get_session(session_id).status == "active"
    # No recorder replay either: it would mark the session exited.
    assert length(ChatHosts.replay_unprojected(session_id)) == 1
  end

  test "the sweep leaves a lease on a session that is not working exactly as it was" do
    %{session_id: session_id, lease_id: lease_id} = running_turn()
    {:ok, _} = StudioChat.update_status(session_id, "active")
    expire!(lease_id, -120)
    before = Repo.get!(ExecutionLease, lease_id)

    assert 0 = ChatHosts.end_expired_turns(DateTime.utc_now())

    assert Repo.get!(ExecutionLease, lease_id) == before
    assert StudioChat.get_session(session_id).status == "active"
    assert length(ChatHosts.replay_unprojected(session_id)) == 1
  end

  test "the sweep leaves a lease that expired before the floor, and its session, exactly as they were" do
    # Rows already stuck before this code ran are not repaired by a deploy.
    %{session_id: session_id, lease_id: lease_id} = running_turn()
    created!(lease_id, -7200)
    put_floor!(-600)
    expire!(lease_id, -3600)
    before = rows(session_id, lease_id)

    assert 0 = ChatHosts.end_expired_turns(DateTime.utc_now())

    assert rows(session_id, lease_id) == before
  end

  # task-d8685be32b21e31b: a Runtime.Event carries no lease id, so a recorder
  # that gets the old lease's close cannot tell it from the newer turn's and
  # would end the newer turn and mark the session exited.
  test "an older lease's close refused as lease_expired leaves the newer live turn working, with a recorder running" do
    %{host: host, session_id: session_id} = host_session()
    recorder = start_recorder!(session_id)
    old = leased_turn(host, session_id, "old")
    new = leased_turn(host, session_id, "new")
    # Precondition: the recorder took the newer turn_started.
    assert StudioChat.get_session(session_id).status == "working"

    expire!(old.lease_id, -1)

    assert {:error, :lease_expired} =
             ChatHosts.accept_event(host, %{
               lease_id: old.lease_id,
               epoch: old.epoch,
               cursor: 2,
               idempotency_key: "close-old",
               event: %{"kind" => "terminal", "terminal_state" => "failed"}
             })

    assert Repo.get!(ExecutionLease, old.lease_id).status == "completed"
    assert ChatHosts.live_report_fence(session_id).id == new.lease_id
    assert Process.alive?(recorder)
    assert StudioChat.get_session(session_id).status == "working"
    # Not left for replay either: a recorder replaying it would do the same.
    assert ChatHosts.replay_unprojected(session_id) == []
  end

  test "the sweep ends an older silent lease and leaves the newer live turn working, with a recorder running" do
    %{host: host, session_id: session_id} = host_session()
    start_recorder!(session_id)
    old = leased_turn(host, session_id, "old")
    _new = leased_turn(host, session_id, "new")
    assert StudioChat.get_session(session_id).status == "working"

    expire!(old.lease_id, -120)

    assert 1 = ChatHosts.end_expired_turns(DateTime.utc_now())
    assert Repo.get!(ExecutionLease, old.lease_id).status == "completed"
    assert StudioChat.get_session(session_id).status == "working"
  end

  test "a live lease is never swept" do
    %{session_id: session_id, lease_id: lease_id} = running_turn()

    assert 0 = ChatHosts.end_expired_turns(DateTime.utc_now())
    assert StudioChat.get_session(session_id).status == "working"
    assert Repo.get!(ExecutionLease, lease_id).status == "running"
  end

  defp running_turn do
    %{host: host, session_id: session_id} = host_session()
    %{lease_id: lease_id, epoch: epoch} = leased_turn(host, session_id, "1")
    {:ok, _} = StudioChat.update_status(session_id, "working")

    %{host: host, session_id: session_id, lease_id: lease_id, epoch: epoch}
  end

  defp host_session do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "chat-host-exp-turn-#{suffix}", name: "W"})
    root = System.tmp_dir!()

    {:ok, issued} = ChatHosts.issue_enrollment(ws.id, %{name: "laptop", approved_roots: [root]})
    {:ok, enrolled} = ChatHosts.enroll(issued.enrollment_token)
    {:ok, host} = ChatHosts.authenticate(enrolled.credential)

    session_id = Ecto.UUID.generate()

    {:ok, _} =
      %Session{}
      |> Session.create_changeset(%{
        id: session_id,
        owner_workspace_id: ws.id,
        provider: "claude",
        execution_target: "registered_host",
        execution_host_id: host.id
      })
      |> Repo.insert()

    %{host: host, session_id: session_id}
  end

  # One leased command on the session whose turn has started (cursor 1).
  defp leased_turn(host, session_id, tag) do
    command = %Command{
      operation: :start,
      provider: "claude",
      session_id: session_id,
      idempotency_key: "command-#{tag}-#{System.unique_integer([:positive])}",
      payload: %{cwd: System.tmp_dir!(), content: "hello"}
    }

    {:ok, %{lease_id: lease_id, epoch: epoch}} = ChatHosts.lease_and_enqueue(host, command, [])

    {:ok, :accepted} =
      ChatHosts.accept_event(host, %{
        lease_id: lease_id,
        epoch: epoch,
        cursor: 1,
        idempotency_key: "started-#{tag}",
        event: %{"kind" => "turn_started", "turn_id" => "turn-#{tag}"}
      })

    %{lease_id: lease_id, epoch: epoch}
  end

  # A live Recorder for the session. It only needs SOME runtime to start; `cat`
  # runs no CLI. Events reach it through the host ingress.
  defp start_recorder!(session_id) do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    {:ok, recorder} = Recorder.ensure(%{session_id: session_id, mode: "plan", resume: false})

    on_exit(fn ->
      if Process.alive?(recorder),
        do: DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, recorder)

      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    recorder
  end

  defp put_floor!(seconds_from_now),
    do:
      Application.put_env(
        :barkpark,
        @floor_key,
        DateTime.add(DateTime.utc_now(), seconds_from_now)
      )

  defp rows(session_id, lease_id) do
    events =
      from(e in Barkpark.ChatHosts.ExecutionEvent,
        where: e.lease_id == ^lease_id,
        order_by: e.cursor
      )
      |> Repo.all()

    {Repo.get!(ExecutionLease, lease_id), events, Repo.get!(Session, session_id)}
  end

  defp created!(lease_id, seconds_from_now) do
    {1, _} =
      from(l in ExecutionLease, where: l.id == ^lease_id)
      |> Repo.update_all(set: [inserted_at: DateTime.add(DateTime.utc_now(), seconds_from_now)])
  end

  defp expire!(lease_id, seconds_from_now) do
    {1, _} =
      from(l in ExecutionLease, where: l.id == ^lease_id)
      |> Repo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), seconds_from_now)])
  end
end
