defmodule BarkparkWeb.PlaygroundControllerTest do
  @moduledoc """
  Conn tests for the playground front door (perfect-plan-build W2c, charter
  D25/D27): `POST /api/playground` provisions a disposable, self-cleaning
  workspace plus a workspace-scoped visitor token in one admin-gated call.

  Distrust vacuous green — the happy path asserts the REAL side effects, not
  just a 201:

    * the workspace row exists with `tier: "playground"`, `quota: 100`, and a
      non-nil `expires_at`;
    * `expires_at` is ~48h out (the TTL window, not merely "some datetime");
    * the returned token verifies, is bound to THIS workspace, carries
      `["read", "write"]` (NON-admin), and holds a `member` membership.

  Plus the admin gate: a non-admin token → 403, no token → 401.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @ttl_seconds 48 * 60 * 60

  defp authed(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp json_authed(conn, raw) do
    conn
    |> authed(raw)
    |> put_req_header("content-type", "application/json")
  end

  describe "POST /api/playground" do
    test "201 for an admin — provisions a tier=playground workspace, quota 100, 48h TTL, and a scoped NON-admin token",
         %{conn: conn} do
      raw_admin = "pg-admin-#{System.unique_integer([:positive])}"
      {:ok, _admin} = Auth.create_token(raw_admin, "pg admin", "test", ["read", "write", "admin"])

      before = DateTime.utc_now()

      resp =
        conn
        |> authed(raw_admin)
        |> post("/api/playground")

      assert resp.status == 201
      body = Jason.decode!(resp.resp_body)

      # ── Response shape ──────────────────────────────────────────────────
      assert is_binary(body["workspace_slug"])
      assert is_binary(body["token"])
      assert body["tier"] == "playground"
      assert is_binary(body["expires_at"])

      # ── The workspace row really exists, with playground state ───────────
      ws = Tenancy.get_workspace_by_slug(body["workspace_slug"])
      assert ws, "provisioned workspace must be persisted"
      assert ws.tier == "playground"
      assert ws.quota == 100, "playground workspace must carry the 100-doc quota"
      assert ws.expires_at, "playground workspace must carry a TTL"

      # ── The 48h window (not merely "a datetime") ────────────────────────
      # expires_at must be ~48h after the request; allow a generous 60s of
      # test/clock slack on either side of the exact boundary.
      expected = DateTime.add(before, @ttl_seconds, :second)
      drift = DateTime.diff(ws.expires_at, expected, :second) |> abs()
      assert drift <= 60, "expires_at must be ~48h out, drift=#{drift}s"

      # The DB value and the response value agree.
      {:ok, body_expires, _} = DateTime.from_iso8601(body["expires_at"])
      assert DateTime.diff(body_expires, ws.expires_at, :second) |> abs() <= 1

      # ── The minted token is workspace-scoped and NON-admin ──────────────
      assert {:ok, minted} = Auth.verify_token(body["token"])
      assert minted.workspace_id == ws.id, "token must be bound to the playground workspace"
      assert minted.permissions == ["read", "write"]
      refute "admin" in minted.permissions, "playground token must NOT be an admin token"

      # …and it holds a real membership in the workspace — as a member, not owner.
      assert TenancyAuth.membership_role(minted, ws.id) == "member"

      # It is NOT the admin caller's token.
      assert {:ok, admin_tok} = Auth.verify_token(raw_admin)
      refute minted.id == admin_tok.id
    end

    test "each call provisions a DISTINCT disposable workspace + token", %{conn: conn} do
      raw_admin = "pg-admin-distinct-#{System.unique_integer([:positive])}"

      {:ok, _admin} =
        Auth.create_token(raw_admin, "pg admin", "test", ["read", "write", "admin"])

      one = conn |> authed(raw_admin) |> post("/api/playground") |> Map.get(:resp_body)
      two = conn |> authed(raw_admin) |> post("/api/playground") |> Map.get(:resp_body)

      a = Jason.decode!(one)
      b = Jason.decode!(two)

      refute a["workspace_slug"] == b["workspace_slug"]
      refute a["token"] == b["token"]
    end

    test "403 for a NON-admin token (permission-denial path)", %{conn: conn} do
      raw = "pg-nonadmin-#{System.unique_integer([:positive])}"
      # read+write but NO global admin perm.
      {:ok, _tok} = Auth.create_token(raw, "pg non-admin", "test", ["read", "write"])

      resp =
        conn
        |> authed(raw)
        |> post("/api/playground")

      assert resp.status == 403
      # The gate halts before the action — no playground workspace is provisioned.
      assert playground_count() == 0
    end

    test "401 for an unauthenticated request (no token)", %{conn: conn} do
      resp = post(conn, "/api/playground")
      assert resp.status == 401
    end
  end

  describe "POST /api/playground — seeded showcase paper (charter D47)" do
    test "the fresh workspace is NOT empty — a curated showcase paper is present + readable",
         %{conn: conn} do
      raw_admin = "pg-admin-seed-#{System.unique_integer([:positive])}"
      {:ok, _admin} = Auth.create_token(raw_admin, "pg admin", "test", ["read", "write", "admin"])

      body =
        conn
        |> authed(raw_admin)
        |> post("/api/playground")
        |> Map.get(:resp_body)
        |> Jason.decode!()

      ws = Tenancy.get_workspace_by_slug(body["workspace_slug"])
      showcase_slug = "showcase-" <> body["workspace_slug"]

      # Present: the seed lands under the workspace's "production" dataset,
      # scoped to the new tenant (NOT the literal portabledoc-showcase doc_id).
      paper = Content.get_paper(showcase_slug, "production", workspace_id: ws.id)
      assert paper, "a showcase paper must be seeded into the fresh playground workspace"

      # Readable: it is a real, rendered paper, not an empty shell — the seeded
      # heading is in the stored content and the render produced body HTML.
      assert paper.content["blocks"] != [] and not is_nil(paper.content["blocks"])
      assert is_binary(paper.content["body_html"]) and paper.content["body_html"] != ""
      assert paper.content["body_html"] =~ "Welcome to your playground"
    end

    test "response carries the write coordinates project_slug + dataset (D34/D46)",
         %{conn: conn} do
      raw_admin = "pg-admin-coords-#{System.unique_integer([:positive])}"
      {:ok, _admin} = Auth.create_token(raw_admin, "pg admin", "test", ["read", "write", "admin"])

      body =
        conn
        |> authed(raw_admin)
        |> post("/api/playground")
        |> Map.get(:resp_body)
        |> Jason.decode!()

      # The caller learns the write URL in-band rather than hardcoding it.
      assert body["project_slug"] == "default"
      assert body["dataset"] == "production"

      # …and those coordinates resolve to a real project in the new workspace.
      assert Tenancy.get_project(body["workspace_slug"], body["project_slug"])
    end
  end

  describe "D34 anti-404: the provision response's own slugs authorize a scoped write" do
    test "provision → mint token → POST create at /w/:ws/p/:proj/v1/data/mutate/:ds → 200; a non-member → 403",
         %{conn: conn} do
      raw_admin = "pg-admin-d34-#{System.unique_integer([:positive])}"
      {:ok, _admin} = Auth.create_token(raw_admin, "pg admin", "test", ["read", "write", "admin"])

      body =
        conn
        |> authed(raw_admin)
        |> post("/api/playground")
        |> Map.get(:resp_body)
        |> Jason.decode!()

      ws_slug = body["workspace_slug"]
      proj_slug = body["project_slug"]
      dataset = body["dataset"]
      pg_token = body["token"]

      # Register a "post" schema in the provisioned workspace so a valid create
      # is not an unknown-type 422 — scoped to the same workspace+project the
      # mutate route resolves.
      project = Tenancy.get_project(ws_slug, proj_slug)

      {:ok, _schema} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
          dataset,
          workspace_id: project.workspace_id,
          project_id: project.id
        )

      mutate_url = "/w/#{ws_slug}/p/#{proj_slug}/v1/data/mutate/#{dataset}"

      create_body =
        Jason.encode!(%{
          "mutations" => [
            %{"create" => %{"_id" => "pg-hello-1", "_type" => "post", "title" => "Hello"}}
          ]
        })

      # The minted playground token (a workspace MEMBER) writes content → 200.
      ok = conn |> json_authed(pg_token) |> post(mutate_url, create_body)

      assert ok.status == 200,
             "the provision response's OWN slugs + token must authorize a write (got #{ok.status})"

      # A token with NO membership in the workspace → the membership gate 403s
      # (the path resolves — this is authorization, not a 404 dead-end).
      raw_outsider = "pg-outsider-#{System.unique_integer([:positive])}"
      {:ok, _out} = Auth.create_token(raw_outsider, "outsider", "test", ["read", "write"])

      denied = conn |> json_authed(raw_outsider) |> post(mutate_url, create_body)
      assert denied.status == 403
    end
  end

  # Count of playground-tier workspaces — a side-effect guard for the rejection
  # paths (a gated-out call must provision nothing).
  defp playground_count do
    import Ecto.Query

    Barkpark.Repo.aggregate(
      from(w in Barkpark.Tenancy.Workspace, where: w.tier == "playground"),
      :count
    )
  end
end
