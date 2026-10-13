defmodule BarkparkWeb.SessionControllerTest do
  @moduledoc """
  Task #6 / S3 — controller tests for the browser-facing session controller.

  Covers:
    * GET /login form render + return_to echo
    * POST /login success (default redirect, custom redirect, open-redirect defense, whitespace trim)
    * POST /login failure (invalid token, missing token) — flash + no session leak + token not echoed
    * POST /logout — drops session and redirects
    * POST /login/mfa — the step-up RECENCY window, incl. its clock-step floor

  clk-w4-mfa-recency-floor (clock-semantics wave): `studio_mfa_at` is a
  server-written instant round-tripped through the SIGNED session cookie —
  correctly wall-clock (class A). The defect was SIDEDNESS: with only an upper
  bound, an anchor LATER than now (what a backward wall-clock step on this node
  produces) held the 5-minute pending window open indefinitely. The
  future-anchor test below reds on the unfixed predicate — it mints a session
  and redirects to /studio there — and the stale/in-window controls prove the
  floor did not over-tighten. This is a HARDENING, not an exploitable bug: no
  attacker-supplied value is involved and `mfa_factor_ok?/2` still demands a
  live TOTP or a burned recovery code.
  """

  use BarkparkWeb.ConnCase, async: true

  # TOTP codes come from the window-stable helper ONLY — a code minted inline
  # can expire in the gap before the server validates it.
  import Barkpark.TotpTestHelper

  import Ecto.Query

  alias Barkpark.{Accounts, Auth, Repo}
  alias Barkpark.Accounts.UserSession

  @valid_token "test-session-valid-token-12345"
  @invalid_token "this-token-does-not-exist"

  setup do
    {:ok, _} = Auth.create_token(@valid_token, "test-session", "test", ["read", "admin"])
    :ok
  end

  describe "GET /login" do
    test "renders the form (200)", %{conn: conn} do
      conn = get(conn, "/login")
      body = html_response(conn, 200)
      assert body =~ "Sign in"
      assert body =~ ~s|action="/login"|
    end

    test "echoes a safe return_to in the hidden field", %{conn: conn} do
      conn = get(conn, "/login?return_to=/studio/test/post")
      body = html_response(conn, 200)
      assert body =~ ~s|name="return_to"|
      assert body =~ ~s|value="/studio/test/post"|
    end

    test "rejects external return_to in the hidden field", %{conn: conn} do
      conn = get(conn, "/login?return_to=//evil.com/path")
      body = html_response(conn, 200)
      # Sanitized to default
      assert body =~ ~s|value="/studio"|
      refute body =~ "evil.com"
    end
  end

  # Ruling #16 rework half (task-57f23825b18ab55d): a successful login no
  # longer puts the raw bearer in the session — it mints a
  # `Barkpark.Auth.TokenSession` and stores only its opaque id under
  # `session["api_token_session"]`. These assertions resolve that id back to
  # the same api_token/raw-bearer pair via `Auth.resolve_session_credential/2`
  # rather than comparing the cookie's contents to the raw token directly —
  # the whole point is that the cookie no longer CAN be compared that way.
  defp assert_session_resolves_to(conn, expected_raw) do
    session_id = get_session(conn, "api_token_session")
    assert is_binary(session_id)

    assert {:ok, %Barkpark.Auth.ApiToken{}, ^expected_raw} =
             Auth.resolve_session_credential(session_id, nil)
  end

  describe "POST /login (success)" do
    test "valid token sets session and redirects to /studio by default", %{conn: conn} do
      conn = post(conn, "/login", %{"token" => @valid_token})
      assert redirected_to(conn, 302) == "/studio"
      assert_session_resolves_to(conn, @valid_token)
    end

    test "valid token + safe return_to redirects to that path", %{conn: conn} do
      conn = post(conn, "/login", %{"token" => @valid_token, "return_to" => "/studio/test/page"})

      assert redirected_to(conn, 302) == "/studio/test/page"
      assert_session_resolves_to(conn, @valid_token)
    end

    test "open-redirect attempt is rejected (//evil.com)", %{conn: conn} do
      conn = post(conn, "/login", %{"token" => @valid_token, "return_to" => "//evil.com"})
      assert redirected_to(conn, 302) == "/studio"
      assert_session_resolves_to(conn, @valid_token)
    end

    # task-5ab7e3e4d678ec4c: browsers read `\` as `/` and drop tab/CR/LF, so
    # these all became the protocol-relative `//evil.com`.
    for evil <- ["/\\evil.com", "/\\/evil.com", "/\t/evil.com", "/\n/evil.com"] do
      test "open-redirect attempt is rejected (#{inspect(evil)})", %{conn: conn} do
        conn = post(conn, "/login", %{"token" => @valid_token, "return_to" => unquote(evil)})
        assert redirected_to(conn, 302) == "/studio"
      end
    end

    test "external https return_to is rejected", %{conn: conn} do
      conn = post(conn, "/login", %{"token" => @valid_token, "return_to" => "https://evil.com/x"})

      assert redirected_to(conn, 302) == "/studio"
    end

    test "trims surrounding whitespace and newlines on the token", %{conn: conn} do
      padded = "  " <> @valid_token <> "  \n"
      conn = post(conn, "/login", %{"token" => padded})
      assert redirected_to(conn, 302) == "/studio"
      # The minted session resolves to the TRIMMED value, not the padded one.
      assert_session_resolves_to(conn, @valid_token)
    end

    test "the session cookie never contains the raw API token, even decrypted server-side",
         %{conn: conn} do
      logged_in = post(conn, "/login", %{"token" => @valid_token})

      # Round-trip through the REAL wire cookie (Set-Cookie -> Cookie) and
      # decrypt it exactly as the server would on the next request — not the
      # in-process conn.private shortcut.
      rehydrated = recycle(logged_in) |> get("/login")
      session = Plug.Conn.get_session(rehydrated)

      refute @valid_token in Map.values(session)
      assert is_binary(session["api_token_session"])
      refute session["api_token_session"] == @valid_token
      refute Map.has_key?(session, "api_token")
    end
  end

  describe "POST /login (failure)" do
    test "invalid token re-renders form with error flash and no session", %{conn: conn} do
      conn = post(conn, "/login", %{"token" => @invalid_token})
      body = html_response(conn, 200)
      assert body =~ "Invalid API token."
      assert get_session(conn, "api_token") == nil
      assert get_session(conn, "api_token_session") == nil
      # The token must NOT be reflected back in the rendered HTML.
      refute body =~ @invalid_token
    end

    test "missing token params returns form with error flash", %{conn: conn} do
      conn = post(conn, "/login", %{})
      body = html_response(conn, 200)
      assert body =~ "Token is required."
      assert get_session(conn, "api_token") == nil
      assert get_session(conn, "api_token_session") == nil
    end
  end

  describe "POST /logout" do
    test "clears the session and redirects to /studio", %{conn: conn} do
      # Seed a logged-in session by going through the real login flow.
      logged_in = post(conn, "/login", %{"token" => @valid_token})
      assert_session_resolves_to(logged_in, @valid_token)

      # POST /logout while carrying the session cookie forward.
      logged_out =
        logged_in
        |> recycle()
        |> post("/logout")

      assert redirected_to(logged_out, 302) == "/studio"

      # `configure_session(drop: true)` drops the cookie at response time,
      # so a fresh request after recycle() should see an empty session.
      next = recycle(logged_out) |> get("/login")
      assert get_session(next, "api_token") == nil
      assert get_session(next, "api_token_session") == nil
    end

    # The criterion this PR exists for (ruling #16 rework half,
    # task-57f23825b18ab55d): BEFORE this change, a token sign-in stored the
    # RAW bearer directly in the session, and logout's only effect was
    # `configure_session(drop: true)` — it dropped THIS browser's cookie but
    # revoked nothing server-side. A cookie copied before logout (a stolen
    # device, a backed-up browser profile) kept authenticating forever, right
    # up until the underlying api_token was separately revoked. Now logout
    # deletes the `TokenSession` row the cookie's opaque id names, so a copied
    # cookie's session id stops resolving the instant the real session signs
    # out — proven here by resolving the SAME session id, read from a COPY of
    # the cookie taken before logout, through the real `/login` + `/logout`
    # HTTP flow.
    test "after sign-in and logout, replaying a COPIED cookie no longer authenticates",
         %{conn: conn} do
      logged_in = post(conn, "/login", %{"token" => @valid_token})
      copied_cookie_session_id = get_session(logged_in, "api_token_session")
      assert is_binary(copied_cookie_session_id)

      # The copy currently resolves (sanity: the later refusal is the
      # logout's doing, not a setup mistake).
      assert {:ok, _token, @valid_token} =
               Auth.resolve_session_credential(copied_cookie_session_id, nil)

      # The REAL browser signs out, on an independent lineage carrying the
      # same cookie.
      signed_out = recycle(logged_in) |> post("/logout")
      assert redirected_to(signed_out, 302) == "/studio"

      # REPLAY: the copy made before logout still carries that exact session
      # id. It must no longer resolve to anything live.
      assert Auth.resolve_session_credential(copied_cookie_session_id, nil) == :error
    end

    # PDS-D523: the sign-out receipt used to say "Signed out." over a revoke
    # whose count died inside `Accounts.revoke_user_session_token/1`. The flash
    # is now answered over the rows the revoke actually stamped, and the STORED
    # UserSession row — read back through Repo, never a second HTTP endpoint —
    # is what certifies it.
    test "the sign-out receipt is backed by the revoked row, and a second sign-out still succeeds",
         %{conn: conn} do
      {:ok, user} =
        Accounts.register_user(%{
          email: "logout-receipt@example.com",
          password: "correct-horse-battery"
        })

      {:ok, token} = Accounts.create_user_session_token(user)

      first =
        conn
        |> init_test_session(%{"user_session" => token})
        |> post("/logout")

      assert redirected_to(first, 302) == "/studio"
      assert Phoenix.Flash.get(first.assigns.flash, :info) == "Signed out."

      # The claim, read off the stored row rather than off the response.
      row = Repo.one(from s in UserSession, where: s.user_id == ^user.id)
      refute is_nil(row.revoked_at)
      revoked_at = row.revoked_at

      # A benign double logout: still a success (302 to /studio, cookie dropped),
      # but the receipt no longer claims a session was killed, and the already
      # revoked row is untouched.
      second =
        scoped_conn()
        |> init_test_session(%{"user_session" => token})
        |> post("/logout")

      assert redirected_to(second, 302) == "/studio"
      assert Phoenix.Flash.get(second.assigns.flash, :info) == "You were already signed out."

      assert Repo.one(from s in UserSession, where: s.user_id == ^user.id).revoked_at ==
               revoked_at
    end
  end

  describe "POST /login/mfa (step-up recency window)" do
    # A TOTP-armed user plus one live recovery code. The recovery code is the
    # deterministic second factor here: `verify_totp` consumes a period, so a
    # code reused within the enrolment period would read as replay and make the
    # positive control flaky. Recovery codes burn individually.
    defp arm_mfa!(email) do
      {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
      secret = NimbleTOTP.secret()

      {:ok, user, [recovery | _]} =
        Accounts.enable_totp(user, secret, totp_code_stable!(secret))

      {user, recovery}
    end

    # Seed the pending marker the way `complete_sign_in/3` does, but with an
    # explicit anchor — no sleeping, no barriers, no timing flake.
    defp post_mfa(user, at, recovery) do
      scoped_conn()
      |> init_test_session(%{"studio_mfa_user" => user.id, "studio_mfa_at" => at})
      |> post("/login/mfa", %{"recovery_code" => recovery})
    end

    defp session_rows(user), do: Repo.all(from s in UserSession, where: s.user_id == ^user.id)

    test "an anchor in the FUTURE is rejected — no session is minted", %{conn: _conn} do
      {user, recovery} = arm_mfa!("mfa-future-anchor@example.com")

      # Arithmetically identical to a 100_000s BACKWARD wall-clock step on this
      # node, and the only reachable route since the cookie is signed. On the
      # UNFIXED predicate this redirects to /studio and mints a session.
      conn = post_mfa(user, System.system_time(:second) + 100_000, recovery)

      assert redirected_to(conn, 302) == "/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Sign-in expired"
      refute get_session(conn, "user_session")
      assert session_rows(user) == []
    end

    test "a STALE anchor is still rejected (the negative control)", %{conn: _conn} do
      {user, recovery} = arm_mfa!("mfa-stale-anchor@example.com")

      conn = post_mfa(user, System.system_time(:second) - 1000, recovery)

      assert redirected_to(conn, 302) == "/login"
      refute get_session(conn, "user_session")
      assert session_rows(user) == []
    end

    test "an IN-WINDOW anchor still mints a session (the floor did not over-tighten)",
         %{conn: _conn} do
      {user, recovery} = arm_mfa!("mfa-in-window-anchor@example.com")

      conn = post_mfa(user, System.system_time(:second) - 10, recovery)

      assert redirected_to(conn, 302) == "/studio"
      assert is_binary(get_session(conn, "user_session"))
      assert [row] = session_rows(user)
      refute is_nil(row.mfa_verified_at)
    end

    test "an anchor exactly at now still mints a session (the floor is inclusive)",
         %{conn: _conn} do
      {user, recovery} = arm_mfa!("mfa-now-anchor@example.com")

      conn = post_mfa(user, System.system_time(:second), recovery)

      assert redirected_to(conn, 302) == "/studio"
      assert is_binary(get_session(conn, "user_session"))
    end
  end
end
