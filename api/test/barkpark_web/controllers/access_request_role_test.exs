defmodule BarkparkWeb.AccessRequestRoleTest do
  @moduledoc """
  A member asks for a higher role (task-018e79d8734a1b08): `POST
  /v1/auth/access-requests {workspace, role}` from a member; the admin list
  shows the requested and the current role; approve changes the seat through
  `Members.update_role/4`. The seat-request flow is `access_request_test.exs`.

  On origin/main a member's ask is always `409 already_member`, so the
  role-request tests here fail there.

  `async: false`: the dataset-bound case flips the app-wide
  `:dataset_bound_admin_reads` switch.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :capture_log

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.{Accounts, Auth, Repo}
  alias Barkpark.Audit.Event
  alias Barkpark.Tenancy.{AccessRequest, Members, Role, RolePermission}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @admin_perms ["read", "write", "admin"]

  setup do
    ws = create_workspace!("arr-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    other = create_workspace!("arr-other-#{System.unique_integer([:positive])}")
    other_project = create_project!(other)
    custom_role!(ws, "viewer", ~w(read))

    previous = Application.get_env(:barkpark, :dataset_bound_admin_reads)
    on_exit(fn -> Application.put_env(:barkpark, :dataset_bound_admin_reads, previous) end)

    %{
      ws: ws,
      base: "/w/#{ws.slug}/p/#{project.slug}/v1",
      other_base: "/w/#{other.slug}/p/#{other_project.slug}/v1",
      admin: seated_token!(ws, "admin"),
      owner: seated_token!(ws, "owner"),
      other_admin: seated_token!(other, "admin")
    }
  end

  defp custom_role!(ws, name, actions) do
    {:ok, role} = Repo.insert(Role.changeset(%Role{}, %{name: name, workspace_id: ws.id}))

    for action <- actions,
        do:
          {:ok, _} =
            Repo.insert(RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: action}))
  end

  defp seated_token!(ws, role, opts \\ []) do
    raw = "arr-#{role}-#{System.unique_integer([:positive])}"

    {:ok, token} =
      cond do
        opts[:dataset_bound] ->
          Auth.create_token(raw, "arr", "production", @admin_perms, ws.id, dataset_bound: true)

        opts[:owner_user_id] ->
          Auth.create_token(raw, "pat", "production", @admin_perms, nil,
            owner_user_id: opts[:owner_user_id]
          )

        true ->
          Auth.create_token(raw, "arr", "production", @admin_perms)
      end

    unless opts[:dataset_bound],
      do: {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, role, "api_token")

    raw
  end

  # A confirmed user with a login session, seated in `ws` as `role` (nil: no seat).
  defp user!(ws, role) do
    {:ok, user} =
      Accounts.register_user(%{
        email: "arr-#{System.unique_integer([:positive])}@example.com",
        password: "correct horse battery"
      })

    user = Accounts.confirm_provisioned_user(user)
    if role, do: {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, role, "user")
    {:ok, session} = Accounts.create_user_session_token(user)
    %{user: user, session: session}
  end

  defp as(bearer) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> bearer)
    |> put_req_header("content-type", "application/json")
  end

  defp ask(%{session: s}, slug, role),
    do: as(s) |> post("/v1/auth/access-requests", Jason.encode!(%{workspace: slug, role: role}))

  defp approve(raw, base, id, body \\ %{}),
    do: as(raw) |> post("#{base}/access-requests/#{id}/approve", Jason.encode!(body))

  defp listed(raw, base),
    do: json_response(as(raw) |> get("#{base}/access-requests"), 200)["access_requests"]

  defp role_in(ws, %{user: user}) do
    case TenancyAuth.membership(user.id, ws.id, :user) do
      %{role: role} -> role
      nil -> nil
    end
  end

  defp rows_of(%{user: user}),
    do: Repo.all(from r in AccessRequest, where: r.user_id == ^user.id)

  defp approved_audit(ws),
    do:
      Repo.all(
        from e in Event, where: e.workspace_id == ^ws.id and e.action == "access_request_approved"
      )

  test "a viewer asks for member; the admin sees both roles; approve makes them a member", ctx do
    viewer = user!(ctx.ws, "viewer")

    req = json_response(ask(viewer, ctx.ws.slug, "member"), 202)["access_request"]
    assert %{"status" => "pending", "requested_role" => "member"} = req
    assert [%AccessRequest{from_role: "viewer", requested_role: "member"}] = rows_of(viewer)

    assert [row] = listed(ctx.admin, ctx.base)
    assert row["id"] == req["id"]
    assert row["kind"] == "role"
    assert row["requested_role"] == "member"
    assert row["current_role"] == "viewer"

    # No role in the body: the role asked for is granted.
    body = json_response(approve(ctx.admin, ctx.base, req["id"]), 200)
    assert body["member"]["role"] == "member"
    assert body["access_request"]["status"] == "approved"
    assert body["access_request"]["role"] == "member"
    assert role_in(ctx.ws, viewer) == "member"
    assert listed(ctx.admin, ctx.base) == []

    assert [event] = approved_audit(ctx.ws)
    assert event.category == "membership"
    assert event.subject == viewer.user.id
    assert event.metadata["role"] == "member"
    assert event.metadata["from_role"] == "viewer"
  end

  test "an explicit role from the approver wins over the one asked for", ctx do
    viewer = user!(ctx.ws, "viewer")
    id = json_response(ask(viewer, ctx.ws.slug, "admin"), 202)["access_request"]["id"]

    assert json_response(approve(ctx.admin, ctx.base, id, %{role: "contributor"}), 200)
    assert role_in(ctx.ws, viewer) == "contributor"
  end

  test "a member asking for the same, a lower or an unknown role is refused; nothing is stored",
       ctx do
    member = user!(ctx.ws, "member")

    for role <- ["member", "contributor", "viewer"] do
      assert json_response(ask(member, ctx.ws.slug, role), 409)["error"]["code"] ==
               "role_not_higher"
    end

    assert json_response(ask(member, ctx.ws.slug, "no-such-role"), 422)["error"]["code"] ==
             "unknown_role"

    assert json_response(ask(member, ctx.ws.slug, nil), 409)["error"]["code"] == "already_member"
    assert rows_of(member) == []
    assert role_in(ctx.ws, member) == "member"
  end

  test "ceiling: an admin cannot approve owner, the roster path refuses it; an owner can", ctx do
    asker = user!(ctx.ws, "admin")
    id = json_response(ask(asker, ctx.ws.slug, "owner"), 202)["access_request"]["id"]

    assert json_response(approve(ctx.admin, ctx.base, id), 403)["error"]["code"] ==
             "owner_required"

    assert role_in(ctx.ws, asker) == "admin"
    assert Repo.get!(AccessRequest, id).status == "pending"
    assert approved_audit(ctx.ws) == []

    assert json_response(approve(ctx.owner, ctx.base, id), 200)
    assert role_in(ctx.ws, asker) == "owner"
  end

  test "the asker cannot approve their own request through a token they own", ctx do
    asker = user!(ctx.ws, "member")
    own_admin_token = seated_token!(ctx.ws, "admin", owner_user_id: asker.user.id)
    id = json_response(ask(asker, ctx.ws.slug, "admin"), 202)["access_request"]["id"]

    assert json_response(approve(own_admin_token, ctx.base, id), 403)["error"]["code"] ==
             "self_approval"

    assert role_in(ctx.ws, asker) == "member"
    assert Repo.get!(AccessRequest, id).status == "pending"
  end

  test "a seat changed after the ask: approve refuses and changes nothing", ctx do
    moved = user!(ctx.ws, "viewer")
    gone = user!(ctx.ws, "viewer")
    moved_id = json_response(ask(moved, ctx.ws.slug, "member"), 202)["access_request"]["id"]
    gone_id = json_response(ask(gone, ctx.ws.slug, "member"), 202)["access_request"]["id"]

    # Still below `member`, but not the role the request was judged against.
    {:ok, _} = Members.update_role(ctx.ws.id, %{type: :user, id: moved.user.id}, "contributor")
    {:ok, _} = Members.remove_member(ctx.ws.id, %{type: :user, id: gone.user.id})

    assert listed(ctx.admin, ctx.base) |> Enum.map(& &1["stale"]) == [true, true]

    for id <- [moved_id, gone_id] do
      assert json_response(approve(ctx.admin, ctx.base, id), 409)["error"]["code"] ==
               "request_stale"

      assert Repo.get!(AccessRequest, id).status == "pending"
    end

    assert role_in(ctx.ws, moved) == "contributor"
    assert role_in(ctx.ws, gone) == nil
    assert approved_audit(ctx.ws) == []
  end

  test "demoted after asking: asking again replaces the stale request", ctx do
    asker = user!(ctx.ws, "viewer")
    old = json_response(ask(asker, ctx.ws.slug, "admin"), 202)["access_request"]["id"]
    {:ok, _} = Members.update_role(ctx.ws.id, %{type: :user, id: asker.user.id}, "contributor")

    new = json_response(ask(asker, ctx.ws.slug, "admin"), 202)["access_request"]["id"]
    assert new != old
    assert Repo.get(AccessRequest, old) == nil
    assert [%AccessRequest{from_role: "contributor"}] = rows_of(asker)

    assert [%{"id" => ^new, "stale" => false, "current_role" => "contributor"}] =
             listed(ctx.admin, ctx.base)
  end

  test "removed after asking: asking again is a seat request, not the old role request", ctx do
    asker = user!(ctx.ws, "viewer")
    old = json_response(ask(asker, ctx.ws.slug, "member"), 202)["access_request"]["id"]
    {:ok, _} = Members.remove_member(ctx.ws.id, %{type: :user, id: asker.user.id})

    new = json_response(ask(asker, ctx.ws.slug, nil), 202)["access_request"]["id"]
    assert new != old
    assert [%AccessRequest{id: ^new, from_role: nil}] = rows_of(asker)
    assert [%{"kind" => "seat", "stale" => false}] = listed(ctx.admin, ctx.base)

    assert json_response(approve(ctx.admin, ctx.base, new), 200)["member"]["role"] == "member"
  end

  test "approve with a role that would lower or keep the seat is refused", ctx do
    asker = user!(ctx.ws, "contributor")
    id = json_response(ask(asker, ctx.ws.slug, "admin"), 202)["access_request"]["id"]

    for role <- ["contributor", "viewer"] do
      assert json_response(approve(ctx.admin, ctx.base, id, %{role: role}), 409)["error"][
               "code"
             ] == "role_not_higher"
    end

    assert role_in(ctx.ws, asker) == "contributor"
    assert Repo.get!(AccessRequest, id).status == "pending"
  end

  test "another workspace's admin and a non-admin member see and change nothing", ctx do
    asker = user!(ctx.ws, "viewer")
    id = json_response(ask(asker, ctx.ws.slug, "member"), 202)["access_request"]["id"]
    member = seated_token!(ctx.ws, "member")

    for raw <- [ctx.other_admin, member] do
      assert as(raw) |> get("#{ctx.base}/access-requests") |> Map.get(:status) == 403
      assert approve(raw, ctx.base, id).status == 403
    end

    # The forged id: this workspace's request through another workspace's own routes.
    assert json_response(approve(ctx.other_admin, ctx.other_base, id), 404)
    assert listed(ctx.other_admin, ctx.other_base) == []
    assert Repo.get!(AccessRequest, id).status == "pending"
    assert role_in(ctx.ws, asker) == "viewer"
  end

  test "a seatless asker's role is a hint: shape only, never applied by default", ctx do
    stranger = user!(ctx.ws, nil)
    ghost = "arr-ghost-#{System.unique_integer([:positive])}"

    # The same answer for a workspace that has the custom role and one that
    # does not exist: the role tells a stranger nothing.
    real = json_response(ask(stranger, ctx.ws.slug, "viewer"), 202)["access_request"]
    other = json_response(ask(stranger, ghost, "viewer"), 202)["access_request"]
    assert Map.keys(real) == Map.keys(other)
    assert real["requested_role"] == "viewer" and other["requested_role"] == "viewer"

    assert json_response(ask(stranger, ctx.ws.slug <> "-x", "Not A Role"), 422)

    assert [row] = listed(ctx.admin, ctx.base)
    assert row["kind"] == "seat"
    assert row["current_role"] == nil

    assert json_response(approve(ctx.admin, ctx.base, real["id"]), 200)["member"]["role"] ==
             "member"
  end

  test "a dataset-bound admin token: enforce refuses a role approve; observe records one row",
       ctx do
    bound = seated_token!(ctx.ws, "admin", dataset_bound: true)
    asker = user!(ctx.ws, "viewer")
    id = json_response(ask(asker, ctx.ws.slug, "member"), 202)["access_request"]["id"]

    Application.put_env(:barkpark, :dataset_bound_admin_reads, :enforce)
    assert approve(bound, ctx.base, id).status == 403
    assert role_in(ctx.ws, asker) == "viewer"

    Application.put_env(:barkpark, :dataset_bound_admin_reads, :observe)
    assert json_response(approve(bound, ctx.base, id), 200)
    assert role_in(ctx.ws, asker) == "member"

    assert [row] =
             Repo.all(
               from e in Event,
                 where: e.workspace_id == ^ctx.ws.id and e.action == "bound_token.admin_write"
             )

    assert row.metadata["surface"] == "members_write"
  end
end
