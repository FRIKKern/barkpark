defmodule Barkpark.ScimGroupRoleValidationTest do
  @moduledoc """
  SCIM group-membership role writes route through `Membership.changeset/3`
  with the same per-workspace valid-role set `Tenancy.Auth.create_membership/4`
  enforces (arpss-w10-bl-scim-set-member-role-unvalidated).

  Before this seam, `Scim.set_member_role/3` was a raw `Repo.update_all` gated
  only by the EXISTENCE check `known_role?/2` at group-CREATE time — a Role
  deleted after the group was created (or scoped to a different workspace of
  the org) still landed on every membership with zero validation.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.{Accounts, Repo, Scim, Tenancy}
  alias Barkpark.Scim.Group
  alias Barkpark.Tenancy.{Membership, Role}
  import Ecto.Query

  defp org_with_ws(slug) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug <> "-ws", name: "WS"})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    %{org: org, ws: ws}
  end

  defp provision(org, email) do
    {:ok, _user} = Scim.provision_user(org, %{"userName" => email})
    Accounts.get_user_by_email(email)
  end

  # A group row inserted DIRECTLY, bypassing create_group's known_role? gate —
  # the stored-state shape a post-create Role deletion leaves behind.
  defp group!(org, role_name) do
    {:ok, group} =
      Repo.insert(
        Group.changeset(%Group{}, %{
          organization_id: org.id,
          display_name: "g-" <> role_name,
          role_name: role_name
        })
      )

    group
  end

  defp stored_roles(user_id) do
    Repo.all(
      from(m in Membership,
        where: m.principal_type == "user" and m.principal_id == ^user_id,
        order_by: m.inserted_at,
        select: m.role
      )
    )
  end

  test "a role the membership changeset would reject is REFUSED, not written" do
    %{org: org} = org_with_ws("scim-inv")
    user = provision(org, "u@scim-inv.com")
    assert stored_roles(user.id) == ["member"]

    # No Role row named "ghost-role" exists anywhere — known_role? would have
    # blocked group CREATION, but the write path itself must also refuse.
    group = group!(org, "ghost-role")

    assert {:error, :invalid_role} = Scim.add_group_member(org, group, user.id)
    assert stored_roles(user.id) == ["member"]
  end

  test "a workspace-scoped role is refused ATOMICALLY across a multi-workspace org" do
    %{org: org, ws: ws1} = org_with_ws("scim-atom")
    {:ok, ws2} = Tenancy.create_workspace(%{slug: "scim-atom-ws2", name: "WS2"})
    {:ok, _ws2} = Tenancy.assign_workspace_to_organization(ws2, org.id)

    # Valid in ws1 ONLY. known_role?/2 (org-wide existence) accepts it, so
    # group creation succeeds — but the org-wide grant must refuse rather than
    # attach a role to a ws2 membership whose changeset rejects it.
    {:ok, _role} =
      Repo.insert(Role.changeset(%Role{}, %{name: "ws1-editor", workspace_id: ws1.id}))

    user = provision(org, "u@scim-atom.com")
    assert stored_roles(user.id) == ["member", "member"]

    assert {:ok, group} =
             Scim.create_group(org, %{"displayName" => "Editors", "role" => "ws1-editor"})

    assert {:error, :invalid_role} = Scim.add_group_member(org, group, user.id)

    # Transaction rollback: NEITHER membership moved — no partial grant.
    assert stored_roles(user.id) == ["member", "member"]
  end

  test "a valid custom role still lands, and remove reverts it (positive control)" do
    %{org: org, ws: ws} = org_with_ws("scim-ok")
    {:ok, _role} = Repo.insert(Role.changeset(%Role{}, %{name: "editor", workspace_id: ws.id}))
    user = provision(org, "u@scim-ok.com")

    assert {:ok, group} =
             Scim.create_group(org, %{"displayName" => "Editors", "role" => "editor"})

    assert {:ok, 1} = Scim.add_group_member(org, group, user.id)
    assert stored_roles(user.id) == ["editor"]

    assert {:ok, 1} = Scim.remove_group_member(org, group, user.id)
    assert stored_roles(user.id) == ["member"]
  end
end
