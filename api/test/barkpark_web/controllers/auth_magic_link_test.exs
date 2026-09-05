defmodule BarkparkWeb.AuthMagicLinkTest do
  @moduledoc "The passwordless magic-link HTTP surface (era-w2-passwordless)."
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Accounts
  alias Barkpark.Accounts.UserEmailToken
  alias Barkpark.Repo
  import Ecto.Query

  @password "correct-horse-battery"

  defp json_conn(conn), do: put_req_header(conn, "content-type", "application/json")
  defp post_json(conn, path, body), do: conn |> json_conn() |> post(path, Jason.encode!(body))

  defp user(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: @password})
    u
  end

  # The plaintext a client would extract from the emailed link — read it back
  # from the freshly-issued login token via a known-good re-hash is impossible
  # (only the hash is stored), so we drive the plaintext through Accounts.
  defp issue_link(email) do
    {:ok, plaintext, _u} = Accounts.build_login_token(email)
    plaintext
  end

  describe "POST /v1/auth/request-magic-link" do
    test "returns generic ok for a known email and writes a login token", %{conn: conn} do
      user("known@example.com")
      resp = post_json(conn, "/v1/auth/request-magic-link", %{email: "known@example.com"})
      assert json_response(resp, 200) == %{"ok" => true}
      assert Repo.aggregate(from(t in UserEmailToken, where: t.context == "login"), :count) == 1
    end

    test "returns the SAME generic ok for an unknown email (no enumeration)", %{conn: conn} do
      resp = post_json(conn, "/v1/auth/request-magic-link", %{email: "ghost@example.com"})
      assert json_response(resp, 200) == %{"ok" => true}
      assert Repo.aggregate(from(t in UserEmailToken, where: t.context == "login"), :count) == 0
    end

    test "400 when email is missing", %{conn: conn} do
      resp = post_json(conn, "/v1/auth/request-magic-link", %{})
      assert json_response(resp, 400)
    end
  end

  describe "POST /v1/auth/magic-login" do
    test "consumes a valid token and issues a session", %{conn: conn} do
      u = user("signin@example.com")
      token = issue_link("signin@example.com")

      resp = post_json(conn, "/v1/auth/magic-login", %{token: token})
      body = json_response(resp, 201)
      assert body["token"]
      assert body["user"]["email"] == u.email
    end

    test "a second use of the same token is rejected (single-use)", %{conn: conn} do
      user("once@example.com")
      token = issue_link("once@example.com")

      assert conn |> post_json("/v1/auth/magic-login", %{token: token}) |> json_response(201)
      resp2 = post_json(scoped_conn(), "/v1/auth/magic-login", %{token: token})
      assert json_response(resp2, 401)["error"]["code"] == "invalid_token"
    end

    test "unknown token → generic 401 invalid_token", %{conn: conn} do
      resp = post_json(conn, "/v1/auth/magic-login", %{token: "never-issued"})
      assert json_response(resp, 401)["error"]["code"] == "invalid_token"
    end

    test "400 when token is missing", %{conn: conn} do
      resp = post_json(conn, "/v1/auth/magic-login", %{})
      assert json_response(resp, 400)
    end
  end
end
