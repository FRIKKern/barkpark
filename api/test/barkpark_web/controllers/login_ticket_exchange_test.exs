defmodule BarkparkWeb.LoginTicketExchangeTest do
  @moduledoc """
  "Sign in with Barkpark Cloud" for an external Studio — the instance half.

  The control plane mints an EXCHANGE ticket (purpose + audience + PKCE S256
  challenge) with the stored admin bearer; the Studio's server trades it at
  `POST /v1/auth/login-tickets/exchange` for a login session. Pins:

    * the allowed path returns a login session for the account, usable as a
      bearer, seated at the carried role in the Default workspace only
    * replay, wrong audience, wrong verifier and expiry are one 401
    * neither door takes the other's ticket
    * a malformed exchange mint is a 422, never a browser ticket
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.Auth.LoginTicket
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @admin_token "exchange-admin-token-abcdef"
  @email "editor@cloud.example"
  @audience "https://studio.example.com"
  @verifier "dBjftJeZ4CVP-mJ92K9gEhZn7hrdsX2HhhRWqkdOkkZ6"

  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "exchange admin", "production", ["read", "write", "admin"])

    :ok
  end

  defp challenge(verifier),
    do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

  defp post_json(conn, path, body, token \\ nil) do
    conn = put_req_header(conn, "content-type", "application/json")
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    post(conn, path, Jason.encode!(body))
  end

  defp mint!(overrides \\ %{}) do
    body =
      Map.merge(
        %{
          email: @email,
          role: "member",
          purpose: "exchange",
          audience: @audience,
          code_challenge: challenge(@verifier)
        },
        overrides
      )

    resp = post_json(scoped_conn(), "/v1/auth/login-tickets", body, @admin_token)
    assert %{"ticket" => ticket, "purpose" => "exchange"} = json_response(resp, 201)
    ticket
  end

  defp exchange(ticket, overrides \\ %{}) do
    body = Map.merge(%{ticket: ticket, audience: @audience, code_verifier: @verifier}, overrides)
    post_json(scoped_conn(), "/v1/auth/login-tickets/exchange", body)
  end

  test "allowed: the exchange answers a login session for the account, Default seat only" do
    {:ok, other} = Tenancy.create_workspace(%{slug: "gyldendal-no", name: "Gyldendal"})

    resp = exchange(mint!())
    assert %{"token" => token, "user" => %{"email" => @email}} = json_response(resp, 201)
    assert get_resp_header(resp, "cache-control") == ["no-store"]

    user = Accounts.get_user_by_email(@email)
    assert Accounts.verify_user_session_token(token).id == user.id

    %{id: default_id} = Tenancy.get_default_workspace()
    assert %{role: "member"} = TenancyAuth.membership(user, default_id)
    # never auto-seated anywhere else
    assert TenancyAuth.membership(user, other.id) == nil

    # the bearer works where a login session does
    me =
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/v1/auth/me")

    assert json_response(me, 200)["user"]["email"] == @email
  end

  test "denied: a replayed ticket" do
    ticket = mint!()
    assert exchange(ticket).status == 201
    assert %{"error" => %{"code" => "invalid_ticket"}} = json_response(exchange(ticket), 401)
  end

  test "denied: the wrong audience burns the ticket" do
    ticket = mint!()
    assert exchange(ticket, %{audience: "https://evil.example.com"}).status == 401
    assert exchange(ticket).status == 401
  end

  test "denied: a verifier that does not answer the challenge" do
    ticket = mint!()
    assert exchange(ticket, %{code_verifier: String.duplicate("x", 43)}).status == 401
  end

  test "denied: an expired ticket" do
    ticket = mint!()

    Repo.update_all(LoginTicket,
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    assert exchange(ticket).status == 401
  end

  test "denied: missing fields and an unknown ticket" do
    assert exchange("bplt_nope").status == 401

    assert post_json(scoped_conn(), "/v1/auth/login-tickets/exchange", %{ticket: mint!()}).status ==
             401
  end

  test "a browser ticket is not exchangeable, an exchange ticket does not open a browser session" do
    browser =
      post_json(scoped_conn(), "/v1/auth/login-tickets", %{email: @email}, @admin_token)
      |> json_response(201)

    assert browser["purpose"] == "browser"
    assert exchange(browser["ticket"]).status == 401

    consume = scoped_conn() |> get("/login/ticket/#{mint!()}")
    assert redirected_to(consume) == "/login"
    refute get_session(consume, "user_session")
  end

  test "a malformed exchange mint is refused, never minted as a browser ticket" do
    for bad <- [
          %{audience: nil},
          %{audience: "https://studio.example.com/path"},
          %{code_challenge: "short"},
          %{email: nil},
          %{purpose: "something-else"}
        ] do
      body =
        Map.merge(
          %{
            email: @email,
            purpose: "exchange",
            audience: @audience,
            code_challenge: challenge(@verifier)
          },
          bad
        )

      resp = post_json(scoped_conn(), "/v1/auth/login-tickets", body, @admin_token)
      assert resp.status == 422, "expected 422 for #{inspect(bad)}, got #{resp.status}"
    end
  end
end
