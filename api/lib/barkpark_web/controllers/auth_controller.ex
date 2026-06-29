defmodule BarkparkWeb.AuthController do
  @moduledoc """
  Core user-auth JSON API (`/v1/auth/*`).

  Public: register, login (with TOTP second factor), verify-email, request-reset,
  reset. Session-gated (`RequireUserSession`): me, logout, mfa/enroll, mfa/verify.

  Login returns the session token as a bearer in the body AND sets a signed
  `user_session` cookie, so both API clients and browsers are served. Anti-
  enumeration: request-reset always 200s; login failures are a single generic
  `invalid_credentials` regardless of whether the email exists.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Accounts
  alias Barkpark.Accounts.UserNotifier

  # ── Registration ───────────────────────────────────────────────────────────

  def register(conn, %{"email" => email, "password" => password}) do
    case Accounts.register_user(%{email: email, password: password}) do
      {:ok, user} ->
        send_confirmation(user)

        conn
        |> put_status(:created)
        |> json(%{user: %{id: user.id, email: user.email, confirmed: false}})

      {:error, changeset} ->
        error(conn, 422, "invalid_registration", changeset_errors(changeset))
    end
  end

  def register(conn, _), do: error(conn, 400, "bad_request", "email and password are required")

  # ── Login (+ TOTP second factor) ────────────────────────────────────────────

  def login(conn, %{"email" => email, "password" => password} = params) do
    case Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        error(conn, 401, "invalid_credentials", "email or password is incorrect")

      user ->
        if user.totp_enabled do
          login_with_mfa(conn, user, params["totp_code"], params["recovery_code"])
        else
          issue_session(conn, user)
        end
    end
  end

  def login(conn, _), do: error(conn, 400, "bad_request", "email and password are required")

  defp login_with_mfa(conn, user, code, recovery) do
    cond do
      is_binary(code) and Accounts.valid_totp?(user, code) ->
        issue_session(conn, user)

      is_binary(recovery) and match?({:ok, _}, Accounts.consume_recovery_code(user, recovery)) ->
        issue_session(conn, user)

      true ->
        conn
        |> put_status(401)
        |> json(%{error: %{code: "mfa_required", message: "a TOTP or recovery code is required"}})
    end
  end

  # ── Session lifecycle ───────────────────────────────────────────────────────

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
      {:ok, _user} -> json(conn, %{ok: true})
      :error -> error(conn, 422, "invalid_token", "the confirmation link is invalid or expired")
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

  def reset(conn, %{"token" => token, "password" => password}) do
    case Accounts.reset_user_password(token, %{password: password}) do
      {:ok, _user} -> json(conn, %{ok: true})
      {:error, cs} -> error(conn, 422, "invalid_password", changeset_errors(cs))
      :error -> error(conn, 422, "invalid_token", "the reset link is invalid or expired")
    end
  end

  # ── TOTP MFA enrolment ───────────────────────────────────────────────────────

  def mfa_enroll(conn, _params) do
    user = conn.assigns.current_user
    secret = Accounts.totp_secret()
    uri = Accounts.totp_uri(user, secret)

    json(conn, %{
      secret: Base.encode32(secret, padding: false),
      otpauth_uri: uri,
      qr_svg: uri |> EQRCode.encode() |> EQRCode.svg()
    })
  end

  def mfa_verify(conn, %{"secret" => secret_b32, "code" => code}) do
    user = conn.assigns.current_user

    with {:ok, secret} <- decode_secret(secret_b32),
         {:ok, _user, recovery_codes} <- Accounts.enable_totp(user, secret, code) do
      json(conn, %{ok: true, recovery_codes: recovery_codes})
    else
      _ -> error(conn, 422, "invalid_code", "the TOTP code did not match the secret")
    end
  end

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

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
  end
end
