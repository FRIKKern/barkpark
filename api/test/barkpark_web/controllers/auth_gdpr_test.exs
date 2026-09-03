defmodule BarkparkWeb.AuthGdprTest do
  @moduledoc "The GDPR data-subject HTTP surface (era-w6-gdpr): export + erase."
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Accounts

  @password "correct-horse-battery"

  defp json_conn(conn), do: put_req_header(conn, "content-type", "application/json")
  defp post_json(conn, path, body), do: conn |> json_conn() |> post(path, Jason.encode!(body))

  defp session_token(email) do
    {:ok, _u} = Accounts.register_user(%{email: email, password: @password})

    scoped_conn()
    |> json_conn()
    |> post("/v1/auth/login", Jason.encode!(%{email: email, password: @password}))
    |> json_response(201)
    |> Map.fetch!("token")
  end

  defp authed(token), do: scoped_conn() |> put_req_header("authorization", "Bearer #{token}")

  describe "GET /v1/auth/export" do
    test "returns the subject's own data bundle", %{conn: _conn} do
      token = session_token("export@example.com")
      body = authed(token) |> get("/v1/auth/export") |> json_response(200)

      assert body["account"]["email"] == "export@example.com"
      assert is_list(body["sessions"])
      assert is_list(body["memberships"])
    end

    test "401 without a session", %{conn: conn} do
      assert conn |> get("/v1/auth/export") |> json_response(401)
    end
  end

  describe "POST /v1/auth/erase" do
    test "erases the subject with password reauth, then the session is dead", %{conn: _conn} do
      token = session_token("erase-http@example.com")

      body =
        authed(token) |> post_json("/v1/auth/erase", %{password: @password}) |> json_response(200)

      assert body["ok"] == true
      assert body["erased"]["sessions_deleted"] >= 1

      # the session is revoked → subsequent authed calls 401
      assert authed(token) |> get("/v1/auth/me") |> json_response(401)
      # the old password no longer logs in (PII scrubbed)
      assert scoped_conn()
             |> json_conn()
             |> post(
               "/v1/auth/login",
               Jason.encode!(%{email: "erase-http@example.com", password: @password})
             )
             |> json_response(401)
    end

    test "403 with a wrong password (no erasure)", %{conn: _conn} do
      token = session_token("keep@example.com")

      assert authed(token)
             |> post_json("/v1/auth/erase", %{password: "wrong-password"})
             |> json_response(403)

      # still alive
      assert authed(token) |> get("/v1/auth/me") |> json_response(200)
    end

    test "400 without a password", %{conn: _conn} do
      token = session_token("noargs@example.com")
      assert authed(token) |> post_json("/v1/auth/erase", %{}) |> json_response(400)
    end
  end
end
