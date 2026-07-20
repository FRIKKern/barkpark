defmodule BarkparkWeb.Integration.PublicReadEnforcementTest do
  @moduledoc """
  ROUTED enforcement of the `public-read` clamp (site-spawner charter D6).

  Unlike `BarkparkWeb.Plugs.PublicReadTest` — which calls `PublicRead.call/2`
  on a hand-built `%Plug.Conn{}` and therefore only proves the plug does the
  right thing IF it runs — this suite drives REAL requests through the router
  so it proves the plug is actually MOUNTED on the read pipelines and clamps a
  token minted `["public-read"]`.

  Two routes, one clamp:

    * SCOPED `/w/:ws/p/:project/v1/data/query|doc/...` (`:shared_docs_api`) —
      the route the site-spawner BUILD token fetches over. Workspace membership
      (ResolveWorkspace) is NECESSARY but not SUFFICIENT: it does not pin
      published-vs-draft, so a member public-read token could read drafts.
      PublicRead is the missing clamp.
    * FLAT `/v1/data/query|doc/...` (`:api_grant_read`).

  ## Fail-before (the leak this closes)

  `BarkparkWeb.Plugs.PublicRead` was written + unit-tested but mounted NOWHERE
  (`grep PublicRead router.ex` = 0 hits before this slice). Live-proven on
  guerrilla: a `public-read` token read `?perspective=drafts` and private-schema
  content byte-identical to an admin token, because `QueryController.authed?/1`
  is merely "a token is present" and the anonymous perspective guard EXEMPTS any
  token. With the mount removed, the `perspective=drafts` assertions below flip
  from 403 to 200 (drafts leak) and the private-schema assertions flip from
  404/403 to 200 — i.e. this suite fails closed only because the plug is mounted.
  Verified by temporarily deleting both `plug(...PublicRead)` lines: the
  drafts + private-schema cases returned 200 (leak reproduced), restoring them
  returns the suite to green.

  read/write/admin tokens are NOT clamped — PublicRead acts ONLY on a token
  whose permissions == `["public-read"]`; every other principal (and anonymous)
  passes through untouched. The `admin token is unaffected` cases prove that.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}

  import Barkpark.TenancyFixtures

  @dataset "production"

  # ── SCOPED route (the site-spawner BUILD fetch path) ──────────────────────
  describe "scoped route /w/:ws/p/:project — public-read token is clamped" do
    setup do
      ws = create_workspace!("spawn-ws")
      project = create_project!(ws, "spawn-proj")
      scope = [workspace_id: ws.id, project_id: project.id]

      # A PUBLIC type and a PRIVATE type in THIS workspace.
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
          @dataset,
          scope
        )

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "secret", "title" => "Secret", "visibility" => "private", "fields" => []},
          @dataset,
          scope
        )

      # A PUBLISHED post and a DRAFT-ONLY post: `drafts.d1` exists but the
      # published `d1` does not, so a drafts leak is observable.
      {:ok, _} =
        Content.create_document("post", %{"_id" => "p1", "title" => "Live"}, @dataset, scope)

      {:ok, _} = Content.publish_document("p1", "post", @dataset, scope)

      {:ok, _} =
        Content.create_document("post", %{"_id" => "d1", "title" => "Draft"}, @dataset, scope)

      raw = "site-build-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw, "site-spawner build", @dataset, ["public-read"], ws.id)

      %{ws: ws, project: project, token: raw}
    end

    defp scoped(ws, project, suffix),
      do: "/w/#{ws.slug}/p/#{project.slug}/v1/data/#{suffix}"

    defp authed(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

    test "reads published + public content (200) — the happy path stays open", %{
      conn: conn,
      ws: ws,
      project: project,
      token: token
    } do
      body =
        conn
        |> authed(token)
        |> get(scoped(ws, project, "query/#{@dataset}/post"))
        |> json_response(200)

      ids = body["result"]["documents"] |> Enum.map(& &1["_id"])
      assert "p1" in ids
      # published-only: the draft never appears even without asking for it.
      refute "d1" in ids
    end

    test "reads a published doc by id (200)", %{
      conn: conn,
      ws: ws,
      project: project,
      token: token
    } do
      body =
        conn
        |> authed(token)
        |> get(scoped(ws, project, "doc/#{@dataset}/post/p1"))
        |> json_response(200)

      assert body["result"]["_id"] == "p1"
    end

    test "?perspective=drafts is DENIED (403 perspective not allowed)", %{
      conn: conn,
      ws: ws,
      project: project,
      token: token
    } do
      body =
        conn
        |> authed(token)
        |> get(scoped(ws, project, "query/#{@dataset}/post?perspective=drafts"))
        |> json_response(403)

      assert body["error"] == "perspective not allowed"
    end

    test "?perspective=raw is DENIED (403)", %{conn: conn, ws: ws, project: project, token: token} do
      conn
      |> authed(token)
      |> get(scoped(ws, project, "query/#{@dataset}/post?perspective=raw"))
      |> json_response(403)
    end

    test "a private-schema type is DENIED (404 not found)", %{
      conn: conn,
      ws: ws,
      project: project,
      token: token
    } do
      body =
        conn
        |> authed(token)
        |> get(scoped(ws, project, "query/#{@dataset}/secret"))
        |> json_response(404)

      assert body["error"] == "not found"
    end

    test "a private-schema doc-by-id is DENIED (404)", %{
      conn: conn,
      ws: ws,
      project: project,
      token: token
    } do
      conn
      |> authed(token)
      |> get(scoped(ws, project, "doc/#{@dataset}/secret/x1"))
      |> json_response(404)
    end

    test "an admin token is NOT clamped — drafts + private read through", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      raw = "admin-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw, "admin", @dataset, ["read", "write", "admin"], ws.id)

      # drafts perspective is allowed for a non-public-read token (no 403 clamp).
      conn
      |> authed(raw)
      |> get(scoped(ws, project, "query/#{@dataset}/post?perspective=drafts"))
      |> json_response(200)
    end
  end

  # ── FLAT route (:api_grant_read) — proves the second mount point ───────────
  describe "flat route /v1/data — public-read token is clamped" do
    setup do
      {ws, project} = ensure_default_scope!()
      scope = [workspace_id: ws.id, project_id: project.id]

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "fpost", "title" => "FPost", "visibility" => "public", "fields" => []},
          @dataset,
          scope
        )

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "fsecret", "title" => "FSecret", "visibility" => "private", "fields" => []},
          @dataset,
          scope
        )

      {:ok, _} =
        Content.create_document("fpost", %{"_id" => "fp1", "title" => "Live"}, @dataset, scope)

      {:ok, _} = Content.publish_document("fp1", "fpost", @dataset, scope)

      raw = "flat-build-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw, "flat public-read", @dataset, ["public-read"], ws.id)

      %{token: raw}
    end

    test "reads published + public content (200)", %{conn: conn, token: token} do
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/v1/data/query/#{@dataset}/fpost")
        |> json_response(200)

      ids = body["result"]["documents"] |> Enum.map(& &1["_id"])
      assert "fp1" in ids
    end

    test "?perspective=drafts is DENIED (403)", %{conn: conn, token: token} do
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/v1/data/query/#{@dataset}/fpost?perspective=drafts")
        |> json_response(403)

      assert body["error"] == "perspective not allowed"
    end

    test "a private-schema type is DENIED (404)", %{conn: conn, token: token} do
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/v1/data/query/#{@dataset}/fsecret")
        |> json_response(404)

      assert body["error"] == "not found"
    end
  end
end
