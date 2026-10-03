defmodule BarkparkWeb.TokenSeatRuleTest do
  @moduledoc """
  OWNER RULING 2026-10-03 #2 (task-6132833921b7dc36 RQ1+RQ3, task-f462de9e4c1c4621
  item 2, task-1631e0fa917452d9 Q1, task-d9e8f02056e39763 item 4): a token
  follows its holder's CURRENT workspace role on every request (the D22 seat
  rule). Demotion and removal take effect at once, without revoking the token.

    * `Tenancy.Auth.authorize/3`, token arm: the token's permissions AND its
      seat's role must allow the action; a user-owned token also needs its
      owner's seat to allow it.
    * Flat admin routes (`RequireAdmin`): a workspace-bound token needs admin
      authority in that workspace; a workspace-less user-owned token needs its
      owner's admin authority in the workspace it acts on. A workspace-less
      machine token (instance credential) is unchanged.
    * Grants: revoking through the admin arm needs an admin seat; the grantor
      arm needs the grantor to still be seated in the grant's workspace.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.{Access, Accounts, Auth, Repo, Tenancy}
  alias Barkpark.Tenancy.{Members, Role, RolePermission}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery"

  defp bound_token(ws, perms) do
    raw = "seat-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "seat", "production", perms, ws.id)
    %{raw: raw, token: token}
  end

  defp user(prefix) do
    {:ok, u} =
      Accounts.register_user(%{
        email: "#{prefix}-#{Ecto.UUID.generate()}@example.com",
        password: @password
      })

    u
  end

  defp flat_webhooks(raw) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> get("/v1/webhooks/production")
  end

  defp token_ref(token), do: %{type: :api_token, id: token.id}

  describe "flat admin routes follow the bound token's seat (RQ1)" do
    test "an admin seat passes; demoted to member the same token is refused" do
      ws = create_workspace!("seat-flat-#{System.unique_integer([:positive])}")
      %{raw: raw, token: token} = bound_token(ws, ["read", "write", "admin"])

      assert flat_webhooks(raw).status == 200

      {:ok, _} = Members.update_role(ws.id, token_ref(token), "member")
      assert flat_webhooks(raw).status == 403
    end

    test "a token whose seat was removed is refused" do
      ws = create_workspace!("seat-flat-rm-#{System.unique_integer([:positive])}")
      %{raw: raw, token: token} = bound_token(ws, ["read", "write", "admin"])
      # A second owner so the removal is not the last-owner case.
      {:ok, _} = Members.remove_member(ws.id, token_ref(token))

      assert flat_webhooks(raw).status == 403
    end

    test "a workspace-less machine admin token (instance credential) still passes" do
      raw = "seat-machine-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw, "machine", "production", ["read", "write", "admin"])

      assert flat_webhooks(raw).status == 200
    end
  end

  describe "a workspace-less user-owned admin token follows its owner's Default seat (RQ3)" do
    setup do
      %{id: default_id} = Tenancy.get_default_workspace()
      u = user("rq3")

      {:ok, token} =
        Repo.insert(
          Auth.ApiToken.changeset(%Auth.ApiToken{}, %{
            token_hash: Auth.ApiToken.hash_token("rq3-#{u.id}"),
            label: "rq3",
            dataset: "production",
            permissions: ["read", "write", "admin"],
            owner_user_id: u.id
          })
        )

      %{default_id: default_id, user: u, raw: "rq3-#{u.id}", token: token}
    end

    test "a read seat on Default no longer reaches Default's flat admin routes",
         %{default_id: default_id, user: u, raw: raw} do
      {:ok, _} = TenancyAuth.create_membership(default_id, u.id, "member", "user")
      assert flat_webhooks(raw).status == 403
    end

    test "an admin seat on Default still does", %{default_id: default_id, user: u, raw: raw} do
      {:ok, _} = TenancyAuth.create_membership(default_id, u.id, "admin", "user")
      assert flat_webhooks(raw).status == 200
    end
  end

  describe "Tenancy.Auth.authorize/3 token arm (the D22 seat rule)" do
    test "a global-admin token seated as member is not admin there, but still writes" do
      ws = create_workspace!("seat-arm-#{System.unique_integer([:positive])}")
      %{token: token} = bound_token(ws, ["read", "write", "admin"])
      assert TenancyAuth.authorize(token, ws.id, :admin) == :ok

      {:ok, _} = Members.update_role(ws.id, token_ref(token), "member")
      assert TenancyAuth.authorize(token, ws.id, :admin) == {:error, :forbidden}
      assert TenancyAuth.authorize(token, ws.id, :write) == :ok
      assert TenancyAuth.authorize(token, ws.id, :read) == :ok
    end

    test "a write token demoted to a read-only custom role stops writing" do
      ws = create_workspace!("seat-viewer-#{System.unique_integer([:positive])}")
      {:ok, role} = Repo.insert(Role.changeset(%Role{}, %{name: "viewer", workspace_id: ws.id}))

      {:ok, _} =
        Repo.insert(
          RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: "read"})
        )

      %{token: token} = bound_token(ws, ["read", "write"])
      assert TenancyAuth.authorize(token, ws.id, :write) == :ok

      {:ok, _} = Members.update_role(ws.id, token_ref(token), "viewer")
      assert TenancyAuth.authorize(token, ws.id, :write) == {:error, :forbidden}
      assert TenancyAuth.authorize(token, ws.id, :read) == :ok
    end

    test "a user-owned token follows its OWNER's seat: demotion and removal bite" do
      ws = create_workspace!("seat-pat-#{System.unique_integer([:positive])}")
      u = user("pat-owner")
      {:ok, _} = TenancyAuth.create_membership(ws.id, u.id, "admin", "user")

      {:ok, {_raw, pat}} =
        Auth.create_personal_access_token("device", ["read", "write"],
          role: "admin",
          workspace_id: ws.id,
          owner_user_id: u.id
        )

      assert TenancyAuth.authorize(pat, ws.id, :write) == :ok

      # Demote the USER (not the token's own seat) to a read-only custom role.
      {:ok, role} = Repo.insert(Role.changeset(%Role{}, %{name: "reader", workspace_id: ws.id}))

      {:ok, _} =
        Repo.insert(
          RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: "read"})
        )

      {:ok, _} = Members.update_role(ws.id, %{type: :user, id: u.id}, "reader")
      assert TenancyAuth.authorize(pat, ws.id, :write) == {:error, :forbidden}
      assert TenancyAuth.authorize(pat, ws.id, :read) == :ok

      # Remove the user: the token's own seat is still there, but its holder is not.
      {:ok, _} = Members.remove_member(ws.id, %{type: :user, id: u.id})
      assert TenancyAuth.authorize(pat, ws.id, :read) == {:error, :forbidden}
    end
  end

  describe "grants follow the current seat (Q1, former grantor)" do
    test "a global-admin token seated as member cannot revoke the workspace's grants" do
      ws = create_workspace!("seat-grant-#{System.unique_integer([:positive])}")
      %{token: grantor} = bound_token(ws, ["read", "write", "admin"])
      %{token: other} = bound_token(ws, ["read", "write", "admin"])

      {:ok, %{grant: grant}} =
        Access.mint(grantor, %{
          "workspace_id" => ws.id,
          "grantee_email" => "g@example.com",
          "capabilities" => ["read"]
        })

      {:ok, _} = Members.update_role(ws.id, token_ref(other), "member")
      assert {:error, :forbidden} = Access.revoke(grant.id, other)
    end

    test "a grantor whose seat was removed can no longer revoke its grant; a seated one can" do
      ws = create_workspace!("seat-grantor-#{System.unique_integer([:positive])}")
      %{token: keeper} = bound_token(ws, ["read", "write", "admin"])
      %{token: grantor} = bound_token(ws, ["read", "write"])

      {:ok, %{grant: grant}} =
        Access.mint(grantor, %{
          "workspace_id" => ws.id,
          "grantee_email" => "g@example.com",
          "capabilities" => ["read"]
        })

      {:ok, %{grant: grant2}} =
        Access.mint(grantor, %{
          "workspace_id" => ws.id,
          "grantee_email" => "g2@example.com",
          "capabilities" => ["read"]
        })

      assert {:ok, _} = Access.revoke(grant2.id, grantor)

      {:ok, _} = Members.remove_member(ws.id, token_ref(grantor))
      assert {:error, :forbidden} = Access.revoke(grant.id, grantor)
      # A seated admin still can.
      assert {:ok, _} = Access.revoke(grant.id, keeper)
    end
  end
end
