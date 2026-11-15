defmodule Barkpark.ChatHosts.HandoutCapabilityRecheckTest do
  @moduledoc """
  A send_turn lease is checked again against the host's CURRENT capabilities
  each time `ChatHosts.next_commands/1` would hand it out
  (task-fb73a4f2ed75231f, review of PR #26451, F1).

  The dispatch path checks `BotFolder.admit/3` and `TurnAttachments.admit/3`
  once, when it leases. A heartbeat can then drop the capability: the host
  binary was swapped for an older one while the lease was pending. Before this
  change the lease was still handed out, and an older binary ignores
  `payload.bot_folder` (it runs the bot in the shared root) or drops a file it
  does not take. Now such a lease is ended by the server with the dispatch
  path's own refusal as its reason, the session leaves `working`, and nothing
  is handed out again.

  The host is enrolled and heartbeated with the Go binary's capabilities
  fixtures, and polled the way `GET /v1/chat-host/commands` polls: the host row
  is read fresh, then `next_commands/1`.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.{ExecutionEvent, ExecutionLease, RegisteredHost}
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.{Runtime, Session}
  alias Barkpark.Tenancy

  @fixtures Path.expand("../../support/fixtures", __DIR__)
  # claude advertises bot_folders and the image and file types.
  @capable_fixture Path.join(@fixtures, "chat_host_go_capabilities_bot_folders.json")

  @csv "name,city\nÅse,Tromsø\n"

  setup do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "handout-recheck-#{suffix}", name: "Recheck"})
    %{ws: ws, caps: @capable_fixture |> File.read!() |> Jason.decode!()}
  end

  test "a foldered turn leased before a heartbeat drops bot_folders is ended as host_cannot_use_bot_folder, never handed out",
       %{ws: ws, caps: caps} do
    %{host_id: host_id, ref: ref, session_id: sid} = open_turn(ws, caps, "bot-z")
    assert :ok = Runtime.send_turn("claude", ref, "hi")
    # Precondition: leased while the host advertised bot_folders.
    assert [%{lease_id: lease_id}] = poll(host_id)

    heartbeat!(host_id, update_in(caps, ["providers", "claude"], &Map.delete(&1, "bot_folders")))

    assert poll(host_id) == []
    assert_refused(sid, lease_id, "host_cannot_use_bot_folder")
  end

  test "a file turn leased before a heartbeat drops file types is ended as host_cannot_receive_attachments, never handed out",
       %{ws: ws, caps: caps} do
    %{host_id: host_id, ref: ref, session_id: sid} = open_turn(ws, caps, nil)

    assert :ok =
             Runtime.send_turn("claude", ref, [
               %{"type" => "text", "text" => "read this"},
               %{
                 "type" => "document",
                 "source" => %{
                   "type" => "base64",
                   "media_type" => "text/plain",
                   "data" => Base.encode64(@csv)
                 },
                 "title" => "notes.csv"
               }
             ])

    assert [%{lease_id: lease_id}] = poll(host_id)

    images = ~w(image/png image/jpeg image/gif image/webp)
    heartbeat!(host_id, put_in(caps, ["providers", "claude", "attachments"], images))

    assert poll(host_id) == []
    assert_refused(sid, lease_id, "host_cannot_receive_attachments")
  end

  test "a host whose heartbeat keeps its capabilities is still handed its foldered file turn",
       %{ws: ws, caps: caps} do
    %{host_id: host_id, ref: ref, session_id: sid} = open_turn(ws, caps, "bot-z")

    assert :ok =
             Runtime.send_turn("claude", ref, [
               %{
                 "type" => "document",
                 "source" => %{
                   "type" => "base64",
                   "media_type" => "application/pdf",
                   "data" => Base.encode64("%PDF-1.7\n")
                 },
                 "title" => "report.pdf"
               }
             ])

    heartbeat!(host_id, caps)

    assert [%{lease_id: lease_id, command: %{payload: payload}}] = poll(host_id)
    assert payload.bot_folder == "bot-z"
    assert [%{media_type: "application/pdf"}] = payload.attachments
    # Handed out again on the next poll, as every live lease is.
    assert [%{lease_id: ^lease_id}] = poll(host_id)

    assert Repo.get!(ExecutionLease, lease_id).status == "leased"
    assert StudioChat.get_session(sid).status == "working"
    assert events(lease_id) == []
  end

  defp assert_refused(sid, lease_id, reason) do
    assert Repo.get!(ExecutionLease, lease_id).status == "completed"
    assert StudioChat.get_session(sid).status == "exited"

    assert [
             %ExecutionEvent{
               cursor: 1,
               payload: %{
                 "kind" => "terminal",
                 "terminal_state" => "failed",
                 "origin" => "server",
                 "reason" => ^reason
               }
             }
           ] = events(lease_id)

    # Nothing is leased again: a later poll hands out nothing and ends nothing twice.
    assert poll(host_id_of(lease_id)) == []
    assert length(events(lease_id)) == 1
    assert Repo.aggregate(from(l in ExecutionLease, where: l.session_id == ^sid), :count) == 1
  end

  # A session whose Recorder has a turn open (`working`), with one runtime ref.
  defp open_turn(ws, caps, bot_folder) do
    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{
        name: "recheck-mac",
        approved_roots: [System.tmp_dir!()]
      })

    {:ok, %{credential: credential}} =
      ChatHosts.enroll(issued.enrollment_token, %{"protocol_version" => 1, "capabilities" => caps})

    {:ok, host} = ChatHosts.authenticate(credential)
    {:ok, _} = ChatHosts.heartbeat(host, %{"protocol_version" => 1, "capabilities" => caps})
    session_id = Ecto.UUID.generate()

    {:ok, _} =
      %Session{}
      |> Session.create_changeset(%{
        id: session_id,
        owner_workspace_id: ws.id,
        provider: "claude",
        execution_target: "registered_host",
        execution_host_id: host.id,
        bot_folder: bot_folder
      })
      |> Repo.insert()

    {:ok, ref} =
      Runtime.open("claude", %{
        execution_target: "registered_host",
        session_id: session_id,
        workspace_id: ws.id,
        execution_host_id: host.id,
        bot_folder: bot_folder
      })

    {:ok, _} = StudioChat.update_status(session_id, "working")
    %{host_id: host.id, ref: ref, session_id: session_id}
  end

  defp heartbeat!(host_id, caps) do
    {:ok, _} =
      ChatHosts.heartbeat(Repo.get!(RegisteredHost, host_id), %{
        "protocol_version" => 1,
        "capabilities" => caps
      })
  end

  # What `GET /v1/chat-host/commands` hands the host: the row as authenticated now.
  defp poll(host_id), do: RegisteredHost |> Repo.get!(host_id) |> ChatHosts.next_commands()

  defp host_id_of(lease_id), do: Repo.get!(ExecutionLease, lease_id).host_id

  defp events(lease_id),
    do: Repo.all(from(e in ExecutionEvent, where: e.lease_id == ^lease_id, order_by: e.cursor))
end
