defmodule Barkpark.ChatHosts.HeldLeasesTest do
  @moduledoc """
  A heartbeat that lists the leases the host still holds (task-e8a91dd731695004).

  A heartbeat renewed every live lease of its host, and the expiry sweep ends
  only expired ones, so a lease the host had given up on (its close refused
  for good, or an outage that outlasted its retries) kept its session
  `working` for as long as the host heartbeated. A Go host now sends
  `held_leases`: the leases its process still runs. A `running` lease it
  leaves off is not renewed, so the sweep closes it as it closes a silent
  host's, with its typed close.

  A list can be older than the lease: a heartbeat in flight while the host took
  the lease, or one answered after a newer heartbeat. So a lease that took an
  event within a lease TTL is renewed though the list leaves it off; the host
  gives up on a request after 30 s, so no list it sent is older than that. A
  lease the host has not started (`leased`) is renewed as before, and so is
  every lease of a host that sends no list.
  """
  use Barkpark.DataCase, async: false

  @moduletag :requires_plugins

  import Ecto.Query

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.{ExecutionEvent, ExecutionLease}
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Runtime.Command
  alias Barkpark.StudioChat.Session
  alias Barkpark.Tenancy

  @floor_key :chat_host_expired_turn_floor

  setup do
    previous = Application.fetch_env(:barkpark, @floor_key)
    Application.put_env(:barkpark, @floor_key, DateTime.add(DateTime.utc_now(), -86_400))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:barkpark, @floor_key, value)
        :error -> Application.delete_env(:barkpark, @floor_key)
      end
    end)

    :ok
  end

  test "a running lease the heartbeating host no longer holds is ended by the sweep with its typed close, and the session leaves working" do
    %{host: host, session_id: session_id, lease_id: lease_id} = running_turn()
    quiet!(lease_id, -120)
    expire!(lease_id, -100)

    assert {:ok, _} = ChatHosts.heartbeat(host, %{"held_leases" => []})
    assert expired?(lease_id), "a lease the host no longer holds is not renewed"

    assert 1 = ChatHosts.end_expired_turns(DateTime.utc_now())
    assert StudioChat.get_session(session_id).status == "exited"
    assert Repo.get!(ExecutionLease, lease_id).status == "completed"

    assert %{"kind" => "terminal", "origin" => "server", "reason" => "host_silent"} =
             last_event(lease_id)
  end

  test "a running lease the host lists is renewed" do
    %{host: host, session_id: session_id, lease_id: lease_id} = running_turn()
    quiet!(lease_id, -120)
    expire!(lease_id, -100)

    assert {:ok, _} = ChatHosts.heartbeat(host, %{"held_leases" => [lease_id]})
    refute expired?(lease_id)
    assert 0 = ChatHosts.end_expired_turns(DateTime.utc_now())
    assert StudioChat.get_session(session_id).status == "working"
  end

  test "a host that sends no list has every live lease renewed, as before" do
    %{host: host, lease_id: lease_id} = running_turn()
    quiet!(lease_id, -120)
    expire!(lease_id, -100)

    assert {:ok, _} = ChatHosts.heartbeat(host, %{})
    refute expired?(lease_id)
  end

  test "a list that is not a list of lease ids is no list" do
    %{host: host, lease_id: lease_id} = running_turn()
    quiet!(lease_id, -120)
    expire!(lease_id, -100)

    assert {:ok, _} = ChatHosts.heartbeat(host, %{"held_leases" => "all"})
    refute expired?(lease_id)
  end

  test "a lease that took an event within a lease TTL is renewed though an older list leaves it off" do
    %{host: host, lease_id: lease_id} = running_turn()
    expire!(lease_id, -100)

    assert {:ok, _} = ChatHosts.heartbeat(host, %{"held_leases" => []})
    refute expired?(lease_id), "a list sent before the host took the lease cannot starve it"
  end

  test "a lease the host has not started is renewed though the list leaves it off" do
    %{host: host, session_id: session_id} = host_session()
    %{lease_id: lease_id} = lease!(host, session_id)
    expire!(lease_id, -100)

    assert {:ok, _} = ChatHosts.heartbeat(host, %{"held_leases" => ["not-a-uuid", 7]})
    refute expired?(lease_id)
  end

  defp running_turn do
    %{host: host, session_id: session_id} = host_session()
    %{lease_id: lease_id, epoch: epoch} = lease!(host, session_id)

    {:ok, :accepted} =
      ChatHosts.accept_event(host, %{
        lease_id: lease_id,
        epoch: epoch,
        cursor: 1,
        idempotency_key: "#{lease_id}:#{epoch}:1",
        event: %{"kind" => "turn_started", "turn_id" => "turn-1"}
      })

    {:ok, _} = StudioChat.update_status(session_id, "working")
    %{host: host, session_id: session_id, lease_id: lease_id}
  end

  defp host_session do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "chat-host-held-#{suffix}", name: "W"})
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

  defp lease!(host, session_id) do
    command = %Command{
      operation: :start,
      provider: "claude",
      session_id: session_id,
      idempotency_key: "held-#{System.unique_integer([:positive])}",
      payload: %{cwd: System.tmp_dir!(), content: "hello"}
    }

    {:ok, fence} = ChatHosts.lease_and_enqueue(host, command, [])
    fence
  end

  # Every event the lease took, as if taken seconds_from_now.
  defp quiet!(lease_id, seconds_from_now) do
    from(e in ExecutionEvent, where: e.lease_id == ^lease_id)
    |> Repo.update_all(set: [inserted_at: DateTime.add(DateTime.utc_now(), seconds_from_now)])
  end

  defp expire!(lease_id, seconds_from_now) do
    {1, _} =
      from(l in ExecutionLease, where: l.id == ^lease_id)
      |> Repo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), seconds_from_now)])
  end

  defp expired?(lease_id),
    do:
      DateTime.compare(Repo.get!(ExecutionLease, lease_id).expires_at, DateTime.utc_now()) == :lt

  defp last_event(lease_id) do
    from(e in ExecutionEvent,
      where: e.lease_id == ^lease_id,
      order_by: [desc: e.cursor],
      limit: 1
    )
    |> Repo.one!()
    |> Map.fetch!(:payload)
  end
end
