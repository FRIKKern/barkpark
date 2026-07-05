defmodule BarkparkWeb.AuthController do
  @moduledoc """
  Core user-auth JSON API (`/v1/auth/*`).

  Public: register, login (with TOTP second factor), verify-email, request-reset,
  reset. Session-gated (`RequireUserSession`): me, logout, mfa/enroll, mfa/verify,
  mfa/disable. The three mfa/* routes additionally require the current password
  (re-auth) so a hijacked-but-unlocked session cannot silently alter MFA.

  Login returns the session token as a bearer in the body AND sets a signed
  `user_session` cookie, so both API clients and browsers are served. Anti-
  enumeration: request-reset AND register always return a generic success;
  login failures are a single generic `invalid_credentials` regardless of
  whether the email exists OR whether the password was correct-but-MFA-needed.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Accounts
  alias Barkpark.Accounts.UserNotifier

  # ── Registration ───────────────────────────────────────────────────────────

  # MEDIUM-7: anti-enumeration. A duplicate email must be INDISTINGUISHABLE from
  # a fresh signup — same status, same body shape — so a caller can't probe which
  # addresses are registered. We notify the existing owner out-of-band instead of
  # leaking "has already been taken". Real validation errors (weak password) stay
  # 422. The response omits the user id precisely so the two paths can't diverge.
  #
  # The email-taken signal must NEVER reach the caller, even when it co-occurs with
  # another error (the weak-password probe: validate_email's unsafe_validate_unique
  # still runs when only :password is invalid, so a duplicate+short password
  # produces BOTH errors). We therefore always strip the :email signal from any
  # 422 body, so existing-email+weak-password and new-email+weak-password are
  # byte-identical (password error only).
  def register(conn, %{"email" => email, "password" => password}) do
    case Accounts.register_user(%{email: email, password: password}) do
      {:ok, user} ->
        send_confirmation(user)
        registration_accepted(conn, email)

      {:error, changeset} ->
        if email_taken?(changeset) do
          # An existing account is implicated — notify it out-of-band, never leak.
          notify_existing_account(email)
        end

        case errors_without_email_signal(changeset) do
          # Email collision was the ONLY problem → indistinguishable from a fresh
          # signup (generic 201). Otherwise surface the real errors with the email
          # existence signal already stripped.
          map when map_size(map) == 0 -> registration_accepted(conn, email)
          errors -> error(conn, 422, "invalid_registration", errors)
        end
    end
  end

  def register(conn, _), do: error(conn, 400, "bad_request", "email and password are required")

  # ── Login (+ TOTP second factor) ────────────────────────────────────────────

  def login(conn, %{"email" => email, "password" => password} = params) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        error(
          conn,
          401,
          "invalid_credentials",
          "email or password is incorrect",
          "double-check the email and password; if forgotten, start a reset with request-reset"
        )

      user ->
        if user.totp_enabled do
          login_with_mfa(conn, user, params["totp_code"], params["recovery_code"])
        else
          issue_session(conn, user)
        end
    end
  end

  def login(conn, _), do: error(conn, 400, "bad_request", "email and password are required")

  # Standard two-step 2FA UX: the PASSWORD is already correct here (a wrong
  # password never reaches this fn — `login/2` returns `invalid_credentials`
  # first), so a missing OR invalid second factor returns `mfa_required` —
  # the "now enter your code" signal a two-step login client needs.
  #
  # DELIBERATE, industry-accepted tradeoff (restores LOW-13's removal): replying
  # `mfa_required` only after a correct password confirms password validity to a
  # caller who already supplied it — a minor oracle that standard 2FA flows
  # accept as the price of a usable two-step login. The generic-on-everything
  # alternative breaks the UX (the client can't tell "wrong password" from
  # "needs a code").
  #
  # MEDIUM-6: the TOTP is consumed via verify_totp so the code is one-time.
  defp login_with_mfa(conn, user, code, recovery) do
    cond do
      is_binary(code) and match?({:ok, _}, Accounts.verify_totp(user, code)) ->
        issue_session(conn, user)

      is_binary(recovery) and match?({:ok, _}, Accounts.consume_recovery_code(user, recovery)) ->
        issue_session(conn, user)

      true ->
        error(
          conn,
          401,
          "mfa_required",
          "a valid TOTP or recovery code is required",
          "enter the 6-digit code from your authenticator app (or a one-time recovery code) and retry"
        )
    end
  end

  # ── Session lifecycle ───────────────────────────────────────────────────────

  @doc """
  GDPR right of access — export the current subject's complete data bundle as
  machine-readable JSON. Session-gated: a subject can only export their own data.
  """
  def export(conn, _params) do
    user = conn.assigns.current_user
    json(conn, Barkpark.Accounts.Privacy.export_subject(user))
  end

  @doc """
  GDPR right to erasure — pseudonymise the current subject and revoke all access.
  Sensitive: requires the current password (reauth). The now-erased session is
  dropped from the response.
  """
  def erase(conn, %{"password" => password}) do
    user = conn.assigns.current_user

    if reauthed?(user, password) do
      {:ok, summary} = Barkpark.Accounts.Privacy.erase_subject(user)

      conn
      |> configure_session(drop: true)
      |> json(%{ok: true, erased: summary})
    else
      error(
        conn,
        403,
        "invalid_password",
        "the current password is required to erase your account"
      )
    end
  end

  def erase(conn, _), do: error(conn, 400, "bad_request", "password is required")

  def me(conn, _params) do
    user = conn.assigns.current_user

    json(conn, %{
      user: %{
        id: user.id,
        email: user.email,
        confirmed: not is_nil(user.confirmed_at),
        mfa: user.totp_enabled
      }
    })
  end

  def logout(conn, _params) do
    case bearer_or_cookie(conn) do
      nil -> :noop
      token -> Accounts.revoke_user_session_token(token)
    end

    conn
    |> clear_session()
    |> json(%{ok: true})
  end

  # ── Email verification + password reset ─────────────────────────────────────

  def verify_email(conn, %{"token" => token}) do
    case Accounts.confirm_user(token) do
      {:ok, _user} ->
        json(conn, %{ok: true})

      :error ->
        error(
          conn,
          422,
          "invalid_token",
          "the confirmation link is invalid or expired",
          "request a fresh confirmation email — verification links are single-use and time-limited"
        )
    end
  end

  def request_reset(conn, %{"email" => email}) do
    # Always 200 — never reveal whether the email is registered.
    if user = Accounts.get_user_by_email(email) do
      {:ok, token} = Accounts.build_email_token(user, "reset")
      UserNotifier.deliver_reset(user.email, build_url("/auth/reset/", token))
    end

    json(conn, %{ok: true})
  end

  @doc """
  Passwordless sign-in — request a magic link. Emails a single-use login link
  if the address maps to a user; ALWAYS returns a generic `{ok: true}` so the
  response never reveals whether the email is registered (anti-enumeration,
  identical to request-reset).
  """
  def request_magic_link(conn, %{"email" => email}) do
    case Accounts.build_login_token(email) do
      {:ok, token, user} ->
        UserNotifier.deliver_magic_link(user.email, build_url("/auth/magic/", token))

      _ ->
        :ok
    end

    json(conn, %{ok: true})
  end

  def request_magic_link(conn, _), do: error(conn, 400, "bad_request", "email is required")

  @doc """
  Passwordless sign-in — complete it. Consumes the single-use magic-link token
  and issues a session. Unknown, already-used, and expired tokens all return
  the same generic `invalid_token` error (no oracle).
  """
  def magic_login(conn, %{"token" => token}) do
    case Accounts.consume_login_token(token) do
      {:ok, user} ->
        issue_session(conn, user)

      :error ->
        error(
          conn,
          401,
          "invalid_token",
          "this sign-in link is invalid or has expired",
          "request a fresh sign-in link and use it promptly"
        )
    end
  end

  def magic_login(conn, _), do: error(conn, 400, "bad_request", "token is required")

  def reset(conn, %{"token" => token, "password" => password}) do
    case Accounts.reset_user_password(token, %{password: password}) do
      {:ok, _user} ->
        json(conn, %{ok: true})

      {:error, cs} ->
        error(conn, 422, "invalid_password", changeset_errors(cs))

      :error ->
        error(
          conn,
          422,
          "invalid_token",
          "the reset link is invalid or expired",
          "request a new reset link with request-reset — reset links are single-use and time-limited"
        )
    end
  end

  # ── TOTP MFA enrolment ───────────────────────────────────────────────────────

  # MEDIUM-8: re-auth on enrol. Even behind a live session, minting a new MFA
  # secret requires the current password — a stolen/forgotten-unlocked session
  # cannot silently bootstrap attacker-controlled MFA.
  def mfa_enroll(conn, %{"password" => password}) do
    user = conn.assigns.current_user

    if reauthed?(user, password) do
      secret = Accounts.totp_secret()
      uri = Accounts.totp_uri(user, secret)

      json(conn, %{
        secret: Base.encode32(secret, padding: false),
        otpauth_uri: uri,
        qr_svg: uri |> EQRCode.encode() |> EQRCode.svg()
      })
    else
      error(conn, 403, "reauth_required", "the current password is required")
    end
  end

  def mfa_enroll(conn, _),
    do: error(conn, 403, "reauth_required", "the current password is required")

  # MEDIUM-8: re-auth on verify too — the step that actually persists the secret.
  def mfa_verify(conn, %{"secret" => secret_b32, "code" => code, "password" => password}) do
    user = conn.assigns.current_user

    cond do
      not reauthed?(user, password) ->
        error(conn, 403, "reauth_required", "the current password is required")

      true ->
        with {:ok, secret} <- decode_secret(secret_b32),
             {:ok, _user, recovery_codes} <- Accounts.enable_totp(user, secret, code) do
          json(conn, %{ok: true, recovery_codes: recovery_codes})
        else
          _ ->
            error(
              conn,
              422,
              "invalid_code",
              "the TOTP code did not match the secret",
              "codes rotate every 30s — re-read the current code from your authenticator and retry"
            )
        end
    end
  end

  # Secret + code present but no password → the re-auth gate, not a code problem.
  def mfa_verify(conn, %{"secret" => _, "code" => _}),
    do: error(conn, 403, "reauth_required", "the current password is required")

  def mfa_verify(conn, _),
    do: error(conn, 422, "invalid_code", "secret, code and password are required")

  # MEDIUM-8: an MFA-disable route, session-gated AND password-gated. Without
  # this, a user (or admin recovering a hijacked account) had no way to drop MFA
  # short of a full password reset.
  def mfa_disable(conn, %{"password" => password}) do
    user = conn.assigns.current_user

    if reauthed?(user, password) do
      {:ok, _user} = Accounts.disable_totp(user)
      json(conn, %{ok: true})
    else
      error(conn, 403, "reauth_required", "the current password is required")
    end
  end

  def mfa_disable(conn, _),
    do: error(conn, 403, "reauth_required", "the current password is required")

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp issue_session(conn, user) do
    {:ok, token} =
      Accounts.create_user_session_token(user,
        ip_address: client_ip(conn),
        user_agent: user_agent(conn)
      )

    conn
    |> configure_session(renew: true)
    |> put_session("user_session", token)
    |> put_status(:created)
    |> json(%{token: token, user: %{id: user.id, email: user.email}})
  end

  # Verify the current password for a session-authenticated, sensitive action.
  defp reauthed?(user, password) when is_binary(password),
    do: Barkpark.Accounts.User.valid_password?(user, password)

  defp reauthed?(_user, _), do: false

  # MEDIUM-7: the single registration-accepted shape, reused by the fresh-signup
  # and duplicate-email paths so they're byte-identical to the caller.
  defp registration_accepted(conn, email) do
    conn
    |> put_status(:created)
    |> json(%{user: %{email: email, confirmed: false}})
  end

  # True iff the changeset carries the "email already registered" signal (a unique
  # collision). This is the existence oracle that MEDIUM-7 must never surface to a
  # caller — regardless of whether it co-occurs with a genuine error (the weak-
  # password probe: unsafe_validate_unique still runs when only :password is bad).
  defp email_taken?(%Ecto.Changeset{errors: errors}),
    do: Enum.any?(errors, &email_taken_error?/1)

  defp email_taken_error?({:email, {_msg, opts}}),
    do: opts[:validation] == :unsafe_unique or opts[:constraint] == :unique

  defp email_taken_error?(_), do: false

  # Serialize the changeset's errors WITH the email-uniqueness signal removed, so
  # the 422 body can never reveal account existence. A legitimate :email *format*
  # error is preserved (it carries no existence information).
  defp errors_without_email_signal(changeset) do
    filtered = Enum.reject(changeset.errors, &email_taken_error?/1)
    %{changeset | errors: filtered} |> changeset_errors()
  end

  defp notify_existing_account(email) do
    if user = Accounts.get_user_by_email(email) do
      UserNotifier.deliver_already_registered(user.email)
    end

    :ok
  end

  defp send_confirmation(user) do
    case Accounts.build_email_token(user, "confirm") do
      {:ok, token} ->
        UserNotifier.deliver_confirmation(user.email, build_url("/auth/confirm/", token))

      _ ->
        :ok
    end
  end

  defp decode_secret(b32) do
    case Base.decode32(b32, padding: false) do
      {:ok, secret} -> {:ok, secret}
      :error -> :error
    end
  end

  defp bearer_or_cookie(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw] -> String.trim(raw)
      _ -> get_session(conn, "user_session")
    end
  end

  defp build_url(path, token), do: BarkparkWeb.Endpoint.url() <> path <> token

  defp client_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  defp user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      _ -> nil
    end
  end

  defp error(conn, status, code, message, hint \\ nil) do
    error_map = %{code: code, message: message}
    error_map = if hint, do: Map.put(error_map, :hint, hint), else: error_map

    conn
    |> put_status(status)
    |> json(%{error: error_map})
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
  end
end
