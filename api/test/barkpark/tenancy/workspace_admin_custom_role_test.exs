defmodule Barkpark.Tenancy.WorkspaceAdminCustomRoleTest do
  @moduledoc """
  `arpss-w10-bl-workspace-admin-denies-custom-role-admin` — RULED by team-lead
  2026-09-02: `workspace_admin?/2,3` HONOURS a workspace-scoped custom role
  carrying the `admin` action, and the built-in shadowing tripwire ships in the
  same PR.

  THE BUG this file pins the fix for: `workspace_admin?/2` was
  `membership_role(p, ws) in @admin_roles` — a role NAME check — while
  `authorize/3` resolved the ACTION SET through `granted_actions/2`. A
  membership whose role was a workspace custom role holding an `admin`
  permission row therefore passed `authorize(user, ws, :admin)` and FAILED
  `workspace_admin?(user, ws)`, locking a legitimate custom-role admin out of
  every `LiveAuth :scoped_admin` surface (`BarkparkWeb.LiveAuthCustomRoleAdminTest`
  covers the mount).

  Four axes, and three of them are DENIALS this change must not lose:

    * ADMIT — a workspace-scoped custom role carrying `admin` is an admin.
    * DENY (charter D9, global permissions) — a global-`admin` token holding a
      plain `member` row is still NOT a workspace admin.
    * DENY (charter D9, share-edit tokens) — a share-edit token has no
      membership row and is still NOT a workspace admin.
    * DENY (shadowing) — a tenant `roles` row NAMED a built-in cannot redefine
      that built-in. `granted_actions/3` reads the compiled-in
      `@builtin_role_actions` map BEFORE any DB read; the "built-in shadowing"
      tests below red if that lookup order is flipped.

  Plus the C3 disposition: a GLOBAL custom role (`workspace_id: nil`) does NOT
  confer admin in other workspaces. `role_permits?/3` keeps its historical
  `:inherit_global` reach; the admin gate resolves `:workspace_only`.
  """
  use Barkpark.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Accounts
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.{Role, RolePermission}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery"
  @dataset "production"

  defp workspace(slug) do
    {:ok, w} = Tenancy.create_workspace(%{slug: "#{slug}-#{System.unique_integer([:positive])}", name: "WS"})
    w
  end

  defp user(prefix) do
    {:ok, u} =
      Accounts.register_user(%{
        email: "#{prefix}-#{Ecto.UUID.generate()}@example.com",
        password: @password
      })

    u
  end

  # The working recipe from `test/barkpark/tenancy_rbac_test.exs`: a Role row
  # must EXIST before `create_membership/4` will accept its name (the changeset
  # enum is widened by `valid_role_names/1`).
  defp custom_role(ws_id, name, actions) do
    {:ok, role} = Repo.insert(Role.changeset(%Role{}, %{name: name, workspace_id: ws_id}))

    Enum.each(actions, fn a ->
      {:ok, _} =
        Repo.insert(RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: a}))
    end)

    role
  end

  describe "ADMIT — a workspace custom role carrying the admin action" do
    test "workspace_admin?/2 honours it for a USER, and authorize/3 agrees" do
      ws = workspace("cra-admit")
      custom_role(ws.id, "content-lead", ["read", "write", "admin"])
      u = user("content-lead")
      {:ok, _} = TenancyAuth.create_membership(ws.id, u.id, "content-lead", "user")

      # The measured divergence from the filing: authorize said :ok…
      assert TenancyAuth.authorize(u, ws.id, :admin) == :ok
      assert TenancyAuth.membership_role(u, ws.id) == "content-lead"
      assert TenancyAuth.role_permits?("content-lead", ws.id, :admin)

      # …and this is the line that was FALSE on origin/main.
      assert TenancyAuth.workspace_admin?(u, ws.id)
      # The stated-kind arity must agree — /2 and /3 share one rule.
      assert TenancyAuth.workspace_admin?(u.id, ws.id, :user)
    end

    test "a custom role WITHOUT the admin action is still not an admin" do
      ws = workspace("cra-editor")
      custom_role(ws.id, "editor", ["read", "write"])
      u = user("editor")
      {:ok, _} = TenancyAuth.create_membership(ws.id, u.id, "editor", "user")

      assert TenancyAuth.authorize(u, ws.id, :write) == :ok
      refute TenancyAuth.workspace_admin?(u, ws.id)
      refute TenancyAuth.workspace_admin?(u.id, ws.id, :user)
    end

    test "the same custom role name confers nothing in a workspace that did not define it" do
      ws_a = workspace("cra-a")
      ws_b = workspace("cra-b")
      custom_role(ws_a.id, "content-lead", ["read", "write", "admin"])
      u = user("cross")
      {:ok, _} = TenancyAuth.create_membership(ws_a.id, u.id, "content-lead", "user")

      assert TenancyAuth.workspace_admin?(u, ws_a.id)
      # No membership in B at all — the tenant boundary is upstream of the role.
      refute TenancyAuth.workspace_admin?(u, ws_b.id)
    end

    test "an API TOKEN whose membership row carries the custom role is admitted too" do
      ws = workspace("cra-tok")
      custom_role(ws.id, "content-lead", ["read", "write", "admin"])

      raw = "cra-tok-#{System.unique_integer([:positive])}"

      {:ok, tok} =
        %ApiToken{}
        |> ApiToken.changeset(%{
          token_hash: ApiToken.hash_token(raw),
          label: "custom role token",
          dataset: @dataset,
          permissions: ["read", "write"]
        })
        |> Repo.insert()

      {:ok, _} = TenancyAuth.create_membership(ws.id, tok.id, "content-lead", "api_token")

      refute Barkpark.Auth.has_permission?(tok, "admin")
      assert TenancyAuth.workspace_admin?(tok, ws.id)
      assert TenancyAuth.workspace_admin?(tok.id, ws.id, :api_token)
    end
  end

  describe "DENY — charter D9 survives (the two divergences it ratifies)" do
    test "a global-admin TOKEN holding a plain member row is still NOT a workspace admin" do
      ws = workspace("cra-d9-global")
      raw = "cra-global-#{System.unique_integer([:positive])}"

      {:ok, tok} =
        Barkpark.Auth.create_token(raw, "global admin", @dataset, ["read", "write", "admin"])

      {:ok, _} = TenancyAuth.create_membership(ws.id, tok.id)

      # The D9 shape verbatim: authorize/3 admits on the token's global perms…
      assert Barkpark.Auth.has_permission?(tok, "admin")
      assert TenancyAuth.authorize(tok, ws.id, :admin) == :ok
      assert TenancyAuth.membership_role(tok, ws.id) == "member"
      # …and the admin gate still refuses. The custom-role arm never reaches a
      # built-in role name, so "member" cannot borrow an admin action.
      refute TenancyAuth.workspace_admin?(tok, ws.id)
      refute TenancyAuth.workspace_admin?(tok.id, ws.id, :api_token)
    end

    test "a global-admin token stays denied even where the workspace HAS an admin-bearing custom role" do
      ws = workspace("cra-d9-coexist")
      custom_role(ws.id, "content-lead", ["read", "write", "admin"])

      raw = "cra-global2-#{System.unique_integer([:positive])}"

      {:ok, tok} =
        Barkpark.Auth.create_token(raw, "global admin 2", @dataset, ["read", "write", "admin"])

      {:ok, _} = TenancyAuth.create_membership(ws.id, tok.id)

      refute TenancyAuth.workspace_admin?(tok, ws.id)
    end

    test "a share-EDIT token has no membership row and is still NOT a workspace admin" do
      ws = workspace("cra-d9-share")

      {:ok, _proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})

      share_raw = "cra-share-#{System.unique_integer([:positive])}"

      {:ok, share} =
        %ApiToken{}
        |> ApiToken.changeset(%{
          token_hash: ApiToken.hash_token(share_raw),
          label: "share edit",
          dataset: @dataset,
          permissions: ["read", "write"],
          workspace_id: ws.id
        })
        |> Repo.insert()

      # Scope-bound but membership-less: EVERY predicate here denies it.
      assert share.workspace_id == ws.id
      assert TenancyAuth.membership(share, ws.id) == nil
      assert TenancyAuth.membership_role(share, ws.id) == nil
      refute TenancyAuth.workspace_admin?(share, ws.id)
      refute TenancyAuth.workspace_admin?(share.id, ws.id, :api_token)
    end

    test "a non-member and a malformed id both deny without raising" do
      ws = workspace("cra-total")
      u = user("nonmember")

      refute TenancyAuth.workspace_admin?(u, ws.id)
      refute TenancyAuth.workspace_admin?(u, "not-a-uuid")
      refute TenancyAuth.workspace_admin?(u, "")
      refute TenancyAuth.workspace_admin?(nil, ws.id)
      refute TenancyAuth.workspace_admin?(u.id, nil, :user)
    end
  end

  describe "TRIPWIRE — built-in shadowing: a tenant row named a built-in cannot escalate" do
    # MUTATION THIS REDS ON: swap the two arms of the `case` in
    # `granted_actions/3` so `db_actions/3` is consulted before
    # `@builtin_role_actions`. Then the workspace's own "member" row (carrying
    # an `admin` action) wins and both assertions below flip to true.
    test "a workspace row NAMED \"member\" carrying an admin action grants no admin" do
      ws = workspace("cra-shadow-member")
      custom_role(ws.id, "member", ["read", "write", "admin"])
      u = user("shadow-member")
      {:ok, _} = TenancyAuth.create_membership(ws.id, u.id, "member", "user")

      # The resolver ignores the DB row for a built-in NAME, in both readers.
      refute TenancyAuth.role_permits?("member", ws.id, :admin)
      assert TenancyAuth.authorize(u, ws.id, :admin) == {:error, :forbidden}
      refute TenancyAuth.workspace_admin?(u, ws.id)
      refute TenancyAuth.workspace_admin?(u.id, ws.id, :user)

      # …and the row really is there — the test is not vacuous.
      assert Repo.exists?(
               from r in Role,
                 join: rp in RolePermission,
                 on: rp.role_id == r.id,
                 where: r.name == "member" and r.workspace_id == ^ws.id and rp.action == "admin"
             )
    end

    test "a workspace row NAMED \"admin\" cannot WEAKEN the built-in either" do
      ws = workspace("cra-shadow-admin")
      # A tenant row that grants only :read under the name "admin".
      custom_role(ws.id, "admin", ["read"])
      u = user("shadow-admin")
      {:ok, _} = TenancyAuth.create_membership(ws.id, u.id, "admin", "user")

      # The compiled map still owns "admin" — no silent lockout, no silent
      # narrowing. `role_permits?` reds here too if the lookup order flips.
      assert TenancyAuth.role_permits?("admin", ws.id, :admin)
      assert TenancyAuth.workspace_admin?(u, ws.id)
      assert TenancyAuth.workspace_admin?(u.id, ws.id, :user)
    end

    test "a built-in admin is admitted with NO roles row at all (the fail-safe)" do
      ws = workspace("cra-failsafe")
      u = user("failsafe")
      {:ok, _} = TenancyAuth.create_membership(ws.id, u.id, "admin", "user")

      refute Repo.exists?(from r in Role, where: r.workspace_id == ^ws.id)
      assert TenancyAuth.workspace_admin?(u, ws.id)
    end
  end

  describe "C3 — a GLOBAL custom role (workspace_id: nil) does not confer admin everywhere" do
    # DISPOSITION: NARROWED. Nothing in `api/lib` writes a nil-`workspace_id`
    # CUSTOM role — `Barkpark.Seeds.Shared.ensure_builtin_roles/0` is the sole
    # `Role` writer and inserts owner/admin/member only — and the migration
    # declares "NULL = global built-in". So a nil-workspace custom row is an
    # unintended shape, and the admin gate resolves `:workspace_only`.
    #
    # What is NOT narrowed, deliberately: `role_permits?/3` and `authorize/3`
    # keep their historical `:inherit_global` reach. Narrowing THEM would be a
    # silent authorization tightening on the chokepoint, out of this row's
    # scope; the asserts below pin that reach so a future narrowing is a
    # visible decision rather than a drift.
    test "the ADMIN gate refuses a nil-workspace custom role in an unrelated workspace" do
      ws_a = workspace("cra-glob-a")
      ws_b = workspace("cra-glob-b")

      {:ok, role} = Repo.insert(Role.changeset(%Role{}, %{name: "global-lead"}))
      assert role.workspace_id == nil

      {:ok, _} =
        Repo.insert(RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: "admin"}))

      u = user("global-lead")
      {:ok, _} = TenancyAuth.create_membership(ws_a.id, u.id, "global-lead", "user")
      {:ok, _} = TenancyAuth.create_membership(ws_b.id, u.id, "global-lead", "user")

      # The amplifier the filing proved: role_permits?/authorize still see the
      # global row in EVERY workspace (unchanged, and pinned here on purpose).
      assert TenancyAuth.role_permits?("global-lead", ws_a.id, :admin)
      assert TenancyAuth.role_permits?("global-lead", ws_b.id, :admin)

      # The admin gate does NOT. One hand-inserted global row can no longer
      # mint an admin of every workspace on the instance.
      refute TenancyAuth.workspace_admin?(u, ws_a.id)
      refute TenancyAuth.workspace_admin?(u, ws_b.id)
    end

    test "a workspace-scoped row of the SAME name still confers admin in ITS workspace" do
      ws_a = workspace("cra-glob-scoped-a")
      ws_b = workspace("cra-glob-scoped-b")

      {:ok, global} = Repo.insert(Role.changeset(%Role{}, %{name: "dual-lead"}))

      {:ok, _} =
        Repo.insert(
          RolePermission.changeset(%RolePermission{}, %{role_id: global.id, action: "admin"})
        )

      custom_role(ws_a.id, "dual-lead", ["read", "write", "admin"])

      u = user("dual-lead")
      {:ok, _} = TenancyAuth.create_membership(ws_a.id, u.id, "dual-lead", "user")
      {:ok, _} = TenancyAuth.create_membership(ws_b.id, u.id, "dual-lead", "user")

      # A defined in A, only the global row reaches B.
      assert TenancyAuth.workspace_admin?(u, ws_a.id)
      refute TenancyAuth.workspace_admin?(u, ws_b.id)
    end
  end
end
