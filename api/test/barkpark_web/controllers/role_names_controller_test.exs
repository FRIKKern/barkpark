defmodule BarkparkWeb.RoleNamesControllerTest do
  @moduledoc """
  task-4d3cd1a5e8265646 — `GET /w/:ws/p/:proj/v1/workspace/roles`: every role
  name a seat in this workspace may hold, for any seated member, names only.
  The Studio's paste lock needs it for people who are not admins, signed in
  with their own login session.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Access, Accounts, Auth, Repo}
  alias Barkpark.Tenancy.{Role, RolePermission}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct horse battery staple"
  @dataset "production"
  @built_ins ["owner", "admin", "member", "contributor"]

  setup do
    ws = create_workspace!("roles-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    admin_raw = "roles-admin-#{System.unique_integer([:positive])}"
    {:ok, admin} = Auth.create_token(admin_raw, "roles-admin", @dataset, ~w(read write admin))
    {:ok, _} = TenancyAuth.create_membership(ws.id, admin.id, "admin", "api_token")
    member_raw = "roles-member-#{System.unique_integer([:positive])}"
    {:ok, member} = Auth.create_token(member_raw, "roles-member", @dataset, ~w(read write))
    {:ok, _} = TenancyAuth.create_membership(ws.id, member.id, "member", "api_token")

    email = "roles-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    Accounts.confirm_provisioned_user(user)

    %{
      ws: ws,
      project: project,
      admin: admin,
      admin_raw: admin_raw,
      member_raw: member_raw,
      email: email,
      user: user
    }
  end

  defp custom_role!(workspace_id, name) do
    {:ok, role} =
      Repo.insert(Role.changeset(%Role{}, %{workspace_id: workspace_id, name: name}))

    {:ok, _} =
      Repo.insert(
        RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: "read"})
      )

    role
  end

  defp bearer(raw), do: put_req_header(scoped_conn(), "authorization", "Bearer #{raw}")
  defp roles_path(ws, project), do: "/w/#{ws.slug}/p/#{project.slug}/v1/workspace/roles"

  defp login!(email) do
    scoped_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/v1/auth/login", Jason.encode!(%{email: email, password: @password}))
    |> json_response(201)
    |> Map.fetch!("token")
  end

  # Seated the way the Studio's people are: invited by an admin, accepted with
  # their own login session.
  defp seated_session!(ctx) do
    token = login!(ctx.email)

    bearer(ctx.admin_raw)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/members",
      Jason.encode!(%{email: ctx.email, role: "member"})
    )
    |> json_response(202)

    [inv] = json_response(bearer(token) |> get("/v1/auth/invitations"), 200)["invitations"]

    bearer(token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/auth/invitations/#{inv["id"]}/accept", "{}")
    |> json_response(201)

    token
  end

  test "a plain member gets the built-ins, then custom and global names A-Z, names only", ctx do
    custom_role!(ctx.ws.id, "reviewer")
    custom_role!(ctx.ws.id, "editor-in-chief")
    global = "global-#{System.unique_integer([:positive])}"
    custom_role!(nil, global)

    expected = @built_ins ++ Enum.sort(["reviewer", "editor-in-chief", global])
    body = json_response(bearer(ctx.member_raw) |> get(roles_path(ctx.ws, ctx.project)), 200)
    assert body == %{"roles" => expected}
  end

  test "a plain member signed in with their login session gets the list", ctx do
    custom_role!(ctx.ws.id, "reviewer")
    token = seated_session!(ctx)
    body = json_response(bearer(token) |> get(roles_path(ctx.ws, ctx.project)), 200)
    assert body["roles"] == @built_ins ++ ["reviewer"]
  end

  test "another workspace's custom role never appears", ctx do
    other = create_workspace!("roles-other-#{System.unique_integer([:positive])}")
    custom_role!(other.id, "other-secret")
    custom_role!(ctx.ws.id, "reviewer")

    conn = bearer(ctx.member_raw) |> get(roles_path(ctx.ws, ctx.project))
    roles = json_response(conn, 200)["roles"]
    refute "other-secret" in roles
    assert "reviewer" in roles
  end

  describe "refusals" do
    test "a non-member token and a non-member session get 403 not_a_member", ctx do
      stranger_raw = "roles-stranger-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(stranger_raw, "roles-stranger", @dataset, ~w(read))
      token = login!(ctx.email)

      for raw <- [stranger_raw, token] do
        conn = bearer(raw) |> get(roles_path(ctx.ws, ctx.project))
        assert %{"error" => %{"code" => "forbidden"} = err} = json_response(conn, 403)
        assert err["reason"] == "not_a_member"
      end
    end

    test "a member of another workspace is refused here", ctx do
      other = create_workspace!("roles-elsewhere-#{System.unique_integer([:positive])}")
      other_project = create_project!(other)
      conn = bearer(ctx.member_raw) |> get(roles_path(other, other_project))
      assert json_response(conn, 403)["error"]["reason"] == "not_a_member"
    end

    test "a dataset-bound token reads its workspace's list, and is refused naming another dataset",
         ctx do
      raw = "roles-bound-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.create_token(raw, "roles-bound", @dataset, ~w(read), ctx.ws.id, dataset_bound: true)

      assert json_response(bearer(raw) |> get(roles_path(ctx.ws, ctx.project)), 200)["roles"] ==
               @built_ins

      conn = bearer(raw) |> get(roles_path(ctx.ws, ctx.project) <> "?dataset=staging")
      err = json_response(conn, 403)["error"]
      assert %{"code" => "forbidden", "reason" => "dataset_not_bound"} = err
    end

    test "a login session admitted only by an access grant, with no seat, is refused", ctx do
      {:ok, %{token: grant_raw}} =
        Access.mint(ctx.admin, %{
          grantee_email: ctx.email,
          workspace_id: ctx.ws.id,
          project_id: ctx.project.id,
          dataset: @dataset,
          type: "granted-type",
          capabilities: ["read"]
        })

      assert {:ok, _} = Access.claim(grant_raw, ctx.user)
      refute TenancyAuth.member?(ctx.user, ctx.ws.id)

      conn = bearer(login!(ctx.email)) |> get(roles_path(ctx.ws, ctx.project))
      assert json_response(conn, 403)["error"]["reason"] == "not_a_member"
    end
  end
end
