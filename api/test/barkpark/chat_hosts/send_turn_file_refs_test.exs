defmodule Barkpark.ChatHosts.SendTurnFileRefsTest do
  @moduledoc """
  A turn with a file, sent to a registered host, leases a command that names
  the file by reference: `{id, media_type, byte_size, name}`, and never its
  bytes (`/papers/chat-host-file-attachments-plan`, T3). A host is leased the
  reference only when its `providers.claude.attachments` lists the file's
  type; otherwise the turn is refused by name and nothing is leased.

  The command is read back the way the host reads it, through
  `ChatHosts.next_commands/1`.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.{ExecutionLease, RegisteredHost}
  alias Barkpark.StudioChat.{Runtime, Session}
  alias Barkpark.Tenancy

  @csv "name,city\nÅse,Tromsø\n"
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <> :binary.copy(<<7, 1, 3>>, 40)

  @images ~w(image/png image/jpeg image/gif image/webp)
  @files ~w(text/plain application/pdf)

  setup do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "turn-file-refs-#{suffix}", name: "Files"})
    %{ws: ws}
  end

  test "a send_turn with a text document block leases a reference with id, media_type, byte_size and name and no base64 data",
       %{ws: ws} do
    %{host: host, ref: ref} = open_host_session(ws, "files-mac", @images ++ @files)
    data = Base.encode64(@csv)

    assert :ok =
             Runtime.send_turn("claude", ref, [
               text("read this"),
               document("text/plain", data, "notes.csv")
             ])

    assert [%{command: command}] = ChatHosts.next_commands(host)
    payload = command.payload

    assert payload.content == "read this"

    assert payload.attachments == [
             %{
               id: :sha256 |> :crypto.hash(@csv) |> Base.encode16(case: :lower),
               media_type: "text/plain",
               byte_size: byte_size(@csv),
               name: "notes.csv"
             }
           ]

    wire = Jason.encode!(command)
    refute wire =~ data
    refute wire =~ "base64"
  end

  test "an image beside a file keeps exactly id, media_type and byte_size", %{ws: ws} do
    %{host: host, ref: ref} = open_host_session(ws, "mixed-mac", @images ++ @files)

    assert :ok =
             Runtime.send_turn("claude", ref, [
               image("image/png", Base.encode64(@png)),
               document("application/pdf", Base.encode64("%PDF-1.7\n"), "report.pdf")
             ])

    assert [%{command: %{payload: payload}}] = ChatHosts.next_commands(host)
    assert [image_ref, file_ref] = payload.attachments
    assert image_ref |> Map.keys() |> Enum.sort() == [:byte_size, :id, :media_type]
    assert file_ref |> Map.keys() |> Enum.sort() == [:byte_size, :id, :media_type, :name]
    assert file_ref.media_type == "application/pdf"
  end

  test "a host listing only images is refused a file by name and leases nothing", %{ws: ws} do
    %{host: host, ref: ref, session_id: sid} = open_host_session(ws, "images-mac", @images)

    assert {:error, {:host_cannot_receive_attachments, "claude"}} =
             Runtime.send_turn("claude", ref, [
               text("read this"),
               document("text/plain", Base.encode64(@csv), "notes.csv")
             ])

    assert ChatHosts.next_commands(host) == []
    assert Repo.aggregate(from(l in ExecutionLease, where: l.session_id == ^sid), :count) == 0
  end

  test "codex on a host that lists files for claude is refused a file and leases nothing",
       %{ws: ws} do
    %{host: host, ref: ref, session_id: sid} =
      open_host_session(ws, "codex-mac", @images ++ @files, "codex")

    assert {:error, {:host_cannot_receive_attachments, "codex"}} =
             Runtime.send_turn("codex", ref, [
               text("read this"),
               document("text/plain", Base.encode64(@csv), "notes.csv")
             ])

    assert ChatHosts.next_commands(host) == []
    assert Repo.aggregate(from(l in ExecutionLease, where: l.session_id == ^sid), :count) == 0
  end

  test "codex is refused a file even when the host lists file types under codex",
       %{ws: ws} do
    %{host: host, ref: ref, session_id: sid} =
      open_host_session(ws, "codex-files-mac", @images ++ @files, "codex", @images ++ @files)

    assert {:error, {:host_cannot_receive_attachments, "codex"}} =
             Runtime.send_turn("codex", ref, [
               text("read this"),
               document("text/plain", Base.encode64(@csv), "notes.csv")
             ])

    assert ChatHosts.next_commands(host) == []
    assert Repo.aggregate(from(l in ExecutionLease, where: l.session_id == ^sid), :count) == 0
  end

  test "a document block that is not a well-formed named file is refused and leases nothing",
       %{ws: ws} do
    %{host: host, ref: ref} = open_host_session(ws, "strict-mac", @images ++ @files)
    data = Base.encode64(@csv)

    bad_blocks = [
      {"no title", Map.delete(document("text/plain", data, "x"), "title")},
      {"a title that is not a string", document("text/plain", data, 7)},
      {"an empty title", document("text/plain", data, "")},
      {"a newline in the title", document("text/plain", data, "notes\n.csv")},
      {"a slash in the title", document("text/plain", data, "../notes.csv")},
      {"a backslash in the title", document("text/plain", data, "a\\b.csv")},
      {"a right-to-left override in the title",
       document("text/plain", data, "notes" <> <<0x202E::utf8>> <> "vsc.exe")},
      {"a title of ..", document("text/plain", data, "..")},
      {"a title over 255 bytes", document("text/plain", data, String.duplicate("a", 256))},
      {"an image type in a document block", document("image/png", Base.encode64(@png), "a.png")},
      {"a type outside the store's set", document("application/zip", data, "a.zip")},
      {"data that is not base64", document("text/plain", "not base64 !!", "notes.csv")}
    ]

    for {label, block} <- bad_blocks do
      assert {:error, :invalid_turn_content} == Runtime.send_turn("claude", ref, [block]),
             "#{label} must refuse the turn"
    end

    # A file type in an image block is refused too: each block keeps its own types.
    assert {:error, :invalid_turn_content} ==
             Runtime.send_turn("claude", ref, [image("text/plain", data)])

    assert ChatHosts.next_commands(host) == []
  end

  # The host is enrolled with the image list (which every release admits) and
  # its file types are then written past the heartbeat changeset, so this file
  # tests the lease alone; registered_host_readiness_test.exs tests that a real
  # heartbeat may carry the file types.
  defp open_host_session(ws, name, attachments, provider \\ "claude", codex_attachments \\ nil) do
    root = System.tmp_dir!()
    caps = caps(Enum.filter(attachments, &(&1 in @images)))

    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{name: name, approved_roots: [root], capabilities: caps})

    {:ok, enrolled} = ChatHosts.enroll(issued.enrollment_token, %{capabilities: caps})
    {:ok, host} = ChatHosts.authenticate(enrolled.credential)

    {1, _} =
      Repo.update_all(from(h in RegisteredHost, where: h.id == ^host.id),
        set: [capabilities: caps(attachments, codex_attachments)]
      )

    {:ok, host} = ChatHosts.authenticate(enrolled.credential)
    session_id = Ecto.UUID.generate()

    {:ok, _} =
      %Session{}
      |> Session.create_changeset(%{
        id: session_id,
        owner_workspace_id: ws.id,
        provider: provider,
        execution_target: "registered_host",
        execution_host_id: host.id
      })
      |> Repo.insert()

    {:ok, ref} =
      Runtime.open(provider, %{
        execution_target: "registered_host",
        session_id: session_id,
        workspace_id: ws.id,
        execution_host_id: host.id
      })

    %{host: host, ref: ref, session_id: session_id}
  end

  # Codex on a host takes no attachment of any kind, unless a test lists some
  # under it to show the server refuses a file to codex regardless.
  defp caps(attachments, codex_attachments \\ nil) do
    codex = %{
      "installed" => true,
      "auth_ready" => true,
      "operations" => ~w(send_turn steer interrupt answer_approval close),
      "task_hands" => true
    }

    %{
      "protocol_version" => 1,
      "providers" => %{
        "claude" => %{
          "installed" => true,
          "auth_ready" => true,
          "operations" => ~w(send_turn steer interrupt answer_approval close),
          "task_hands" => true,
          "attachments" => attachments
        },
        "codex" =>
          if(codex_attachments, do: Map.put(codex, "attachments", codex_attachments), else: codex)
      }
    }
  end

  defp text(text), do: %{"type" => "text", "text" => text}

  defp image(media_type, data),
    do: %{
      "type" => "image",
      "source" => %{"type" => "base64", "media_type" => media_type, "data" => data}
    }

  defp document(media_type, data, title),
    do: %{
      "type" => "document",
      "source" => %{"type" => "base64", "media_type" => media_type, "data" => data},
      "title" => title
    }
end
