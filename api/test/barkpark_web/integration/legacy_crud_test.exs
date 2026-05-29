defmodule BarkparkWeb.Integration.LegacyCrudTest do
  @moduledoc """
  Integration probe for the `/api/documents/*` legacy CRUD surface (Goal
  `barkpark-b1m`, Task `barkpark-upn`, gap #5).

  Pre-s7 coverage: zero for the CRUD endpoints. The only legacy test —
  `legacy_headers_test.exs` (10 LOC) — smokes the Deprecation header on
  `GET /api/schemas` only. The four `/api/documents/*` actions back the Go
  TUI's backward-compat path and are completely untested today.

  This file pins:

    * `GET /api/documents/:type` → 200 + JSON list + `Deprecation`/`Sunset`/`Link`
    * `GET /api/documents/:type/:id` → 200 + JSON doc + headers
    * `POST /api/documents/:type` → 201 + creates + headers
    * `DELETE /api/documents/:type/:id` → 200 + removes + headers
    * `GET /api/documents/<unknown-type>` → documents the actual behaviour
      (likely 200 + empty list, per the unexpected finding in the gap
      analysis — this is intentionally captured as a contract test pinning
      the observed behaviour; an audit-time decision will follow in s8)

  `LegacyController` hard-codes `@dataset "production"`, so all docs in this
  file land in `production`. `on_exit` cleans them up so the dev DB isn't
  polluted.

  `async: false` because the test mutates the shared `production` dataset
  and the dev token; tests in the suite that touch the same surface
  follow the same pattern.
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content}

  @token "barkpark-dev-token"
  @type_name "post"

  setup do
    Auth.create_token(@token, "dev", "legacy-crud-integration", ["read", "write", "admin"])

    # Drain the boot-time codelist seeder Task before grabbing the DB —
    # otherwise it can hog the sandbox connection and our setup blows up.
    drain_task_supervisor(30_000)

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => @type_name, "title" => "Post", "visibility" => "public", "fields" => []},
        "production"
      )

    # DB rows are rolled back by the SQL sandbox — no manual cleanup needed.
    :ok
  end

  defp drain_task_supervisor(deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_drain(deadline)
  end

  defp do_drain(deadline) do
    case Task.Supervisor.children(Barkpark.TaskSupervisor) do
      [] ->
        :ok

      _children ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(50)
          do_drain(deadline)
        end
    end
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp assert_legacy_headers(resp) do
    assert get_resp_header(resp, "deprecation") == ["true"]
    assert get_resp_header(resp, "sunset") == ["Wed, 31 Dec 2026 23:59:59 GMT"]
    refute get_resp_header(resp, "link") == []
  end

  # ── Tests ──────────────────────────────────────────────────────────────

  describe "GET /api/documents/:type" do
    test "without auth → 401 (legacy now requires a token, w1.5-E)", %{conn: conn} do
      # Wave 1.5-E (Goal barkpark-qprk): the legacy `/api/documents/*` surface
      # was UNAUTHENTICATED + UNSCOPED — a tenancy hole. It now sits behind
      # `:require_token`; an anonymous read is rejected with 401.
      {:ok, _} =
        Content.create_document(@type_name, %{"_id" => "lc-list-1", "title" => "L1"}, "production")

      resp = get(conn, ~p"/api/documents/#{@type_name}")

      assert resp.status == 401
    end

    test "with auth → 200 + JSON list + deprecation headers", %{conn: conn} do
      {:ok, _} =
        Content.create_document(@type_name, %{"_id" => "lc-list-2", "title" => "L2"}, "production")

      resp = conn |> authed() |> get(~p"/api/documents/#{@type_name}")

      assert resp.status == 200
      assert_legacy_headers(resp)

      body = json_response(resp, 200)
      assert body["type"] == @type_name
      assert is_list(body["documents"])
      assert is_integer(body["count"])
      assert Enum.any?(body["documents"], &(&1["id"] == "drafts.lc-list-2"))
    end

    test "unknown type — documents actual behaviour (200 + empty list, authed)", %{conn: conn} do
      # Known/deliberate behaviour: the surface answers 200+empty
      # rather than 404 for unknown types. Pinning the observed value here makes
      # any drift loud. Now requires auth (w1.5-E) — anonymous would 401.
      resp = conn |> authed() |> get(~p"/api/documents/nosuchtype")
      assert resp.status == 200
      assert_legacy_headers(resp)

      body = json_response(resp, 200)
      assert body["type"] == "nosuchtype"
      assert body["documents"] == []
      assert body["count"] == 0
    end
  end

  describe "GET /api/documents/:type/:id" do
    test "returns the legacy doc shape + headers for an existing draft", %{conn: conn} do
      {:ok, _} =
        Content.create_document(@type_name, %{"_id" => "lc-show-1", "title" => "S1"}, "production")

      resp = conn |> authed() |> get(~p"/api/documents/#{@type_name}/drafts.lc-show-1")
      assert resp.status == 200
      assert_legacy_headers(resp)

      body = json_response(resp, 200)
      assert body["id"] == "drafts.lc-show-1"
      assert body["title"] == "S1"
    end

    test "unknown id → 404 + headers still injected", %{conn: conn} do
      resp = conn |> authed() |> get(~p"/api/documents/#{@type_name}/does-not-exist")
      assert resp.status == 404
      assert_legacy_headers(resp)
    end
  end

  describe "POST /api/documents/:type" do
    test "creates the doc and returns 201 + headers", %{conn: conn} do
      body = Jason.encode!(%{"id" => "lc-create-1", "title" => "New", "status" => "draft"})

      resp =
        conn
        |> authed()
        |> post(~p"/api/documents/#{@type_name}", body)

      assert resp.status == 201
      assert_legacy_headers(resp)

      parsed = json_response(resp, 201)
      assert parsed["title"] == "New"

      # Persistence — Content.upsert_document writes `drafts.lc-create-1`.
      assert {:ok, _} = Content.get_document("drafts.lc-create-1", @type_name, "production")
    end
  end

  describe "DELETE /api/documents/:type/:id" do
    test "removes the doc and returns 200 + headers", %{conn: conn} do
      {:ok, _} =
        Content.create_document(@type_name, %{"_id" => "lc-del-1", "title" => "D1"}, "production")

      resp =
        conn
        |> authed()
        |> delete(~p"/api/documents/#{@type_name}/drafts.lc-del-1")

      assert resp.status == 200
      assert_legacy_headers(resp)
      assert %{"deleted" => "drafts.lc-del-1"} = json_response(resp, 200)

      assert {:error, :not_found} =
               Content.get_document("drafts.lc-del-1", @type_name, "production")
    end
  end

  # ── Tenancy: Default-scope isolation (w1.5-E, Goal barkpark-qprk) ────────
  #
  # The legacy surface assigns the seeded Default workspace via the `:api`
  # pipeline's `AssignDefaultScope` and threads `scope_opts(conn)` into the
  # Content reads. A token-authed read must therefore return ONLY Default-scope
  # docs — a row stamped to a different (non-Default) workspace must not leak.
  describe "tenancy scope" do
    test "authed list returns only Default-scope docs, never workspace-A's", %{conn: conn} do
      {default_ws, default_proj} = ensure_default_scope!()

      # A doc in a DIFFERENT workspace, same (type, dataset) leaf as Default.
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)

      {:ok, _other} =
        Content.create_document(
          @type_name,
          %{"_id" => "lc-ten-otherws", "title" => "OtherWS"},
          "production",
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      # A doc explicitly in Default — the row the legacy read SHOULD surface.
      {:ok, _mine} =
        Content.create_document(
          @type_name,
          %{"_id" => "lc-ten-default", "title" => "Default"},
          "production",
          workspace_id: default_ws.id,
          project_id: default_proj.id
        )

      body =
        conn
        |> authed()
        |> get(~p"/api/documents/#{@type_name}")
        |> json_response(200)

      ids = Enum.map(body["documents"], & &1["id"])

      assert "drafts.lc-ten-default" in ids,
             "expected the Default-scope doc to be visible, got #{inspect(ids)}"

      refute "drafts.lc-ten-otherws" in ids,
             "CROSS-WORKSPACE LEAK: workspace-A's doc leaked into the Default-scoped legacy read"
    end
  end
end
