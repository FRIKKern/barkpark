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
  alias Barkpark.StudioChat.Runtime.{Command, Event}
  alias Barkpark.StudioChat.Session
  alias Barkpark.Tenancy

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

  test "a live lease is never swept" do
    %{session_id: session_id, lease_id: lease_id} = running_turn()

    assert 0 = ChatHosts.end_expired_turns(DateTime.utc_now())
    assert StudioChat.get_session(session_id).status == "working"
    assert Repo.get!(ExecutionLease, lease_id).status == "running"
  end

  defp running_turn do
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

    command = %Command{
      operation: :start,
      provider: "claude",
      session_id: session_id,
      idempotency_key: "command-#{suffix}",
      payload: %{cwd: root, content: "hello"}
    }

    {:ok, %{lease_id: lease_id, epoch: epoch}} = ChatHosts.lease_and_enqueue(host, command, [])

    {:ok, :accepted} =
      ChatHosts.accept_event(host, %{
        lease_id: lease_id,
        epoch: epoch,
        cursor: 1,
        idempotency_key: "started-1",
        event: %{"kind" => "turn_started", "turn_id" => "turn-1"}
      })

    {:ok, _} = StudioChat.update_status(session_id, "working")

    %{host: host, session_id: session_id, lease_id: lease_id, epoch: epoch}
  end

  defp expire!(lease_id, seconds_from_now) do
    {1, _} =
      from(l in ExecutionLease, where: l.id == ^lease_id)
      |> Repo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), seconds_from_now)])
  end
end
