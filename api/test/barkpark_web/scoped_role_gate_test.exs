defmodule BarkparkWeb.ScopedRoleGateTest do
  @moduledoc """
  End-to-end conn tests for the per-membership role authz model
  (barkpark-23yi) closing the P0 cross-tenant write/admin bypass
  (barkpark-fsko).

  The MODEL: admin authority on a scoped workspace is conferred by the
  membership ROLE (the grant: owner/admin → admin, member → write content),
  NOT by the token's GLOBAL `permissions[]`. The teeth are on admin —
  `RequireWorkspaceRole` reads `workspace_memberships.role` for the resolved
  `current_workspace`.

  Cases (all hit the /w/:ws/p/:project scoped admin + write surfaces):

    * LEAK GATE (core): a token that is a `member` of B but holds global
      ["read","write","admin"] → scoped ADMIN op on B (schema upsert) → 403.
    * WRITE allowed: that same member → scoped mutate on B → NOT 403 (members
      write content).
    * ADMIN legit: an owner/admin of B → scoped admin op on B → 201.
    * NON-MEMBER: a token with no membership in B → scoped admin/write → 403
      (ResolveWorkspace's :read gate; confirmed).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "scoped_role_gate_ds"

  setup do
    # Workspace B — the tenant whose admin surface must be protected.
    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "role-gate-b", name: "Role Gate B"})
    {:ok, _proj_b} = Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})

    # Schema in B so an upsert reaches the controller (the gate is what we
    # measure; the upsert succeeding for an admin proves the surface works).
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        workspace_id: ws_b.id
      )

    # MEMBER token: global admin perms, but added to B as a plain `member`.
    # This is the exact bypass vector — a global-admin token granted member
    # access to another tenant.
    member_raw = "role-gate-member-#{System.unique_integer([:positive])}"

    {:ok, member_token} =
      Auth.create_token(member_raw, "member of B", @dataset, ["read", "write", "admin"])

    # create_membership defaults to `member` — independent of global perms.
    {:ok, m} = TenancyAuth.create_membership(ws_b.id, member_token.id)
    assert m.role == "member"

    # ADMIN token: explicitly granted admin of B (legit workspace admin).
    admin_raw = "role-gate-admin-#{System.unique_integer([:positive])}"

    {:ok, admin_token} =
      Auth.create_token(admin_raw, "admin of B", @dataset, ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws_b.id, admin_token.id, "admin")

    # NON-MEMBER token: global admin perms, NO membership in B at all.
    nonmember_raw = "role-gate-nonmember-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(nonmember_raw, "non-member", @dataset, ["read", "write", "admin"])

    {:ok, member_raw: member_raw, admin_raw: admin_raw, nonmember_raw: nonmember_raw}
  end

  defp authed(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp schema_upsert(conn, raw, name) do
    body = %{"name" => name, "title" => name, "visibility" => "public", "fields" => []}

    conn
    |> authed(raw)
    |> post("/w/role-gate-b/p/default/v1/schemas/#{@dataset}", Jason.encode!(body))
  end

  defp scoped_mutate(conn, raw) do
    # Invalid payload (no _type) so a write-allowed caller reaches validation
    # (422) and a write-denied caller is gated (403) — the discriminator is
    # 403-vs-not-403, mirroring mutate_controller_test.
    body = %{
      "mutations" => [%{"create" => %{"_id" => "no-type-1", "title" => "x"}}]
    }

    conn
    |> authed(raw)
    |> post("/w/role-gate-b/p/default/v1/data/mutate/#{@dataset}", Jason.encode!(body))
  end

  describe "scoped ADMIN gate (the leak)" do
    test "LEAK GATE: a `member` of B with global admin perms → scoped admin op → 403", %{
      conn: conn,
      member_raw: raw
    } do
      resp = schema_upsert(conn, raw, "leak_member_schema")

      assert resp.status == 403,
             "cross-tenant bypass: a member of B with global admin perms reached B's " <>
               "admin surface (status #{resp.status})"

      assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"
    end

    test "ADMIN legit: an admin of B → scoped admin op → 201", %{conn: conn, admin_raw: raw} do
      resp = schema_upsert(conn, raw, "admin_legit_schema")
      assert resp.status == 201
    end

    test "NON-MEMBER: no membership in B → scoped admin op → 403", %{
      conn: conn,
      nonmember_raw: raw
    } do
      resp = schema_upsert(conn, raw, "nonmember_schema")
      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"
    end
  end

  describe "scoped WRITE gate (members write content)" do
    test "WRITE allowed: a `member` of B → scoped mutate → NOT 403 (reaches the controller)", %{
      conn: conn,
      member_raw: raw
    } do
      resp = scoped_mutate(conn, raw)

      # Member passes the write gate (global write perm as cap + active
      # membership) → reaches validation, which 422s the no-_type payload.
      refute resp.status == 403,
             "a member of B was wrongly denied content write (status #{resp.status})"

      assert resp.status == 422
    end

    test "NON-MEMBER: no membership in B → scoped mutate → 403", %{
      conn: conn,
      nonmember_raw: raw
    } do
      resp = scoped_mutate(conn, raw)
      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"
    end
  end
end
