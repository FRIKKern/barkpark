defmodule BarkparkWeb.ChatSessionHostFolderTest do
  @moduledoc """
  A registered-host chat session can name a bot folder, so several bots share
  one computer and each works in its own folder under the host's approved root
  (task-ed93b8c0ab2b44b8, Paper barkbot-many-bots-plan task 5).

  Before: `POST /v1/chat/sessions` refused `bot_folder` as an unknown key, and
  every registered-host turn ran in the host's first approved root
  (`Runtime.registered_host_cwd/2`), so two bots on one computer shared one
  folder, its files and its CLAUDE.md.

  The folder is a name, never a path (`Barkpark.StudioChat.BotFolder`). The
  lease carries it as `payload.bot_folder` beside an unchanged `payload.cwd`;
  the server never joins the two. A session with no folder leases exactly what
  it leased before, with no `bot_folder` key. A host that does not advertise
  `providers.claude.bot_folders` is never leased a folder turn, because a host
  binary from before this change would ignore the key and run in the shared
  root.

  The host is enrolled and heartbeated through `ChatHosts` with the Go binary's
  own capabilities fixtures and read the way `GET /v1/chat-host/commands` reads
  it (`ChatHosts.next_commands/1`).
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
  alias Barkpark.StudioChat.Session
  alias Barkpark.Tenancy

  @dataset "production"
  @fixtures Path.expand("../../support/fixtures", __DIR__)
  @folders_fixture Path.join(@fixtures, "chat_host_go_capabilities_bot_folders.json")
  # Today's shipped host: attachments, no bot_folders.
  @legacy_fixture Path.join(@fixtures, "chat_host_go_capabilities_attachments.json")

  setup do
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      reap_recorders()
      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "hfold-#{suffix}", name: "HFold #{suffix}"})

    raw = "hfold-member-#{suffix}"
    {:ok, _} = Auth.create_token(raw, "hfold-member", @dataset, ["read", "write", "admin"], ws.id)

    %{
      raw: raw,
      root: System.tmp_dir!(),
      host_id: enroll_host!(ws, "folders-host-#{suffix}", @folders_fixture),
      legacy_host_id: enroll_host!(ws, "legacy-host-#{suffix}", @legacy_fixture)
    }
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp enroll_host!(ws, name, fixture) do
    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{name: name, approved_roots: [System.tmp_dir!()]})

    caps = fixture |> File.read!() |> Jason.decode!()

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

  defp create(raw, body), do: json_conn(raw) |> post("/v1/chat/sessions", Jason.encode!(body))

  defp host_body(host_id, extra \\ %{}) do
    Map.merge(
      %{provider: "claude", execution_target: "registered_host", execution_host_id: host_id},
      extra
    )
  end

  defp send_hi(raw, sid),
    do:
      json_conn(raw) |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(%{content: "hi"}))

  # What `GET /v1/chat-host/commands` hands the host, for this session.
  defp send_turns(host_id, sid) do
    RegisteredHost
    |> Repo.get!(host_id)
    |> ChatHosts.next_commands()
    |> Enum.filter(&(&1.command.operation == :send_turn and &1.command.session_id == sid))
  end

  defp leases_for(sid),
    do: Repo.aggregate(from(l in ExecutionLease, where: l.session_id == ^sid), :count)

  defp session_count, do: Repo.aggregate(Session, :count)

  @rule_message "bot_folder must match ^[a-z0-9][a-z0-9-]{0,39}$"

  defp refusal(resp) do
    %{"error" => %{"code" => code, "message" => message}} = Jason.decode!(resp.resp_body)
    {code, message}
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

  # ── a folder rides the lease ───────────────────────────────────────────────

  describe "a session with a bot folder" do
    test "is created with it, and its turn is leased with cwd the root and bot_folder the name",
         %{raw: raw, root: root, host_id: host_id} do
      created = create(raw, host_body(host_id, %{bot_folder: "bot-1a2b"}))
      assert created.status == 201, "create answered #{created.status}: #{created.resp_body}"
      body = json_response(created, 201)
      assert body["bot_folder"] == "bot-1a2b"

      sid = body["id"]
      assert StudioChat.get_session(sid, :global).bot_folder == "bot-1a2b"

      assert send_hi(raw, sid).status == 202
      assert [%{command: command}] = send_turns(host_id, sid)
      assert command.payload.cwd == root, "the server never joins the folder onto the root"
      assert command.payload.bot_folder == "bot-1a2b"
    end

    test "takes the 40-character maximum and a name that is digits only",
         %{raw: raw, host_id: host_id} do
      forty = "a" <> String.duplicate("0", 39)
      assert create(raw, host_body(host_id, %{bot_folder: forty})).status == 201
      assert create(raw, host_body(host_id, %{bot_folder: "7"})).status == 201
    end

    test "is refused at send on a host that does not advertise bot_folders, and nothing is leased",
         %{raw: raw, legacy_host_id: host_id} do
      sid =
        create(raw, host_body(host_id, %{bot_folder: "bot-1a2b"}))
        |> json_response(201)
        |> Map.fetch!("id")

      log =
        capture_log(fn ->
          conn = send_hi(raw, sid)
          send(self(), {:refusal, conn.status, Jason.decode!(conn.resp_body)})
        end)

      assert_received {:refusal, 422, %{"error" => %{"code" => "chat_unsupported"}}}
      assert log =~ "host_cannot_use_bot_folder"
      assert leases_for(sid) == 0
      assert send_turns(host_id, sid) == []
    end
  end

  # ── no folder: byte-for-byte as before ─────────────────────────────────────

  describe "a session with no bot folder" do
    test "leases cwd the root exactly and no bot_folder key, on either host",
         %{raw: raw, root: root, host_id: host_id, legacy_host_id: legacy_host_id} do
      for host <- [host_id, legacy_host_id] do
        body = create(raw, host_body(host)) |> json_response(201)
        assert body["bot_folder"] == nil
        sid = body["id"]

        assert send_hi(raw, sid).status == 202
        assert [%{command: command}] = send_turns(host, sid)
        assert command.payload.cwd == root
        refute Map.has_key?(command.payload, :bot_folder)
      end
    end

    test "an explicit null is the same as no folder", %{raw: raw, host_id: host_id} do
      body = create(raw, host_body(host_id, %{bot_folder: nil})) |> json_response(201)
      assert body["bot_folder"] == nil
    end
  end

  # ── the rule cannot express a path ─────────────────────────────────────────

  describe "create refuses a folder that is not one strict segment" do
    @bad [
      "..",
      ".",
      "a/b",
      "/etc",
      "a\\b",
      "A",
      "Bot-1",
      "",
      " ",
      "-bot",
      ".barkpark",
      "bot.1",
      "bot_1",
      "bot 1",
      "bot-1\n",
      "bot\u0000",
      "bøt",
      "bot∕x",
      "a" <> String.duplicate("0", 40)
    ]

    test "each bad name answers 400 and creates nothing", %{raw: raw, host_id: host_id} do
      before = session_count()

      for name <- @bad do
        resp = create(raw, host_body(host_id, %{bot_folder: name}))

        assert resp.status == 400,
               "#{inspect(name)} answered #{resp.status}: #{resp.resp_body}"

        # The rule refused it, not the unknown-key check that refuses every
        # bot_folder on a server without this field.
        assert refusal(resp) == {"invalid_request", @rule_message}
      end

      assert session_count() == before
    end

    test "a non-string folder answers 400 and creates nothing", %{raw: raw, host_id: host_id} do
      before = session_count()

      for value <- [1, true, ["bot"], %{"a" => "b"}] do
        resp = create(raw, host_body(host_id, %{bot_folder: value}))
        assert resp.status == 400
        assert refusal(resp) == {"invalid_request", @rule_message}
      end

      assert session_count() == before
    end

    test "a folder on a managed session or a codex session answers 400 and creates nothing",
         %{raw: raw, host_id: host_id} do
      before = session_count()
      managed = "bot_folder is only for registered_host execution"

      for {body, message} <- [
            {%{bot_folder: "bot-1a2b"}, managed},
            {%{provider: "claude", execution_target: "managed", bot_folder: "bot-1"}, managed},
            {host_body(host_id, %{provider: "codex", bot_folder: "bot-1a2b"}),
             "bot_folder is only for the claude provider"}
          ] do
        resp = create(raw, body)
        assert resp.status == 400, "#{inspect(body)} answered #{resp.status}"
        assert refusal(resp) == {"invalid_request", message}
      end

      assert session_count() == before
    end

    test "the store refuses a bad folder even past the controller" do
      for {attrs, field} <- [
            {%{
               execution_target: "registered_host",
               execution_host_id: Ecto.UUID.generate(),
               bot_folder: "../x"
             }, :bot_folder},
            {%{execution_target: "managed", bot_folder: "bot-1"}, :bot_folder},
            {%{
               provider: "codex",
               execution_target: "registered_host",
               execution_host_id: Ecto.UUID.generate(),
               bot_folder: "bot-1"
             }, :bot_folder}
          ] do
        cs = Session.create_changeset(%Session{}, Map.put(attrs, :id, Ecto.UUID.generate()))
        refute cs.valid?
        assert Keyword.has_key?(cs.errors, field)
      end
    end

    test "the database refuses a bad folder written around the changeset" do
      id = Ecto.UUID.generate()

      {:ok, _} =
        StudioChat.create_session(%{
          id: id,
          execution_target: "registered_host",
          execution_host_id: Ecto.UUID.generate()
        })

      assert_raise Postgrex.Error, ~r/chat_sessions_bot_folder_check/, fn ->
        Repo.update_all(from(s in Session, where: s.id == ^id), set: [bot_folder: "../escape"])
      end
    end
  end

  # ── create-only ────────────────────────────────────────────────────────────

  describe "the folder is create-only" do
    test "PATCH with a folder is refused and changes nothing", %{raw: raw, host_id: host_id} do
      sid =
        create(raw, host_body(host_id, %{bot_folder: "bot-1a2b"}))
        |> json_response(201)
        |> Map.fetch!("id")

      plain = create(raw, host_body(host_id)) |> json_response(201) |> Map.fetch!("id")

      for {id, folder} <- [{sid, "bot-other"}, {plain, "bot-new"}, {sid, nil}] do
        resp =
          json_conn(raw)
          |> patch("/v1/chat/sessions/#{id}", Jason.encode!(%{bot_folder: folder}))

        assert resp.status == 400, "PATCH answered #{resp.status}: #{resp.resp_body}"
      end

      assert StudioChat.get_session(sid, :global).bot_folder == "bot-1a2b"
      assert StudioChat.get_session(plain, :global).bot_folder == nil
    end
  end

  # ── the migration ──────────────────────────────────────────────────────────

  test "chat_sessions.bot_folder is one nullable text column with no default" do
    %{rows: rows} =
      Repo.query!("""
      SELECT is_nullable, column_default, data_type
        FROM information_schema.columns
       WHERE table_name = 'chat_sessions' AND column_name = 'bot_folder'
      """)

    assert rows == [["YES", nil, "character varying"]]
  end
end
