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
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @ttl_seconds 48 * 60 * 60

  defp authed(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

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
