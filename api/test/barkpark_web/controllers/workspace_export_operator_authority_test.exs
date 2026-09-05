defmodule BarkparkWeb.WorkspaceExportOperatorAuthorityTest do
  @moduledoc """
  THE REAL 403, AND THE PREDICATE THAT PRODUCES IT (task-e25b94b9db28392a
  c0 + c3).

  `bp cloud instance authority` is a CLIENT of two server facts. This file is
  where those facts are PROVED — a Go test against a mock can only pin what the
  CLI does with an answer, never that the server gives that answer.

  FACT 1 (c0) — an operator token carrying the global `admin` permission is
  DENIED on `GET /api/workspaces/:slug/export` for a workspace it did not
  CREATE. Not modelled, not asserted from the mint path: a real request, a real
  403. The mechanism is on record — `TenancyAuth.workspace_admin?/2` consults
  the `workspace_memberships` GRANT only (`@admin_roles ~w(owner admin)`), with
  NO global/platform-admin bypass, and `Auth.create_token/5` binds a new token
  to ONE workspace and nothing else. A token's membership set then grows only
  when it CREATES a workspace
  (`Tenancy.do_create_workspace_with_owner/3` grants the creator `owner`). So a
  workspace that arrived by seeds, a migration, a bundle import, or another
  principal has no membership row for that token at all.

  FACT 2 (c3, the NEGATIVE ARM) — the remedy is a GRANT, and the predicate is
  UNCHANGED. `TenancyAuth.create_membership(ws.id, token.id, "admin")` restores
  export (the known-good endpoint PR #12854 pinned). Weakening
  `workspace_admin?/2` toward `member?/2` would reinstate the cross-tenant hole
  four merged PRs closed, so this file pins the DIVERGENCE directly: on a plain
  `member` grant `member?/2` answers TRUE while `workspace_admin?/2` answers
  FALSE and export still 403s. A widening mutation reds here rather than
  shipping.

  FACT 3 — `GET /api/workspaces` is the membership set, which is the DATA
  SOURCE the CLI check reads. A workspace the token holds no grant in is never
  listed; the grant makes it appear. If that ever stopped being true, the CLI
  would compute coverage from a body that no longer means coverage, so it is
  pinned beside the 403 that motivates it.

  DENIAL SHAPE, deliberately asserted as 403 and not 404: `export/2` follows the
  path-addressed law documented on `WorkspaceController` — an UNKNOWN slug is
  404, a REAL workspace the caller does not administer is 403. Asserting the
  wrong one here would red for the wrong reason on a future correct change.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  defp authed(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp verified(raw) do
    {:ok, token} = Auth.verify_token(raw)
    token
  end

  # The target-side OPERATOR credential: full `admin` permission, HOME workspace
  # its own. This is the shape the control plane decrypts into
  # SupportBindSpec.ParentAdminToken and the shape `bp` presents.
  defp operator_token do
    n = System.unique_integer([:positive])
    raw = "operator-authority-#{n}"

    {:ok, home} =
      Tenancy.create_workspace(%{slug: "op-home-#{n}", name: "Operator home #{n}"})

    {:ok, token} = Auth.create_token(raw, "operator", "test", ["read", "write", "admin"], home.id)
    {raw, token}
  end

  # A workspace that arrived by ANOTHER ROUTE — created by a DIFFERENT principal,
  # exactly like one that arrived by seeds, a migration, or a bundle import. The
  # operator token has no membership row in it.
  defp foreign_workspace do
    n = System.unique_integer([:positive])
    raw_other = "other-principal-#{n}"
    {:ok, _} = Auth.create_token(raw_other, "other principal", "test", ["read", "write", "admin"])

    {:ok, ws} =
      Tenancy.create_workspace_with_owner(%{name: "Imported WS #{n}"}, verified(raw_other))

    ws
  end

  describe "an admin-permissioned operator token on a workspace it did not create" do
    test "GET export is a REAL 403, and the `admin` GRANT restores it", %{conn: conn} do
      {raw, token} = operator_token()
      ws = foreign_workspace()

      # The premise, stated as an assertion rather than assumed: no grant.
      refute TenancyAuth.member?(token, ws.id),
             "the operator token must start with NO membership row — otherwise this test proves nothing"

      refute TenancyAuth.workspace_admin?(token, ws.id)

      # c0: the real refusal. The token carries the global `admin` permission the
      # whole time — that permission is workspace-BLIND by construction, which is
      # the entire point.
      assert "admin" in token.permissions

      denied =
        conn
        |> authed(raw)
        |> get("/api/workspaces/#{ws.slug}/export")

      assert denied.status == 403,
             "want the path-addressed 403 for a real workspace the caller does not administer, got #{denied.status}"

      # FACT 3: the CLI's data source agrees — the workspace is absent from the
      # membership index while the grant is missing.
      listed =
        conn
        |> authed(raw)
        |> get("/api/workspaces")
        |> json_response(200)

      refute ws.slug in Enum.map(listed["workspaces"], & &1["slug"]),
             "an ungranted workspace was listed by GET /api/workspaces — the membership index no longer means membership"

      # c3: THE REMEDY IS A GRANT. create_membership/4 validates the role against
      # the workspace's valid role names, so an explicit "admin" is accepted.
      assert {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "admin")
      assert TenancyAuth.workspace_admin?(token, ws.id)

      restored =
        build_conn()
        |> authed(raw)
        |> get("/api/workspaces/#{ws.slug}/export")

      assert restored.status == 200,
             "the `admin` grant did not restore export (got #{restored.status}) — the known-good endpoint PR #12854 pinned"

      relisted =
        build_conn()
        |> authed(raw)
        |> get("/api/workspaces")
        |> json_response(200)

      assert ws.slug in Enum.map(relisted["workspaces"], & &1["slug"])
    end

    test "an unknown slug is 404, not 403 — the two denial shapes stay distinct", %{conn: conn} do
      {raw, _token} = operator_token()

      missing =
        conn
        |> authed(raw)
        |> get("/api/workspaces/no-such-workspace-#{System.unique_integer([:positive])}/export")

      assert missing.status == 404
    end
  end

  describe "workspace_admin?/2 is UNCHANGED by this work" do
    test "a plain `member` grant satisfies member?/2 and NOT workspace_admin?/2 — export still 403s",
         %{conn: conn} do
      {raw, token} = operator_token()
      ws = foreign_workspace()

      assert {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "member")

      # THE DIVERGENCE IS THE TENANT BOUNDARY. If a later change widened the
      # export gate to member?/2, this pair would still both read true and the
      # 403 below would flip to 200 — which is the cross-tenant hole, back.
      assert TenancyAuth.member?(token, ws.id),
             "a `member` grant must satisfy member?/2 — otherwise the divergence below is vacuous"

      refute TenancyAuth.workspace_admin?(token, ws.id),
             "workspace_admin?/2 admitted a `member` role — @admin_roles is owner|admin"

      still_denied =
        conn
        |> authed(raw)
        |> get("/api/workspaces/#{ws.slug}/export")

      assert still_denied.status == 403
    end

    test "`owner` and `admin` are the admin roles; a non-member is denied", %{conn: _conn} do
      {_raw_owner, owner_tok} = operator_token()
      {_raw_admin, admin_tok} = operator_token()
      {_raw_none, none_tok} = operator_token()
      ws = foreign_workspace()

      assert {:ok, _} = TenancyAuth.create_membership(ws.id, owner_tok.id, "owner")
      assert {:ok, _} = TenancyAuth.create_membership(ws.id, admin_tok.id, "admin")

      assert TenancyAuth.workspace_admin?(owner_tok, ws.id)
      assert TenancyAuth.workspace_admin?(admin_tok, ws.id)
      refute TenancyAuth.workspace_admin?(none_tok, ws.id)
    end
  end
end
