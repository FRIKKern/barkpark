defmodule BarkparkWeb.AuthControllerTest do
  @moduledoc "Phase 1 — the /v1/auth HTTP surface (register, login, MFA, sessions)."
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  alias Barkpark.{Accounts, Audit, Repo}
  alias Barkpark.Audit.Event

  @password "correct-horse-battery"

  defp json_conn(conn), do: put_req_header(conn, "content-type", "application/json")
  defp post_json(conn, path, body), do: conn |> json_conn() |> post(path, Jason.encode!(body))

  # A JSON-ready conn carrying `token` as a session bearer.
  defp authed(token),
    do: build_conn() |> put_req_header("authorization", "Bearer #{token}") |> json_conn()

  # Enrol TOTP on `token`'s session (enrol → verify). Returns {secret, recovery_codes}.
  defp enroll_totp!(token) do
    enroll =
      authed(token)
      |> post("/v1/auth/mfa/enroll", Jason.encode!(%{password: @password}))
      |> json_response(200)

    secret = Base.decode32!(enroll["secret"], padding: false)

    verify =
      authed(token)
      |> post(
        "/v1/auth/mfa/verify",
        Jason.encode!(%{secret: enroll["secret"], code: NimbleTOTP.verification_code(secret), password: @password})
      )
      |> json_response(200)

    {secret, verify["recovery_codes"]}
  end

  # Age `token`'s session step-up stamp past the window, so the next guarded
  # action is challenged. Simulates the freshness window lapsing.
  defp backdate_step_up!(token) do
    hash = Accounts.UserSession.hash_token(token)
    old = DateTime.utc_now() |> DateTime.add(-20 * 60, :second) |> DateTime.truncate(:microsecond)

    {1, _} =
      Repo.update_all(
        from(s in Accounts.UserSession, where: s.token_hash == ^hash),
        set: [mfa_verified_at: old]
      )

    :ok
  end

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

    test "MEDIUM-7: a duplicate email is indistinguishable from a fresh signup", %{conn: conn} do
      fresh = register!(conn, "enum@example.com") |> json_response(201)

      # Second registration of the SAME email — same status, same body shape.
      dup =
        post_json(build_conn(), "/v1/auth/register", %{
          email: "enum@example.com",
          password: @password
        })
        |> json_response(201)

      assert dup == fresh
      # No leaked existence signal anywhere in the body.
      refute dup["error"]
      refute get_in(dup, ["user", "id"])
      # And no shadow user was created (still exactly one).
      assert Accounts.get_user_by_email("enum@example.com")
    end

    test "MEDIUM-7: existing-email + weak password is byte-identical to new-email + weak password",
         %{conn: conn} do
      register!(conn, "taken@example.com")

      # Same too-short password against an EXISTING vs an ABSENT email. The unique
      # check still fires alongside the password error — the 422 must NOT leak the
      # "has already been taken" signal, so both bodies must be identical.
      existing =
        post_json(build_conn(), "/v1/auth/register", %{email: "taken@example.com", password: "x"})

      absent =
        post_json(build_conn(), "/v1/auth/register", %{email: "absent@example.com", password: "x"})

      assert response(existing, 422) == response(absent, 422)

      body = json_response(existing, 422)
      assert body["error"]["code"] == "invalid_registration"
      # The email existence oracle is gone; only the password error survives.
      refute get_in(body, ["error", "message", "email"])
      assert get_in(body, ["error", "message", "password"])
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

    test "an auth error carries a `hint` the bp CLI + SDK surface", %{conn: conn} do
      resp = post_json(conn, "/v1/auth/login", %{email: "alice@example.com", password: "nope"})
      error = json_response(resp, 401)["error"]
      assert error["code"] == "invalid_credentials"
      # The hint completes the chain server→CLI(#557)/SDK(err.hint): it must be
      # present and non-empty so the fix-suggestion actually reaches the user.
      assert is_binary(error["hint"]) and error["hint"] != ""
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

      enroll =
        authed.()
        |> json_conn()
        |> post("/v1/auth/mfa/enroll", Jason.encode!(%{password: @password}))
        |> json_response(200)

      assert enroll["otpauth_uri"] =~ "otpauth://"
      secret = Base.decode32!(enroll["secret"], padding: false)

      verify =
        authed.()
        |> json_conn()
        |> post(
          "/v1/auth/mfa/verify",
          Jason.encode!(%{
            secret: enroll["secret"],
            code: NimbleTOTP.verification_code(secret),
            password: @password
          })
        )
        |> json_response(200)

      assert length(verify["recovery_codes"]) == 10

      # Standard two-step 2FA UX: a correct password with NO code returns
      # `mfa_required` ("now enter your code"). The deliberate, accepted tradeoff
      # (restores LOW-13's removal) — this confirms password validity to a caller
      # who already supplied it, the industry-standard 2FA behaviour.
      no_code =
        post_json(build_conn(), "/v1/auth/login", %{email: "mfa@example.com", password: @password})

      assert json_response(no_code, 401)["error"]["code"] == "mfa_required"

      # An INVALID code on a correct password is ALSO mfa_required (not generic).
      bad_code =
        post_json(build_conn(), "/v1/auth/login", %{
          email: "mfa@example.com",
          password: @password,
          totp_code: "000000"
        })

      assert json_response(bad_code, 401)["error"]["code"] == "mfa_required"

      # A WRONG password stays the generic invalid_credentials — the password
      # oracle is NOT widened: a wrong password never reveals the account has MFA.
      wrong_pw =
        post_json(build_conn(), "/v1/auth/login", %{email: "mfa@example.com", password: "nope"})

      assert json_response(wrong_pw, 401)["error"]["code"] == "invalid_credentials"

      # … and succeeds with a live TOTP code.
      assert login_token(build_conn(), "mfa@example.com", %{
               totp_code: NimbleTOTP.verification_code(secret)
             })
    end

    test "MEDIUM-8: enroll + verify require the current password (re-auth)", %{token: token} do
      authed = fn -> build_conn() |> put_req_header("authorization", "Bearer #{token}") end

      # No password → 403, even with a valid session.
      assert authed.()
             |> json_conn()
             |> post("/v1/auth/mfa/enroll", Jason.encode!(%{}))
             |> json_response(403)

      # Wrong password → 403.
      assert authed.()
             |> json_conn()
             |> post("/v1/auth/mfa/enroll", Jason.encode!(%{password: "wrong-password"}))
             |> json_response(403)

      # verify also refuses without the password.
      assert authed.()
             |> json_conn()
             |> post(
               "/v1/auth/mfa/verify",
               Jason.encode!(%{secret: "AAAA", code: "000000"})
             )
             |> json_response(403)
    end

    test "MEDIUM-8: mfa/disable needs the current password and turns MFA off", %{token: token} do
      authed = fn -> build_conn() |> put_req_header("authorization", "Bearer #{token}") end

      enroll =
        authed.()
        |> json_conn()
        |> post("/v1/auth/mfa/enroll", Jason.encode!(%{password: @password}))
        |> json_response(200)

      secret = Base.decode32!(enroll["secret"], padding: false)

      authed.()
      |> json_conn()
      |> post(
        "/v1/auth/mfa/verify",
        Jason.encode!(%{
          secret: enroll["secret"],
          code: NimbleTOTP.verification_code(secret),
          password: @password
        })
      )
      |> json_response(200)

      assert Accounts.get_user_by_email("mfa@example.com").totp_enabled

      # Wrong password cannot disable.
      assert authed.()
             |> json_conn()
             |> post("/v1/auth/mfa/disable", Jason.encode!(%{password: "nope"}))
             |> json_response(403)

      # Correct password disables MFA.
      assert authed.()
             |> json_conn()
             |> post("/v1/auth/mfa/disable", Jason.encode!(%{password: @password}))
             |> json_response(200)

      refute Accounts.get_user_by_email("mfa@example.com").totp_enabled

      # Login no longer needs a code.
      assert login_token(build_conn(), "mfa@example.com")
    end
  end

  describe "step-up MFA (sensitive-action gate)" do
    setup %{conn: conn} do
      register!(conn, "mfa@example.com")
      token = login_token(conn, "mfa@example.com")
      %{token: token}
    end

    test "a user WITHOUT MFA is never step-up-challenged (opt-in, zero friction)", %{token: token} do
      # Not enrolled → the guarded route runs straight to its own password gate,
      # no 401 mfa_required.
      assert authed(token)
             |> post("/v1/auth/mfa/disable", Jason.encode!(%{password: @password}))
             |> json_response(200)
    end

    test "an enrolled user's stale session is challenged; step-up (TOTP) clears it", %{token: token} do
      {secret, _codes} = enroll_totp!(token)

      # Enrolment stamped the session fresh — simulate the window lapsing.
      backdate_step_up!(token)

      # The guarded action now demands a fresh factor (before the password is even checked).
      challenge = authed(token) |> post("/v1/auth/mfa/disable", Jason.encode!(%{password: @password}))
      assert json_response(challenge, 401)["error"]["code"] == "mfa_required"

      # Step up with a live TOTP → session fresh again.
      step = authed(token) |> post("/v1/auth/mfa/step-up", Jason.encode!(%{code: NimbleTOTP.verification_code(secret)}))
      assert json_response(step, 200)["factor"] == "totp"

      # The guarded action now succeeds.
      assert authed(token)
             |> post("/v1/auth/mfa/disable", Jason.encode!(%{password: @password}))
             |> json_response(200)
    end

    test "a recovery code satisfies step-up and is single-use", %{token: token} do
      {_secret, codes} = enroll_totp!(token)
      [code | _] = codes

      backdate_step_up!(token)
      ok = authed(token) |> post("/v1/auth/mfa/step-up", Jason.encode!(%{code: code}))
      assert json_response(ok, 200)["factor"] == "recovery"

      # Re-using the SAME recovery code fails (consumed) — go stale first.
      backdate_step_up!(token)
      reused = authed(token) |> post("/v1/auth/mfa/step-up", Jason.encode!(%{code: code}))
      assert json_response(reused, 422)["error"]["code"] == "invalid_code"
    end

    test "enrol, challenge, fail and pass all emit onto the audit chain", %{token: token} do
      {secret, _codes} = enroll_totp!(token)
      assert Repo.one(from e in Event, where: e.action == "mfa_enrolled")

      backdate_step_up!(token)
      # A challenge (401) emits mfa_challenged.
      authed(token) |> post("/v1/auth/mfa/disable", Jason.encode!(%{password: @password}))
      assert Repo.one(from e in Event, where: e.action == "mfa_challenged")

      # A bad step-up emits mfa_failed; a good one emits mfa_passed.
      authed(token) |> post("/v1/auth/mfa/step-up", Jason.encode!(%{code: "000000"}))
      assert Repo.one(from e in Event, where: e.action == "mfa_failed")

      authed(token) |> post("/v1/auth/mfa/step-up", Jason.encode!(%{code: NimbleTOTP.verification_code(secret)}))
      assert Repo.one(from e in Event, where: e.action == "mfa_passed")

      # The global (no-workspace) chain stays intact through all these emits.
      assert :ok == Audit.verify_chain(nil)
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

    test "verify-email 422s (not 500s) on an array-shaped token param", %{conn: conn} do
      # Phoenix parses `?token[]=x` into a list; confirm_user/1 must fail soft to
      # :error → 422 invalid_token, never raise FunctionClauseError → 500.
      resp = post_json(conn, "/v1/auth/verify-email", %{token: ["x"]}) |> json_response(422)
      assert resp["error"]["code"] == "invalid_token"
    end

    test "reset 422s (not 500s) on a map-shaped token param", %{conn: conn} do
      resp =
        post_json(conn, "/v1/auth/reset", %{token: %{"a" => "b"}, password: "ValidPass123!"})
        |> json_response(422)

      assert resp["error"]["code"] == "invalid_token"
    end
  end
end
