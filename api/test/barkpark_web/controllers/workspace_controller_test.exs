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
    {:ok, member_proj} = Tenancy.create_project(member_ws, %{slug: "member-proj", name: "Member Proj"})
    {:ok, _m} = TenancyAuth.create_membership(member_ws.id, token.id, "member")

    # A THIRD workspace the caller is NOT a member of — the leak guard. Has its
    # own project so a leaked :projects response would be visibly wrong.
    {:ok, other_ws} = Tenancy.create_workspace(%{slug: "other-ws", name: "Other WS"})
    {:ok, _other_proj} = Tenancy.create_project(other_ws, %{slug: "other-proj", name: "Other Proj"})

    {:ok,
     raw_token: raw,
     member_ws: member_ws,
     member_proj: member_proj,
     other_ws: other_ws}
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
end
