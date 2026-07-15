defmodule Barkpark.ChatHosts.LifecycleTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.{ExecutionLease, RegisteredHost}
  alias Barkpark.StudioChat.Session
  alias Barkpark.StudioChat.Runtime.Command
  alias Barkpark.Tenancy

  test "enrollment, rotation, fencing, tenant opacity, and revocation fail closed" do
    suffix = System.unique_integer([:positive])
    {:ok, ws_a} = Tenancy.create_workspace(%{slug: "chat-host-a-#{suffix}", name: "A"})
    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "chat-host-b-#{suffix}", name: "B"})
    root = System.tmp_dir!()

    assert {:ok, issued} =
             ChatHosts.issue_enrollment(ws_a.id, %{
               name: "laptop",
               approved_roots: [root],
               capabilities: readiness_capabilities()
             })

    stored = Repo.get!(RegisteredHost, issued.host.id)
    refute stored.enrollment_hash == issued.enrollment_token
    assert is_nil(stored.credential_hash)

    assert {:ok, enrolled} =
             ChatHosts.enroll(issued.enrollment_token, %{
               approved_roots: ["/host-cannot-expand-server-roots"],
               capabilities: readiness_capabilities()
             })

    assert enrolled.host.approved_roots == [root]

    assert {:error, :invalid_enrollment} = ChatHosts.enroll(issued.enrollment_token)
    assert {:ok, authenticated} = ChatHosts.authenticate(enrolled.credential)
    assert authenticated.id == issued.host.id
    assert {:error, :host_not_found} = ChatHosts.resolve(ws_b.id, authenticated.id)
    assert is_nil(ChatHosts.get_host(ws_b.id, authenticated.id))

    assert {:ok, rotated} = ChatHosts.rotate_credential(authenticated)
    assert {:error, :invalid_credential} = ChatHosts.authenticate(enrolled.credential)
    assert {:ok, authenticated} = ChatHosts.authenticate(rotated.credential)

    session_id = Ecto.UUID.generate()

    assert {:ok, _session} =
             %Session{}
             |> Session.create_changeset(%{
               id: session_id,
               owner_workspace_id: ws_a.id,
               provider: "claude",
               execution_target: "registered_host",
               execution_host_id: authenticated.id
             })
             |> Repo.insert()

    command = %Command{
      operation: :start,
      provider: "claude",
      session_id: session_id,
      idempotency_key: "command-1",
      payload: %{cwd: root, content: "hello"}
    }

    assert {:ok, fence} = ChatHosts.lease_and_enqueue(authenticated, command, [])
    assert [%{lease_id: lease_id, epoch: epoch}] = ChatHosts.next_commands(authenticated)
    assert lease_id == fence.lease_id
    assert epoch == fence.epoch

    event = %{
      lease_id: lease_id,
      epoch: epoch,
      cursor: 1,
      idempotency_key: "event-1",
      event: %{
        "kind" => "session_started",
        "provider_session_id" => "provider-thread-1"
      }
    }

    parent = self()

    recorder =
      spawn_link(fn ->
        Registry.register(Barkpark.StudioChat.RecorderRegistry, session_id, :test_recorder)
        send(parent, :recorder_ready)
        fake_recorder(parent)
      end)

    assert_receive :recorder_ready

    assert {:error, :stale_fence} =
             ChatHosts.accept_event(authenticated, %{event | epoch: epoch + 1})

    assert {:ok, :accepted} = ChatHosts.accept_event(authenticated, event)

    assert_receive {:studio_chat_runtime_event,
                    %Barkpark.StudioChat.Runtime.Event{
                      provider: "claude",
                      session_id: ^session_id,
                      sequence: 1,
                      idempotency_key: "event-1",
                      provider_session_id: "provider-thread-1",
                      kind: :session_started
                    }}

    assert {:ok, :duplicate} = ChatHosts.accept_event(authenticated, event)

    Process.unlink(recorder)
    Process.exit(recorder, :shutdown)

    gap_event = %{
      event
      | cursor: 2,
        idempotency_key: "event-2",
        event: %{"kind" => "text_delta", "delta" => "survives recorder gap"}
    }

    assert {:ok, :accepted} = ChatHosts.accept_event(authenticated, gap_event)

    assert [{event_id, %Barkpark.StudioChat.Runtime.Event{kind: :text_delta} = replayed}] =
             ChatHosts.replay_unprojected(session_id)

    assert get_in(replayed.native, ["params", "delta"]) == "survives recorder gap"
    assert :ok = ChatHosts.mark_projected(event_id)
    assert [] = ChatHosts.replay_unprojected(session_id)

    assert {:error, :cursor_conflict} =
             ChatHosts.accept_event(authenticated, %{event | idempotency_key: "conflict"})

    assert {:error, :cursor_gap} =
             ChatHosts.accept_event(authenticated, %{
               event
               | cursor: 4,
                 idempotency_key: "event-3"
             })

    assert {:ok, revoked_host} = ChatHosts.revoke(ws_a.id, authenticated.id)
    assert revoked_host.revoked
    assert {:error, :invalid_credential} = ChatHosts.authenticate(rotated.credential)
    assert Repo.get!(ExecutionLease, lease_id).status == "cancelled"

    assert {:error, :stale_fence} =
             ChatHosts.accept_event(authenticated, %{
               event
               | cursor: 2,
                 idempotency_key: "event-2"
             })
  end

  test "expired enrollment is indistinguishable from an invalid token" do
    suffix = System.unique_integer([:positive])

    {:ok, workspace} =
      Tenancy.create_workspace(%{slug: "chat-host-exp-#{suffix}", name: "Expired"})

    assert {:ok, issued} = ChatHosts.issue_enrollment(workspace.id, %{name: "expired"})

    RegisteredHost
    |> Repo.get!(issued.host.id)
    |> Ecto.Changeset.change(enrollment_expires_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    assert {:error, :expired_enrollment} = ChatHosts.enroll(issued.enrollment_token)
  end

  defp readiness_capabilities do
    %{
      "protocol_version" => 1,
      "providers" => %{
        "claude" => %{"installed" => true, "auth_ready" => true}
      }
    }
  end

  defp fake_recorder(parent) do
    receive do
      {:"$gen_call", from, {:project_runtime_event, event}} ->
        send(parent, {:studio_chat_runtime_event, event})
        GenServer.reply(from, :ok)
        fake_recorder(parent)
    end
  end
end
