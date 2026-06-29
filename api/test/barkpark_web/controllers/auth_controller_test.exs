defmodule BarkparkWeb.AuthControllerTest do
  @moduledoc "Phase 1 — the /v1/auth HTTP surface (register, login, MFA, sessions)."
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Accounts

  @password "correct-horse-battery"

  defp json_conn(conn), do: put_req_header(conn, "content-type", "application/json")
  defp post_json(conn, path, body), do: conn |> json_conn() |> post(path, Jason.encode!(body))

  defp register!(conn, email) do
    post_json(conn, "/v1/auth/register", %{email: email, password: @password})
  end

  defp login_token(conn, email, extra \\ %{}) do
    resp =
      post_json(conn, "/v1/auth/login", Map.merge(%{email: email, password: @password}, extra))
      |> json_response(201)

    resp["token"]
  end

  describe "register" do
    test "creates a user and 201s", %{conn: conn} do
      resp = register!(conn, "new@example.com") |> json_response(201)
      assert resp["user"]["email"] == "new@example.com"
      assert Accounts.get_user_by_email("new@example.com")
    end

    test "422 on a weak password", %{conn: conn} do
      assert register!(conn, "weak@example.com")
      resp = post_json(conn, "/v1/auth/register", %{email: "x@y.com", password: "short"})
      assert json_response(resp, 422)["error"]["code"] == "invalid_registration"
    end
  end

  describe "login + me + logout" do
    setup %{conn: conn} do
      register!(conn, "alice@example.com")
      :ok
    end

    test "login returns a bearer that authenticates /me", %{conn: conn} do
      token = login_token(conn, "alice@example.com")

      me =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/v1/auth/me")
        |> json_response(200)

      assert me["user"]["email"] == "alice@example.com"
    end

    test "wrong password is a generic 401", %{conn: conn} do
      resp = post_json(conn, "/v1/auth/login", %{email: "alice@example.com", password: "nope"})
      assert json_response(resp, 401)["error"]["code"] == "invalid_credentials"
    end

    test "/me without a session is 401", %{conn: conn} do
      assert conn |> get("/v1/auth/me") |> json_response(401)
    end

    test "logout revokes the session bearer", %{conn: conn} do
      token = login_token(conn, "alice@example.com")
      authed = fn -> build_conn() |> put_req_header("authorization", "Bearer #{token}") end

      assert authed.() |> delete("/v1/auth/logout") |> json_response(200)
      assert authed.() |> get("/v1/auth/me") |> json_response(401)
    end
  end

  describe "TOTP MFA" do
    setup %{conn: conn} do
      register!(conn, "mfa@example.com")
      token = login_token(conn, "mfa@example.com")
      %{token: token}
    end

    test "enroll → verify → login now requires a code", %{token: token} do
      authed = fn -> build_conn() |> put_req_header("authorization", "Bearer #{token}") end

      enroll = authed.() |> post("/v1/auth/mfa/enroll") |> json_response(200)
      assert enroll["otpauth_uri"] =~ "otpauth://"
      secret = Base.decode32!(enroll["secret"], padding: false)

      verify =
        authed.()
        |> json_conn()
        |> post(
          "/v1/auth/mfa/verify",
          Jason.encode!(%{secret: enroll["secret"], code: NimbleTOTP.verification_code(secret)})
        )
        |> json_response(200)

      assert length(verify["recovery_codes"]) == 10

      # Login without a code now fails with mfa_required …
      no_code =
        post_json(build_conn(), "/v1/auth/login", %{email: "mfa@example.com", password: @password})

      assert json_response(no_code, 401)["error"]["code"] == "mfa_required"

      # … and succeeds with a live TOTP code.
      assert login_token(build_conn(), "mfa@example.com", %{
               totp_code: NimbleTOTP.verification_code(secret)
             })
    end
  end

  describe "email flows" do
    test "request-reset always 200s (no account enumeration)", %{conn: conn} do
      assert post_json(conn, "/v1/auth/request-reset", %{email: "ghost@example.com"})
             |> json_response(200)
    end

    test "verify-email confirms via a real token", %{conn: conn} do
      register!(conn, "confirm@example.com")
      user = Accounts.get_user_by_email("confirm@example.com")
      {:ok, raw} = Accounts.build_email_token(user, "confirm")

      assert post_json(conn, "/v1/auth/verify-email", %{token: raw}) |> json_response(200)
      assert Accounts.get_user("#{user.id}").confirmed_at
    end

    test "reset via a real token logs the session out and changes the password", %{conn: conn} do
      register!(conn, "pwreset@example.com")
      user = Accounts.get_user_by_email("pwreset@example.com")
      {:ok, raw} = Accounts.build_email_token(user, "reset")

      assert post_json(conn, "/v1/auth/reset", %{token: raw, password: "a-brand-new-password"})
             |> json_response(200)

      # Old password no longer works …
      assert post_json(build_conn(), "/v1/auth/login", %{
               email: "pwreset@example.com",
               password: @password
             })
             |> json_response(401)

      # … the new one does.
      assert post_json(build_conn(), "/v1/auth/login", %{
               email: "pwreset@example.com",
               password: "a-brand-new-password"
             })
             |> json_response(201)
             |> Map.fetch!("token")
    end
  end
end
