defmodule BarkparkWeb.ChatControllerTest do
  @moduledoc """
  The `/v1/chat` transport (charter `bp-chat-tui`, D21-D24). Focused controller
  tests in the `ListenController` seam convention: the eight non-SSE routes run
  end-to-end through `ConnCase` (a valid `cat` fake CLI drives send/interrupt/
  approval), while the long-lived SSE `receive` loop — un-assertable through a
  full `get/2` (it blocks on `send_chunked`) — is proven at the controller's
  `@doc false` public seams (frame serializers, exit-reason mapping, replay
  projection, the subscription forwarder).

  Obligations A-I from the charter map onto the describe blocks below.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias BarkparkWeb.ChatController
  alias BarkparkWeb.Studio.ClaudeChat

  @dataset "production"

  defmodule FakeCodexAdapter do
    @moduledoc false

    def capabilities do
      %{modes: ["default", "read-only"], models: ["gpt-5.6"], efforts: ["high"]}
    end

    def cwd, do: "/tmp/codex-managed"
  end

  setup do
    # A valid `cat` echo-server fake CLI so send/interrupt/approval can bring up a
    # real Recorder + Session without a real `claude`. public_demo_studio is ON in
    # test config (which fail-closes enabled?/0), so both must flip.
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    prev_adapters = Application.get_env(:barkpark, :studio_chat_runtime_adapters)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    Application.put_env(
      :barkpark,
      :studio_chat_runtime_adapters,
      Map.put(prev_adapters || %{}, :codex, FakeCodexAdapter)
    )

    on_exit(fn ->
      # Reap any spawned runtimes so a live subprocess never leaks into the next test.
      Barkpark.StudioChat.RuntimeSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn
        {_, pid, _, _} when is_pid(pid) ->
          DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)

        _ ->
          :ok
      end)

      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)

      if prev_adapters,
        do: Application.put_env(:barkpark, :studio_chat_runtime_adapters, prev_adapters),
        else: Application.delete_env(:barkpark, :studio_chat_runtime_adapters)
    end)

    admin = "chat-admin-#{System.unique_integer([:positive])}"
    admin2 = "chat-admin2-#{System.unique_integer([:positive])}"
    reader = "chat-reader-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(admin, "chat-admin", @dataset, ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(admin2, "chat-admin2", @dataset, ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(reader, "chat-reader", @dataset, ["read"])

    {:ok, session} =
      StudioChat.create_session(%{id: Ecto.UUID.generate(), cwd: ClaudeChat.cwd(), mode: "plan"})

    %{admin: admin, admin2: admin2, reader: reader, sid: session.id}
  end

  defp as(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp json_conn(raw), do: as(build_conn(), raw)

  # ── A. eight-route auth matrix (16 negative-auth assertions) ────────────────

  describe "auth matrix — auth runs BEFORE any UUID/store/runtime work (obligation A)" do
    setup %{sid: sid} do
      %{
        routes: [
          {:get, "/v1/chat/sessions"},
          {:post, "/v1/chat/sessions"},
          {:get, "/v1/chat/sessions/#{sid}"},
          {:patch, "/v1/chat/sessions/#{sid}"},
          {:post, "/v1/chat/sessions/#{sid}/messages"},
          {:post, "/v1/chat/sessions/#{sid}/interrupt"},
          {:post, "/v1/chat/sessions/#{sid}/approval"},
          {:get, "/v1/chat/sessions/#{sid}/events"}
        ]
      }
    end

    test "missing bearer => 401 canonical request-id envelope on every route", %{routes: routes} do
      for {method, path} <- routes do
        conn =
          dispatch(
            build_conn() |> put_req_header("content-type", "application/json"),
            method,
            path
          )

        body = json_response(conn, 401)
        assert body["error"]["code"] == "unauthorized", "#{method} #{path}"
        assert Map.has_key?(body["error"], "request_id"), "#{method} #{path} missing request_id"
      end
    end

    test "valid NON-admin bearer => 403 canonical request-id envelope on every route",
         %{routes: routes, reader: reader} do
      for {method, path} <- routes do
        conn = dispatch(json_conn(reader), method, path)
        body = json_response(conn, 403)
        assert body["error"]["code"] == "forbidden", "#{method} #{path}"
        assert Map.has_key?(body["error"], "request_id"), "#{method} #{path} missing request_id"
      end
    end

    test "the events route negotiates a text/event-stream Accept (D6) — not 406", %{
      reader: reader
    } do
      # A spec-compliant SSE Accept must reach the controller (where auth then
      # 403s a non-admin) rather than 406-ing in :accepts ["json"]. Proving it on
      # the non-admin leg avoids the admin leg's blocking send_chunked.
      conn =
        json_conn(reader)
        |> put_req_header("accept", "text/event-stream")
        |> get("/v1/chat/sessions/#{Ecto.UUID.generate()}/events")

      assert conn.status == 403
    end
  end

  # ── B. instance-global admin authority (obligation B / D21) ─────────────────

  describe "authority is instance-global admin (obligation B)" do
    test "two distinct global-admin tokens both read the SAME session",
         %{admin: a1, admin2: a2, sid: sid} do
      assert json_conn(a1) |> get("/v1/chat/sessions/#{sid}") |> json_response(200)
      assert json_conn(a2) |> get("/v1/chat/sessions/#{sid}") |> json_response(200)
    end

    test "workspace/project query params neither narrow nor escalate — no scoped route",
         %{admin: a1, sid: sid} do
      # A workspace_id query value is inert (there is no tenancy filter, D21).
      body =
        json_conn(a1)
        |> get("/v1/chat/sessions/#{sid}?workspace_id=#{Ecto.UUID.generate()}&project_id=x")
        |> json_response(200)

      assert body["id"] == sid
    end
  end

  # ── B'. cross-tenant isolation — a workspace Connector is confined to its own
  #        tenant (Connectors D18/D19a) ────────────────────────────────────────

  describe "cross-tenant isolation — a workspace connector cannot reach another tenant's session" do
    setup do
      ws_a = create_workspace!()
      ws_b = create_workspace!()

      conn_a_raw = "chat-conn-a-#{System.unique_integer([:positive])}"
      conn_b_raw = "chat-conn-b-#{System.unique_integer([:positive])}"

      # Workspace-bound Connector tokens: NOT global admin — they carry `chat` and
      # resolve to `{:workspace, ws}` in RequireChatAccess.
      {:ok, _} = Auth.create_token(conn_a_raw, "conn-a", @dataset, ["read", "chat"], ws_a.id)
      {:ok, _} = Auth.create_token(conn_b_raw, "conn-b", @dataset, ["read", "chat"], ws_b.id)

      %{ws_a: ws_a, ws_b: ws_b, conn_a: conn_a_raw, conn_b: conn_b_raw}
    end

    test "a ws-B connector hits the not-found oracle on a session it does not own across every id route, while a :global admin reads it",
         %{admin: admin, conn_a: conn_a, conn_b: conn_b, sid: sid} do
      # Each id-bearing route carries a VALID body so the tenant check (not a 400)
      # is what produces the 404 — proving the wrong-tenant read is
      # indistinguishable from a missing id (never a distinct 403).
      not_found_calls = [
        fn -> json_conn(conn_b) |> get("/v1/chat/sessions/#{sid}") end,
        fn ->
          json_conn(conn_b) |> patch("/v1/chat/sessions/#{sid}", Jason.encode!(%{draft: "x"}))
        end,
        fn ->
          json_conn(conn_b)
          |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(%{content: "x"}))
        end,
        fn -> json_conn(conn_b) |> post("/v1/chat/sessions/#{sid}/interrupt", "") end,
        fn ->
          json_conn(conn_b)
          |> post(
            "/v1/chat/sessions/#{sid}/approval",
            Jason.encode!(%{request_id: "r", decision: "allow"})
          )
        end,
        fn -> json_conn(conn_b) |> get("/v1/chat/sessions/#{sid}/events") end
      ]

      for call <- not_found_calls do
        conn = call.()
        body = json_response(conn, 404)

        assert body["error"]["code"] == "not_found",
               "cross-tenant read must join the not-found oracle, not a distinct 403"
      end

      # index: ws-B's list never surfaces a session it does not own.
      listed = json_conn(conn_b) |> get("/v1/chat/sessions") |> json_response(200)

      refute Enum.any?(listed["sessions"], &(&1["id"] == sid)),
             "ws-B leaked another tenant's session"

      # The 404s above are ISOLATION, not a dead token: the SAME ws-B connector is
      # authorized through the plug and can create its OWN session.
      own =
        json_conn(conn_b) |> post("/v1/chat/sessions", Jason.encode!(%{})) |> json_response(201)

      assert {:ok, _} = Ecto.UUID.cast(own["id"])

      # A :global admin retains instance-wide authority (D21 unchanged) — it reads
      # the very session ws-B was 404'd on.
      assert json_conn(admin) |> get("/v1/chat/sessions/#{sid}") |> json_response(200)

      # POSITIVE isolation leg (Connectors D19a) — the owner reads back what it
      # created. ws-A's connector creates a session (must be stamped
      # owner_workspace_id = ws_a from the create scope), then reads it (200) and
      # sees it in its own list; ws-B is 404'd on that same fresh id. Without the
      # create-scope stamp the session would be nil-owned and its OWNING connector
      # would 404 on it — this leg pins that the stamp lands (charter D17/D18).
      a_own =
        json_conn(conn_a) |> post("/v1/chat/sessions", Jason.encode!(%{})) |> json_response(201)

      a_id = a_own["id"]

      assert json_conn(conn_a) |> get("/v1/chat/sessions/#{a_id}") |> json_response(200),
             "ws-A must read back the session it just created (owner stamp lands)"

      a_listed = json_conn(conn_a) |> get("/v1/chat/sessions") |> json_response(200)
      assert Enum.any?(a_listed["sessions"], &(&1["id"] == a_id)), "ws-A must see its OWN session"

      nf = json_conn(conn_b) |> get("/v1/chat/sessions/#{a_id}") |> json_response(404)
      assert nf["error"]["code"] == "not_found", "ws-B must be 404'd on ws-A's fresh session"
    end
  end

  # ── C. UUID / not-found oracle safety (obligation C) ────────────────────────

  describe "UUID / not-found oracle (obligation C)" do
    test "admin: malformed UUID and absent well-formed UUID return the SAME 404 envelope",
         %{admin: a1} do
      malformed = json_conn(a1) |> get("/v1/chat/sessions/not-a-uuid") |> json_response(404)

      absent =
        json_conn(a1) |> get("/v1/chat/sessions/#{Ecto.UUID.generate()}") |> json_response(404)

      assert malformed["error"]["code"] == "not_found"
      assert absent["error"]["code"] == "not_found"
      assert malformed["error"]["code"] == absent["error"]["code"]
    end

    test "unauthenticated stays 401 for BOTH malformed and absent ids (auth first)",
         %{} do
      base = build_conn() |> put_req_header("content-type", "application/json")
      assert dispatch(base, :get, "/v1/chat/sessions/not-a-uuid") |> json_response(401)

      assert dispatch(base, :get, "/v1/chat/sessions/#{Ecto.UUID.generate()}")
             |> json_response(401)
    end

    test "non-admin stays 403 for BOTH malformed and absent ids", %{reader: reader} do
      assert json_conn(reader) |> get("/v1/chat/sessions/not-a-uuid") |> json_response(403)

      assert json_conn(reader)
             |> get("/v1/chat/sessions/#{Ecto.UUID.generate()}")
             |> json_response(403)
    end
  end

  # ── create: server-owned id + cwd, strict params (obligations D + E) ────────

  describe "POST /sessions — server-owned UUID + cwd, no launcher escalation (E)" do
    test "mints the id and derives cwd from ClaudeChat.cwd/0 only", %{admin: a1} do
      body =
        json_conn(a1)
        |> post(
          "/v1/chat/sessions",
          Jason.encode!(%{mode: "acceptEdits", model: "opus", effort: "high"})
        )
        |> json_response(201)

      assert {:ok, _} = Ecto.UUID.cast(body["id"])
      assert body["cwd"] == ClaudeChat.cwd()
      assert body["mode"] == "acceptEdits"
      assert body["model_choice"] == "opus"
      assert body["effort_choice"] == "high"
      assert body["messages"] == []
      # The row is really persisted with the derived cwd (not a request value).
      assert StudioChat.get_session(body["id"]).cwd == ClaudeChat.cwd()
    end

    test "an absent mode defaults to plan", %{admin: a1} do
      body = json_conn(a1) |> post("/v1/chat/sessions", Jason.encode!(%{})) |> json_response(201)
      assert body["mode"] == "plan"
      assert body["provider"] == "claude"
      assert body["execution_target"] == "managed"
      assert body["execution_host_id"] == nil
      assert body["provider_session_id"] == body["id"]
    end

    test "persists and projects explicit provider and registered-host identity", %{admin: a1} do
      host_id = Ecto.UUID.generate()

      body =
        json_conn(a1)
        |> post(
          "/v1/chat/sessions",
          Jason.encode!(%{
            provider: "codex",
            execution_target: "registered_host",
            execution_host_id: host_id,
            mode: "read-only",
            model: "gpt-5.6",
            effort: "high"
          })
        )
        |> json_response(201)

      assert body["provider"] == "codex"
      assert body["execution_target"] == "registered_host"
      assert body["execution_host_id"] == host_id
      assert body["provider_session_id"] == nil
      assert body["mode"] == "read-only"
      assert body["model_choice"] == "gpt-5.6"
      assert body["effort_choice"] == "high"

      stored = StudioChat.get_session(body["id"])
      assert stored.provider == "codex"
      assert stored.execution_target == "registered_host"
      assert stored.execution_host_id == host_id
      assert stored.provider_session_id == nil
    end

    test "rejects invalid provider/target/host combinations before writing", %{admin: a1} do
      before = length(StudioChat.list_sessions())
      host_id = Ecto.UUID.generate()

      for invalid <- [
            %{provider: "other"},
            %{execution_target: "other"},
            %{execution_target: "managed", execution_host_id: host_id},
            %{execution_target: "registered_host"},
            %{execution_target: "registered_host", execution_host_id: "not-a-uuid"}
          ] do
        response =
          json_conn(a1)
          |> post("/v1/chat/sessions", Jason.encode!(invalid))
          |> json_response(400)

        assert response["error"]["code"] == "invalid_request", inspect(invalid)
      end

      assert length(StudioChat.list_sessions()) == before
    end

    test "every launcher control / unknown key is rejected 400 with ZERO store write",
         %{admin: a1} do
      before = length(StudioChat.list_sessions())

      controls = [
        %{command: "rm -rf /"},
        %{executable: "/bin/sh"},
        %{args: ["--dangerous"]},
        %{env: %{"X" => "y"}},
        %{cwd: "/etc"},
        %{session_id: Ecto.UUID.generate()},
        %{resume: true},
        %{minter: "admin"},
        %{token: "secret"},
        %{bypass_armed: true},
        %{updatedInput: %{}},
        %{mode: "bypassPermissions"},
        %{mode: 123},
        %{mode: "nonsense"},
        %{model: "gpt-4"},
        %{effort: "ultra"},
        %{unknown_key: 1}
      ]

      for body <- controls do
        conn = json_conn(a1) |> post("/v1/chat/sessions", Jason.encode!(body))
        assert json_response(conn, 400)["error"]["code"] == "invalid_request", inspect(body)
      end

      # A JSON array body (non-object) is rejected too.
      assert json_conn(a1)
             |> post("/v1/chat/sessions", Jason.encode!([1, 2, 3]))
             |> json_response(400)

      assert length(StudioChat.list_sessions()) == before, "a rejected create wrote a session row"
    end
  end

  # ── list (obligation B sidebar shape + D14 vacuous-green trap) ──────────────

  describe "GET /sessions — sidebar shape, archived filter" do
    test "omits the draft/choices continuity fields (D14 vacuous-green trap)", %{
      admin: a1,
      sid: sid
    } do
      {:ok, _} = StudioChat.set_draft(sid, "unsent words")

      entry =
        json_conn(a1)
        |> get("/v1/chat/sessions")
        |> json_response(200)
        |> Map.fetch!("sessions")
        |> Enum.find(&(&1["id"] == sid))

      assert entry, "expected the session in the active list"
      refute Map.has_key?(entry, "draft")
      refute Map.has_key?(entry, "model_choice")
      refute Map.has_key?(entry, "rail_snapshot")
    end

    test "?archived= filters the shelf; a malformed value is 400", %{admin: a1, sid: sid} do
      {:ok, _} = StudioChat.archive_session(sid)

      active = json_conn(a1) |> get("/v1/chat/sessions?archived=false") |> json_response(200)
      refute Enum.any?(active["sessions"], &(&1["id"] == sid))

      archived = json_conn(a1) |> get("/v1/chat/sessions?archived=true") |> json_response(200)
      assert Enum.any?(archived["sessions"], &(&1["id"] == sid))

      assert json_conn(a1) |> get("/v1/chat/sessions?archived=maybe") |> json_response(400)
    end
  end

  # ── GET session: full continuity + messages + blocks + since (D8/D14) ───────

  describe "GET /sessions/:id — full continuity, blocks, since (D8/D14)" do
    test "returns the full continuity set plus seq-ascending messages with assistant blocks",
         %{admin: a1, sid: sid} do
      {:ok, _} = StudioChat.set_draft(sid, "resume me")
      {:ok, _} = StudioChat.set_model_choice(sid, "opus")
      {:ok, _} = StudioChat.set_effort_choice(sid, "high")
      {:ok, _} = StudioChat.append_message(sid, %{role: "user", source_markdown: "hi"})

      {:ok, _} =
        StudioChat.append_message(sid, %{
          role: "assistant",
          source_markdown: "## Answer\n\nA paragraph."
        })

      body = json_conn(a1) |> get("/v1/chat/sessions/#{sid}") |> json_response(200)

      assert body["draft"] == "resume me"
      assert body["model_choice"] == "opus"
      assert body["effort_choice"] == "high"
      assert body["mode"] == "plan"
      assert Map.has_key?(body, "rail_snapshot")
      assert Map.has_key?(body, "title")

      seqs = Enum.map(body["messages"], & &1["seq"])
      assert seqs == Enum.sort(seqs), "messages must be seq-ascending"

      assistant = Enum.find(body["messages"], &(&1["role"] == "assistant"))
      assert assistant["source_markdown"] =~ "Answer"
      # D8: assistant rows carry the exact PortableDoc block JSON (heading first).
      assert [%{"type" => "heading"} | _] = assistant["blocks"]

      # A user row is NOT re-blocked (only assistant, D8).
      user = Enum.find(body["messages"], &(&1["role"] == "user"))
      refute Map.has_key?(user, "blocks")
    end

    test "?since=<seq> returns only newer rows (the turn-boundary tail refetch)",
         %{admin: a1, sid: sid} do
      for i <- 1..3,
          do: {:ok, _} = StudioChat.append_message(sid, %{role: "user", source_markdown: "m#{i}"})

      body = json_conn(a1) |> get("/v1/chat/sessions/#{sid}?since=1") |> json_response(200)
      seqs = Enum.map(body["messages"], & &1["seq"])
      assert seqs == [2, 3]
    end

    test "a negative / non-integer since is 400", %{admin: a1, sid: sid} do
      assert json_conn(a1) |> get("/v1/chat/sessions/#{sid}?since=-1") |> json_response(400)
      assert json_conn(a1) |> get("/v1/chat/sessions/#{sid}?since=abc") |> json_response(400)
      assert json_conn(a1) |> get("/v1/chat/sessions/#{sid}?since=1.5") |> json_response(400)
    end
  end

  # ── PATCH: exact allowlist, bounds, StudioChat.rename (obligation D) ────────

  describe "PATCH /sessions/:id — exact allowlist + bounds" do
    test "persists draft/mode/model_choice/effort_choice and title (human rename)",
         %{admin: a1, sid: sid} do
      body =
        json_conn(a1)
        |> patch(
          "/v1/chat/sessions/#{sid}",
          Jason.encode!(%{
            draft: "wip",
            mode: "acceptEdits",
            model_choice: "sonnet",
            effort_choice: "medium",
            title: "  Renamed  "
          })
        )
        |> json_response(200)

      assert body["draft"] == "wip"
      assert body["mode"] == "acceptEdits"
      assert body["model_choice"] == "sonnet"
      assert body["effort_choice"] == "medium"
      assert body["title"] == "Renamed"
      assert body["title_source"] == "human"
    end

    test "rejects bypassPermissions, unknown keys, and archived (list-only, not a write)",
         %{admin: a1, sid: sid} do
      for body <- [
            %{mode: "bypassPermissions"},
            %{archived: true},
            %{foo: 1},
            %{title: "  "},
            %{provider: "codex"},
            %{execution_target: "registered_host"},
            %{execution_host_id: Ecto.UUID.generate()},
            %{provider_session_id: "native-thread"}
          ] do
        conn = json_conn(a1) |> patch("/v1/chat/sessions/#{sid}", Jason.encode!(body))
        assert json_response(conn, 400)["error"]["code"] == "invalid_request", inspect(body)
      end

      stored = StudioChat.get_session(sid)
      assert stored.provider == "claude"
      assert stored.execution_target == "managed"
      assert stored.execution_host_id == nil
      assert stored.provider_session_id == sid
    end

    test "title and draft honor the exact 256-byte / 64-KiB boundaries", %{admin: a1, sid: sid} do
      ok_title = String.duplicate("x", 256)
      too_long_title = String.duplicate("x", 257)
      ok_draft = String.duplicate("d", 65_536)
      too_long_draft = String.duplicate("d", 65_537)

      assert json_conn(a1)
             |> patch("/v1/chat/sessions/#{sid}", Jason.encode!(%{title: ok_title}))
             |> json_response(200)

      assert json_conn(a1)
             |> patch("/v1/chat/sessions/#{sid}", Jason.encode!(%{title: too_long_title}))
             |> json_response(400)

      assert json_conn(a1)
             |> patch("/v1/chat/sessions/#{sid}", Jason.encode!(%{draft: ok_draft}))
             |> json_response(200)

      assert json_conn(a1)
             |> patch("/v1/chat/sessions/#{sid}", Jason.encode!(%{draft: too_long_draft}))
             |> json_response(400)
    end

    test "PATCH on an absent session is 404", %{admin: a1} do
      assert json_conn(a1)
             |> patch("/v1/chat/sessions/#{Ecto.UUID.generate()}", Jason.encode!(%{draft: "x"}))
             |> json_response(404)
    end
  end

  # ── send: strict adapter, validation before any runtime call (D + wire) ─────

  describe "POST /sessions/:id/messages — send" do
    test "a valid content dispatches through the runtime => 202 {accepted:true}",
         %{admin: a1, sid: sid} do
      body =
        json_conn(a1)
        |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(%{content: "hello"}))
        |> json_response(202)

      assert body["accepted"] == true
      assert is_pid(Recorder.whereis(sid)), "the send brought the runtime up"
    end

    test "a bad body is 400 with ZERO runtime spawned (validation before ensure)",
         %{admin: a1, sid: sid} do
      for body <- [%{}, %{content: 123}, %{content: %{}}, %{content: "hi", extra: 1}] do
        conn = json_conn(a1) |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(body))
        assert json_response(conn, 400)["error"]["code"] == "invalid_request", inspect(body)
      end

      assert Recorder.whereis(sid) == nil, "a rejected send must not spawn a runtime"
    end

    test "content honors the exact 64-KiB boundary", %{admin: a1, sid: sid} do
      at_limit = String.duplicate("a", 65_536)
      over = String.duplicate("a", 65_537)

      # Over the limit fails BEFORE any runtime call.
      assert json_conn(a1)
             |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(%{content: over}))
             |> json_response(400)

      assert Recorder.whereis(sid) == nil

      # At the limit dispatches.
      assert json_conn(a1)
             |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(%{content: at_limit}))
             |> json_response(202)
    end

    test "send to an absent session is 404", %{admin: a1} do
      assert json_conn(a1)
             |> post(
               "/v1/chat/sessions/#{Ecto.UUID.generate()}/messages",
               Jason.encode!(%{content: "x"})
             )
             |> json_response(404)
    end
  end

  # ── interrupt (D11) ─────────────────────────────────────────────────────────

  describe "POST /sessions/:id/interrupt (D11)" do
    test "with a live runtime returns 202 {request_id}", %{admin: a1, sid: sid} do
      {:ok, _} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})

      body =
        json_conn(a1)
        |> post("/v1/chat/sessions/#{sid}/interrupt", "")
        |> json_response(202)

      assert is_binary(body["request_id"])
    end

    test "with NO live runtime is a silent no-op (202 request_id:null), never a spawn",
         %{admin: a1, sid: sid} do
      body = json_conn(a1) |> post("/v1/chat/sessions/#{sid}/interrupt", "") |> json_response(202)
      assert body["request_id"] == nil
      assert Recorder.whereis(sid) == nil
    end

    test "interrupt on an absent session is 404", %{admin: a1} do
      assert json_conn(a1)
             |> post("/v1/chat/sessions/#{Ecto.UUID.generate()}/interrupt", "")
             |> json_response(404)
    end
  end

  # ── approval (D22 — allow/deny only, never caller updatedInput) ─────────────

  describe "POST /sessions/:id/approval (D22)" do
    defp pending_approval(sid, request_id) do
      {:ok, _} =
        StudioChat.append_message(StudioChat.get_session(sid), %{
          role: "approval",
          source_markdown: "Allow Write /tmp/example?",
          metadata: %{
            "request_id" => request_id,
            "tool_name" => "Write",
            "input" => %{"file_path" => "/tmp/example"},
            "approval_status" => "pending"
          }
        })
    end

    test "a delivered allow/deny persists terminal metadata visible on refetch", %{
      admin: a1,
      sid: sid
    } do
      pending_approval(sid, "req-1")
      pending_approval(sid, "req-2")
      {:ok, _} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})

      assert json_conn(a1)
             |> post(
               "/v1/chat/sessions/#{sid}/approval",
               Jason.encode!(%{request_id: "req-1", decision: "allow"})
             )
             |> response(204)

      assert json_conn(a1)
             |> post(
               "/v1/chat/sessions/#{sid}/approval",
               Jason.encode!(%{request_id: "req-2", decision: "deny"})
             )
             |> response(204)

      refetched = json_conn(a1) |> get("/v1/chat/sessions/#{sid}") |> json_response(200)

      statuses =
        Map.new(refetched["messages"], fn message ->
          {message["metadata"]["request_id"], message["metadata"]["approval_status"]}
        end)

      assert statuses == %{"req-1" => "allowed", "req-2" => "denied"}
      assert refetched["pending_approvals"] == 0
    end

    test "without a live runtime the request is a 204 no-op and stays pending", %{
      admin: a1,
      sid: sid
    } do
      pending_approval(sid, "req-pending")

      assert json_conn(a1)
             |> post(
               "/v1/chat/sessions/#{sid}/approval",
               Jason.encode!(%{request_id: "req-pending", decision: "allow"})
             )
             |> response(204)

      [message] = StudioChat.list_messages(sid)
      assert message.metadata["approval_status"] == "pending"
      assert StudioChat.get_session(sid).pending_approvals == 1
    end

    test "a missing or terminal request is a 204 no-op after runtime delivery", %{
      admin: a1,
      sid: sid
    } do
      pending_approval(sid, "req-terminal")
      assert {:ok, _} = StudioChat.update_approval_status(sid, "req-terminal", "allowed")
      {:ok, _} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})

      for {request_id, decision} <- [{"req-terminal", "deny"}, {"missing", "allow"}] do
        assert json_conn(a1)
               |> post(
                 "/v1/chat/sessions/#{sid}/approval",
                 Jason.encode!(%{request_id: request_id, decision: decision})
               )
               |> response(204)
      end

      [message] = StudioChat.list_messages(sid)
      assert message.metadata["approval_status"] == "allowed"
      assert StudioChat.get_session(sid).pending_approvals == 0
    end

    test "rejects a bad decision, a missing request_id, and a caller-supplied updatedInput",
         %{admin: a1, sid: sid} do
      bodies = [
        %{request_id: "r", decision: "maybe"},
        %{decision: "allow"},
        %{request_id: "r"},
        %{request_id: "r", decision: "allow", updatedInput: %{"x" => 1}},
        %{request_id: String.duplicate("r", 257), decision: "allow"}
      ]

      for body <- bodies do
        conn = json_conn(a1) |> post("/v1/chat/sessions/#{sid}/approval", Jason.encode!(body))
        assert json_response(conn, 400)["error"]["code"] == "invalid_request", inspect(body)
      end
    end

    test "approval on an absent session is 404", %{admin: a1} do
      assert json_conn(a1)
             |> post(
               "/v1/chat/sessions/#{Ecto.UUID.generate()}/approval",
               Jason.encode!(%{request_id: "r", decision: "allow"})
             )
             |> json_response(404)
    end
  end

  # ── F. SSE exit secrecy — the internal tail cannot reach the wire (D23) ──────

  describe "SSE exit frame secrecy (obligation F / D23)" do
    test "exit_payload is exactly {status, reason} over the fixed public enum" do
      cases = [
        {0, %{status: 0, reason: "clean"}},
        {137, %{status: 137, reason: "crashed"}},
        {:crashed, %{status: nil, reason: "crashed"}},
        {:idle_reaped, %{status: nil, reason: "idle_reaped"}},
        {:failed_start, %{status: nil, reason: "failed_start"}},
        {:something_weird, %{status: nil, reason: "unknown"}}
      ]

      for {status, expected} <- cases do
        assert ChatController.exit_payload(status) == expected
      end
    end

    test "the serialized exit frame carries only status+reason — no tail can leak" do
      # The seam takes ONLY the status, so a stderr tail packed with secrets is
      # STRUCTURALLY unable to reach the frame (D23 — DROP the tail).
      frame = ChatController.sse_exit_frame(139)
      assert frame =~ "event: exit"

      data =
        frame
        |> String.split("data: ", parts: 2)
        |> List.last()
        |> String.trim()
        |> Jason.decode!()

      assert data == %{"status" => 139, "reason" => "crashed"}
      refute frame =~ "Bearer"
      refute frame =~ "/home/"
      refute frame =~ "secret"
      refute frame =~ "stderr"
    end
  end

  # ── I. SSE frame contract + replay projection (D5/D8) ───────────────────────

  describe "SSE frame serializers + replay projection (obligations G/I)" do
    test "chat frame is verbatim JSON with NO id (deltas unreplayable, D5)" do
      frame = ChatController.sse_chat_frame(%{"type" => "assistant", "text" => "hi"})
      assert String.starts_with?(frame, "event: chat\ndata: ")
      assert String.ends_with?(frame, "\n\n")
      refute frame =~ "id:"

      data =
        frame
        |> String.split("data: ", parts: 2)
        |> List.last()
        |> String.trim()
        |> Jason.decode!()

      assert data == %{"type" => "assistant", "text" => "hi"}
    end

    test "permission + keepalive frames" do
      pframe = ChatController.sse_permission_frame(%{request_id: "r"})
      assert String.starts_with?(pframe, "event: permission\ndata: ")

      data =
        pframe
        |> String.split("data: ", parts: 2)
        |> List.last()
        |> String.trim()
        |> Jason.decode!()

      assert data == %{"request_id" => "r"}

      assert ChatController.sse_keepalive() == ": keepalive\n\n"
    end

    test "replay_events returns id-bearing message frames for rows seq > since",
         %{sid: sid} do
      for i <- 1..3,
          do: {:ok, _} = StudioChat.append_message(sid, %{role: "user", source_markdown: "m#{i}"})

      frames = ChatController.replay_events(sid, 1)
      assert length(frames) == 2

      assert Enum.at(frames, 0) =~ ~r/\Aid: 2\nevent: message\ndata: /
      assert Enum.at(frames, 1) =~ ~r/\Aid: 3\nevent: message\ndata: /

      # nil since replays everything.
      assert length(ChatController.replay_events(sid, nil)) == 3
    end

    test "a replayed assistant row carries PortableDoc blocks (D8)", %{sid: sid} do
      {:ok, _} = StudioChat.append_message(sid, %{role: "assistant", source_markdown: "# Title"})
      [frame] = ChatController.replay_events(sid, 0)

      data =
        frame
        |> String.split("data: ", parts: 2)
        |> List.last()
        |> String.trim()
        |> Jason.decode!()

      assert [%{"type" => "heading"} | _] = data["blocks"]
    end
  end

  # ── G. SSE ownership / cleanup — forwarder is linked + stops (D24) ──────────

  describe "SSE subscription forwarder ownership (obligation G / D24)" do
    test "forwards topic frames, then stops + unsubscribes on :stop" do
      topic = Recorder.topic(Ecto.UUID.generate())
      fwd = ChatController.start_forwarder(topic, self())

      Phoenix.PubSub.broadcast(Barkpark.PubSub, topic, {:claude_chat_event, %{"k" => 1}})
      assert_receive {:claude_chat_event, %{"k" => 1}}, 500

      ref = Process.monitor(fwd)
      send(fwd, :stop)
      assert_receive {:DOWN, ^ref, :process, ^fwd, _}, 500

      # Subscription is gone with the helper — a fresh broadcast reaches nobody.
      Phoenix.PubSub.broadcast(Barkpark.PubSub, topic, {:claude_chat_event, %{"k" => 2}})
      refute_receive {:claude_chat_event, %{"k" => 2}}, 100
    end

    test "the emergency per-connection heap cap defaults to 10_000_000 words (D24)" do
      assert ChatController.sse_max_heap_words() == 10_000_000
    end

    test "GET events on an absent session is 404 before any stream is opened", %{admin: a1} do
      assert json_conn(a1)
             |> get("/v1/chat/sessions/#{Ecto.UUID.generate()}/events")
             |> json_response(404)
    end
  end

  # dispatch a request by method atom (the auth matrix iterates method+path).
  defp dispatch(conn, :get, path), do: get(conn, path)
  defp dispatch(conn, :post, path), do: post(conn, path, "")
  defp dispatch(conn, :patch, path), do: patch(conn, path, "")
end
