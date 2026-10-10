defmodule BarkparkWeb.LoginTokenScopedQueryTest do
  @moduledoc """
  task-ce99fd602a697010 (P1, the owner's own login on guerrilla): POST
  /v1/auth/login → accept an invite → GET /w/:ws/p/:proj/v1/data/query/…
  with the login token as `Authorization: Bearer` answered 401 "missing or
  invalid token". #22180 promised a login session reaches the scoped data
  API; it does — through the session COOKIE. The bearer arm of
  `OptionalSessionToken` only ever tried the token as an API token
  (`Auth.verify_token/1`), so the token `/v1/auth/login` returns (a user
  session token, the same value the cookie carries) never verified as a
  bearer, and `strict_on_presented` turned that into the 401.

  Every step here goes through the REAL endpoint, in the owner's order, with
  the REAL login token — never a hand-minted one.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Content}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct horse battery staple"
  @dataset "production"

  setup do
    ws = create_workspace!("parity-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    admin_raw = "ce99-admin-#{System.unique_integer([:positive])}"

    {:ok, admin} =
      Auth.create_token(admin_raw, "ce99-admin", @dataset, ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws.id, admin.id, "admin", "api_token")

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "private",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset,
        workspace_id: ws.id,
        project_id: project.id
      )

    email = "owner-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    Accounts.confirm_provisioned_user(user)

    %{ws: ws, project: project, admin_raw: admin_raw, email: email}
  end

  defp json_conn(bearer) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> put_req_header("content-type", "application/json")
  end

  defp login!(email) do
    scoped_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/v1/auth/login", Jason.encode!(%{email: email, password: @password}))
    |> json_response(201)
    |> Map.fetch!("token")
  end

  defp invite_and_accept!(ctx, login_token) do
    json_conn(ctx.admin_raw)
    |> post(
      "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/members",
      Jason.encode!(%{email: ctx.email, role: "member"})
    )
    |> json_response(202)

    [inv] =
      json_response(json_conn(login_token) |> get("/v1/auth/invitations"), 200)["invitations"]

    json_conn(login_token)
    |> post("/v1/auth/invitations/#{inv["id"]}/accept", "{}")
    |> json_response(201)
  end

  defp query(ctx, bearer) do
    json_conn(bearer)
    |> get("/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/data/query/#{@dataset}/post?limit=1")
  end

  test "login, THEN accept the invite: the same login token reads the scoped data API (200)",
       ctx do
    token = login!(ctx.email)
    invite_and_accept!(ctx, token)

    resp = query(ctx, token)
    assert resp.status == 200, resp.resp_body
  end

  test "accept, THEN a fresh login: that token reads too (the live repro's order)", ctx do
    first = login!(ctx.email)
    invite_and_accept!(ctx, first)

    resp = query(ctx, login!(ctx.email))
    assert resp.status == 200, resp.resp_body
  end

  test "REFUSED WITHOUT membership: before accepting, the login token is a 403 not_a_member",
       ctx do
    token = login!(ctx.email)
    resp = query(ctx, token)
    assert resp.status == 403, resp.resp_body
    assert resp.resp_body =~ "not_a_member"
  end

  test "the same login session as a COOKIE reads too (parity with the bearer)", ctx do
    token = login!(ctx.email)
    invite_and_accept!(ctx, token)

    resp =
      scoped_conn()
      |> Plug.Test.init_test_session(%{"user_session" => token})
      |> get("/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/data/query/#{@dataset}/post?limit=1")

    assert resp.status == 200, resp.resp_body
  end

  test "a garbage bearer is still 401 missing-or-invalid", ctx do
    resp = query(ctx, "bpcs_not-a-real-session")
    assert resp.status == 401, resp.resp_body
  end

  test "a revoked login session is refused", ctx do
    token = login!(ctx.email)
    invite_and_accept!(ctx, token)
    assert query(ctx, token).status == 200

    logout = json_conn(token) |> delete("/v1/auth/logout")
    assert logout.status in 200..204, logout.resp_body

    resp = query(ctx, token)
    assert resp.status == 401, resp.resp_body
  end
end
