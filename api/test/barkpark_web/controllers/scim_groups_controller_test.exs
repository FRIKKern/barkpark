defmodule BarkparkWeb.ScimGroupsControllerTest do
  @moduledoc "SCIM 2.0 /scim/v2/Groups — group→role mapping (era-w4-scim-groups)."
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Accounts, Repo, Scim, Tenancy}
  alias Barkpark.Audit.Event
  alias Barkpark.Tenancy.{Auth, Role, RolePermission}
  import Ecto.Query

  defp org_with_ws(slug) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug <> "-ws", name: "WS"})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {:ok, {token, _}} = Scim.mint_token(org.id, "test")
    %{org: org, ws: ws, token: token}
  end

  defp scim(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  defp provision(token, email),
    do:
      scim(token)
      |> post("/scim/v2/Users", Jason.encode!(%{"userName" => email}))
      |> json_response(201)

  defp custom_role(ws_id, name, actions) do
    {:ok, role} = Repo.insert(Role.changeset(%Role{}, %{name: name, workspace_id: ws_id}))

    Enum.each(actions, fn a ->
      {:ok, _} =
        Repo.insert(RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: a}))
    end)

    role
  end

  defp member_op(op, user_id),
    do:
      Jason.encode!(%{
        "Operations" => [%{"op" => op, "path" => "members", "value" => [%{"value" => user_id}]}]
      })

  describe "group → custom role, enforced at authorize/3" do
    test "adding a user to a group grants the mapped role; removing reverts it" do
      %{ws: ws, token: token} = org_with_ws("grp")
      custom_role(ws.id, "editor-no-publish", ["read"])
      provision(token, "u@grp.com")
      user = Accounts.get_user_by_email("u@grp.com")

      # baseline: provisioned as member → can write
      assert Auth.authorize(user, ws.id, :write) == :ok

      # map a group to the read-only custom role
      gid =
        scim(token)
        |> post(
          "/scim/v2/Groups",
          Jason.encode!(%{"displayName" => "Editors", "role" => "editor-no-publish"})
        )
        |> json_response(201)
        |> Map.fetch!("id")

      # add to group → role becomes editor-no-publish → write is now forbidden
      scim(token)
      |> patch("/scim/v2/Groups/#{gid}", member_op("add", user.id))
      |> json_response(200)

      assert Auth.authorize(user, ws.id, :read) == :ok
      assert Auth.authorize(user, ws.id, :write) == {:error, :forbidden}

      # remove from group → reverts to member → write allowed again
      scim(token)
      |> patch("/scim/v2/Groups/#{gid}", member_op("remove", user.id))
      |> json_response(200)

      assert Auth.authorize(user, ws.id, :write) == :ok
    end

    test "membership changes are audited" do
      %{ws: ws, token: token} = org_with_ws("grpaudit")
      custom_role(ws.id, "reviewer", ["read"])
      provision(token, "a@grpaudit.com")
      user = Accounts.get_user_by_email("a@grpaudit.com")

      gid =
        scim(token)
        |> post(
          "/scim/v2/Groups",
          Jason.encode!(%{"displayName" => "Reviewers", "role" => "reviewer"})
        )
        |> json_response(201)
        |> Map.fetch!("id")

      scim(token)
      |> patch("/scim/v2/Groups/#{gid}", member_op("add", user.id))
      |> json_response(200)

      scim(token)
      |> patch("/scim/v2/Groups/#{gid}", member_op("remove", user.id))
      |> json_response(200)

      assert Repo.exists?(from e in Event, where: e.action == "group_member_added")
      assert Repo.exists?(from e in Event, where: e.action == "group_member_removed")
    end
  end

  describe "group creation validation + isolation" do
    test "400 when the mapped role does not exist" do
      %{token: token} = org_with_ws("grpbad")

      assert scim(token)
             |> post(
               "/scim/v2/Groups",
               Jason.encode!(%{"displayName" => "X", "role" => "no-such-role"})
             )
             |> json_response(400)
    end

    test "a built-in role (admin) is an accepted mapping" do
      %{token: token} = org_with_ws("grpadmin")

      assert scim(token)
             |> post(
               "/scim/v2/Groups",
               Jason.encode!(%{"displayName" => "Admins", "role" => "admin"})
             )
             |> json_response(201)
    end

    test "org isolation: a group in org A is not visible to org B" do
      %{token: token_a} = org_with_ws("g-org-a")
      %{token: token_b} = org_with_ws("g-org-b")

      gid =
        scim(token_a)
        |> post("/scim/v2/Groups", Jason.encode!(%{"displayName" => "AOnly", "role" => "member"}))
        |> json_response(201)
        |> Map.fetch!("id")

      assert scim(token_b) |> get("/scim/v2/Groups/#{gid}") |> json_response(404)
      assert scim(token_a) |> get("/scim/v2/Groups/#{gid}") |> json_response(200)
    end
  end
end
