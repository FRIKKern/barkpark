defmodule Barkpark.ChatHosts.SendTurnAttachmentRefsTest do
  @moduledoc """
  A turn sent to a registered host leases a command that names its images by
  reference and never carries their bytes (Paper chat-host-attachments-plan,
  task-7072ee861bfa3fdf). The bytes stay in the chat-owned store; the host
  fetches them through its own lease.

  A host only receives references when its `providers.claude.attachments`
  lists every referenced type; otherwise the turn is refused with
  `{:host_cannot_receive_attachments, provider}` and nothing is leased
  (task-2b5de78f8f8d1c1a), so an old host binary cannot drop the image without
  a word.

  The command is read back the way the host reads it, through
  `ChatHosts.next_commands/1`, so the assertion covers what actually rides
  `ChatHosts.Transport` and the poll response.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.ExecutionLease
  alias Barkpark.StudioChat.{Attachments, Runtime, Session}
  alias Barkpark.Tenancy

  # A sniffable PNG: the magic prefix plus enough tail to be distinct.
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <> :binary.copy(<<7, 1, 3>>, 40)

  @images ~w(image/png image/jpeg image/gif image/webp)

  setup do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "turn-refs-#{suffix}", name: "Refs"})

    # The host advertises the four image types (T2): the server refuses to lease
    # attachments to a host that does not.
    %{host: host, ref: ref, session_id: session_id} =
      open_host_session(ws, "mac", Map.put(ready_provider(), "attachments", @images))

    # Stored the way the Studio composer stores it, so the reference id can be
    # checked against the store's own content address.
    {:ok, pointer} = Attachments.put(session_id, @png)

    %{ws: ws, host: host, ref: ref, pointer: pointer}
  end

  test "a send_turn with an image block leases a command with a reference and no base64 data",
       %{host: host, ref: ref, pointer: pointer} do
    data = Base.encode64(@png)

    assert :ok = Runtime.send_turn("claude", ref, studio_blocks("what is in this picture?", data))

    assert [%{command: command}] = ChatHosts.next_commands(host)
    payload = command.payload

    assert payload.content == "what is in this picture?"

    assert payload.attachments == [
             %{id: pointer.sha256, media_type: "image/png", byte_size: byte_size(@png)}
           ]

    wire = Jason.encode!(command)
    refute wire =~ data
    refute wire =~ "base64"
  end

  test "a leased send_turn attachment reference has exactly id, media_type and byte_size",
       %{host: host, ref: ref} do
    assert :ok = Runtime.send_turn("claude", ref, studio_blocks("", Base.encode64(@png)))

    assert [%{command: %{payload: payload}}] = ChatHosts.next_commands(host)
    assert payload.content == ""
    assert [reference] = payload.attachments
    assert reference |> Map.keys() |> Enum.sort() == [:byte_size, :id, :media_type]
  end

  test "a text-only send_turn leases the text unchanged and names no attachments",
       %{host: host, ref: ref} do
    assert :ok = Runtime.send_turn("claude", ref, "hello")

    assert [%{command: %{payload: payload}}] = ChatHosts.next_commands(host)
    assert payload.content == "hello"
    refute Map.has_key?(payload, :attachments)
  end

  test "an image block whose data is not base64 is refused and leases nothing",
       %{host: host, ref: ref} do
    assert {:error, :invalid_turn_content} =
             Runtime.send_turn("claude", ref, studio_blocks("look", "not base64 !!"))

    assert ChatHosts.next_commands(host) == []
  end

  describe "a host that does not advertise attachments (T2)" do
    test "a send with attachments to a host that does not advertise them is refused and leases nothing",
         %{ws: ws} do
      %{host: host, ref: ref, session_id: sid} =
        open_host_session(ws, "old-mac", ready_provider())

      assert {:error, {:host_cannot_receive_attachments, "claude"}} =
               Runtime.send_turn("claude", ref, studio_blocks("look", Base.encode64(@png)))

      assert ChatHosts.next_commands(host) == []
      assert Repo.aggregate(from(l in ExecutionLease, where: l.session_id == ^sid), :count) == 0
    end

    test "a host that lists other image types is refused a type it does not list", %{ws: ws} do
      %{host: host, ref: ref} =
        open_host_session(
          ws,
          "jpeg-mac",
          Map.put(ready_provider(), "attachments", ["image/jpeg"])
        )

      assert {:error, {:host_cannot_receive_attachments, "claude"}} =
               Runtime.send_turn("claude", ref, studio_blocks("look", Base.encode64(@png)))

      assert ChatHosts.next_commands(host) == []
    end

    test "a text-only turn to that host is leased as before", %{ws: ws} do
      %{host: host, ref: ref} = open_host_session(ws, "old-mac", ready_provider())

      assert :ok = Runtime.send_turn("claude", ref, studio_blocks("just words", nil))

      assert [%{command: %{payload: payload}}] = ChatHosts.next_commands(host)
      assert payload.content == "just words"
      refute Map.has_key?(payload, :attachments)
    end
  end

  defp open_host_session(ws, name, claude_metadata) do
    root = System.tmp_dir!()
    caps = %{"protocol_version" => 1, "providers" => %{"claude" => claude_metadata}}

    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{name: name, approved_roots: [root], capabilities: caps})

    {:ok, enrolled} = ChatHosts.enroll(issued.enrollment_token, %{capabilities: caps})
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

    {:ok, ref} =
      Runtime.open("claude", %{
        execution_target: "registered_host",
        session_id: session_id,
        workspace_id: ws.id,
        execution_host_id: host.id
      })

    %{host: host, ref: ref, session_id: session_id}
  end

  # The block list `ChatLive.build_user_content/2` hands `Runtime.send_turn/3`.
  defp studio_blocks(text, nil), do: [%{"type" => "text", "text" => text}]

  defp studio_blocks(text, data) do
    text_blocks = if text == "", do: [], else: [%{"type" => "text", "text" => text}]

    text_blocks ++
      [
        %{
          "type" => "image",
          "source" => %{"type" => "base64", "media_type" => "image/png", "data" => data}
        }
      ]
  end

  defp ready_provider do
    %{
      "installed" => true,
      "auth_ready" => true,
      "operations" => ~w(send_turn steer interrupt answer_approval close),
      "task_hands" => true
    }
  end
end
