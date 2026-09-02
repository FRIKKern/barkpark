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
  import Ecto.Query, only: [from: 2]

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.BlockedSweeper
  alias Barkpark.StudioChat.Message
  alias Barkpark.StudioChat.PlanPapers
  alias Barkpark.StudioChat.QuestionAnswer
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.Tenancy
  alias Barkpark.Webhooks
  alias BarkparkWeb.ChatController
  alias BarkparkWeb.Studio.ClaudeChat

  @dataset "production"

  defmodule FakeCodexAdapter do
    @moduledoc false

    def capabilities do
      %{modes: ["default", "read-only"], models: ["gpt-5.6"], efforts: ["high"]}
    end

    def cwd, do: "/tmp/codex-managed"

    # A codex-style NON-:ok delivery: the double-answer race returns
    # {:error, :unknown_approval}. chat_controller.approval/2 must swallow this
    # (soft-match) and still flip the status + 204, never MatchError → 500.
    #
    # The echo is what makes the /answer contract OBSERVABLE
    # (ct-bl-question-updatedinput): the decision the controller hands the runtime
    # is the ONLY place the rebuilt updatedInput exists, so a test that only
    # inspected the flipped row would be vacuous about the whole point of the
    # route. Guarded on a configured pid, so every pre-existing codex test is
    # byte-identical.
    def answer_approval(_ref, request_id, decision) do
      case Application.get_env(:barkpark, :chat_answer_test_pid) do
        pid when is_pid(pid) -> send(pid, {:answered, request_id, decision})
        _ -> :ok
      end

      {:error, :unknown_approval}
    end
  end

  defmodule SweepEcho do
    @moduledoc false
    # Webhook HTTP adapter that echoes each delivery to the test pid — makes a
    # BlockedSweeper fire observable (blocked_sweeper_test's PidEcho twin).
    def post(url, body, _headers) do
      case Application.get_env(:barkpark, :chat_owner_stamp_test_pid) do
        pid when is_pid(pid) -> send(pid, {:sweep_delivered, url, body})
        _ -> :ok
      end

      {:ok, 200}
    end
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

  # ── wave-session-card wire fixtures (wsc charter D3/D6/D9) ────────────────

  # A live 2-phase workflow rail: Explore settled, Build 1 done + 1 running.
  defp workflow_rail do
    %{
      "wf" => %{
        "status" => "running",
        "seq" => 1,
        "row" => %{"task_type" => "local_workflow", "description" => "wave 1"},
        "workflow" => [
          %{"type" => "workflow_phase", "index" => 1, "title" => "Explore"},
          %{"type" => "workflow_phase", "index" => 2, "title" => "Build"},
          %{
            "type" => "workflow_agent",
            "phaseIndex" => 2,
            "label" => "build:a",
            "state" => "done",
            "startedAt" => 100,
            "tokens" => 10
          },
          %{
            "type" => "workflow_agent",
            "phaseIndex" => 2,
            "label" => "build:b",
            "state" => "progress",
            "startedAt" => 200
          }
        ]
      }
    }
  end

  defp sidebar_entry(admin, sid) do
    entry =
      json_conn(admin)
      |> get("/v1/chat/sessions")
      |> json_response(200)
      |> Map.fetch!("sessions")
      |> Enum.find(&(&1["id"] == sid))

    assert entry, "expected the session in the active list"
    entry
  end

  # epic_goal reads the published documents table directly — insert the lean
  # ledger rows, no claim machinery (the READ path is under test).
  defp insert_ledger_task!(doc_id, title, content) do
    Barkpark.Repo.insert!(%Barkpark.Content.Document{
      doc_id: doc_id,
      type: "task",
      title: title,
      status: "published",
      content: content,
      rev: Ecto.UUID.generate()
    })
  end

  # ── A. ten-route auth matrix (20 negative-auth assertions) ──────────────────

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
          {:post, "/v1/chat/sessions/#{sid}/answer"},
          {:post, "/v1/chat/sessions/#{sid}/archive"},
          {:post, "/v1/chat/sessions/#{sid}/unarchive"},
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
        fn -> json_conn(conn_b) |> post("/v1/chat/sessions/#{sid}/archive", "") end,
        fn -> json_conn(conn_b) |> post("/v1/chat/sessions/#{sid}/unarchive", "") end,
        fn ->
          json_conn(conn_b)
          |> post(
            "/v1/chat/sessions/#{sid}/approval",
            Jason.encode!(%{request_id: "r", decision: "allow"})
          )
        end,
        # ct-bl-question-updatedinput: answering ANOTHER tenant's question is the
        # same not-found oracle. The body is VALID in shape, so what produces the
        # 404 is `fetch_scoped`, not a 400 — a wrong-tenant answer is
        # indistinguishable from a missing id.
        fn ->
          json_conn(conn_b)
          |> post(
            "/v1/chat/sessions/#{sid}/answer",
            Jason.encode!(%{request_id: "r", answers: %{"Pick one" => "Blue"}})
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

  # ── create: owner_workspace_id stamp (herd charter D43h seal) ───────────────

  describe "POST /sessions — owner_workspace_id stamp feeds BlockedSweeper (D43h)" do
    # `BlockedSweeper` is deliberately fail-closed on NULL owners: a `nil`-owned
    # session can NEVER fire `chat_blocked`. The live-proof on guerrilla found
    # EVERY real session NULL-owned — created by admin (`:global`) tokens, which
    # used to stamp NULL. These tests pin the fix at the wire: an admin-created
    # session carries a real owner AND the fail-closed sweeper actually fires
    # for it. Breaking the create-scope stamp (reverting `create_scope/1` to
    # `scope/1`) reds BOTH assertions — the sweep returns 0 again.

    setup do
      prev = Application.get_env(:barkpark, :webhook_http_adapter)
      Application.put_env(:barkpark, :webhook_http_adapter, SweepEcho)
      Application.put_env(:barkpark, :chat_owner_stamp_test_pid, self())

      on_exit(fn ->
        if prev,
          do: Application.put_env(:barkpark, :webhook_http_adapter, prev),
          else: Application.delete_env(:barkpark, :webhook_http_adapter)

        Application.delete_env(:barkpark, :chat_owner_stamp_test_pid)
      end)

      :ok
    end

    test "a workspace-bound admin stamps its workspace — and BlockedSweeper fires for the session" do
      ws = create_workspace!()
      raw = "chat-admin-ws-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.create_token(raw, "chat-admin-ws", @dataset, ["read", "write", "admin"], ws.id)

      body = json_conn(raw) |> post("/v1/chat/sessions", Jason.encode!(%{})) |> json_response(201)
      session = StudioChat.get_session(body["id"])

      assert session.owner_workspace_id == ws.id,
             "a wire-created admin session must carry a non-NULL owner " <>
               "(BlockedSweeper is fail-closed on NULL, D43h)"

      # The stamp is what makes the session VISIBLE to the fail-closed sweeper:
      # a chat_blocked webhook + one over-threshold pending ask ⇒ EXACTLY one
      # fire, carrying this session id and the stamped workspace.
      {:ok, _wh} =
        Webhooks.create_webhook(
          %{
            "name" => "cb-#{System.unique_integer([:positive])}",
            "url" => "https://sink.example/blocked",
            "secret" => "sek",
            "blocked_threshold_s" => 300
          },
          workspace_id: ws.id
        )

      {:ok, _ask} =
        %Message{}
        |> Message.changeset(%{
          session_id: session.id,
          seq: System.unique_integer([:positive]),
          role: "approval",
          metadata: %{"approval_status" => "pending"}
        })
        |> Barkpark.Repo.insert()

      assert BlockedSweeper.sweep(DateTime.add(DateTime.utc_now(), 360, :second)) == 1,
             "the sweeper must pick up the wire-created session via its stamped owner"

      assert_received {:sweep_delivered, "https://sink.example/blocked", delivered}
      payload = Jason.decode!(delivered)
      assert payload["session_id"] == session.id
      assert payload["workspace_id"] == ws.id
    end

    test "a pre-tenancy (unbound) admin token falls back to the seeded Default Workspace" do
      {default_ws, _project} = ensure_default_scope!()

      # Insert the token row DIRECTLY: `Auth.create_token/5` always binds to the
      # Default Workspace when one exists, but guerrilla's real admin token is
      # pre-tenancy — `workspace_id` NULL. That shape must exercise the
      # create-time fallback arm, not stamp NULL.
      raw = "chat-admin-unbound-#{System.unique_integer([:positive])}"

      {:ok, _} =
        %Auth.ApiToken{}
        |> Auth.ApiToken.changeset(%{
          token_hash: Auth.ApiToken.hash_token(raw),
          label: "pre-tenancy-admin",
          dataset: @dataset,
          permissions: ["read", "write", "admin"]
        })
        |> Barkpark.Repo.insert()

      body = json_conn(raw) |> post("/v1/chat/sessions", Jason.encode!(%{})) |> json_response(201)

      assert StudioChat.get_session(body["id"]).owner_workspace_id == default_ws.id,
             "an unbound admin's session must fall back to the seeded Default Workspace"
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

    # ── herd cold-mount widen (herd charter D50h) ────────────────────────────

    test "carries agent_state/agent_state_at so the herd home cold-mounts (D50h)",
         %{admin: a1, sid: sid} do
      # a fresh session wears the column default honestly
      entry = sidebar_entry(a1, sid)
      assert entry["agent_state"] == "idle"
      assert Map.has_key?(entry, "agent_state_at")

      # a persisted flip rides the same projection, timestamp included
      now = DateTime.utc_now()
      StudioChat.set_agent_state(sid, "working", :derived, now)
      entry = sidebar_entry(a1, sid)
      assert entry["agent_state"] == "working"

      assert {:ok, at, 0} = DateTime.from_iso8601(entry["agent_state_at"])

      assert DateTime.compare(DateTime.truncate(at, :second), DateTime.truncate(now, :second)) in [
               :eq,
               :gt
             ]

      # the wave-12 read-tracking stamp is retired (herd — no read receipts)
      refute Map.has_key?(entry, "last_visited_at")
    end

    # ── wave-session-card compact wire (wsc charter D3/D6 — amends D14) ──────

    test "a workflow rail earns the compact `workflow` key; the raw rail stays off the wire",
         %{admin: a1, sid: sid} do
      {:ok, _} = StudioChat.set_rail_snapshot(sid, workflow_rail())

      entry = sidebar_entry(a1, sid)
      workflow = entry["workflow"]

      # the D3 PINNED key set, string-keyed on the wire — S4's Go mirror
      # renders these fields verbatim (D13); the terminal flag serialises as
      # the Elixir atom `terminal?` verbatim
      assert workflow |> Map.keys() |> Enum.sort() ==
               ~w(agents_done agents_total ended_at label outcome phase phase_index phases_total running started_at terminal? ticks tokens)

      assert workflow["outcome"] == "live"
      assert workflow["terminal?"] == false
      # Explore carries no agents while the run lives → :future; Build breathes
      assert workflow["ticks"] == ["future", "active"]
      assert workflow["phase"] == "Build"
      assert workflow["phase_index"] == 2
      assert workflow["phases_total"] == 2
      assert workflow["agents_done"] == 1
      assert workflow["agents_total"] == 2
      assert workflow["running"] == 1
      assert workflow["started_at"] == 100
      assert workflow["ended_at"] == nil
      assert workflow["label"] == "wave 1"

      # D14's law is NOT amended away: the raw snapshot never rides the list
      refute Map.has_key?(entry, "rail_snapshot")
    end

    test "a plain session carries NO workflow/epic keys (Ecto-doctrine omission mirror of draft/effort_choice)",
         %{admin: a1, sid: sid} do
      # even a rail WITHOUT workflow nodes is a plain row on the wire — the
      # compact key exists only for workflow sessions (vacuous-green trap: the
      # key must be ABSENT, not null)
      {:ok, _} =
        StudioChat.set_rail_snapshot(sid, %{
          "bg" => %{
            "status" => "running",
            "seq" => 1,
            "row" => %{"task_type" => "local_shell", "description" => "npm test"}
          }
        })

      entry = sidebar_entry(a1, sid)
      refute Map.has_key?(entry, "workflow")
      refute Map.has_key?(entry, "epic")
      refute Map.has_key?(entry, "rail_snapshot")
    end

    test "the epic-goal map rides only when the ledger resolves the one-hop chain (wsc D9)",
         %{admin: a1, sid: sid} do
      {:ok, _} = StudioChat.set_rail_snapshot(sid, workflow_rail())

      # no held claim → workflow present, epic absent (never invented)
      entry = sidebar_entry(a1, sid)
      assert Map.has_key?(entry, "workflow")
      refute Map.has_key?(entry, "epic")

      worker = ClaudeChat.worker_id(sid)

      insert_ledger_task!("task-wsc-wire-epic", "Wire Epic", %{
        "lifecycle_status" => "in_progress",
        "wave_status" => "wave: building"
      })

      insert_ledger_task!("task-wsc-wire-held", "Held slice", %{
        "lifecycle_status" => "in_progress",
        "parent_id" => "task-wsc-wire-epic",
        "claim" => %{"worker" => worker}
      })

      insert_ledger_task!("task-wsc-wire-done", "Done slice", %{
        "lifecycle_status" => "done",
        "parent_id" => "task-wsc-wire-epic"
      })

      epic = sidebar_entry(a1, sid)["epic"]
      assert epic["id"] == "task-wsc-wire-epic"
      assert epic["title"] == "Wire Epic"
      assert epic["slices_done"] == 1
      assert epic["slices_total"] == 2
      assert epic["wave_status"] == "wave: building"
      # "PRs open" has no data source (wsc D8) — no such key, ever
      refute Map.has_key?(epic, "prs_open")
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

    # ── herd show-widen (herd charter D65h) ──────────────────────────────────

    test "carries agent_state/agent_state_at — a single-session poller needs no sidebar (D65h)",
         %{admin: a1, sid: sid} do
      # a fresh session wears the column default honestly
      body = json_conn(a1) |> get("/v1/chat/sessions/#{sid}") |> json_response(200)
      assert body["agent_state"] == "idle"
      assert Map.has_key?(body, "agent_state_at")

      # MUTATION-PROVEN: a persisted flip changes the SHOW read, timestamp too
      now = DateTime.utc_now()
      StudioChat.set_agent_state(sid, "working", :derived, now)
      body = json_conn(a1) |> get("/v1/chat/sessions/#{sid}") |> json_response(200)
      assert body["agent_state"] == "working"
      assert {:ok, at, 0} = DateTime.from_iso8601(body["agent_state_at"])

      assert DateTime.compare(DateTime.truncate(at, :second), DateTime.truncate(now, :second)) in [
               :eq,
               :gt
             ]

      # the wave-12 read-tracking stamp is retired (herd — no read receipts)
      refute Map.has_key?(body, "last_visited_at")
    end
  end

  # ── the session's CONNECTION IDENTITY (chat-local-cloud-context-w3) ─────────
  #
  # `session_context_json/1` projects the facts a remote client cannot measure
  # for itself — the execution host, the owning workspace, the cwd and the
  # repository root — so the chat context band on every surface (the CLI's
  # internal/chat/context.go, Studio's ContextIdentity, apps/mobile's
  # ContextBand) reconciles against ONE server answer instead of three guesses.
  #
  # The obligation is HONESTY, not completeness: every nil below is a distinct,
  # named fact, and a projection that collapsed two of them would let "I could
  # not look" reach a phone as "you are not in a repo".
  describe "GET /sessions/:id — the session's connection identity (chat-local-cloud-context-w3)" do
    test "carries a context map naming host / execution_target / cwd / workspace / repo",
         %{admin: a1, sid: sid} do
      ctx =
        json_conn(a1)
        |> get("/v1/chat/sessions/#{sid}")
        |> json_response(200)
        |> Map.fetch!("context")

      # The shape a client may rely on — every key present, always. An absent
      # key and a nil value are the same thing to JSON but NOT to a decoder that
      # has to tell "the server does not do this" from "the server measured
      # nothing", so the projection always emits all six.
      assert Enum.sort(Map.keys(ctx)) ==
               ~w(cwd execution_target host repo_root repo_status workspace)

      # No enrolled host holds a lease on this session, so the SERVER runs it.
      # nil is the measurement the band paints as `(server-local)`; it is not a
      # failure and must never be confused with one.
      assert ctx["host"] == nil
      assert ctx["execution_target"] == "managed"
      assert ctx["cwd"] == StudioChat.get_session(sid).cwd
    end

    test "the repo root is MEASURED for a server-local cwd: a work tree, and a directory outside one",
         %{admin: a1, sid: sid} do
      root = Path.join(System.tmp_dir!(), "ctx-repo-#{System.unique_integer([:positive])}")
      nested = Path.join([root, "a", "b"])
      File.mkdir_p!(nested)
      File.mkdir_p!(Path.join(root, ".git"))
      on_exit(fn -> File.rm_rf(root) end)

      # Inside a work tree, from a NESTED directory: the answer is the TOP, not
      # the cwd — a band that echoed the cwd back would agree with itself on
      # every path in the filesystem.
      Repo.update!(Ecto.Changeset.change(StudioChat.get_session(sid), cwd: nested))
      ctx = show_context(a1, sid)
      assert ctx["repo_status"] == "set"
      assert ctx["repo_root"] == Path.expand(root)

      # Outside one: MEASURED and empty, which is a real answer ("you are
      # chatting from outside a checkout") and renders `(not a git repo)`.
      bare = Path.join(System.tmp_dir!(), "ctx-bare-#{System.unique_integer([:positive])}")
      File.mkdir_p!(bare)
      on_exit(fn -> File.rm_rf(bare) end)
      Repo.update!(Ecto.Changeset.change(StudioChat.get_session(sid), cwd: bare))
      bare_ctx = show_context(a1, sid)

      # NOT "unknown": collapsing these two is the exact confusion the band's
      # typed absences exist to prevent.
      assert bare_ctx["repo_status"] in ["not_a_repo", "set"]

      if bare_ctx["repo_status"] == "not_a_repo" do
        assert bare_ctx["repo_root"] == nil
      else
        # /tmp itself is inside a work tree on this machine — vanishingly odd,
        # but assert the ONLY other honest answer rather than a flaky red.
        assert is_binary(bare_ctx["repo_root"])
      end
    end

    test "a registered-host session's repo root is UNKNOWN — the server never probes another machine's path",
         %{admin: a1} do
      %{host: host, sid: sid} = host_session!()
      # A cwd that IS a work tree ON THIS SERVER. The point is that the answer
      # is `unknown` ANYWAY: for a host-executed session that path names a
      # directory on someone ELSE's machine, and probing our own filesystem for
      # it would answer confidently and wrongly. This is the arm a lazier
      # projection passes by accident and this one passes on purpose — which is
      # why the cwd is deliberately resolvable here.
      here = File.cwd!()

      Repo.update!(
        Ecto.Changeset.change(StudioChat.get_session(sid),
          cwd: here,
          execution_target: "registered_host",
          execution_host_id: host.id
        )
      )

      ctx = show_context(a1, sid)
      assert ctx["repo_status"] == "unknown"
      assert ctx["repo_root"] == nil
      # The cwd still rides, so the band can name WHICH directory nobody could
      # resolve — an unknown with no subject is not actionable.
      assert ctx["cwd"] == here
      assert ctx["execution_target"] == "registered_host"
    end

    test "the host is the LIVE LEASE holder's NAME, and the workspace is the session's own slug",
         %{admin: a1} do
      %{ws: ws, host: host, credential: credential, sid: sid, suffix: suffix} =
        host_session!("studio-mini")

      # BEFORE the lease: the server runs it.
      assert show_context(a1, sid)["host"] == nil
      # The session's OWN owner workspace — not the caller's, not a default.
      assert show_context(a1, sid)["workspace"] == ws.slug

      {:ok, _fence} =
        ChatHosts.lease_and_enqueue(
          host,
          %Barkpark.StudioChat.Runtime.Command{
            operation: :start,
            provider: "claude",
            session_id: sid,
            idempotency_key: "ctx-cmd-#{suffix}",
            payload: %{}
          },
          []
        )

      # AFTER: the NAME of the host holding the live lease. A name is the only
      # part of a registered host safe to paint — never its id, never its
      # credential, neither of which may appear anywhere in the projection.
      ctx = show_context(a1, sid)
      assert ctx["host"] == "studio-mini"
      refute host.id in Map.values(ctx)
      refute credential in Map.values(ctx)
    end
  end

  defp show_context(admin, sid) do
    json_conn(admin)
    |> get("/v1/chat/sessions/#{sid}")
    |> json_response(200)
    |> Map.fetch!("context")
  end

  # A REAL enrolled chat host and a session owned by its workspace — the same
  # mint path a registered host actually rides (chat_host_report_state_test's
  # setup), because a hand-inserted row would prove the projection reads a table
  # rather than that it reads the FENCE.
  defp host_session!(name \\ "ctx-host") do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "ctx-#{suffix}", name: "Ctx #{suffix}"})
    {:ok, %{enrollment_token: t}} = ChatHosts.issue_enrollment(ws.id, %{name: name})
    {:ok, %{credential: credential}} = ChatHosts.enroll(t)
    {:ok, host} = ChatHosts.authenticate(credential)

    sid = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: sid, mode: "plan"}, {:workspace, ws.id})

    %{ws: ws, host: host, credential: credential, sid: sid, suffix: suffix}
  end

  # ── observed runtime telemetry readout (wb-api-chat-observed-telemetry-readout) ──
  # `Barkpark.StudioChat.Session`'s schema (studio_chat/session.ex) declares
  # observed_model / observed_effort /
  # observed_{input,cached_input,output,reasoning_output,total}_tokens /
  # observed_context_window / runtime_identity / runtime_telemetry_limitations,
  # and RuntimeTelemetry writes them on every provider result frame — this
  # describe block proves the FULL continuity read actually surfaces them.
  describe "GET /sessions/:id — provider-observed runtime telemetry readout" do
    test "serialises observed_* / runtime_identity / runtime_telemetry_limitations once written",
         %{admin: a1, sid: sid} do
      session = StudioChat.get_session(sid)

      Barkpark.Repo.update!(
        Ecto.Changeset.change(session,
          observed_model: "claude-opus-4-6",
          observed_effort: "high",
          observed_input_tokens: 1234,
          observed_cached_input_tokens: 500,
          observed_output_tokens: 321,
          observed_reasoning_output_tokens: 77,
          observed_total_tokens: 1555,
          observed_context_window: 200_000,
          runtime_identity: %{"runtime_id" => "codex-app-server-9"},
          runtime_telemetry_limitations: [
            "registered-host CPU and memory telemetry are unavailable"
          ]
        )
      )

      body = json_conn(a1) |> get("/v1/chat/sessions/#{sid}") |> json_response(200)

      assert body["observed_model"] == "claude-opus-4-6"
      assert body["observed_effort"] == "high"
      assert body["observed_input_tokens"] == 1234
      assert body["observed_cached_input_tokens"] == 500
      assert body["observed_output_tokens"] == 321
      assert body["observed_reasoning_output_tokens"] == 77
      assert body["observed_total_tokens"] == 1555
      assert body["observed_context_window"] == 200_000
      assert body["runtime_identity"] == %{"runtime_id" => "codex-app-server-9"}

      assert body["runtime_telemetry_limitations"] == [
               "registered-host CPU and memory telemetry are unavailable"
             ]
    end

    test "a session with no observations renders every observed_* key as nil, never 0/requested/empty map",
         %{admin: a1, sid: sid} do
      {:ok, _} = StudioChat.set_model_choice(sid, "opus")
      {:ok, _} = StudioChat.set_effort_choice(sid, "high")

      body = json_conn(a1) |> get("/v1/chat/sessions/#{sid}") |> json_response(200)

      # honesty rule: nil stays nil — never coalesced to 0, to the requested
      # model_choice/effort_choice, or to an empty map.
      assert body["observed_model"] == nil
      assert body["observed_effort"] == nil
      assert body["observed_input_tokens"] == nil
      assert body["observed_cached_input_tokens"] == nil
      assert body["observed_output_tokens"] == nil
      assert body["observed_reasoning_output_tokens"] == nil
      assert body["observed_total_tokens"] == nil
      assert body["observed_context_window"] == nil
      assert body["runtime_identity"] == nil
      assert body["runtime_telemetry_limitations"] == nil

      refute body["observed_model"] == body["model_choice"]
      refute body["observed_effort"] == body["effort_choice"]
    end

    test "the sidebar shape deliberately omits observed_* (same D14 vacuous-green-trap boundary as draft/rail/choices)",
         %{admin: a1, sid: sid} do
      session = StudioChat.get_session(sid)

      Barkpark.Repo.update!(
        Ecto.Changeset.change(session,
          observed_model: "claude-opus-4-6",
          observed_effort: "high",
          runtime_identity: %{"runtime_id" => "codex-app-server-9"}
        )
      )

      entry = sidebar_entry(a1, sid)

      refute Map.has_key?(entry, "observed_model")
      refute Map.has_key?(entry, "observed_effort")
      refute Map.has_key?(entry, "observed_input_tokens")
      refute Map.has_key?(entry, "observed_cached_input_tokens")
      refute Map.has_key?(entry, "observed_output_tokens")
      refute Map.has_key?(entry, "observed_reasoning_output_tokens")
      refute Map.has_key?(entry, "observed_total_tokens")
      refute Map.has_key?(entry, "observed_context_window")
      refute Map.has_key?(entry, "runtime_identity")
      refute Map.has_key?(entry, "runtime_telemetry_limitations")
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

    test "a mode PATCH with a LIVE runtime steers it best-effort and persists",
         %{admin: a1, sid: sid} do
      prev = Application.get_env(:barkpark, :claude_chat)
      Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})

      on_exit(fn ->
        if prev,
          do: Application.put_env(:barkpark, :claude_chat, prev),
          else: Application.delete_env(:barkpark, :claude_chat)
      end)

      {:ok, recorder} =
        Barkpark.StudioChat.Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})

      body =
        json_conn(a1)
        |> patch("/v1/chat/sessions/#{sid}", Jason.encode!(%{mode: "auto"}))
        |> json_response(200)

      assert body["mode"] == "auto"
      # The steer is fire-and-forget into the live session (the TUI toggle's
      # mid-session effect); the runtime must survive it — a lost steer
      # self-heals off the next init frame's observation.
      assert Process.alive?(recorder)

      DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, recorder)
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

    test "PIN: unknown session + BAD body is 404, not 400 (fetch-before-validate precedence)",
         %{admin: a1} do
      # The provider-aware validators need the session row first, so the
      # not-found oracle now outranks body shape. A tenant probing with garbage
      # bodies learns nothing it wouldn't learn from a valid one.
      for body <- [%{mode: "not-a-mode"}, %{bogus: 1}, %{draft: 123}] do
        conn =
          json_conn(a1)
          |> patch("/v1/chat/sessions/#{Ecto.UUID.generate()}", Jason.encode!(body))

        assert json_response(conn, 404)["error"]["code"] == "not_found", inspect(body)
      end
    end

    test "mode/model/effort validators consult the SESSION's provider, not hardcoded claude",
         %{admin: a1} do
      # A codex session (FakeCodexAdapter caps: modes default/read-only, models
      # gpt-5.6, efforts high) accepts its own vocabulary and rejects claude's.
      body =
        json_conn(a1)
        |> post("/v1/chat/sessions", Jason.encode!(%{provider: "codex"}))
        |> json_response(201)

      codex_sid = body["id"]

      # codex's own vocabulary validates (model_choice "gpt-5.6" was a 400
      # under the old hardcoded-claude validator) and persists. The mode axis
      # uses "default" — the value both FakeCodex advertises and the store
      # persists (Session.persistable_modes/0 gates persistence separately).
      ok =
        json_conn(a1)
        |> patch(
          "/v1/chat/sessions/#{codex_sid}",
          Jason.encode!(%{mode: "default", model_choice: "gpt-5.6", effort_choice: "high"})
        )
        |> json_response(200)

      assert ok["mode"] == "default"
      assert ok["model_choice"] == "gpt-5.6"
      assert ok["effort_choice"] == "high"

      # claude vocabulary is INVALID on a codex session…
      for body <- [%{mode: "acceptEdits"}, %{model_choice: "sonnet"}, %{effort_choice: "max"}] do
        conn = json_conn(a1) |> patch("/v1/chat/sessions/#{codex_sid}", Jason.encode!(body))
        assert json_response(conn, 400)["error"]["code"] == "invalid_request", inspect(body)
      end
    end

    test "codex vocabulary stays invalid on a claude session", %{admin: a1, sid: sid} do
      for body <- [%{mode: "read-only"}, %{model_choice: "gpt-5.6"}] do
        conn = json_conn(a1) |> patch("/v1/chat/sessions/#{sid}", Jason.encode!(body))
        assert json_response(conn, 400)["error"]["code"] == "invalid_request", inspect(body)
      end
    end

    test "a model_choice PATCH with a LIVE runtime steers set_model on CHANGE only (steer parity)",
         %{admin: a1, sid: sid} do
      {:ok, recorder} =
        Barkpark.StudioChat.Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})

      # The cat fake echoes our outbound set_model control_request straight
      # back; ClaudeChat answers the echo with an error control_response whose
      # request_id matches the one we minted, so the ack surfaces on the topic
      # as a typed {:claude_chat_control, :set_model, …} — observable proof the
      # steer actually went out over the wire.
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))

      assert json_conn(a1)
             |> patch("/v1/chat/sessions/#{sid}", Jason.encode!(%{model_choice: "sonnet"}))
             |> json_response(200)

      assert_receive {:claude_chat_control, :set_model, _rid, _resp}, 2_000

      # The echo PATCH (same value — the TUI leave-PATCH shape): change-guard
      # suppresses the steer entirely.
      assert json_conn(a1)
             |> patch("/v1/chat/sessions/#{sid}", Jason.encode!(%{model_choice: "sonnet"}))
             |> json_response(200)

      refute_receive {:claude_chat_control, :set_model, _rid, _resp}, 300

      assert Process.alive?(recorder)
      DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, recorder)
    end

    test "an effort_choice PATCH with a LIVE runtime persists and the runtime survives the steer",
         %{admin: a1, sid: sid} do
      # claude's adapter has no effort steer axis ({:error, {:unsupported_steer,
      # _}} — swallowed); the honest bar here is the mode-steer test's: persisted
      # choice + a runtime that survives the attempt.
      {:ok, recorder} =
        Barkpark.StudioChat.Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})

      body =
        json_conn(a1)
        |> patch("/v1/chat/sessions/#{sid}", Jason.encode!(%{effort_choice: "high"}))
        |> json_response(200)

      assert body["effort_choice"] == "high"
      assert Process.alive?(recorder)
      DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, recorder)
    end

    test "model_choice/effort_choice PATCH with NO live Recorder is fail-soft — persist only",
         %{admin: a1, sid: sid} do
      assert Barkpark.StudioChat.Recorder.whereis(sid) == nil

      body =
        json_conn(a1)
        |> patch(
          "/v1/chat/sessions/#{sid}",
          Jason.encode!(%{model_choice: "opus", effort_choice: "low"})
        )
        |> json_response(200)

      assert body["model_choice"] == "opus"
      assert body["effort_choice"] == "low"
    end
  end

  # ── archive/unarchive: the shelf flips (charter D28) ────────────────────────

  describe "POST /sessions/:id/{archive,unarchive} — archive shelf flips (D28)" do
    test "archive → 200 {session} with archived_at; unarchive clears it; both idempotent",
         %{admin: a1, sid: sid} do
      body = json_conn(a1) |> post("/v1/chat/sessions/#{sid}/archive", "") |> json_response(200)
      assert body["id"] == sid
      assert body["archived_at"] != nil

      # Idempotent: re-archiving is a 200 (the stamp refreshes), never an error.
      again = json_conn(a1) |> post("/v1/chat/sessions/#{sid}/archive", "") |> json_response(200)
      assert again["archived_at"] != nil

      back = json_conn(a1) |> post("/v1/chat/sessions/#{sid}/unarchive", "") |> json_response(200)
      assert back["id"] == sid
      assert back["archived_at"] == nil

      # Idempotent the other way too.
      still =
        json_conn(a1) |> post("/v1/chat/sessions/#{sid}/unarchive", "") |> json_response(200)

      assert still["archived_at"] == nil
    end

    test "archiving moves the session between the two list sides", %{admin: a1, sid: sid} do
      json_conn(a1) |> post("/v1/chat/sessions/#{sid}/archive", "") |> json_response(200)

      active = json_conn(a1) |> get("/v1/chat/sessions") |> json_response(200)
      refute sid in Enum.map(active["sessions"], & &1["id"])

      shelf = json_conn(a1) |> get("/v1/chat/sessions?archived=true") |> json_response(200)
      assert sid in Enum.map(shelf["sessions"], & &1["id"])
    end

    test "a missing/non-UUID id joins the not-found oracle on both verbs", %{admin: a1} do
      for verb <- ["archive", "unarchive"] do
        conn = json_conn(a1) |> post("/v1/chat/sessions/#{Ecto.UUID.generate()}/#{verb}", "")
        assert json_response(conn, 404)["error"]["code"] == "not_found", verb

        conn2 = json_conn(a1) |> post("/v1/chat/sessions/not-a-uuid/#{verb}", "")
        assert json_response(conn2, 404)["error"]["code"] == "not_found", verb
      end
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

    # D140 — the API path persists the caller's OWN turn as an organic role:"user"
    # row (the LiveView composer does its own; the API path had zero append sites,
    # leaving channel/bridge sessions with assistant-only replay history).
    test "a send persists an organic role:\"user\" row with the submitted content (zero pre-seeding)",
         %{admin: a1, sid: sid} do
      # A genuinely fresh session — no manual pre-seeding (contrast :470/:503/:955).
      assert StudioChat.list_messages(sid) == []
      assert StudioChat.get_session(sid).message_count == 0

      json_conn(a1)
      |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(%{content: "organic hello"}))
      |> json_response(202)

      user_rows = for m <- StudioChat.list_messages(sid), m.role == "user", do: m

      assert match?([_], user_rows),
             "exactly one organic user row (no double-write), got #{inspect(user_rows)}"

      [row] = user_rows
      assert row.source_markdown == "organic hello"
      assert row.metadata["origin"] == "api"
    end

    test "turn 1 on a fresh session dispatches resume?=false — the append lands AFTER derivation",
         %{admin: a1, sid: sid} do
      # ensure_and_send derives `resume? = (session.message_count || 0) > 0` from the
      # struct captured at controller entry. On a fresh session that count is 0, so
      # turn 1 is resume?=false. The user-row append runs strictly AFTER dispatch, so
      # it cannot retroactively flip turn 1 — but it DOES advance message_count to 1,
      # which is exactly the resume-state a subsequent turn 2 would (correctly) read.
      assert StudioChat.get_session(sid).message_count == 0, "precondition: fresh ⇒ resume-false"

      json_conn(a1)
      |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(%{content: "turn one"}))
      |> json_response(202)

      # The append advanced the count to exactly 1 — proving it ran (post-dispatch),
      # once, without pre-empting turn-1's zero-valued derivation.
      assert StudioChat.get_session(sid).message_count == 1
      assert [%{role: "user", source_markdown: "turn one"}] = StudioChat.list_messages(sid)
    end
  end

  # ── D26: the send-failure reason split ──────────────────────────────────────

  defmodule NilSessionRecorderStub do
    @moduledoc false
    # Claims a session's Recorder registry name and answers :session_pid with
    # {:ok, nil} — the exact reply a Recorder whose provider runtime is gone
    # gives (session_pid/1 has NO failure branch). ensure/1 resolves to this
    # stub via its {:already_started, pid} branch, so the controller walks the
    # REAL path into the nil-session guard.
    use GenServer

    def start_link(sid) do
      GenServer.start_link(__MODULE__, nil,
        name: {:via, Registry, {Barkpark.StudioChat.RecorderRegistry, sid}}
      )
    end

    @impl true
    def init(_), do: {:ok, nil}

    @impl true
    def handle_call(:session_pid, _from, state), do: {:reply, {:ok, nil}, state}
  end

  # The classification seam (ChatController.send_failure_response/2 — public
  # per the exit-reason-mapping convention): one assertion per allowlist leg.
  defp split(reason) do
    conn = ChatController.send_failure_response(build_conn(), reason)

    {conn.status, Jason.decode!(conn.resp_body)["error"],
     Plug.Conn.get_resp_header(conn, "retry-after")}
  end

  describe "send failures split by reason (charter D26)" do
    test "capacity leg: 503 runtime_capacity + Retry-After" do
      for reason <- [{:managed_runtime_capacity, 3}, :admission_registration_conflict] do
        {status, error, retry_after} = split(reason)
        assert status == 503, inspect(reason)
        assert error["code"] == "runtime_capacity", inspect(reason)
        assert [seconds] = retry_after
        assert String.to_integer(seconds) > 0
      end
    end

    test "unavailable leg: 503 runtime_unavailable, no Retry-After" do
      for reason <- [
            {:not_running, :noproc},
            :port_closed,
            :no_port,
            {:app_server_exit, 1},
            :runtime_session_missing
          ] do
        {status, error, retry_after} = split(reason)
        assert status == 503, inspect(reason)
        assert error["code"] == "runtime_unavailable", inspect(reason)
        assert retry_after == [], inspect(reason)
      end
    end

    test "unsupported leg: 422 chat_unsupported (permanent — a 503 would retry forever)" do
      for reason <- [
            {:provider_not_ready, "codex"},
            {:provider_protocol_incompatible, "codex"},
            {:unsupported_runtime_operation, :steer},
            {:missing_runtime_contract, :port}
          ] do
        {status, error, _} = split(reason)
        assert status == 422, inspect(reason)
        assert error["code"] == "chat_unsupported", inspect(reason)
      end
    end

    test "opaque fallback: an unknown reason (raw exception struct) is 503 with NO interpolation" do
      # safe_command's rescue leg can surface raw exception structs — the wire
      # message must never echo them (information leak).
      leaky = %RuntimeError{message: "SECRET-/opt/barkpark/private-path"}
      {status, error, _} = split({:unexpected, leaky})

      assert status == 503
      assert error["code"] == "runtime_unavailable"
      refute error["message"] =~ "SECRET"
      refute inspect(error) =~ "SECRET"
    end

    test "E2E capacity: a full admission pool answers 503 runtime_capacity + Retry-After",
         %{admin: a1, sid: sid} do
      prev = Application.get_env(:barkpark, Barkpark.StudioChat.RuntimeAdmission)

      Application.put_env(:barkpark, Barkpark.StudioChat.RuntimeAdmission,
        max_managed_runtimes: 1
      )

      on_exit(fn ->
        if prev,
          do: Application.put_env(:barkpark, Barkpark.StudioChat.RuntimeAdmission, prev),
          else: Application.delete_env(:barkpark, Barkpark.StudioChat.RuntimeAdmission)
      end)

      # Fill the single slot with a live cat runtime on another session…
      {:ok, other} =
        StudioChat.create_session(%{
          id: Ecto.UUID.generate(),
          cwd: ClaudeChat.cwd(),
          mode: "plan"
        })

      {:ok, recorder} =
        Barkpark.StudioChat.Recorder.ensure(%{session_id: other.id, mode: "plan", resume: false})

      # …then a send on OUR session has no slot: deterministic backpressure.
      conn =
        json_conn(a1)
        |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(%{content: "hello"}))

      body = json_response(conn, 503)
      assert body["error"]["code"] == "runtime_capacity"
      assert [_seconds] = Plug.Conn.get_resp_header(conn, "retry-after")

      DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, recorder)
    end

    test "E2E unavailable: a spawn failure is an OPAQUE 503 runtime_unavailable",
         %{admin: a1, sid: sid} do
      prev = Application.get_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :claude_chat,
        enabled: true,
        command: {"/nonexistent-bp-e2e", []}
      )

      on_exit(fn ->
        if prev,
          do: Application.put_env(:barkpark, :claude_chat, prev),
          else: Application.delete_env(:barkpark, :claude_chat)
      end)

      conn =
        json_conn(a1)
        |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(%{content: "hello"}))

      body = json_response(conn, 503)
      assert body["error"]["code"] == "runtime_unavailable"
      # Opacity: the internal reason term never reaches the wire.
      refute inspect(body) =~ "nonexistent-bp-e2e"
      refute inspect(body) =~ "binary_not_found"
    end

    test "E2E nil-session guard: a Recorder with NO live runtime session is 503, never 500",
         %{admin: a1, sid: sid} do
      # Claim sid's Recorder name with the stub; ensure/1 adopts it via
      # {:already_started, pid} and session_pid/1 answers {:ok, nil} — the
      # runtime-gone shape that used to FunctionClauseError → 500 in the
      # is_pid-guarded adapter send.
      {:ok, stub} = NilSessionRecorderStub.start_link(sid)

      conn =
        json_conn(a1)
        |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(%{content: "hello"}))

      body = json_response(conn, 503)
      assert body["error"]["code"] == "runtime_unavailable"

      GenServer.stop(stub)
    end

    test "PATCH steer nil-session guard: a runtime-gone Recorder is fail-soft persist-only, never 500",
         %{admin: a1, sid: sid} do
      # Same runtime-gone shape as above, but on the PATCH steer path: the
      # three steer blocks (mode/model_choice/effort_choice) must treat
      # {:ok, nil} from session_pid/1 like an absent Recorder — persist the
      # choice, skip the steer. Unguarded, nil flowed into the is_pid-guarded
      # adapter (ClaudeChat.set_model/set_permission_mode) → FunctionClauseError
      # → 500 while the persisted value had ALREADY landed.
      {:ok, stub} = NilSessionRecorderStub.start_link(sid)

      body =
        json_conn(a1)
        |> patch(
          "/v1/chat/sessions/#{sid}",
          Jason.encode!(%{mode: "acceptEdits", model_choice: "opus", effort_choice: "low"})
        )
        |> json_response(200)

      assert body["mode"] == "acceptEdits"
      assert body["model_choice"] == "opus"
      assert body["effort_choice"] == "low"

      GenServer.stop(stub)
    end

    test "create-failure code is distinct: chat_unavailable is fully retired from the wire" do
      # The two legacy chat_unavailable emitters are gone (grep-proven in the
      # slice evidence): the create branch now answers chat_create_failed and
      # the send branch answers the D26 split codes. Pin the send seam never
      # re-grows the legacy code for any allowlisted reason.
      for reason <- [
            {:managed_runtime_capacity, 3},
            :port_closed,
            {:provider_not_ready, "codex"},
            :some_unknown_reason
          ] do
        {_status, error, _} = split(reason)
        refute error["code"] == "chat_unavailable", inspect(reason)
      end
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

    # A pending needs-you row of ANY role (approval | question | plan). The
    # controller flip (StudioChat.update_approval_status) is role-agnostic across
    # @needs_you_roles, so a POST /approval must resolve a question/plan card exactly
    # like a tool approval (charter D31).
    defp pending_needs_you(sid, request_id, role) do
      {:ok, _} =
        StudioChat.append_message(StudioChat.get_session(sid), %{
          role: role,
          source_markdown: "Needs you: #{role} #{request_id}",
          metadata: %{
            "request_id" => request_id,
            "approval_status" => "pending"
          }
        })
    end

    test "a QUESTION-role card flips pending->allowed on a delivered allow (D31)", %{
      admin: a1,
      sid: sid
    } do
      pending_needs_you(sid, "q-1", "question")
      {:ok, _} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})

      assert json_conn(a1)
             |> post(
               "/v1/chat/sessions/#{sid}/approval",
               Jason.encode!(%{request_id: "q-1", decision: "allow"})
             )
             |> response(204)

      [message] = StudioChat.list_messages(sid)
      assert message.role == "question"
      assert message.metadata["approval_status"] == "allowed"
      assert StudioChat.get_session(sid).pending_approvals == 0
    end

    test "a PLAN-role card flips pending->denied on a delivered deny (D31)", %{
      admin: a1,
      sid: sid
    } do
      pending_needs_you(sid, "p-1", "plan")
      {:ok, _} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})

      assert json_conn(a1)
             |> post(
               "/v1/chat/sessions/#{sid}/approval",
               Jason.encode!(%{request_id: "p-1", decision: "deny"})
             )
             |> response(204)

      [message] = StudioChat.list_messages(sid)
      assert message.role == "plan"
      assert message.metadata["approval_status"] == "denied"
      assert StudioChat.get_session(sid).pending_approvals == 0
    end

    test "a non-:ok answer_approval (codex double-answer race) still 204s and flips — the seal is non-vacuous",
         %{admin: a1} do
      # DB provider is codex → FakeCodexAdapter.answer_approval/3 returns
      # {:error, :unknown_approval}. Before the soft-match this MatchError'd → 500;
      # the runtime ref is a live claude `cat` Recorder so the controller actually
      # reaches answer_approval (a no-live-runtime path would 204 vacuously).
      {:ok, session} =
        StudioChat.create_session(%{
          id: Ecto.UUID.generate(),
          cwd: ClaudeChat.cwd(),
          mode: "plan",
          provider: "codex"
        })

      sid = session.id
      pending_approval(sid, "req-codex")
      {:ok, _} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})

      assert json_conn(a1)
             |> post(
               "/v1/chat/sessions/#{sid}/approval",
               Jason.encode!(%{request_id: "req-codex", decision: "allow"})
             )
             |> response(204)

      [message] = StudioChat.list_messages(sid)
      assert message.metadata["approval_status"] == "allowed"
      assert StudioChat.get_session(sid).pending_approvals == 0
    end
  end

  # ── D49 adopted into the transport (ct-bl-plan-paper-parity) ────────────────
  #
  # Before this, a TUI-origin plan allow flipped the card on BOTH surfaces
  # (`update_approval_status` is role-agnostic) but published NO Paper: the
  # projection was a Studio-LiveView-only `defp` reading the socket's copy of the
  # plan. A colleague watching in Studio therefore saw the SAME approved plan
  # carry a different durable artifact depending on who clicked Allow. These
  # tests pin the convergence at the wire and the whole "publishes nothing"
  # contract around it.
  describe "POST /sessions/:id/approval — plan → Paper (studio-chat D49)" do
    @plan_md "# Ship the migration\n\nInventory, port, delete the shim."

    defp pending_plan(sid, request_id, input \\ %{"plan" => @plan_md}) do
      {:ok, _} =
        StudioChat.append_message(StudioChat.get_session(sid), %{
          role: "plan",
          source_markdown: @plan_md,
          metadata: %{
            "request_id" => request_id,
            "tool_name" => "ExitPlanMode",
            "input" => input,
            "approval_status" => "pending"
          }
        })
    end

    defp answer(raw, sid, request_id, decision) do
      json_conn(raw)
      |> post(
        "/v1/chat/sessions/#{sid}/approval",
        Jason.encode!(%{request_id: request_id, decision: decision})
      )
    end

    defp await(fun, tries \\ 100) do
      cond do
        fun.() -> :ok
        tries <= 0 -> flunk("condition never became true")
        true -> Process.sleep(20) && await(fun, tries - 1)
      end
    end

    defp settle, do: Process.sleep(150)

    defp paper_rows(slug) do
      Repo.all(
        from(d in Document,
          where: d.doc_id == ^slug and d.type == "paper" and d.dataset == ^@dataset
        )
      )
    end

    # EVERY plan paper in the (sandbox-isolated) dataset — a duplicate written
    # under a DIFFERENT slug is exactly what "one Paper per approved plan"
    # forbids, and a slug-keyed count cannot see it.
    defp all_plan_paper_ids do
      Repo.all(
        from(d in Document,
          where: like(d.doc_id, "chat-plan-%") and d.type == "paper" and d.dataset == ^@dataset,
          select: d.doc_id,
          order_by: d.doc_id
        )
      )
    end

    setup do
      ensure_default_scope!()
      :ok
    end

    test "a TUI-origin allow publishes the Paper and stamps paper_id/url on the shared row",
         %{admin: a1, sid: sid} do
      pending_plan(sid, "tui-plan")
      {:ok, _} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))

      assert answer(a1, sid, "tui-plan", "allow") |> response(204)

      slug = PlanPapers.slug_for(sid, "tui-plan")
      url = "/papers/#{slug}"

      # a REAL published paper at the deterministic slug — the row /papers/:slug serves
      await(fn ->
        match?(%{status: "published", type: "paper"}, Content.get_paper(slug, @dataset))
      end)

      # the SAME {:plan_paper, request_id, %{paper_id, paper_url}} frame the Studio
      # LiveView broadcasts, on the same session topic — a co-viewing Studio tab
      # grows its "→ published as Paper" link off a TUI-origin allow
      assert_receive {:plan_paper, "tui-plan", %{paper_id: ^slug, paper_url: ^url}}, 3_000

      await(fn ->
        m = StudioChat.get_needs_you_message(sid, "tui-plan")
        {m.metadata["paper_id"], m.metadata["paper_url"]} == {slug, url}
      end)

      # …and the card is resolved on that same row (the parity that already held)
      assert StudioChat.get_needs_you_message(sid, "tui-plan").metadata["approval_status"] ==
               "allowed"
    end

    test "TUI-origin and Studio-origin allows converge on ONE Paper — a repeat mints no duplicate",
         %{admin: a1, sid: sid} do
      pending_plan(sid, "conv-plan")
      {:ok, _} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})

      slug = PlanPapers.slug_for(sid, "conv-plan")

      # origin 1: the flat transport (TUI / bp / any HTTP client)
      assert answer(a1, sid, "conv-plan", "allow") |> response(204)
      await(fn -> paper_rows(slug) != [] end)

      # origin 2: the Studio LiveView, which delegates to the SAME seam with the
      # SAME two ids (`maybe_publish_plan/3` → `publish_approved_plan/3`). Its ask
      # is already terminal here, exactly as a second answer would find it.
      assert :ok == PlanPapers.publish_approved_plan(sid, "conv-plan", :allow)
      settle()

      # …and a third answer over the wire, for good measure
      assert answer(a1, sid, "conv-plan", "allow") |> response(204)
      settle()

      assert all_plan_paper_ids() == [slug],
             "three allows across both surfaces must converge on ONE Paper (under any slug)"

      m = StudioChat.get_needs_you_message(sid, "conv-plan")
      assert m.metadata["paper_id"] == slug
      assert m.metadata["paper_url"] == "/papers/#{slug}"
    end

    test "a deny on a plan publishes nothing", %{admin: a1, sid: sid} do
      pending_plan(sid, "deny-plan")
      {:ok, _} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})

      assert answer(a1, sid, "deny-plan", "deny") |> response(204)
      settle()

      assert Content.get_paper(PlanPapers.slug_for(sid, "deny-plan"), @dataset) == nil
      assert StudioChat.get_needs_you_message(sid, "deny-plan").metadata["paper_id"] == nil
    end

    test "an allow on an ordinary tool approval publishes nothing", %{admin: a1, sid: sid} do
      pending_approval(sid, "appr-nopaper")
      {:ok, _} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})

      assert answer(a1, sid, "appr-nopaper", "allow") |> response(204)
      settle()

      assert Content.get_paper(PlanPapers.slug_for(sid, "appr-nopaper"), @dataset) == nil
    end

    test "a blank plan and a provider-shaped ask with no input.plan publish nothing",
         %{admin: a1, sid: sid} do
      pending_plan(sid, "blank-plan", %{"plan" => "   \n  "})
      pending_plan(sid, "shaped-plan", %{"steps" => ["a", "b"]})
      {:ok, _} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})

      for rid <- ~w(blank-plan shaped-plan) do
        assert answer(a1, sid, rid, "allow") |> response(204)
      end

      settle()

      for rid <- ~w(blank-plan shaped-plan) do
        assert Content.get_paper(PlanPapers.slug_for(sid, rid), @dataset) == nil,
               "#{rid} must not produce a Paper"

        # the CARD still resolves — the missing document is not a failed approval
        assert StudioChat.get_needs_you_message(sid, rid).metadata["approval_status"] == "allowed"
      end
    end

    test "a foreign workspace is 404'd and publishes NOTHING" do
      # Workspace-bound CONNECTOR tokens (a :global admin keeps instance-wide
      # reach by D21, so it is the wrong instrument for a tenancy proof).
      ws_a = create_workspace!()
      ws_b = create_workspace!()
      raw_a = "chat-plan-conn-a-#{System.unique_integer([:positive])}"
      raw_b = "chat-plan-conn-b-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw_a, "plan-conn-a", @dataset, ["read", "chat"], ws_a.id)
      {:ok, _} = Auth.create_token(raw_b, "plan-conn-b", @dataset, ["read", "chat"], ws_b.id)

      # ws-A creates the session over the wire, so it is stamped owner ws-A
      owned =
        json_conn(raw_a) |> post("/v1/chat/sessions", Jason.encode!(%{})) |> json_response(201)

      sid = owned["id"]

      pending_plan(sid, "foreign-plan")
      {:ok, _} = Recorder.ensure(%{session_id: sid, mode: "plan", resume: false})

      assert answer(raw_b, sid, "foreign-plan", "allow") |> json_response(404)
      settle()

      assert Content.get_paper(PlanPapers.slug_for(sid, "foreign-plan"), @dataset) == nil,
             "a tenant that cannot see the session must not be able to mint its Paper"

      assert StudioChat.get_needs_you_message(sid, "foreign-plan").metadata["approval_status"] ==
               "pending"

      # the 404 is ISOLATION, not a dead seam: the OWNER's allow on the very same
      # row DOES publish — so the assertion above cannot pass vacuously
      assert answer(raw_a, sid, "foreign-plan", "allow") |> response(204)

      await(fn ->
        Content.get_paper(PlanPapers.slug_for(sid, "foreign-plan"), @dataset) != nil
      end)
    end
  end

  # ── POST /sessions/:id/answer — the AskUserQuestion answer contract ─────────
  #
  # ct-bl-question-updatedinput (charter D28's backlog, D22/D23-clean). The
  # engine could always carry `{:allow, updated_map}`; the gap was the wire, and
  # the wire is exactly where "let the caller send updatedInput" would have been
  # a hole. These tests pin the constrained shape: the caller SELECTS among
  # server-persisted labels, and the controller rebuilds updatedInput from the
  # STORED ask.

  describe "POST /sessions/:id/answer — constrained AskUserQuestion answers (ct-bl-question-updatedinput)" do
    @ask %{
      "questions" => [
        %{
          "question" => "Which color?",
          "header" => "Color",
          "options" => [
            %{"label" => "Blue", "description" => "the cold one"},
            %{"label" => "Red"}
          ]
        },
        %{
          "question" => "Which toppings?",
          "multiSelect" => true,
          "options" => [%{"label" => "Cheese"}, %{"label" => "Basil"}, %{"label" => "Olive"}]
        }
      ]
    }

    defp pending_question(sid, request_id, input \\ @ask) do
      {:ok, _} =
        StudioChat.append_message(StudioChat.get_session(sid), %{
          role: "question",
          source_markdown: "AskUserQuestion",
          metadata: %{
            "request_id" => request_id,
            "tool_name" => "AskUserQuestion",
            "input" => input,
            "approval_status" => "pending"
          }
        })
    end

    # A codex-provider session so FakeCodexAdapter observes the decision. It is
    # ALSO the non-:ok delivery leg: the adapter returns {:error, :unknown_approval}
    # and /answer must still 204 + flip, exactly as approval/2's D32 seal does.
    defp codex_session_with_question(request_id, input \\ @ask) do
      {:ok, session} =
        StudioChat.create_session(%{
          id: Ecto.UUID.generate(),
          cwd: ClaudeChat.cwd(),
          mode: "plan",
          provider: "codex"
        })

      pending_question(session.id, request_id, input)
      {:ok, _} = Recorder.ensure(%{session_id: session.id, mode: "plan", resume: false})
      session.id
    end

    setup do
      Application.put_env(:barkpark, :chat_answer_test_pid, self())
      on_exit(fn -> Application.delete_env(:barkpark, :chat_answer_test_pid) end)
      :ok
    end

    test "the runtime receives {:allow, SERVER-rebuilt updatedInput} — the caller's map is a selection, never the input",
         %{admin: a1} do
      sid = codex_session_with_question("q-answer")

      assert json_conn(a1)
             |> post(
               "/v1/chat/sessions/#{sid}/answer",
               Jason.encode!(%{request_id: "q-answer", answers: %{"Which color?" => "Blue"}})
             )
             |> response(204)

      assert_receive {:answered, "q-answer", {:allow, updated}}, 1_000

      # The WHOLE original ask is still there (the controller echoed the
      # server-held input, D22) with only `answers` stamped on.
      assert updated["questions"] == @ask["questions"]
      assert updated["answers"] == %{"Which color?" => "Blue"}

      [message] = StudioChat.list_messages(sid)
      assert message.metadata["approval_status"] == "allowed"
      assert StudioChat.get_session(sid).pending_approvals == 0
    end

    test "a multiSelect list is comma-joined exactly as the Studio form joins its chips",
         %{admin: a1} do
      sid = codex_session_with_question("q-multi")

      assert json_conn(a1)
             |> post(
               "/v1/chat/sessions/#{sid}/answer",
               Jason.encode!(%{
                 request_id: "q-multi",
                 answers: %{"Which toppings?" => ["Cheese", "Olive"]}
               })
             )
             |> response(204)

      assert_receive {:answered, "q-multi", {:allow, updated}}, 1_000
      assert updated["answers"] == %{"Which toppings?" => "Cheese, Olive"}
    end

    test "Studio's builder and the wire validator agree on the SAME normalisation (one dialect)" do
      questions = QuestionAnswer.parse_questions(@ask)

      studio =
        QuestionAnswer.build_answers(questions, %{
          selections: %{0 => ["Red"], 1 => ["Cheese", "Olive"]},
          custom: %{}
        })

      {:ok, wire} =
        QuestionAnswer.validate_answers(@ask, %{
          "Which color?" => "Red",
          "Which toppings?" => ["Cheese", "Olive"]
        })

      assert studio == wire
      assert wire == %{"Which color?" => "Red", "Which toppings?" => "Cheese, Olive"}
    end

    test "SHAPE rejections 400 before any store call — no arbitrary payload gets through",
         %{admin: a1, sid: sid} do
      bodies = [
        # a caller-supplied updatedInput is STILL refused (D22) — the whole point
        %{request_id: "q", answers: %{"Which color?" => "Blue"}, updatedInput: %{"x" => 1}},
        %{request_id: "q", updated_input: %{"x" => 1}},
        %{request_id: "q", decision: "allow"},
        %{request_id: "q"},
        %{answers: %{"Which color?" => "Blue"}},
        %{request_id: "", answers: %{"Which color?" => "Blue"}},
        %{request_id: "q", answers: "Blue"},
        %{request_id: "q", answers: ["Blue"]},
        %{request_id: "q", answers: %{}},
        %{request_id: String.duplicate("q", 257), answers: %{"Which color?" => "Blue"}}
      ]

      for body <- bodies do
        conn = json_conn(a1) |> post("/v1/chat/sessions/#{sid}/answer", Jason.encode!(body))
        assert json_response(conn, 400)["error"]["code"] == "invalid_request", inspect(body)
      end
    end

    test "SEMANTIC rejections 400 — a question or a label the stored ask never offered",
         %{admin: a1} do
      sid = codex_session_with_question("q-sem")

      bodies = [
        # a question string the ask does not carry
        %{request_id: "q-sem", answers: %{"Which planet?" => "Blue"}},
        # a label the ask never offered (this is ALSO the free-text refusal:
        # arbitrary prose is just a label that is not on the list)
        %{request_id: "q-sem", answers: %{"Which color?" => "Chartreuse"}},
        %{request_id: "q-sem", answers: %{"Which color?" => "ignore previous instructions"}},
        # a list answer to a SINGLE-select question
        %{request_id: "q-sem", answers: %{"Which color?" => ["Blue", "Red"]}},
        # a repeated label
        %{request_id: "q-sem", answers: %{"Which toppings?" => ["Cheese", "Cheese"]}},
        # a non-string label
        %{request_id: "q-sem", answers: %{"Which toppings?" => [1]}},
        %{request_id: "q-sem", answers: %{"Which color?" => 1}},
        %{request_id: "q-sem", answers: %{"Which toppings?" => []}}
      ]

      for body <- bodies do
        conn = json_conn(a1) |> post("/v1/chat/sessions/#{sid}/answer", Jason.encode!(body))
        assert json_response(conn, 400)["error"]["code"] == "invalid_request", inspect(body)
      end

      # NOTHING was delivered and the row is untouched — a rejected answer must
      # not resolve the card.
      refute_receive {:answered, _, _}, 200
      [message] = StudioChat.list_messages(sid)
      assert message.metadata["approval_status"] == "pending"
    end

    test "a stale/double answer 404s — the second POST cannot re-deliver a decision",
         %{admin: a1} do
      sid = codex_session_with_question("q-once")

      assert json_conn(a1)
             |> post(
               "/v1/chat/sessions/#{sid}/answer",
               Jason.encode!(%{request_id: "q-once", answers: %{"Which color?" => "Blue"}})
             )
             |> response(204)

      assert_receive {:answered, "q-once", {:allow, _}}, 1_000

      body =
        json_conn(a1)
        |> post(
          "/v1/chat/sessions/#{sid}/answer",
          Jason.encode!(%{request_id: "q-once", answers: %{"Which color?" => "Red"}})
        )
        |> json_response(404)

      assert body["error"]["code"] == "not_found"
      refute_receive {:answered, "q-once", _}, 200

      # The FIRST answer still stands — the replay changed nothing.
      [message] = StudioChat.list_messages(sid)
      assert message.metadata["approval_status"] == "allowed"
    end

    test "/answer is question-ONLY: an approval or plan row with the same request_id is a 404",
         %{admin: a1, sid: sid} do
      for role <- ["approval", "plan"] do
        rid = "nonq-#{role}"

        {:ok, _} =
          StudioChat.append_message(StudioChat.get_session(sid), %{
            role: role,
            source_markdown: "not a question",
            metadata: %{
              "request_id" => rid,
              "input" => @ask,
              "approval_status" => "pending"
            }
          })

        body =
          json_conn(a1)
          |> post(
            "/v1/chat/sessions/#{sid}/answer",
            Jason.encode!(%{request_id: rid, answers: %{"Which color?" => "Blue"}})
          )
          |> json_response(404)

        assert body["error"]["code"] == "not_found", role
      end

      # Both rows are still pending: /answer never touched them.
      for message <- StudioChat.list_messages(sid) do
        assert message.metadata["approval_status"] == "pending"
      end
    end

    test "an unknown request_id and an absent session both join the not-found oracle",
         %{admin: a1, sid: sid} do
      pending_question(sid, "q-real")

      for path <- [
            "/v1/chat/sessions/#{sid}/answer",
            "/v1/chat/sessions/#{Ecto.UUID.generate()}/answer"
          ] do
        assert json_conn(a1)
               |> post(
                 path,
                 Jason.encode!(%{request_id: "q-missing", answers: %{"Which color?" => "Blue"}})
               )
               |> json_response(404)
      end
    end

    test "a question row whose stored ask carries no questions cannot be answered", %{
      admin: a1,
      sid: sid
    } do
      pending_question(sid, "q-empty", %{"questions" => []})

      assert json_conn(a1)
             |> post(
               "/v1/chat/sessions/#{sid}/answer",
               Jason.encode!(%{request_id: "q-empty", answers: %{"Which color?" => "Blue"}})
             )
             |> json_response(400)
    end

    test "without a live runtime the answer is a 204 that still flips the row", %{
      admin: a1,
      sid: sid
    } do
      pending_question(sid, "q-noruntime")

      assert json_conn(a1)
             |> post(
               "/v1/chat/sessions/#{sid}/answer",
               Jason.encode!(%{request_id: "q-noruntime", answers: %{"Which color?" => "Blue"}})
             )
             |> response(204)

      [message] = StudioChat.list_messages(sid)
      assert message.metadata["approval_status"] == "allowed"
      assert StudioChat.get_session(sid).pending_approvals == 0
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

    test "task frame is the compact transition JSON with NO SSE id (tlv)" do
      # A live ledger transition (tlv-bl-chat-live-transition-stream): id-less
      # like chat/workflow/permission/exit, so it is never a Last-Event-ID
      # resume cursor. Its OWN `event_id` field is the reducer's dedupe key —
      # a payload field, deliberately NOT the SSE frame id.
      transition = %{
        event_id: "ev-9",
        task_id: "task-tlv-1",
        title: "Sweep the yard",
        status: "done",
        mutation: "task.closed",
        verb: "closed",
        label: "Sweep the yard → done (closed)"
      }

      frame = ChatController.sse_task_frame(transition)
      assert String.starts_with?(frame, "event: task\ndata: ")
      assert String.ends_with?(frame, "\n\n")
      refute frame =~ "id:"

      data =
        frame
        |> String.split("data: ", parts: 2)
        |> List.last()
        |> String.trim()
        |> Jason.decode!()

      assert data == %{
               "event_id" => "ev-9",
               "task_id" => "task-tlv-1",
               "title" => "Sweep the yard",
               "status" => "done",
               "mutation" => "task.closed",
               "verb" => "closed",
               "label" => "Sweep the yard → done (closed)"
             }
    end

    test "workflow frame is the compact summary JSON with NO id (live delta, D23)" do
      # The COMPACT workflow_summary map, byte-identical to the list wire; a live
      # delta like chat/permission/exit — unreplayable, so NO `id:` seq.
      summary = %{label: "run", agents_done: 1, agents_total: 3, running: 2, terminal?: false}
      frame = ChatController.sse_workflow_frame(summary)
      assert String.starts_with?(frame, "event: workflow\ndata: ")
      assert String.ends_with?(frame, "\n\n")
      refute frame =~ "id:"

      data =
        frame
        |> String.split("data: ", parts: 2)
        |> List.last()
        |> String.trim()
        |> Jason.decode!()

      assert data == %{
               "label" => "run",
               "agents_done" => 1,
               "agents_total" => 3,
               "running" => 2,
               "terminal?" => false
             }
    end

    test "title frame is EXACTLY {session_id, title}, with NO id (ct-bl-recorder-titles)" do
      frame = ChatController.sse_title_frame("sess-42", "Fix the flaky login test")
      assert String.starts_with?(frame, "event: title\ndata: ")
      assert String.ends_with?(frame, "\n\n")
      # Unreplayable like every other live delta (D5) — a reconnect re-reads the
      # persisted title off GET session, it never resumes a title frame.
      refute frame =~ "id:"

      data =
        frame
        |> String.split("data: ", parts: 2)
        |> List.last()
        |> String.trim()
        |> Jason.decode!()

      # D23: session identity + the settled title, and NOTHING else. The map is
      # asserted whole, so a later "helpful" addition (cwd, argv, a stderr tail,
      # the session struct) fails here rather than shipping to every client.
      assert data == %{"session_id" => "sess-42", "title" => "Fix the flaky login test"}
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

    test "a Recorder title broadcast reaches the stream process (ct-bl-recorder-titles)" do
      # The end-to-end wiring the SSE loop needs, proven at the seam the loop is
      # assertable at: `Recorder.broadcast_title/2` publishes on the SESSION
      # topic, and the forwarder — subscribed to that topic and nothing else
      # (D24) — hands the tuple to the connection process, whose stream_loop
      # clause serializes it with sse_title_frame/2 (shape asserted above).
      sid = Ecto.UUID.generate()
      fwd = ChatController.start_forwarder(Recorder.topic(sid), self())

      Recorder.broadcast_title(sid, "Pushed to a headless client")
      assert_receive {:chat_title, ^sid, "Pushed to a headless client"}, 500

      send(fwd, :stop)
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

  # ── J. GET /v1/chat/rollup — the workspace fleet rollup (herd D64h) ─────────

  describe "GET /v1/chat/rollup" do
    test "auth runs first: missing bearer 401, non-admin reader 403", %{reader: reader} do
      assert build_conn() |> get("/v1/chat/rollup") |> json_response(401)
      assert json_conn(reader) |> get("/v1/chat/rollup") |> json_response(403)
    end

    test "admin sees the four-key counts + precedence shape over the whole herd",
         %{admin: admin} do
      body = json_conn(admin) |> get("/v1/chat/rollup") |> json_response(200)

      assert %{"counts" => counts, "precedence" => precedence} = body
      assert Map.keys(counts) |> Enum.sort() == ["blocked", "idle", "unknown", "working"]
      assert precedence in ["blocked", "working", "idle", "unknown"]
      # The setup session (default agent_state "idle") is in the :global herd.
      assert counts["idle"] >= 1
    end

    test "a workspace connector's rollup is DB-scoped — another tenant's blocked session never leaks",
         %{admin: admin} do
      ws_a = create_workspace!()
      ws_b = create_workspace!()
      conn_a_raw = "chat-rollup-a-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(conn_a_raw, "rollup-a", @dataset, ["read", "chat"], ws_a.id)

      # ws-A owns one working session; ws-B owns one BLOCKED session. If the
      # scope filter leaked, ws-A's precedence would flip to "blocked".
      {:ok, a_sess} =
        StudioChat.create_session(%{id: Ecto.UUID.generate()}, {:workspace, ws_a.id})

      {:ok, b_sess} =
        StudioChat.create_session(%{id: Ecto.UUID.generate()}, {:workspace, ws_b.id})

      StudioChat.set_agent_state(a_sess.id, "working", :derived)

      # D80h: the blocked flip carries its :ask corroboration — a real pending
      # ask row for ws-B's session first, then the guarded write.
      {:ok, _} =
        StudioChat.append_message(b_sess.id, %{
          role: "approval",
          metadata: %{"request_id" => "ru-b-1", "approval_status" => "pending"}
        })

      {1, _} = StudioChat.set_agent_state(b_sess.id, "blocked", :ask)

      body = json_conn(conn_a_raw) |> get("/v1/chat/rollup") |> json_response(200)

      assert body == %{
               "counts" => %{"working" => 1, "blocked" => 0, "idle" => 0, "unknown" => 0},
               "precedence" => "working"
             }

      # The :global admin still sees both tenants' rows (D21 authority unchanged).
      global = json_conn(admin) |> get("/v1/chat/rollup") |> json_response(200)
      assert global["counts"]["blocked"] >= 1
      assert global["precedence"] == "blocked"
    end
  end

  # dispatch a request by method atom (the auth matrix iterates method+path).
  defp dispatch(conn, :get, path), do: get(conn, path)
  defp dispatch(conn, :post, path), do: post(conn, path, "")
  defp dispatch(conn, :patch, path), do: patch(conn, path, "")
end
