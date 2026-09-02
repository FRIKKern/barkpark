defmodule BarkparkWeb.AuthPasswordTest do
  @moduledoc """
  Self-service password change: `PATCH /v1/auth/password`. Mirrors
  `AuthGdprTest`'s shape for `/v1/auth/erase` — same re-auth pattern, same
  "does it actually take effect" style of assertion.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Accounts

  @password "correct-horse-battery"
  @new_password "new-correct-horse-battery"

  defp json_conn(conn), do: put_req_header(conn, "content-type", "application/json")
  defp patch_json(conn, path, body), do: conn |> json_conn() |> patch(path, Jason.encode!(body))

  defp session_token(email) do
    {:ok, _u} = Accounts.register_user(%{email: email, password: @password})

    build_conn()
    |> json_conn()
    |> post("/v1/auth/login", Jason.encode!(%{email: email, password: @password}))
    |> json_response(201)
    |> Map.fetch!("token")
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer #{token}")

  describe "PATCH /v1/auth/password" do
    test "changes the password with current-password reauth, then the session is dead",
         %{conn: _conn} do
      token = session_token("change-password@example.com")

      body =
        authed(token)
        |> patch_json("/v1/auth/password", %{
          current_password: @password,
          password: @new_password
        })
        |> json_response(200)

      assert body["ok"] == true

      # the session is revoked (same contract as a token-based reset) →
      # subsequent authed calls with the OLD token 401.
      assert authed(token) |> get("/v1/auth/me") |> json_response(401)

      # the old password no longer logs in...
      assert build_conn()
             |> json_conn()
             |> post(
               "/v1/auth/login",
               Jason.encode!(%{email: "change-password@example.com", password: @password})
             )
             |> json_response(401)

      # ...but the NEW one does.
      assert build_conn()
             |> json_conn()
             |> post(
               "/v1/auth/login",
               Jason.encode!(%{email: "change-password@example.com", password: @new_password})
             )
             |> json_response(201)
    end

    test "403 with a wrong current password (no change)", %{conn: _conn} do
      token = session_token("keep-password@example.com")

      assert authed(token)
             |> patch_json("/v1/auth/password", %{
               current_password: "wrong-password",
               password: @new_password
             })
             |> json_response(403)

      # still alive, and the OLD password still works.
      assert authed(token) |> get("/v1/auth/me") |> json_response(200)

      assert build_conn()
             |> json_conn()
             |> post(
               "/v1/auth/login",
               Jason.encode!(%{email: "keep-password@example.com", password: @password})
             )
             |> json_response(201)
    end

    test "422 on a new password that fails validation (no change)", %{conn: _conn} do
      token = session_token("weak-new-password@example.com")

      assert authed(token)
             |> patch_json("/v1/auth/password", %{current_password: @password, password: "short"})
             |> json_response(422)

      # session survives — a rejected new password must not revoke anything.
      assert authed(token) |> get("/v1/auth/me") |> json_response(200)
    end

    test "400 without current_password or password", %{conn: _conn} do
      token = session_token("noargs-password@example.com")

      assert authed(token) |> patch_json("/v1/auth/password", %{}) |> json_response(400)

      assert authed(token)
             |> patch_json("/v1/auth/password", %{current_password: @password})
             |> json_response(400)
    end

    test "401 without a session", %{conn: conn} do
      assert conn
             |> patch_json("/v1/auth/password", %{
               current_password: @password,
               password: @new_password
             })
             |> json_response(401)
    end
  end
end
