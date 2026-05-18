defmodule BarkparkWeb.Integration.LegacyCrudTest do
  @moduledoc """
  Integration probe for the `/api/documents/*` legacy CRUD surface (Goal
  `barkpark-b1m`, Task `barkpark-upn`, gap #5 from
  `tmp/api-gap-analysis.md`).

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
    test "without auth → 200 + JSON list + deprecation headers", %{conn: conn} do
      {:ok, _} =
        Content.create_document(@type_name, %{"_id" => "lc-list-1", "title" => "L1"}, "production")

      resp = get(conn, ~p"/api/documents/#{@type_name}")

      assert resp.status == 200
      assert_legacy_headers(resp)

      body = json_response(resp, 200)
      assert body["type"] == @type_name
      assert is_list(body["documents"])
      assert is_integer(body["count"])
      assert Enum.any?(body["documents"], &(&1["id"] == "drafts.lc-list-1"))
    end

    test "with auth → identical shape (the route is optional-auth)", %{conn: conn} do
      {:ok, _} =
        Content.create_document(@type_name, %{"_id" => "lc-list-2", "title" => "L2"}, "production")

      resp = conn |> authed() |> get(~p"/api/documents/#{@type_name}")
      assert resp.status == 200
      assert_legacy_headers(resp)
    end

    test "unknown type — documents actual behaviour (likely 200 + empty list)", %{conn: conn} do
      # Per `tmp/api-gap-analysis.md` finding 1, the public surface answers
      # 200+empty rather than 404 for unknown types. Pinning the observed
      # value here makes any drift loud; the policy decision lives in s8.
      resp = get(conn, ~p"/api/documents/nosuchtype")
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

      resp = get(conn, ~p"/api/documents/#{@type_name}/drafts.lc-show-1")
      assert resp.status == 200
      assert_legacy_headers(resp)

      body = json_response(resp, 200)
      assert body["id"] == "drafts.lc-show-1"
      assert body["title"] == "S1"
    end

    test "unknown id → 404 + headers still injected", %{conn: conn} do
      resp = get(conn, ~p"/api/documents/#{@type_name}/does-not-exist")
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
end
