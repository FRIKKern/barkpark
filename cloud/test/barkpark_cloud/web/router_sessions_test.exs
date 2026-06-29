defmodule BarkparkCloud.Web.RouterSessionsTest do
  @moduledoc """
  Drives the account-sessions HTTP surface (cloud account-sessions) directly via
  Plug.Test: DELETE /v1/auth/logout, the GET/DELETE /v1/account/sessions trio,
  and PUT /v1/account/password. Mirrors router_test.exs's DataCase + Ecto sandbox
  setup and its `call/4` request helper.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @new_password "fresh-horse-battery-staple"

  ## Fixtures

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })
      |> Accounts.register_user()

    user
  end

  # A user who belongs to a fresh team, plus a live session token. Returns
  # {user, token}.
  defp user_with_token(attrs \\ %{}) do
    user = user_fixture(attrs)
    {:ok, token} = Accounts.create_user_session_token(user, user_agent: "TestAgent")
    {user, token}
  end

  defp call(method, path, body \\ nil, token \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  ## DELETE /v1/auth/logout

  describe "DELETE /v1/auth/logout" do
    test "revokes the calling token → the next request 401s" do
      {_user, token} = user_with_token()

      conn = call(:delete, "/v1/auth/logout", nil, token)
      assert conn.status == 200
      assert json_body(conn) == %{"ok" => true}

      # The token is dead — a follow-up authed call is rejected.
      assert call(:get, "/v1/me", nil, token).status == 401
    end

    test "401s without a token" do
      assert call(:delete, "/v1/auth/logout").status == 401
    end
  end

  ## GET /v1/account/sessions

  describe "GET /v1/account/sessions" do
    test "lists live sessions, flags the calling row, never leaks the hash" do
      {user, token} = user_with_token()
      {:ok, _other} = Accounts.create_user_session_token(user, user_agent: "OtherAgent")

      conn = call(:get, "/v1/account/sessions", nil, token)
      assert conn.status == 200
      sessions = json_body(conn)["sessions"]
      assert length(sessions) == 2

      current = Enum.find(sessions, & &1["current"])
      assert current["user_agent"] == "TestAgent"
      # The token_hash is NEVER serialized.
      refute Map.has_key?(current, "token_hash")
      # Exactly one row is flagged current.
      assert Enum.count(sessions, & &1["current"]) == 1
    end
  end

  ## DELETE /v1/account/sessions/:id

  describe "DELETE /v1/account/sessions/:id" do
    test "revokes one of the caller's own sessions" do
      {user, token} = user_with_token()
      [row] = Accounts.list_user_sessions(user)

      conn = call(:delete, "/v1/account/sessions/#{row.id}", nil, token)
      assert conn.status == 200
      assert is_nil(Accounts.verify_user_session_token(token))
    end

    test "another user's token id is 404 (no existence leak)" do
      {_owner, owner_token} = user_with_token()
      {victim, _victim_token} = user_with_token()
      [victim_row] = Accounts.list_user_sessions(victim)

      conn = call(:delete, "/v1/account/sessions/#{victim_row.id}", nil, owner_token)
      assert conn.status == 404
      # The victim's session is untouched.
      assert [_] = Accounts.list_user_sessions(victim)
    end
  end

  ## DELETE /v1/account/sessions (sign out everywhere)

  describe "DELETE /v1/account/sessions" do
    test "returns {revoked: N} and keeps the calling tab authenticated" do
      {user, token} = user_with_token()
      {:ok, _a} = Accounts.create_user_session_token(user)
      {:ok, _b} = Accounts.create_user_session_token(user)

      conn = call(:delete, "/v1/account/sessions", nil, token)
      assert conn.status == 200
      assert json_body(conn)["revoked"] == 2

      # The acting token survives.
      assert call(:get, "/v1/me", nil, token).status == 200
    end
  end

  ## PUT /v1/account/password

  describe "PUT /v1/account/password" do
    test "200 returns a fresh token; the old token is dead" do
      {_user, old_token} = user_with_token()

      conn =
        call(
          :put,
          "/v1/account/password",
          %{current_password: @password, new_password: @new_password},
          old_token
        )

      assert conn.status == 200
      fresh = json_body(conn)["token"]
      assert is_binary(fresh)
      assert fresh != old_token

      # The old token they presented was revoked; the fresh one works.
      assert is_nil(Accounts.verify_user_session_token(old_token))
      assert call(:get, "/v1/me", nil, fresh).status == 200
    end

    test "401 on the wrong current password" do
      {_user, token} = user_with_token()

      conn =
        call(
          :put,
          "/v1/account/password",
          %{current_password: "nope", new_password: @new_password},
          token
        )

      assert conn.status == 401
      assert json_body(conn)["error"] == "invalid_current_password"
    end

    test "422 on a weak new password" do
      {_user, token} = user_with_token()

      conn =
        call(
          :put,
          "/v1/account/password",
          %{current_password: @password, new_password: "short"},
          token
        )

      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid"
    end
  end
end
