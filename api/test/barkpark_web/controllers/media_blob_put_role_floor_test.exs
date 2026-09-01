defmodule BarkparkWeb.MediaBlobPutRoleFloorTest do
  @moduledoc """
  THE ROLE FLOOR ON `PUT /api/workspaces/:workspace_slug/media/blob/*path`
  (task-62d9364937b538e5, RULED CONFINE by lead-security 2026-09-02).

  The route used to bind on `TenancyAuth.member?/2`, which is
  `not is_nil(membership(...))` — a pure PRESENCE test with no role floor. Any
  principal holding ANY seat in workspace B, plus the workspace-blind global
  `admin` permission the `:require_admin` pipeline checks, could therefore write
  raw bytes into B's blob store. Its two siblings on the SAME `:workspace_slug`
  under the SAME pipeline refuse exactly that principal:

      DELETE /api/workspaces/:workspace_slug          -> workspace_admin?/2
      GET    /api/workspaces/:workspace_slug/export    -> workspace_admin?/2
      PUT    /api/workspaces/:workspace_slug/media/blob/*path -> NOW the same

  A raw-byte write into a tenant's blob store is the RESTORE half of the same
  import/export lifecycle, so it now sits on `TenancyAuth.workspace_admin?/2`
  (`owner`/`admin`) too.

  WHAT EACH ARM BUYS, and why none is redundant:

    * the CONFINE arm is the one the ruling bought — a `member` seat in B plus
      global `admin` is refused. It is also the mutation detector: revert the
      controller to `member?/2` and this arm is the only one that reds.
    * the ALLOW arm proves the floor is a floor and not a wall: an `admin` seat
      in B still lands bytes, read back off disk. Without it a mutation to
      `false` would pass the CONFINE arm.
    * the NON-MEMBER arm pins the DENIAL SHAPE across the change. Raising the
      floor must not lower the existence-hiding: a stranger still gets 404
      `workspace not found`, never the 403 the export/delete siblings answer
      under the path-addressed law. Same status for the sub-admin member, so the
      response cannot be used to probe whether a seat exists either.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Media, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  defp uniq, do: System.unique_integer([:positive])

  defp workspace!(label) do
    n = uniq()

    {:ok, ws} =
      Tenancy.create_workspace(%{slug: "#{label}-#{n}", name: "#{label} #{n}"})

    ws
  end

  # A token carrying the GLOBAL `admin` permission (what `:require_admin`
  # checks) whose HOME workspace is its own — so any seat it holds in the
  # workspace under test is the one the test grants explicitly, never a
  # side effect of minting.
  defp admin_token!(label) do
    n = uniq()
    raw = "#{label}-#{n}"
    home = workspace!("#{label}-home")
    {:ok, token} = Auth.create_token(raw, label, "test", ["read", "write", "admin"], home.id)
    {raw, token}
  end

  defp seat!(ws, token, role) do
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, role, "api_token")
    :ok
  end

  # A fresh server-blob-shaped key. No `media_files` row is created by this
  # route, so there is nothing to scope with a dataset_id — the key is
  # unclaimed, which is what lets the write reach the floor check's verdict
  # rather than dying on `:blob_key_not_owned` first.
  defp blob_key do
    rel = "uploads/blob-floor-test/b-#{uniq()}.png"
    on_exit(fn -> File.rm_rf(Media.file_path(rel)) end)
    rel
  end

  defp push(conn, raw, slug, rel, body) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/octet-stream")
    |> put("/api/workspaces/#{slug}/media/blob/#{rel}", body)
  end

  setup do
    ws_b = workspace!("floor-b")
    {:ok, ws_b: ws_b}
  end

  describe "the owner|admin floor on the blob push" do
    test "CONFINE: a global-admin token holding a plain `member` seat in B is REFUSED",
         %{conn: conn, ws_b: ws_b} do
      {raw, token} = admin_token!("member-seat")
      :ok = seat!(ws_b, token, "member")

      # The precondition the ruling is about: this principal IS a member (the
      # old predicate said yes) and is NOT a workspace admin (the siblings say
      # no). Without both the arm could pass for the wrong reason.
      assert TenancyAuth.member?(token, ws_b.id)
      refute TenancyAuth.workspace_admin?(token, ws_b.id)
      assert "admin" in token.permissions

      rel = blob_key()
      resp = push(conn, raw, ws_b.slug, rel, "SHOULD-NOT-LAND")

      assert resp.status == 404,
             "a `member` seat must not clear the admin floor; got #{resp.status}: #{resp.resp_body}"

      # Existence-hiding is UNCHANGED by the floor change: 404 with the same
      # body a stranger gets, never a 403 that would confirm the seat.
      assert Jason.decode!(resp.resp_body)["error"]["message"] =~ "workspace not found"
      refute File.exists?(Media.file_path(rel))
    end

    test "ALLOW: an `admin` seat in B lands the bytes, and they read back",
         %{conn: conn, ws_b: ws_b} do
      {raw, token} = admin_token!("admin-seat")
      :ok = seat!(ws_b, token, "admin")
      assert TenancyAuth.workspace_admin?(token, ws_b.id)

      rel = blob_key()
      resp = push(conn, raw, ws_b.slug, rel, "ADMIN-BLOB-BYTES")

      assert resp.status == 200,
             "an admin seat must still land the restore half; got #{resp.status}: #{resp.resp_body}"

      assert Jason.decode!(resp.resp_body)["written"] == rel
      assert File.read!(Media.file_path(rel)) == "ADMIN-BLOB-BYTES"
    end

    test "an `owner` seat in B clears the floor too — `owner` is not a stricter role",
         %{conn: conn, ws_b: ws_b} do
      {raw, token} = admin_token!("owner-seat")
      :ok = seat!(ws_b, token, "owner")

      rel = blob_key()
      assert push(conn, raw, ws_b.slug, rel, "OWNER-BLOB-BYTES").status == 200
      assert File.read!(Media.file_path(rel)) == "OWNER-BLOB-BYTES"
    end

    test "UNCHANGED: a non-member admin of another workspace still gets 404, not 403",
         %{conn: conn, ws_b: ws_b} do
      {raw, token} = admin_token!("stranger")
      refute TenancyAuth.member?(token, ws_b.id)

      rel = blob_key()
      resp = push(conn, raw, ws_b.slug, rel, "STRANGER-BYTES")

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["message"] =~ "workspace not found"
      refute File.exists?(Media.file_path(rel))
    end

    test "an unknown slug is the SAME 404 — the three denials are indistinguishable",
         %{conn: conn} do
      {raw, _token} = admin_token!("unknown-slug")

      rel = blob_key()
      resp = push(conn, raw, "no-such-workspace-#{uniq()}", rel, "NOWHERE")

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["message"] =~ "workspace not found"
      refute File.exists?(Media.file_path(rel))
    end
  end
end
