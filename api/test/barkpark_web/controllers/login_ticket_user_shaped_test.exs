defmodule BarkparkWeb.LoginTicketUserShapedTest do
  @moduledoc """
  cloud-identity-studio-handoff — USER-shaped login tickets: the Barkpark
  Cloud owner lands in their instance's Studio signed in AS their cloud
  account, not as an anonymous admin-token session.

  Pins the security properties on top of the dwb-7 base (login_ticket_test):

    * minting with an `email` requires the bearer to hold `admin` — a
      read-only token gets the same generic 401 (the grant at consume time
      is Default-workspace OWNER, so lesser tokens must not mint)
    * consume JIT-provisions the user, grants Default owner, and mints a
      `user_session` (NOT an api_token session)
    * an existing user/membership is reused, never downgraded/duplicated
    * user-shaped tickets are single-use like token-shaped ones
    * a body without `email` keeps the legacy token-shaped behavior
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @admin_token "handoff-admin-token-abcdef"
  @reader_token "handoff-reader-token-123456"
  @cloud_email "owner@cloud.example"

  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "handoff admin", "production", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@reader_token, "handoff reader", "production", ["read"])
    :ok
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp mint!(conn, token, body) do
    conn
    |> bearer(token)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/auth/login-tickets", Jason.encode!(body))
  end

  test "admin bearer mints a user-shaped ticket; consume signs in AS the account",
       %{conn: conn} do
    resp = mint!(conn, @admin_token, %{email: @cloud_email})
    ticket = json_response(resp, 201)["ticket"]
    assert is_binary(ticket)

    # no such user yet — the consume JIT-provisions it
    refute Accounts.get_user_by_email(@cloud_email)

    consume = scoped_conn() |> get("/login/ticket/#{ticket}")
    assert redirected_to(consume) == "/studio"

    # a USER session was minted (not an api_token session)
    assert is_binary(get_session(consume, "user_session"))
    refute get_session(consume, "api_token")

    user = Accounts.get_user_by_email(@cloud_email)
    assert user

    # …with an OWNER grant on the Default workspace
    %{id: ws_id} = Tenancy.get_default_workspace()
    assert %{role: "owner"} = TenancyAuth.membership(user, ws_id)
  end

  test "a read-only bearer cannot mint a user-shaped ticket (privilege gate)",
       %{conn: conn} do
    resp = mint!(conn, @reader_token, %{email: @cloud_email})
    assert resp.status == 401

    # …while the same bearer still mints a legacy token-shaped ticket
    legacy = mint!(conn, @reader_token, %{})
    assert legacy.status == 201
  end

  test "an existing user and membership are reused, never duplicated or downgraded",
       %{conn: conn} do
    {:ok, user} =
      Accounts.register_user(%{email: @cloud_email, password: "correct-horse-battery"})

    %{id: ws_id} = Tenancy.get_default_workspace()
    {:ok, _} = TenancyAuth.create_membership(ws_id, user.id, "member", "user")

    ticket = json_response(mint!(conn, @admin_token, %{email: @cloud_email}), 201)["ticket"]
    consume = scoped_conn() |> get("/login/ticket/#{ticket}")
    assert redirected_to(consume) == "/studio"

    # same user row; the pre-existing member role is left untouched
    assert Accounts.get_user_by_email(@cloud_email).id == user.id
    assert %{role: "member"} = TenancyAuth.membership(user, ws_id)
  end

  test "user-shaped tickets are single-use", %{conn: conn} do
    ticket = json_response(mint!(conn, @admin_token, %{email: @cloud_email}), 201)["ticket"]

    assert redirected_to(scoped_conn() |> get("/login/ticket/#{ticket}")) == "/studio"

    replay = scoped_conn() |> get("/login/ticket/#{ticket}")
    assert redirected_to(replay) == "/login"
  end

  test "no email in the body keeps the legacy token-shaped ticket", %{conn: conn} do
    ticket = json_response(mint!(conn, @admin_token, %{}), 201)["ticket"]
    consume = scoped_conn() |> get("/login/ticket/#{ticket}")

    assert redirected_to(consume) == "/studio"
    assert get_session(consume, "api_token") == @admin_token
    refute get_session(consume, "user_session")
  end
end
