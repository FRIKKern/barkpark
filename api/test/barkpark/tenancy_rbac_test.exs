defmodule Barkpark.TenancyRbacTest do
  @moduledoc "era-w1-custom-rbac Stage A — data-driven USER roles at the authorize/3 chokepoint."
  use Barkpark.DataCase, async: false

  alias Barkpark.Accounts
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.{Auth, Role, RolePermission}
  alias Barkpark.Seeds.Shared
  import Ecto.Query

  @password "correct-horse-battery"

  defp workspace(slug),
    do:
      (fn ->
         {:ok, w} = Tenancy.create_workspace(%{slug: slug, name: "WS"})
         w
       end).()

  defp user(email) do
    {:ok, u} =
      Accounts.register_user(%{
        email: email <> "-" <> Ecto.UUID.generate() <> "@x.com",
        password: @password
      })

    u
  end

  defp custom_role(ws_id, name, actions) do
    {:ok, role} = Repo.insert(Role.changeset(%Role{}, %{name: name, workspace_id: ws_id}))

    Enum.each(actions, fn a ->
      {:ok, _} =
        Repo.insert(RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: a}))
    end)

    role
  end

  describe "custom role enforces at authorize/3 (the headline: editors cannot publish)" do
    test "a user with editor-no-publish (read only) can read but not write/admin" do
      ws = workspace("rbac-editor")
      custom_role(ws.id, "editor-no-publish", ["read"])
      u = user("editor")
      {:ok, _} = Auth.create_membership(ws.id, u.id, "editor-no-publish", "user")

      assert Auth.authorize(u, ws.id, :read) == :ok
      assert Auth.authorize(u, ws.id, :write) == {:error, :forbidden}
      assert Auth.authorize(u, ws.id, :admin) == {:error, :forbidden}
    end

    test "a custom role granting read+write allows write but not admin" do
      ws = workspace("rbac-editor2")
      custom_role(ws.id, "editor", ["read", "write"])
      u = user("ed2")
      {:ok, _} = Auth.create_membership(ws.id, u.id, "editor", "user")

      assert Auth.authorize(u, ws.id, :write) == :ok
      assert Auth.authorize(u, ws.id, :admin) == {:error, :forbidden}
    end
  end

  describe "workspace scoping" do
    test "a workspace that did NOT define the custom role rejects it at create_membership" do
      ws_a = workspace("rbac-a")
      ws_b = workspace("rbac-b")
      custom_role(ws_a.id, "editor-no-publish", ["read"])
      u = user("scoped")

      # defined in A → accepted
      assert {:ok, _} = Auth.create_membership(ws_a.id, u.id, "editor-no-publish", "user")
      # NOT defined in B → the changeset rejects the unknown role
      assert {:error, cs} = Auth.create_membership(ws_b.id, u.id, "editor-no-publish", "user")
      refute cs.valid?
    end
  end

  describe "fail-safe: built-in enforcement never depends on a DB row" do
    test "a member user still gets write even with NO seeded role rows" do
      ws = workspace("rbac-nodb")
      u = user("nodb")
      {:ok, _} = Auth.create_membership(ws.id, u.id, "member", "user")

      # No ensure_builtin_roles/0 here — the compiled-in fallback must hold.
      assert Auth.authorize(u, ws.id, :read) == :ok
      assert Auth.authorize(u, ws.id, :write) == :ok
      assert Auth.authorize(u, ws.id, :admin) == {:error, :forbidden}
    end

    test "seeded built-in rows agree with the fallback (DB path exercised)" do
      Shared.ensure_builtin_roles()
      ws = workspace("rbac-seeded")
      u = user("seeded")
      {:ok, _} = Auth.create_membership(ws.id, u.id, "member", "user")

      # global built-in rows now exist
      assert Repo.aggregate(
               from(r in Role, where: is_nil(r.workspace_id) and r.name == "member"),
               :count
             ) == 1

      assert Auth.authorize(u, ws.id, :write) == :ok
      assert Auth.authorize(u, ws.id, :admin) == {:error, :forbidden}
    end
  end

  describe "built-in precedence: a tenant cannot redefine a built-in to escalate" do
    test "a workspace role named admin cannot narrow/alter the built-in admin grant" do
      ws = workspace("rbac-escalate")
      # Attempt to define a workspace-scoped 'admin' with only :read.
      custom_role(ws.id, "admin", ["read"])
      u = user("esc")
      {:ok, _} = Auth.create_membership(ws.id, u.id, "admin", "user")

      # built-in map wins → admin still grants admin (the tenant row is ignored
      # for the built-in name), so no privilege change either way.
      assert Auth.authorize(u, ws.id, :admin) == :ok
    end
  end

  describe "membership changeset role validation" do
    test "rejects an unknown role, accepts a known custom role" do
      ws = workspace("rbac-cs")
      custom_role(ws.id, "reviewer", ["read"])
      u = user("cs")

      assert {:error, cs} = Auth.create_membership(ws.id, u.id, "nonexistent-role", "user")
      refute cs.valid?
      assert {:ok, _} = Auth.create_membership(ws.id, u.id, "reviewer", "user")
    end
  end
end
