defmodule BarkparkWeb.AccessRequestTest do
  @moduledoc """
  Access requests (task-1b99ba8512bb758e): a signed-in user with no seat asks
  for one (`/v1/auth/access-requests`); an owner or admin of the workspace
  lists, approves with a role, or denies (`/w/:ws/p/:proj/v1/access-requests`).

  On origin/main none of these routes exist, so every test here fails there.

  `async: false`: the dataset-bound cases flip the app-wide
  `:dataset_bound_admin_reads` switch.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :capture_log

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.{Accounts, Auth, Repo}
  alias Barkpark.Accounts.Privacy
  alias Barkpark.Audit.Event
  alias Barkpark.Tenancy.AccessRequest
  alias Barkpark.Tenancy.AccessRequests
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Members

  @admin_perms ["read", "write", "admin"]

  setup do
    ws = create_workspace!("ar-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    other = create_workspace!("ar-other-#{System.unique_integer([:positive])}")
    other_project = create_project!(other)

    previous = Application.get_env(:barkpark, :dataset_bound_admin_reads)
    on_exit(fn -> Application.put_env(:barkpark, :dataset_bound_admin_reads, previous) end)

    %{
      ws: ws,
      base: "/w/#{ws.slug}/p/#{project.slug}/v1",
      other_base: "/w/#{other.slug}/p/#{other_project.slug}/v1",
      admin: seated_token!(ws, "admin"),
      owner: seated_token!(ws, "owner"),
      other_admin: seated_token!(other, "admin"),
      asker: user!()
    }
  end

  defp seated_token!(ws, role, opts \\ []) do
    raw = "ar-#{role}-#{System.unique_integer([:positive])}"

    {:ok, token} =
      if opts[:dataset_bound],
        do: Auth.create_token(raw, "ar", "production", @admin_perms, ws.id, dataset_bound: true),
        else: Auth.create_token(raw, "ar", "production", @admin_perms)

    unless opts[:dataset_bound],
      do: {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, role, "api_token")

    raw
  end

  defp user!(confirmed \\ true) do
    {:ok, user} =
      Accounts.register_user(%{
        email: "asker-#{System.unique_integer([:positive])}@example.com",
        password: "correct horse battery"
      })

    user = if confirmed, do: Accounts.confirm_provisioned_user(user), else: user
    {:ok, session} = Accounts.create_user_session_token(user)
    %{user: user, session: session}
  end

  defp as(bearer) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> bearer)
    |> put_req_header("content-type", "application/json")
  end

  defp ask(%{session: s}, slug, note \\ nil),
    do: as(s) |> post("/v1/auth/access-requests", Jason.encode!(%{workspace: slug, note: note}))

  defp mine(%{session: s}),
    do: json_response(as(s) |> get("/v1/auth/access-requests"), 200)["access_requests"]

  defp approve(raw, base, id, role),
    do: as(raw) |> post("#{base}/access-requests/#{id}/approve", Jason.encode!(%{role: role}))

  defp deny(raw, base, id), do: as(raw) |> post("#{base}/access-requests/#{id}/deny", "{}")

  defp role_in(ws, user) do
    case TenancyAuth.membership(user.id, ws.id, :user) do
      %{role: role} -> role
      nil -> nil
    end
  end

  defp request_row(id), do: Repo.get!(AccessRequest, id)

  defp audit_rows(ws, action) do
    Repo.all(from e in Event, where: e.workspace_id == ^ws.id and e.action == ^action)
  end

  test "a user without a seat asks; an admin lists it and approves; the user is seated", ctx do
    body = json_response(ask(ctx.asker, ctx.ws.slug, "I edit the spring list"), 202)
    req = body["access_request"]
    assert %{"workspace" => slug, "status" => "pending"} = req
    assert slug == ctx.ws.slug

    [listed] =
      json_response(as(ctx.admin) |> get("#{ctx.base}/access-requests"), 200)["access_requests"]

    assert listed["id"] == req["id"]
    assert listed["email"] == ctx.asker.user.email
    assert listed["note"] == "I edit the spring list"

    approved = json_response(approve(ctx.admin, ctx.base, req["id"], "contributor"), 200)
    assert approved["member"]["role"] == "contributor"
    assert approved["member"]["identity"] == ctx.asker.user.email
    assert approved["access_request"]["status"] == "approved"

    # The seat came through Members.add_user_member/4 seating it directly
    # (the user asked): a membership row, no invitation round trip.
    assert role_in(ctx.ws, ctx.asker.user) == "contributor"
    assert Members.list_invitations(ctx.ws.id) == []
    assert [%{status: "approved"}] = mine(ctx.asker) |> Enum.map(&%{status: &1["status"]})

    assert [event] = audit_rows(ctx.ws, "access_request_approved")
    assert event.category == "membership"
    assert event.subject == ctx.asker.user.id
    assert event.metadata["role"] == "contributor"

    # Approved means gone from the pending list.
    assert json_response(as(ctx.admin) |> get("#{ctx.base}/access-requests"), 200)[
             "access_requests"
           ] == []
  end

  test "deny: no seat, the user sees denied, one audit row", ctx do
    id = json_response(ask(ctx.asker, ctx.ws.slug), 202)["access_request"]["id"]

    assert json_response(deny(ctx.admin, ctx.base, id), 200)["access_request"]["status"] ==
             "denied"

    assert role_in(ctx.ws, ctx.asker.user) == nil
    assert [%{"status" => "denied", "id" => ^id}] = mine(ctx.asker)
    assert [%{category: "membership"}] = audit_rows(ctx.ws, "access_request_denied")
    # A decided request is not approvable afterwards.
    assert json_response(approve(ctx.admin, ctx.base, id, "member"), 404)
    assert role_in(ctx.ws, ctx.asker.user) == nil
  end

  test "a missing workspace answers exactly like an existing one; a repeat stays one row", ctx do
    real = ask(ctx.asker, ctx.ws.slug)
    ghost = ask(ctx.asker, "no-such-ws-#{System.unique_integer([:positive])}")

    assert real.status == 202 and ghost.status == 202
    real_row = json_response(real, 202)["access_request"]
    ghost_row = json_response(ghost, 202)["access_request"]
    assert Map.keys(real_row) == Map.keys(ghost_row)
    assert Map.keys(json_response(real, 202)) == Map.keys(json_response(ghost, 202))
    assert ghost_row["status"] == "pending"

    again = json_response(ask(ctx.asker, ctx.ws.slug), 202)["access_request"]
    assert again["id"] == real_row["id"]

    count =
      Repo.aggregate(from(r in AccessRequest, where: r.user_id == ^ctx.asker.user.id), :count)

    assert count == 2
    # The ghost row reaches no admin.
    assert [_one] =
             json_response(as(ctx.admin) |> get("#{ctx.base}/access-requests"), 200)[
               "access_requests"
             ]
  end

  test "a member asking again gets 409 already_member", ctx do
    {:ok, _} = TenancyAuth.create_membership(ctx.ws.id, ctx.asker.user.id, "member", "user")
    assert json_response(ask(ctx.asker, ctx.ws.slug), 409)["error"]["code"] == "already_member"
  end

  test "the sixth ask in an hour is 429", ctx do
    for n <- 1..5, do: assert(ask(ctx.asker, "rl-#{n}-#{ctx.ws.slug}").status == 202)
    resp = ask(ctx.asker, "rl-6-#{ctx.ws.slug}")
    assert json_response(resp, 429)["error"]["code"] == "rate_limited"
    assert get_resp_header(resp, "retry-after") != []
  end

  test "another workspace's admin and a non-admin member see and change nothing", ctx do
    id = json_response(ask(ctx.asker, ctx.ws.slug), 202)["access_request"]["id"]
    member = seated_token!(ctx.ws, "member")

    for raw <- [ctx.other_admin, member] do
      assert as(raw) |> get("#{ctx.base}/access-requests") |> Map.get(:status) == 403
      assert approve(raw, ctx.base, id, "member").status == 403
      assert deny(raw, ctx.base, id).status == 403
    end

    # A forged id: A's request through B's own admin routes is a 404.
    assert json_response(approve(ctx.other_admin, ctx.other_base, id, "admin"), 404)
    assert json_response(deny(ctx.other_admin, ctx.other_base, id), 404)

    assert json_response(as(ctx.other_admin) |> get("#{ctx.other_base}/access-requests"), 200)[
             "access_requests"
           ] == []

    assert request_row(id).status == "pending"
    assert role_in(ctx.ws, ctx.asker.user) == nil
  end

  test "role ceiling: an admin cannot grant owner; an owner can", ctx do
    id = json_response(ask(ctx.asker, ctx.ws.slug), 202)["access_request"]["id"]

    assert json_response(approve(ctx.admin, ctx.base, id, "owner"), 403)["error"]["code"] ==
             "owner_required"

    assert request_row(id).status == "pending"
    assert role_in(ctx.ws, ctx.asker.user) == nil
    assert audit_rows(ctx.ws, "access_request_approved") == []

    assert json_response(approve(ctx.owner, ctx.base, id, "owner"), 200)
    assert role_in(ctx.ws, ctx.asker.user) == "owner"
  end

  test "a dataset-bound admin token: enforce refuses approve and deny; observe records", ctx do
    bound = seated_token!(ctx.ws, "admin", dataset_bound: true)
    id = json_response(ask(ctx.asker, ctx.ws.slug), 202)["access_request"]["id"]

    Application.put_env(:barkpark, :dataset_bound_admin_reads, :enforce)
    assert approve(bound, ctx.base, id, "member").status == 403
    assert deny(bound, ctx.base, id).status == 403
    assert as(bound) |> get("#{ctx.base}/access-requests") |> Map.get(:status) == 403
    assert request_row(id).status == "pending"
    assert role_in(ctx.ws, ctx.asker.user) == nil

    Application.put_env(:barkpark, :dataset_bound_admin_reads, :observe)
    assert json_response(approve(bound, ctx.base, id, "member"), 200)
    assert role_in(ctx.ws, ctx.asker.user) == "member"

    assert [row] = audit_rows(ctx.ws, "bound_token.admin_write")
    assert row.metadata["surface"] == "members_write"
  end

  test "withdraw: own pending only", ctx do
    id = json_response(ask(ctx.asker, ctx.ws.slug), 202)["access_request"]["id"]
    stranger = user!()

    assert json_response(as(stranger.session) |> delete("/v1/auth/access-requests/#{id}"), 404)
    assert json_response(as(ctx.asker.session) |> delete("/v1/auth/access-requests/#{id}"), 200)
    assert mine(ctx.asker) == []
  end

  test "who may ask: an owned token yes, a token nobody owns no, an unconfirmed email no",
       ctx do
    owned_raw = "ar-pat-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(owned_raw, "pat", "production", ["read"], nil,
        owner_user_id: ctx.asker.user.id
      )

    assert json_response(ask(%{session: owned_raw}, ctx.ws.slug), 202)
    assert ask(%{session: ctx.admin}, ctx.ws.slug).status == 401

    unconfirmed = user!(false)

    assert json_response(ask(unconfirmed, ctx.ws.slug), 403)["error"]["code"] ==
             "email_unconfirmed"
  end

  test "erase deletes the user's requests: the admin no longer sees the note, approve seats nobody",
       ctx do
    id =
      json_response(ask(ctx.asker, ctx.ws.slug, "I am Jane Doe, 555-1234"), 202)[
        "access_request"
      ]["id"]

    {:ok, summary} = Privacy.erase_subject(Repo.get!(Accounts.User, ctx.asker.user.id))
    assert summary.access_requests_deleted == 1
    assert Repo.get(AccessRequest, id) == nil

    assert json_response(as(ctx.admin) |> get("#{ctx.base}/access-requests"), 200)[
             "access_requests"
           ] == []

    assert json_response(approve(ctx.admin, ctx.base, id, "member"), 404)
    assert role_in(ctx.ws, ctx.asker.user) == nil
  end

  test "withdraw leaves a decided request alone, even one decided between its read and its delete",
       ctx do
    approved = json_response(ask(ctx.asker, ctx.ws.slug), 202)["access_request"]["id"]
    json_response(approve(ctx.admin, ctx.base, approved, "member"), 200)

    denied = json_response(ask(user!(), ctx.ws.slug), 202)["access_request"]["id"]
    denier = Repo.get!(AccessRequest, denied).user_id
    json_response(deny(ctx.admin, ctx.base, denied), 200)

    assert json_response(
             as(ctx.asker.session) |> delete("/v1/auth/access-requests/#{approved}"),
             404
           )

    assert AccessRequests.withdraw(denier, denied) == {:error, :not_found}
    assert request_row(approved).status == "approved"
    assert request_row(denied).status == "denied"

    # The race: an approve commits while withdraw runs. Simulated by deciding
    # the row as soon as withdraw's FIRST statement on the table returns (in
    # this process only). Whatever the order, withdraw must not answer
    # "withdrawn" for a row an approve had already decided.
    raced = json_response(ask(ctx.asker, "raced-#{ctx.ws.slug}"), 202)["access_request"]["id"]
    handler = "ar-withdraw-race-#{System.unique_integer([:positive])}"
    me = self()

    :ok =
      :telemetry.attach(
        handler,
        [:barkpark, :repo, :query],
        fn _event, _measure, meta, _ ->
          if self() == me and meta[:source] == "workspace_access_requests" and
               Process.get(:ar_decided) == nil do
            Process.put(:ar_decided, 0)

            {n, _} =
              Repo.update_all(
                from(r in AccessRequest, where: r.id == ^raced and r.status == "pending"),
                set: [status: "approved", decided_at: DateTime.utc_now()]
              )

            Process.put(:ar_decided, n)
          end
        end,
        nil
      )

    result =
      try do
        AccessRequests.withdraw(ctx.asker.user.id, raced)
      after
        :telemetry.detach(handler)
      end

    case result do
      {:ok, _} ->
        assert Process.get(:ar_decided) == 0,
               "withdraw deleted a request an approve had already decided"

      {:error, :not_found} ->
        assert request_row(raced).status == "approved"
    end
  end

  test "approve deletes the user's pending invitation to the same workspace", ctx do
    id = json_response(ask(ctx.asker, ctx.ws.slug), 202)["access_request"]["id"]

    invite =
      as(ctx.admin)
      |> post(
        "#{ctx.base}/members",
        Jason.encode!(%{email: ctx.asker.user.email, role: "contributor"})
      )

    assert invite.status == 202
    assert [_] = Members.list_invitations(ctx.ws.id)

    json_response(approve(ctx.admin, ctx.base, id, "member"), 200)
    assert role_in(ctx.ws, ctx.asker.user) == "member"
    assert Members.list_invitations(ctx.ws.id) == []
  end
end
