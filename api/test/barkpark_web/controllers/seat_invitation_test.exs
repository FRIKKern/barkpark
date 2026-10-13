defmodule BarkparkWeb.SeatInvitationTest do
  @moduledoc """
  OWNER RULING 2026-10-03 #7 (task-a08da65bc33083d0): seating an EXISTING
  user needs their acceptance.

  The hole the row names: an admin of workspace `aaa` seated any existing
  account, and that user's next self-minted PAT bound to `aaa` (the first
  workspace by slug). Now the roster API stores an invitation; nothing is
  seated — and so nothing changes which workspace the user's next PAT binds
  to — until the user accepts.
  """
  use BarkparkWeb.ConnCase, async: true

  @password "correct horse battery"

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup do
    ws = create_workspace!("aaa-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    raw = "inv-admin-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "inv-admin", @dataset, ["read", "write", "admin"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "admin", "api_token")

    home = create_workspace!("zzz-home-#{System.unique_integer([:positive])}")

    {:ok, victim} =
      Accounts.register_user(%{
        email: "victim-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    victim = Accounts.confirm_provisioned_user(victim)
    {:ok, _} = TenancyAuth.create_membership(home.id, victim.id, "owner", "user")
    {:ok, session} = Accounts.create_user_session_token(victim)

    %{ws: ws, project: project, admin_raw: raw, home: home, victim: victim, session: session}
  end

  defp admin(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp as_user(session) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{session}")
    |> put_req_header("content-type", "application/json")
  end

  defp seat(ctx, email, role \\ "member") do
    admin(ctx.admin_raw)
    |> post(
      "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/members",
      Jason.encode!(%{email: email, role: role})
    )
  end

  defp mint_pat(session) do
    as_user(session)
    |> post("/v1/auth/tokens", Jason.encode!(%{name: "laptop", current_password: @password}))
  end

  test "seating an existing user stores an invitation and seats nothing", ctx do
    resp = seat(ctx, ctx.victim.email)
    body = json_response(resp, 202)

    assert body["invitation"]["email"] == ctx.victim.email
    assert body["invitation"]["role"] == "member"
    refute TenancyAuth.membership(ctx.victim.id, ctx.ws.id, :user)
  end

  test "the user's next self-minted PAT still binds to their own workspace", ctx do
    assert seat(ctx, ctx.victim.email).status == 202

    pat = json_response(mint_pat(ctx.session), 201)
    {:ok, token} = Auth.verify_token(pat["token"])
    assert token.workspace_id == ctx.home.id
    refute token.workspace_id == ctx.ws.id
  end

  test "the user lists, accepts and is then seated with the invited role", ctx do
    assert seat(ctx, ctx.victim.email, "admin").status == 202

    [inv] = json_response(as_user(ctx.session) |> get("/v1/auth/invitations"), 200)["invitations"]
    assert inv["workspace"] == ctx.ws.slug

    accepted = as_user(ctx.session) |> post("/v1/auth/invitations/#{inv["id"]}/accept", "{}")
    assert json_response(accepted, 201)["member"]["role"] == "admin"
    assert %{role: "admin"} = TenancyAuth.membership(ctx.victim.id, ctx.ws.id, :user)

    assert json_response(as_user(ctx.session) |> get("/v1/auth/invitations"), 200)["invitations"] ==
             []
  end

  test "the user can decline; the admin can list and withdraw", ctx do
    assert seat(ctx, ctx.victim.email).status == 202

    [inv] =
      json_response(
        admin(ctx.admin_raw) |> get("/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/invitations"),
        200
      )[
        "invitations"
      ]

    assert inv["email"] == ctx.victim.email
    assert seat(ctx, ctx.victim.email).status == 409

    assert admin(ctx.admin_raw)
           |> delete("/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/invitations/#{inv["id"]}")
           |> json_response(200)

    assert seat(ctx, ctx.victim.email).status == 202

    [inv2] =
      json_response(as_user(ctx.session) |> get("/v1/auth/invitations"), 200)["invitations"]

    assert as_user(ctx.session)
           |> delete("/v1/auth/invitations/#{inv2["id"]}")
           |> json_response(200)

    refute TenancyAuth.membership(ctx.victim.id, ctx.ws.id, :user)
  end

  test "another user cannot accept someone else's invitation", ctx do
    assert seat(ctx, ctx.victim.email).status == 202
    [inv] = json_response(as_user(ctx.session) |> get("/v1/auth/invitations"), 200)["invitations"]

    {:ok, other} =
      Accounts.register_user(%{
        email: "other-#{System.unique_integer([:positive])}@example.com",
        password: "correct horse battery"
      })

    {:ok, other_session} = Accounts.create_user_session_token(other)

    assert as_user(other_session)
           |> post("/v1/auth/invitations/#{inv["id"]}/accept", "{}")
           |> json_response(404)

    refute TenancyAuth.membership(other.id, ctx.ws.id, :user)
    refute TenancyAuth.membership(ctx.victim.id, ctx.ws.id, :user)
  end

  test "a user in several workspaces must name the PAT's workspace", ctx do
    assert seat(ctx, ctx.victim.email).status == 202
    [inv] = json_response(as_user(ctx.session) |> get("/v1/auth/invitations"), 200)["invitations"]

    assert as_user(ctx.session)
           |> post("/v1/auth/invitations/#{inv["id"]}/accept", "{}")
           |> json_response(201)

    body = json_response(mint_pat(ctx.session), 422)
    assert body["error"]["code"] == "workspace_required"
    assert Enum.sort(body["error"]["workspaces"]) == Enum.sort([ctx.ws.slug, ctx.home.slug])

    named =
      as_user(ctx.session)
      |> post(
        "/v1/auth/tokens",
        Jason.encode!(%{name: "laptop", workspace: ctx.home.slug, current_password: @password})
      )
      |> json_response(201)

    {:ok, token} = Auth.verify_token(named["token"])
    assert token.workspace_id == ctx.home.id

    stranger = create_workspace!("stranger-#{System.unique_integer([:positive])}")

    assert as_user(ctx.session)
           |> post(
             "/v1/auth/tokens",
             Jason.encode!(%{name: "x", workspace: stranger.slug, current_password: @password})
           )
           |> json_response(403)
  end

  test "a user in several workspaces names one by id too, and the PAT reads there", ctx do
    # The CLI and Studio never call this route (no `bp` verb mints a PAT here;
    # `bp token create` uses the scoped /w/:ws/p/:proj/v1/tokens door, whose URL
    # names the workspace). A two-workspace user who names the workspace once
    # gets a PAT that works on the CLI's scoped data verbs in that workspace.
    assert seat(ctx, ctx.victim.email).status == 202
    [inv] = json_response(as_user(ctx.session) |> get("/v1/auth/invitations"), 200)["invitations"]

    assert as_user(ctx.session)
           |> post("/v1/auth/invitations/#{inv["id"]}/accept", "{}")
           |> json_response(201)

    pat =
      as_user(ctx.session)
      |> post(
        "/v1/auth/tokens",
        Jason.encode!(%{name: "cli", workspace: ctx.ws.id, current_password: @password})
      )
      |> json_response(201)

    {:ok, token} = Auth.verify_token(pat["token"])
    assert token.workspace_id == ctx.ws.id

    # Authorized in the named workspace: no 401/403 (the fixture project holds
    # no dataset rows, so the read itself may answer 404 dataset-not-found).
    status =
      admin(pat["token"])
      |> get("/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/data/query/#{@dataset}/post")
      |> Map.fetch!(:status)

    refute status in [401, 403]
  end

  test "a brand-new e-mail is still seated directly (201)", ctx do
    email = "brand-new-#{System.unique_integer([:positive])}@example.com"
    body = json_response(seat(ctx, email), 201)
    assert body["member"]["role"] == "member"
  end
end
