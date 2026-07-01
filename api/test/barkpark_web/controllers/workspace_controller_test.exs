defmodule BarkparkWeb.WorkspaceControllerTest do
  @moduledoc """
  Conn tests for the membership-scoped workspace/project LIST API
  (task barkpark-sj6z):

    * GET /api/workspaces returns ONLY the workspaces the bearer token is a
      member of — a workspace the token is NOT a member of is absent (the hard
      tenant boundary; mirrors the assert_no_cross_workspace_leak shape).
    * GET /api/workspaces/:slug/projects → 200 for a member, listing that
      workspace's projects; 404 for a non-member AND for an unknown slug (no
      existence leak).
    * Unauthenticated requests → 401 (the :require_token pipeline).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  setup do
    # create_token/4 with no explicit workspace_id binds to the seeded Default
    # Workspace AND inserts a membership — so this token is a member of
    # "default" only.
    raw = "ws-list-token-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "ws list", "test", ["read", "write"])

    # A SECOND workspace the caller IS additionally made a member of — proves
    # the list surfaces every membership, not just Default.
    {:ok, member_ws} = Tenancy.create_workspace(%{slug: "member-ws", name: "Member WS"})

    {:ok, member_proj} =
      Tenancy.create_project(member_ws, %{slug: "member-proj", name: "Member Proj"})

    {:ok, _m} = TenancyAuth.create_membership(member_ws.id, token.id, "member")

    # A THIRD workspace the caller is NOT a member of — the leak guard. Has its
    # own project so a leaked :projects response would be visibly wrong.
    {:ok, other_ws} = Tenancy.create_workspace(%{slug: "other-ws", name: "Other WS"})

    {:ok, _other_proj} =
      Tenancy.create_project(other_ws, %{slug: "other-proj", name: "Other Proj"})

    {:ok, raw_token: raw, member_ws: member_ws, member_proj: member_proj, other_ws: other_ws}
  end

  defp authed(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  describe "GET /api/workspaces" do
    test "returns ONLY the caller's member workspaces; a non-member workspace is absent", %{
      conn: conn,
      raw_token: raw,
      member_ws: member_ws,
      other_ws: other_ws
    } do
      resp =
        conn
        |> authed(raw)
        |> get("/api/workspaces")

      assert resp.status == 200
      slugs = Jason.decode!(resp.resp_body)["workspaces"] |> Enum.map(& &1["slug"])

      # Member of: "default" (from create_token) + "member-ws".
      assert "default" in slugs
      assert member_ws.slug in slugs

      # CROSS-WORKSPACE LEAK GUARD: the workspace the caller is NOT a member of
      # must never appear — the hard tenant boundary.
      refute other_ws.slug in slugs
    end

    test "unauthenticated → 401", %{conn: conn} do
      resp = get(conn, "/api/workspaces")

      assert resp.status == 401
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "unauthorized"
    end
  end

  describe "GET /api/workspaces/:workspace_slug/projects" do
    test "200 for a member — lists that workspace's projects", %{
      conn: conn,
      raw_token: raw,
      member_ws: member_ws,
      member_proj: member_proj
    } do
      resp =
        conn
        |> authed(raw)
        |> get("/api/workspaces/#{member_ws.slug}/projects")

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["workspace"]["slug"] == member_ws.slug

      project_slugs = body["projects"] |> Enum.map(& &1["slug"])
      assert member_proj.slug in project_slugs
    end

    test "404 for a real workspace the caller is NOT a member of (no existence leak)", %{
      conn: conn,
      raw_token: raw,
      other_ws: other_ws
    } do
      resp =
        conn
        |> authed(raw)
        |> get("/api/workspaces/#{other_ws.slug}/projects")

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "not_found"
    end

    test "404 for an unknown workspace slug", %{conn: conn, raw_token: raw} do
      resp =
        conn
        |> authed(raw)
        |> get("/api/workspaces/no-such-ws/projects")

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "not_found"
    end

    test "unauthenticated → 401", %{conn: conn, member_ws: member_ws} do
      resp = get(conn, "/api/workspaces/#{member_ws.slug}/projects")

      assert resp.status == 401
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "unauthorized"
    end
  end

  describe "GET /api/workspaces/:workspace_slug/projects/:project_slug/datasets" do
    test "200 for a member — lists that project's datasets", %{
      conn: conn,
      raw_token: raw,
      member_ws: member_ws,
      member_proj: member_proj
    } do
      {:ok, dataset} = Tenancy.create_dataset(member_proj, %{slug: "prod-ds", name: "Prod DS"})

      resp =
        conn
        |> authed(raw)
        |> get("/api/workspaces/#{member_ws.slug}/projects/#{member_proj.slug}/datasets")

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["workspace"]["slug"] == member_ws.slug
      assert body["project"]["slug"] == member_proj.slug

      dataset_slugs = body["datasets"] |> Enum.map(& &1["slug"])
      assert dataset.slug in dataset_slugs
    end

    test "404 for a workspace the caller is NOT a member of (no existence leak)", %{
      conn: conn,
      raw_token: raw,
      other_ws: other_ws
    } do
      resp =
        conn
        |> authed(raw)
        |> get("/api/workspaces/#{other_ws.slug}/projects/other-proj/datasets")

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "not_found"
    end

    test "unauthenticated → 401", %{conn: conn, member_ws: member_ws, member_proj: member_proj} do
      resp = get(conn, "/api/workspaces/#{member_ws.slug}/projects/#{member_proj.slug}/datasets")

      assert resp.status == 401
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "unauthorized"
    end
  end

  describe "POST /api/workspaces" do
    test "201 — creates workspace, owner membership, Default project + production dataset",
         %{conn: conn, raw_token: raw} do
      slug = "fresh-ws-#{System.unique_integer([:positive])}"

      resp =
        conn
        |> authed(raw)
        |> post("/api/workspaces", %{"name" => "Fresh WS", "slug" => slug})

      assert resp.status == 201
      body = Jason.decode!(resp.resp_body)
      assert body["workspace"]["slug"] == slug
      assert body["workspace"]["name"] == "Fresh WS"

      ws = Tenancy.get_workspace_by_slug(slug)
      assert ws

      # Creator is an admin-tier (owner) member.
      membership = TenancyAuth.membership(body_token_id(raw), ws.id)
      assert membership
      assert membership.role == "owner"

      # Default project + production dataset bootstrapped + immediately usable.
      project = Tenancy.get_project(slug, "default")
      assert project
      assert project.name == "Default Project"
      assert Tenancy.get_dataset(project, "production")
    end

    test "201 — derives the slug from the name when slug omitted", %{conn: conn, raw_token: raw} do
      name = "My Cool Space #{System.unique_integer([:positive])}"

      resp =
        conn
        |> authed(raw)
        |> post("/api/workspaces", %{"name" => name})

      assert resp.status == 201
      slug = Jason.decode!(resp.resp_body)["workspace"]["slug"]
      assert slug =~ ~r/^[a-z0-9][a-z0-9-]*$/
      assert Tenancy.get_workspace_by_slug(slug)
    end

    test "422 — duplicate slug (clean conflict)", %{conn: conn, raw_token: raw} do
      slug = "dup-ws-#{System.unique_integer([:positive])}"

      assert conn
             |> authed(raw)
             |> post("/api/workspaces", %{"name" => "A", "slug" => slug})
             |> Map.get(:status) == 201

      resp = conn |> authed(raw) |> post("/api/workspaces", %{"name" => "B", "slug" => slug})

      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "validation_failed"
    end

    test "422 — missing name", %{conn: conn, raw_token: raw} do
      resp = conn |> authed(raw) |> post("/api/workspaces", %{})

      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "validation_failed"
    end

    test "unauthenticated → 401", %{conn: conn} do
      resp = post(conn, "/api/workspaces", %{"name" => "Nope"})

      assert resp.status == 401
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "unauthorized"
    end
  end

  describe "POST /api/workspaces/:workspace_slug/projects" do
    test "201 for a member — creates project + production dataset", %{
      conn: conn,
      raw_token: raw,
      member_ws: member_ws
    } do
      slug = "new-proj-#{System.unique_integer([:positive])}"

      resp =
        conn
        |> authed(raw)
        |> post("/api/workspaces/#{member_ws.slug}/projects", %{
          "name" => "New Proj",
          "slug" => slug
        })

      assert resp.status == 201
      assert Jason.decode!(resp.resp_body)["project"]["slug"] == slug

      project = Tenancy.get_project(member_ws.slug, slug)
      assert project
      assert Tenancy.get_dataset(project, "production")
    end

    test "404 for a NON-member workspace (no existence leak)", %{
      conn: conn,
      raw_token: raw,
      other_ws: other_ws
    } do
      resp =
        conn
        |> authed(raw)
        |> post("/api/workspaces/#{other_ws.slug}/projects", %{"name" => "Sneaky"})

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "not_found"
      # The leak guard: no project was created in the workspace we don't own.
      refute Tenancy.get_project(other_ws.slug, "sneaky")
    end

    test "404 for an unknown workspace slug", %{conn: conn, raw_token: raw} do
      resp =
        conn
        |> authed(raw)
        |> post("/api/workspaces/no-such-ws/projects", %{"name" => "X"})

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "not_found"
    end

    test "422 for a duplicate project slug within the workspace", %{
      conn: conn,
      raw_token: raw,
      member_ws: member_ws
    } do
      slug = "dup-proj-#{System.unique_integer([:positive])}"

      assert conn
             |> authed(raw)
             |> post("/api/workspaces/#{member_ws.slug}/projects", %{
               "name" => "A",
               "slug" => slug
             })
             |> Map.get(:status) == 201

      resp =
        conn
        |> authed(raw)
        |> post("/api/workspaces/#{member_ws.slug}/projects", %{"name" => "B", "slug" => slug})

      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "validation_failed"
    end

    test "unauthenticated → 401", %{conn: conn, member_ws: member_ws} do
      resp = post(conn, "/api/workspaces/#{member_ws.slug}/projects", %{"name" => "X"})

      assert resp.status == 401
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "unauthorized"
    end
  end

  # Resolve the api_token id for the raw bearer used in setup, so membership
  # assertions don't depend on the controller echoing the token.
  defp body_token_id(raw) do
    {:ok, token} = Auth.verify_token(raw)
    token.id
  end
end
