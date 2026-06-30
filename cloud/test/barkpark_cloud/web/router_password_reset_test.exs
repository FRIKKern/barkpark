defmodule BarkparkCloud.Web.RouterPasswordResetTest do
  @moduledoc """
  Drives the forgot-password HTTP surface via Plug.Test: POST /v1/auth/request-reset
  (enumeration-safe, emails the link) and POST /v1/auth/reset (consume token, set
  password). Mirrors router_sessions_test.exs's setup + `call/4` helper. Email is
  asserted via Swoosh.Adapters.Test (config/test.exs).
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn
  import Swoosh.TestAssertions

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @new_password "fresh-horse-battery-staple"

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

  defp call(method, path, body) do
    conn =
      conn(method, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  describe "POST /v1/auth/request-reset" do
    test "known email → 200 {ok:true} and emails the reset link" do
      user = user_fixture()

      conn = call(:post, "/v1/auth/request-reset", %{email: user.email})
      assert conn.status == 200
      assert json_body(conn) == %{"ok" => true}
      assert_email_sent(subject: "Reset your Barkpark Cloud password")
    end

    test "unknown email → still 200 {ok:true} and sends NO email (enumeration-safe)" do
      conn = call(:post, "/v1/auth/request-reset", %{email: "nobody@example.com"})
      assert conn.status == 200
      assert json_body(conn) == %{"ok" => true}
      assert_no_email_sent()
    end

    test "missing email → still 200 (never leaks via a different status)" do
      assert call(:post, "/v1/auth/request-reset", %{}).status == 200
    end
  end

  describe "POST /v1/auth/reset" do
    test "valid token + new password → 200; the new password logs in, the old does not" do
      user = user_fixture()
      {:ok, {_u, raw}} = Accounts.request_password_reset(user.email)

      conn = call(:post, "/v1/auth/reset", %{token: raw, password: @new_password})
      assert conn.status == 200
      assert json_body(conn) == %{"ok" => true}

      assert call(:post, "/v1/auth/login", %{email: user.email, password: @new_password}).status ==
               200

      assert call(:post, "/v1/auth/login", %{email: user.email, password: @password}).status ==
               401
    end

    test "bad token → 401 invalid_token" do
      conn = call(:post, "/v1/auth/reset", %{token: "nope", password: @new_password})
      assert conn.status == 401
      assert json_body(conn)["error"] == "invalid_token"
    end

    test "weak password → 422" do
      user = user_fixture()
      {:ok, {_u, raw}} = Accounts.request_password_reset(user.email)

      conn = call(:post, "/v1/auth/reset", %{token: raw, password: "short"})
      assert conn.status == 422
      assert json_body(conn)["error"] =~ "password"
    end

    test "missing fields → 422" do
      assert call(:post, "/v1/auth/reset", %{token: "x"}).status == 422
    end
  end
end
