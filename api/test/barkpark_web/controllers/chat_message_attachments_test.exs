defmodule BarkparkWeb.ChatMessageAttachmentsTest do
  @moduledoc """
  `POST /v1/chat/sessions/:id/messages` naming attachments the session holds
  (task-3c1505c7cdade860, Paper chat-host-attachments-plan T4).

  The body is `{content, attachments: [sha256 id, ...]}`. The turn reaches the
  runtime as the SAME block list the Studio composer sends (text plus base64
  image blocks), and the persisted user row carries the same pointer a
  Studio-sent row does, so the transcript and the event stream's history rows
  project `attachments` references for it.

  Tenancy: an id is resolved ONLY inside the session the tenant oracle already
  returned. An id stored for another session, in this workspace or another, is
  refused with exactly the body a never-stored id gets, so no answer says
  whether an id exists elsewhere.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the studio_chat capability owns the chat supervisors, registries and /v1/chat routes
  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Attachments
  alias Barkpark.StudioChat.Recorder
  alias BarkparkWeb.ChatController
  alias BarkparkWeb.Studio.ClaudeChat

  @dataset "production"

  # A real 1x1 PNG: the store sniffs the media type from these bytes.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  @gif "GIF87a" <> <<1, 0, 1, 0, 0x80, 0, 0>> <> <<0, 0, 0, 255, 255, 255, 0x3B>>

  # The managed claude runtime, replaced by one that reports the content the
  # controller hands `Runtime.send_turn/3`. That hand-off is the only place the
  # built block list exists, so a test that only read the stored row would say
  # nothing about what the model receives.
  defmodule CaptureAdapter do
    @moduledoc false
    @behaviour Barkpark.StudioChat.Runtime.Adapter

    def start(_opts), do: {:ok, :capture_runtime}
    def resume(_opts), do: {:ok, :capture_runtime}

    def send_turn(_runtime, content) do
      if pid = Application.get_env(:barkpark, :chat_message_attachments_test_pid),
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

    dir =
      Path.join(System.tmp_dir!(), "bp_chat_msg_att_test_#{System.unique_integer([:positive])}")

    Application.put_env(:barkpark, StudioChat, attachments_dir: dir)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    Application.put_env(
      :barkpark,
      :studio_chat_runtime_adapters,
      Map.put(prev_adapters || %{}, :claude, CaptureAdapter)
    )

    Application.put_env(:barkpark, :chat_message_attachments_test_pid, self())

    on_exit(fn ->
      if Process.whereis(Barkpark.StudioChat.RuntimeSupervisor), do: reap_runtimes()
      File.rm_rf(dir)
      Application.delete_env(:barkpark, :chat_message_attachments_test_pid)
      restore(StudioChat, prev_chat)
      restore(:claude_chat, prev_claude)
      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
      restore(:studio_chat_runtime_adapters, prev_adapters)
    end)

    admin = "chat-msg-att-admin-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(admin, "msg-att-admin", @dataset, ["read", "write", "admin"])

    %{admin: admin, sid: new_session!(nil)}
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp new_session!(nil) do
    {:ok, s} =
      StudioChat.create_session(%{id: Ecto.UUID.generate(), cwd: ClaudeChat.cwd(), mode: "plan"})

    s.id
  end

  defp new_session!(ws_id) do
    {:ok, s} =
      StudioChat.create_session(
        %{id: Ecto.UUID.generate(), cwd: ClaudeChat.cwd(), mode: "plan"},
        {:workspace, ws_id}
      )

    s.id
  end

  defp json_conn(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp upload!(raw, sid, bytes) do
    json_conn(raw)
    |> post("/v1/chat/sessions/#{sid}/attachments", Jason.encode!(%{data: Base.encode64(bytes)}))
    |> json_response(201)
    |> get_in(["attachment", "id"])
  end

  defp send_message(raw, sid, body),
    do: json_conn(raw) |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(body))

  defp image_block(media_type, bytes) do
    %{
      "type" => "image",
      "source" => %{
        "type" => "base64",
        "media_type" => media_type,
        "data" => Base.encode64(bytes)
      }
    }
  end

  # A refusal's error object without the per-request id, so two refusals can be
  # compared for sameness.
  defp refusal(conn) do
    conn |> json_response(400) |> Map.fetch!("error") |> Map.delete("request_id")
  end

  # The positive control every refusal test ends on: the same session, the
  # same caller and an id it really holds are accepted, so the 400s above are
  # the attachment check and not a body the route refuses for any reason.
  defp assert_own_id_accepted(raw, sid, id) do
    send_message(raw, sid, %{content: "x", attachments: [id]}) |> json_response(202)
    assert_received {:sent_turn, [_text, _image]}
  end

  # The refusal leaves no trace: nothing reached the runtime, no runtime was
  # brought up, no user row was written.
  defp assert_nothing_sent(sid) do
    refute_received {:sent_turn, _}
    assert Recorder.whereis(sid) == nil, "a refused send must not bring a runtime up"
    assert StudioChat.list_messages(sid, :global) == [], "a refused send must not persist a row"
  end

  describe "a message naming attachments the session holds" do
    test "a message naming an uploaded attachment reaches the runtime as an image block and the user row carries its reference",
         %{admin: admin, sid: sid} do
      id = upload!(admin, sid, @png)

      assert send_message(admin, sid, %{content: "what is this?", attachments: [id]})
             |> json_response(202) == %{"accepted" => true}

      assert_received {:sent_turn, content}

      assert content == [
               %{"type" => "text", "text" => "what is this?"},
               image_block("image/png", @png)
             ]

      # The stored row: the SAME pointer a Studio-sent row carries (the
      # composer persists `Attachments.pointer_json/1` of the `put/2` result).
      {:ok, studio_pointer} = Attachments.put(sid, @png)
      [row] = StudioChat.list_messages(sid, :global)
      assert row.role == "user"
      assert row.source_markdown == "what is this?"

      assert row.metadata == %{
               "origin" => "api",
               "attachments" => [Attachments.pointer_json(studio_pointer)]
             }

      reference = %{
        "id" => id,
        "media_type" => "image/png",
        "byte_size" => byte_size(@png),
        "url" => "/v1/chat/sessions/#{sid}/attachments/#{id}"
      }

      # GET /v1/chat/sessions/:id projects the reference, never the store path.
      [message] =
        json_conn(admin)
        |> get("/v1/chat/sessions/#{sid}")
        |> json_response(200)
        |> Map.fetch!("messages")

      assert message["attachments"] == [reference]
      assert message["metadata"] == %{"origin" => "api"}

      # The event stream's history row is the same projection.
      [frame] = ChatController.replay_events(sid, 0, :global)
      [_, data] = Regex.run(~r/^data: (.*)$/m, frame)
      assert Jason.decode!(data)["attachments"] == [reference]
      refute frame =~ "\"path\""
    end

    test "two attachments keep their order after the text block", %{admin: admin, sid: sid} do
      png = upload!(admin, sid, @png)
      gif = upload!(admin, sid, @gif)

      send_message(admin, sid, %{content: "compare", attachments: [gif, png]})
      |> json_response(202)

      assert_received {:sent_turn, content}

      assert content == [
               %{"type" => "text", "text" => "compare"},
               image_block("image/gif", @gif),
               image_block("image/png", @png)
             ]
    end

    test "an image-only message (empty content) sends the image block alone",
         %{admin: admin, sid: sid} do
      id = upload!(admin, sid, @png)

      send_message(admin, sid, %{content: "", attachments: [id]}) |> json_response(202)

      assert_received {:sent_turn, [image]}
      assert image == image_block("image/png", @png)
    end

    test "a message with no attachments still sends its content as a plain string",
         %{admin: admin, sid: sid} do
      for body <- [%{content: "hello"}, %{content: "hello", attachments: []}] do
        send_message(admin, sid, body) |> json_response(202)
        assert_received {:sent_turn, "hello"}
      end

      for row <- StudioChat.list_messages(sid, :global) do
        assert row.metadata == %{"origin" => "api"}
      end
    end
  end

  describe "refusals (each a 400 before anything is sent)" do
    test "a message naming an attachment from another session is a 400 whose body matches a never-stored id",
         %{admin: admin, sid: sid} do
      other = new_session!(nil)
      foreign = upload!(admin, other, @png)

      # Positive control: the id is real and readable through ITS session, so
      # the refusal below is the session fence, not a dead id.
      assert json_conn(admin)
             |> get("/v1/chat/sessions/#{other}/attachments/#{foreign}")
             |> json_response(200)

      foreign_conn = send_message(admin, sid, %{content: "x", attachments: [foreign]})
      assert refusal(foreign_conn)["code"] == "invalid_request"
      assert_nothing_sent(sid)

      never = :sha256 |> :crypto.hash("never stored") |> Base.encode16(case: :lower)
      never_conn = send_message(admin, sid, %{content: "x", attachments: [never]})

      assert refusal(foreign_conn) == refusal(never_conn),
             "an id stored elsewhere must be indistinguishable from one stored nowhere"

      refute foreign_conn.resp_body =~ foreign, "the refusal must not echo the id"
      assert_nothing_sent(sid)

      assert_own_id_accepted(admin, sid, upload!(admin, sid, @gif))
    end

    test "a message naming an attachment from another workspace's session is a 400 whose body matches a never-stored id" do
      {ws_a, _project} = ensure_default_scope!()
      ws_b = create_workspace!()

      token_a = "chat-msg-att-a-#{System.unique_integer([:positive])}"
      token_b = "chat-msg-att-b-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(token_a, "msg-att-a", @dataset, ["read", "chat"], ws_a.id)
      {:ok, _} = Auth.create_token(token_b, "msg-att-b", @dataset, ["read", "chat"], ws_b.id)

      sid_a = new_session!(ws_a.id)
      sid_b = new_session!(ws_b.id)
      own = upload!(token_a, sid_a, @gif)
      foreign = upload!(token_b, sid_b, @png)

      # Positive control: ws-A's token sends with its OWN attachment, so the
      # refusal below is the fence and not a token that cannot send at all.
      send_message(token_a, sid_a, %{content: "mine", attachments: [own]}) |> json_response(202)
      assert_received {:sent_turn, [_text, _image]}
      reap_runtimes()
      before = StudioChat.list_messages(sid_a, :global)

      foreign_conn = send_message(token_a, sid_a, %{content: "x", attachments: [foreign]})
      assert refusal(foreign_conn)["code"] == "invalid_request"
      refute_received {:sent_turn, _}
      assert StudioChat.list_messages(sid_a, :global) == before
      refute foreign_conn.resp_body =~ foreign, "the refusal must not echo the id"

      never = :sha256 |> :crypto.hash("never stored either") |> Base.encode16(case: :lower)
      never_conn = send_message(token_a, sid_a, %{content: "x", attachments: [never]})
      assert refusal(foreign_conn) == refusal(never_conn)

      # And ws-B, naming its own real id, cannot reach ws-A's session at all:
      # the tenant oracle answers before any attachment is looked at.
      cross = send_message(token_b, sid_a, %{content: "x", attachments: [own]})
      assert json_response(cross, 404)["error"]["code"] == "not_found"

      # The same 404 when ws-B names an id ws-A's session does NOT hold: the
      # oracle answers before the attachment check, never a 400 from it.
      cross_foreign = send_message(token_b, sid_a, %{content: "x", attachments: [foreign]})
      assert json_response(cross_foreign, 404)["error"]["code"] == "not_found"
      refute_received {:sent_turn, _}
    end

    test "a malformed attachment id is a 400", %{admin: admin, sid: sid} do
      id = upload!(admin, sid, @png)

      for bad <- [
            String.upcase(id),
            binary_part(id, 0, 63),
            id <> "0",
            "../#{id}",
            "#{sid}/#{id}",
            "",
            42,
            nil,
            %{"id" => id}
          ] do
        conn = send_message(admin, sid, %{content: "x", attachments: [bad]})

        assert json_response(conn, 400)["error"]["code"] == "invalid_request",
               "attachment id #{inspect(bad)} must be a 400"
      end

      assert_nothing_sent(sid)
      assert_own_id_accepted(admin, sid, id)
    end

    test "a repeated attachment id is a 400", %{admin: admin, sid: sid} do
      id = upload!(admin, sid, @png)

      conn = send_message(admin, sid, %{content: "x", attachments: [id, id]})
      assert json_response(conn, 400)["error"]["code"] == "invalid_request"
      assert_nothing_sent(sid)
      assert_own_id_accepted(admin, sid, id)
    end

    test "five attachments is a 400", %{admin: admin, sid: sid} do
      # Five DISTINCT ids the session really holds, so the refusal is the count
      # and not a missing or repeated id.
      ids = for n <- 1..5, do: upload!(admin, sid, @png <> <<n>>)
      assert length(Enum.uniq(ids)) == 5

      conn = send_message(admin, sid, %{content: "x", attachments: ids})
      assert json_response(conn, 400)["error"]["code"] == "invalid_request"
      assert_nothing_sent(sid)

      # Four of the same five are accepted: the cap is exactly four.
      send_message(admin, sid, %{content: "x", attachments: Enum.take(ids, 4)})
      |> json_response(202)

      assert_received {:sent_turn, [_text | images]}
      assert length(images) == 4
    end

    test "attachments that is not a list is a 400", %{admin: admin, sid: sid} do
      id = upload!(admin, sid, @png)

      for bad <- [id, %{"0" => id}, 1, true] do
        conn = send_message(admin, sid, %{content: "x", attachments: bad})

        assert json_response(conn, 400)["error"]["code"] == "invalid_request",
               "attachments #{inspect(bad)} must be a 400"
      end

      assert_nothing_sent(sid)
      assert_own_id_accepted(admin, sid, id)
    end
  end

  describe "the capability manifest" do
    test "chat.send_message declares attachments as a repeatable body flag", %{admin: admin} do
      send =
        json_conn(admin)
        |> get("/v1/capabilities")
        |> json_response(200)
        |> Map.fetch!("commands")
        |> Enum.find(&(&1["id"] == "chat.send_message"))

      flag = Enum.find(send["flags"] || [], &(&1["name"] == "attachments"))

      # Repeatable is what makes `bp` send a JSON array even for one id; a plain
      # string flag would send a bare string, which the route refuses.
      assert %{"type" => "string", "repeatable" => true} = flag
    end
  end

  defp reap_runtimes(tries \\ 200) do
    Barkpark.StudioChat.RuntimeSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn
      {_, pid, _, _} when is_pid(pid) ->
        DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)

      _ ->
        :ok
    end)

    await_empty_pool(tries)
  end

  defp await_empty_pool(0), do: :ok

  defp await_empty_pool(tries) do
    if Barkpark.StudioChat.RuntimeAdmission.active_count() == 0 do
      :ok
    else
      Process.sleep(10)
      await_empty_pool(tries - 1)
    end
  end
end
