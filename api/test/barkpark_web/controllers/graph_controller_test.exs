defmodule BarkparkWeb.GraphControllerTest do
  @moduledoc """
  Goal ges/graph-edge-seam Phase 4 — contract tests for the `/v1/graph/*`
  surface (`graph_show`, `graph_orphans`, `graph_dangling` on
  `BarkparkWeb.TasksController`).

  The headline test is the ROUTE-PRESENCE assertion: `GET /v1/graph/<id>` MUST
  NOT 404. Because `register_routes/1` is read at MACRO EXPANSION via
  `Registry.collect_routes/1`, a STALE router beam yields a 404 identical to a
  missing route. This test is the trip-wire that catches a future stale beam —
  the Phase-4 verify recipe nukes the test router beam before compiling
  precisely so this passes.

    * route presence: GET /v1/graph/<id> is NOT 404 (the stale-beam guard).
    * graph_show roots on a NON-task content doc (gap #4 generic root).
    * graph_show 404s for an unknown id.
    * graph_orphans returns 200 with an `orphans` list.
    * graph_dangling returns 200 with a `dangling` list.
    * auth: 401 without a token.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @token "barkpark-test-graph-token"
  @dataset "production"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-graph", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    # A plain non-task content schema so we prove graph_show roots on ANY type
    # (gap #4) — NOT just tasks.
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    %{scope: scope}
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp mk_post!(doc_id, scope) do
    {:ok, doc} =
      Content.create_document(
        "post",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => %{}},
        @dataset,
        scope
      )

    doc
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "auth gating" do
    test "GET /v1/graph/orphans returns 401 without a token", %{conn: conn} do
      resp = get(conn, "/v1/graph/orphans")
      assert resp.status == 401
    end
  end

  describe "route presence (stale-router-beam guard)" do
    test "GET /v1/graph/<id> is NOT 404 — the route is mounted", %{conn: conn, scope: scope} do
      doc_id = uniq("graph-route")
      _post = mk_post!(doc_id, scope)

      resp = conn |> authed() |> get("/v1/graph/#{doc_id}")

      # The CARDINAL assertion: a NET-NEW route read at macro-expansion is only
      # live if the router beam was recompiled. A stale beam → 404. We assert the
      # route resolves (200), which can ONLY happen if the route is mounted.
      refute resp.status == 404, "GET /v1/graph/:id 404ed — router beam is STALE (recompile required)"
      assert resp.status == 200
    end
  end

  describe "GET /v1/graph/:id" do
    test "roots on a NON-task content doc (gap #4 generic root)", %{conn: conn, scope: scope} do
      doc_id = uniq("graph-post")
      _post = mk_post!(doc_id, scope)

      resp = conn |> authed() |> get("/v1/graph/#{doc_id}")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      assert body["root"] == doc_id
      assert is_list(body["nodes"])
      assert is_list(body["edges"])
      assert is_list(body["dependents"])
      assert Map.has_key?(body, "truncated")
      assert Map.has_key?(body, "truncation_reason")
    end

    test "404s for an unknown id", %{conn: conn} do
      resp = conn |> authed() |> get("/v1/graph/no-such-doc-#{System.unique_integer([:positive])}")
      assert resp.status == 404
    end
  end

  describe "GET /v1/graph/orphans" do
    test "returns 200 with an orphans list", %{conn: conn, scope: scope} do
      _orphan = mk_post!(uniq("orphan"), scope)

      resp = conn |> authed() |> get("/v1/graph/orphans?dataset=#{@dataset}")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      assert is_list(body["orphans"])
    end
  end

  describe "GET /v1/graph/dangling" do
    test "returns 200 with a dangling list", %{conn: conn} do
      resp = conn |> authed() |> get("/v1/graph/dangling?dataset=#{@dataset}")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert body["ok"] == true
      assert is_list(body["dangling"])
    end
  end
end
