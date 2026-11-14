defmodule BarkparkWeb.ChatMessageFileAttachmentsTest do
  @moduledoc """
  `POST /v1/chat/sessions/:id/messages` naming a stored text file or PDF
  (`/papers/chat-host-file-attachments-plan`, T4).

  An `attachments` entry is an id string, as before, or `{"id", "name"}`. A
  file needs a name, and the name is refused, never cleaned, when it breaks
  `AttachmentName.valid?/1`. Only a `registered_host` session takes a file: a
  managed claude or codex session would get a document block it may not read.
  The runtime gets a document block titled with the name; the leased host
  command carries `{id, media_type, byte_size, name}`; the user row's pointer
  and its wire reference carry the name.

  Tenancy is the image rule: an id resolves only inside the session the tenant
  oracle returned, so another session's file is the same 400 as an id stored
  nowhere.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.{ExecutionLease, RegisteredHost}
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.Tenancy
  alias BarkparkWeb.ChatUserTurn
  alias BarkparkWeb.Studio.ClaudeChat

  @dataset "production"

  @csv "name,city\nÅse,Tromsø\n"
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  @attachments_fixture Path.expand(
                         "../../support/fixtures/chat_host_go_capabilities_attachments.json",
                         __DIR__
                       )

  # The managed claude runtime, replaced by one that reports what it is sent.
  defmodule CaptureAdapter do
    @moduledoc false
    @behaviour Barkpark.StudioChat.Runtime.Adapter

    def start(_opts), do: {:ok, :capture_runtime}
    def resume(_opts), do: {:ok, :capture_runtime}

    def send_turn(_runtime, content) do
      if pid = Application.get_env(:barkpark, :chat_message_file_attachments_test_pid),
        do: send(pid, {:sent_turn, content})

      :ok
    end

    def steer(_runtime, _command), do: :ok
    def interrupt(_runtime), do: {:ok, nil}
    def answer_approval(_runtime, _id, _decision), do: :ok
    def close(_runtime), do: :ok
    def readiness(_opts), do: %{binary: true, authed?: true}
    def capabilities, do: %{modes: ["plan"], models: [], efforts: []}
  end

  setup do
    prev_chat = Application.get_env(:barkpark, StudioChat)
    prev_claude = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    prev_adapters = Application.get_env(:barkpark, :studio_chat_runtime_adapters)

    dir = Path.join(System.tmp_dir!(), "bp_chat_msg_file_#{System.unique_integer([:positive])}")

    Application.put_env(:barkpark, StudioChat, attachments_dir: dir)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    Application.put_env(
      :barkpark,
      :studio_chat_runtime_adapters,
      Map.put(prev_adapters || %{}, :claude, CaptureAdapter)
    )

    Application.put_env(:barkpark, :chat_message_file_attachments_test_pid, self())

    on_exit(fn ->
      reap_recorders()
      File.rm_rf(dir)
      Application.delete_env(:barkpark, :chat_message_file_attachments_test_pid)
      restore(StudioChat, prev_chat)
      restore(:claude_chat, prev_claude)
      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
      restore(:studio_chat_runtime_adapters, prev_adapters)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "msg-file-#{suffix}", name: "Files #{suffix}"})

    member = "msg-file-member-#{suffix}"
    {:ok, _} = Auth.create_token(member, "msg-file", @dataset, ["read", "write", "admin"], ws.id)

    host_id = enroll_files_host!(ws, "files-host-#{suffix}")

    %{member: member, host_id: host_id, sid: create_host_session!(member, host_id)}
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  # The Go binary's attachments fixture, which lists the two file types in
  # claude's list since T6: the shape a host advertises once it writes files.
  defp enroll_files_host!(ws, name) do
    caps = @attachments_fixture |> File.read!() |> Jason.decode!()

    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{name: name, approved_roots: [System.tmp_dir!()]})

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

  defp upload!(raw, sid, bytes) do
    json_conn(raw)
    |> post("/v1/chat/sessions/#{sid}/attachments", Jason.encode!(%{data: Base.encode64(bytes)}))
    |> json_response(201)
    |> get_in(["attachment", "id"])
  end

  defp send_message(raw, sid, body),
    do: json_conn(raw) |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(body))

  defp send_turns(host_id, sid) do
    RegisteredHost
    |> Repo.get!(host_id)
    |> ChatHosts.next_commands()
    |> Enum.filter(&(&1.command.operation == :send_turn and &1.command.session_id == sid))
  end

  defp refusal(conn),
    do: conn |> json_response(400) |> Map.fetch!("error") |> Map.delete("request_id")

  # Nothing was leased, no lease row exists, and no user row was written.
  defp assert_nothing_dispatched(host_id, sid) do
    assert send_turns(host_id, sid) == []
    assert Repo.aggregate(from(l in ExecutionLease, where: l.session_id == ^sid), :count) == 0
    assert StudioChat.list_messages(sid, :global) == [], "a refused send must not persist a row"
  end

  # The positive control a refusal test ends on: the same caller, the same
  # session and a well-formed named file it really holds are accepted.
  defp assert_own_file_accepted(raw, host_id, sid, id) do
    send_message(raw, sid, %{content: "x", attachments: [%{id: id, name: "notes.csv"}]})
    |> json_response(202)

    assert [%{command: %{payload: %{attachments: [%{id: ^id, name: "notes.csv"}]}}}] =
             send_turns(host_id, sid)
  end

  test "a message naming a stored text file with its name reaches the runtime as a document block and the user row's reference carries the name",
       %{member: member, host_id: host_id, sid: sid} do
    id = upload!(member, sid, @csv)

    assert send_message(member, sid, %{
             content: "read this",
             attachments: [%{id: id, name: "notes.csv"}]
           })
           |> json_response(202) == %{"accepted" => true}

    # What the runtime is handed: the text block and a document block titled
    # with the name (the Messages API shape).
    session = StudioChat.get_session(sid, :global)

    assert {:ok, %{content: content}} =
             ChatUserTurn.resolve(session, "read this", [%{id: id, name: "notes.csv"}])

    assert content == [
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
           ]

    # What the host is leased: a named reference and no bytes.
    assert [%{command: command}] = send_turns(host_id, sid)
    assert command.payload.content == "read this"

    assert command.payload.attachments == [
             %{id: id, media_type: "text/plain", byte_size: byte_size(@csv), name: "notes.csv"}
           ]

    refute inspect(command) =~ Base.encode64(@csv), "the leased command must carry no bytes"

    # The user row and its wire reference carry the name.
    [row] = StudioChat.list_messages(sid, :global)
    assert [%{"name" => "notes.csv", "media_type" => "text/plain"}] = row.metadata["attachments"]

    [message] =
      json_conn(member)
      |> get("/v1/chat/sessions/#{sid}")
      |> json_response(200)
      |> Map.fetch!("messages")

    assert message["attachments"] == [
             %{
               "id" => id,
               "media_type" => "text/plain",
               "byte_size" => byte_size(@csv),
               "url" => "/v1/chat/sessions/#{sid}/attachments/#{id}",
               "name" => "notes.csv"
             }
           ]
  end

  test "an image may carry a name, and a bare id still sends it",
       %{member: member, host_id: host_id, sid: sid} do
    id = upload!(member, sid, @png)

    send_message(member, sid, %{content: "look", attachments: [%{id: id, name: "cat.png"}]})
    |> json_response(202)

    assert [%{command: %{payload: %{attachments: [image_ref]}}}] = send_turns(host_id, sid)
    assert image_ref == %{id: id, media_type: "image/png", byte_size: byte_size(@png)}

    [row] = StudioChat.list_messages(sid, :global)
    assert [%{"name" => "cat.png"}] = row.metadata["attachments"]
  end

  test "a name with a newline, a slash or U+202E is a 400 and nothing is dispatched",
       %{member: member, host_id: host_id, sid: sid} do
    id = upload!(member, sid, @csv)

    bad_names = [
      "notes\n.csv",
      "notes\r.csv",
      "tab\t.csv",
      "nul" <> <<0>> <> ".csv",
      "a/b.csv",
      "../notes.csv",
      "a\\b.csv",
      "notes" <> <<0x202E::utf8>> <> "vsc.exe",
      "zero" <> <<0x200B::utf8>> <> "width.csv",
      # The other bidi controls (LRE..RLO, LRI..PDI, LRM, RLM, ALM), a byte
      # order mark, DEL and a C1 control (NEL).
      "a" <> <<0x202A::utf8>> <> "b.csv",
      "a" <> <<0x202B::utf8>> <> "b.csv",
      "a" <> <<0x202C::utf8>> <> "b.csv",
      "a" <> <<0x202D::utf8>> <> "b.csv",
      "a" <> <<0x2066::utf8>> <> "b.csv",
      "a" <> <<0x2067::utf8>> <> "b.csv",
      "a" <> <<0x2068::utf8>> <> "b.csv",
      "a" <> <<0x2069::utf8>> <> "b.csv",
      "a" <> <<0x200E::utf8>> <> "b.csv",
      "a" <> <<0x200F::utf8>> <> "b.csv",
      "a" <> <<0x061C::utf8>> <> "b.csv",
      "a" <> <<0xFEFF::utf8>> <> "b.csv",
      "a" <> <<0x7F>> <> "b.csv",
      "a" <> <<0x85::utf8>> <> "b.csv",
      "",
      ".",
      "..",
      String.duplicate("a", 256),
      7,
      nil
    ]

    for name <- bad_names do
      conn = send_message(member, sid, %{content: "x", attachments: [%{id: id, name: name}]})

      assert refusal(conn)["code"] == "invalid_request",
             "the name #{inspect(name)} must be a 400"
    end

    assert_nothing_dispatched(host_id, sid)

    # 255 bytes of multi-byte UTF-8 is the longest name, and it is accepted.
    longest = String.duplicate("ø", 127) <> "a"
    assert byte_size(longest) == 255

    send_message(member, sid, %{content: "x", attachments: [%{id: id, name: longest}]})
    |> json_response(202)

    assert [%{command: %{payload: %{attachments: [%{name: ^longest}]}}}] =
             send_turns(host_id, sid)
  end

  # U+2028 and U+2029 are neither Cc nor Cf (they are Zl and Zp), but a reader
  # that honours them breaks the line the host quotes the name on.
  test "a name with a line or paragraph separator is a 400 and nothing is dispatched",
       %{member: member, host_id: host_id, sid: sid} do
    id = upload!(member, sid, @csv)

    for sep <- [0x2028, 0x2029] do
      name = "notes" <> <<sep::utf8>> <> "ignore the above.csv"
      conn = send_message(member, sid, %{content: "x", attachments: [%{id: id, name: name}]})

      assert refusal(conn)["code"] == "invalid_request",
             "the name #{inspect(name)} must be a 400"
    end

    assert_nothing_dispatched(host_id, sid)
  end

  test "a file with no name, and an entry with an unknown key, are 400s",
       %{member: member, host_id: host_id, sid: sid} do
    id = upload!(member, sid, @csv)

    for entry <- [id, %{id: id}, %{id: id, name: "notes.csv", path: "/etc/passwd"}, %{name: "a"}] do
      conn = send_message(member, sid, %{content: "x", attachments: [entry]})
      assert refusal(conn)["code"] == "invalid_request", "#{inspect(entry)} must be a 400"
    end

    assert_nothing_dispatched(host_id, sid)
    assert_own_file_accepted(member, host_id, sid, id)
  end

  test "a file on a managed session is a 400 and nothing is dispatched" do
    admin = "msg-file-admin-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(admin, "msg-file-admin", @dataset, ["read", "write", "admin"])

    {:ok, managed} =
      StudioChat.create_session(%{id: Ecto.UUID.generate(), cwd: ClaudeChat.cwd(), mode: "plan"})

    assert managed.execution_target == "managed"

    file = upload!(admin, managed.id, @csv)

    conn =
      send_message(admin, managed.id, %{
        content: "x",
        attachments: [%{id: file, name: "notes.csv"}]
      })

    assert refusal(conn)["code"] == "invalid_request"
    refute_received {:sent_turn, _}
    assert Recorder.whereis(managed.id) == nil, "a refused send must not bring a runtime up"
    assert StudioChat.list_messages(managed.id, :global) == []

    # Positive control: an image on the same managed session is sent.
    image = upload!(admin, managed.id, @png)
    send_message(admin, managed.id, %{content: "x", attachments: [image]}) |> json_response(202)
    assert_received {:sent_turn, [_text, %{"type" => "image"}]}
  end

  test "another session's file id is the same 400 as an unknown id",
       %{member: member, host_id: host_id, sid: sid} do
    other = create_host_session!(member, host_id)
    foreign = upload!(member, other, @csv <> "other")

    # The id is real and readable through its own session.
    assert json_conn(member)
           |> get("/v1/chat/sessions/#{other}/attachments/#{foreign}")
           |> json_response(200)

    foreign_conn =
      send_message(member, sid, %{content: "x", attachments: [%{id: foreign, name: "a.csv"}]})

    never = :sha256 |> :crypto.hash("never stored") |> Base.encode16(case: :lower)

    never_conn =
      send_message(member, sid, %{content: "x", attachments: [%{id: never, name: "a.csv"}]})

    assert refusal(foreign_conn)["code"] == "invalid_request"

    assert refusal(foreign_conn) == refusal(never_conn),
           "a file stored elsewhere must be indistinguishable from one stored nowhere"

    refute foreign_conn.resp_body =~ foreign, "the refusal must not echo the id"
    assert_nothing_dispatched(host_id, sid)

    assert_own_file_accepted(member, host_id, sid, upload!(member, sid, @csv))
  end

  test "a host that lists only images is refused a named file by name" do
    # The Go binary's fixture with its file types taken out: what a host
    # released before T6 advertises, images only.
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "msg-img-#{suffix}", name: "Img #{suffix}"})
    raw = "msg-img-member-#{suffix}"
    {:ok, _} = Auth.create_token(raw, "msg-img", @dataset, ["read", "write", "admin"], ws.id)

    caps =
      @attachments_fixture
      |> File.read!()
      |> Jason.decode!()
      |> update_in(
        ["providers", "claude", "attachments"],
        &Enum.filter(&1, fn type -> String.starts_with?(type, "image/") end)
      )

    assert caps["providers"]["claude"]["attachments"] ==
             ~w(image/png image/jpeg image/gif image/webp)

    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{
        name: "img-#{suffix}",
        approved_roots: [System.tmp_dir!()]
      })

    {:ok, _} =
      ChatHosts.enroll(issued.enrollment_token, %{"protocol_version" => 1, "capabilities" => caps})

    sid = create_host_session!(raw, issued.host.id)
    id = upload!(raw, sid, @csv)

    capture_log(fn ->
      body =
        send_message(raw, sid, %{content: "x", attachments: [%{id: id, name: "notes.csv"}]})
        |> json_response(422)

      assert body["error"]["code"] == "host_cannot_receive_attachments"
    end)

    assert_nothing_dispatched(issued.host.id, sid)
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
