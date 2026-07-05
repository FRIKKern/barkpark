defmodule BarkparkWeb.SessionController do
  @moduledoc """
  Browser-facing session controller. Lets a human paste their raw API
  token via `GET /login`, stores it in `session["api_token"]` on success,
  and clears the session via `POST /logout`.

  This is the canonical browser entry point for admin LiveViews; see
  `BarkparkWeb.LiveAuth` for the on_mount that consumes the session key.
  """
  use BarkparkWeb, :controller

  @default_return_to "/studio"

  def new(conn, params) do
    return_to = sanitize_return_to(params["return_to"])
    render(conn, :new, return_to: return_to, page_title: "Sign in")
  end

  def create(conn, %{"token" => raw_token} = params) when is_binary(raw_token) do
    return_to = sanitize_return_to(params["return_to"])
    trimmed = String.trim(raw_token)

    case Barkpark.Auth.verify_token(trimmed) do
      {:ok, _api_token} ->
        conn
        |> configure_session(renew: true)
        |> put_session("api_token", trimmed)
        |> put_flash(:info, "Signed in.")
        |> redirect(to: return_to)

      {:error, :unauthorized} ->
        conn
        |> put_flash(:error, "Invalid API token.")
        |> render(:new, return_to: return_to, page_title: "Sign in")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Token is required.")
    |> render(:new, return_to: @default_return_to, page_title: "Sign in")
  end

  @doc """
  Consume a single-use login ticket (dwb-7 "Studio one-click entry").

  `GET /login/ticket/:ticket` — atomically consumes the ticket (single-use +
  60s TTL, enforced in `Barkpark.Auth.consume_login_ticket/1`), drops the bound
  RAW api_token into `session["api_token"]` exactly like `create/2` does for a
  pasted token, and redirects to `/studio`. One click, no paste, works from a
  fresh browser.

  Consuming on GET is the magic-link tradeoff: mitigated by single-use + short
  TTL + `Cache-Control: no-store` (no proxy/history reuse) + `Referrer-Policy:
  no-referrer` (the ticket URL never leaks as a Referer to /studio). Every
  failure kind (unknown / used / expired) yields the SAME friendly flash — no
  oracle.
  """
  def ticket(conn, %{"ticket" => raw_ticket}) when is_binary(raw_ticket) do
    conn = no_store(conn)

    case Barkpark.Auth.consume_login_ticket(raw_ticket) do
      {:ok, api_token} ->
        conn
        |> configure_session(renew: true)
        |> put_session("api_token", api_token)
        |> put_flash(:info, "Signed in.")
        |> redirect(to: @default_return_to)

      {:error, :invalid} ->
        conn
        |> put_flash(:error, "This sign-in link is invalid or has expired.")
        |> redirect(to: "/login")
    end
  end

  def ticket(conn, _params) do
    conn
    |> no_store()
    |> put_flash(:error, "This sign-in link is invalid or has expired.")
    |> redirect(to: "/login")
  end

  @doc """
  Account sign-in (studio-user-login): email + password against the core auth
  system — the SAME `Accounts.get_user_by_email_and_password/2` the API login
  uses, so lockout and constant-time verification apply identically. A user
  with TOTP armed gets the second step (`mfa/2` below) via a short-lived
  pending marker in the session — the password is never round-tripped through
  the form. A factor-less user governed by a `require_mfa` org is blocked with
  enrolment guidance (the browser has no enrolment UI yet — that is the
  documented follow-up).
  """
  def account(conn, %{"email" => email, "password" => password} = params) do
    return_to = sanitize_return_to(params["return_to"])

    case Barkpark.Accounts.get_user_by_email_and_password(email, password) do
      nil ->
        conn
        |> put_flash(:error, "Email or password is incorrect.")
        |> render(:new, return_to: return_to, page_title: "Sign in")

      user ->
        cond do
          user.totp_enabled ->
            conn
            |> put_session("studio_mfa_user", user.id)
            |> put_session("studio_mfa_at", System.system_time(:second))
            |> render(:mfa, return_to: return_to, page_title: "Two-factor code")

          Barkpark.Tenancy.org_requires_mfa_for_user?(user.id) ->
            conn
            |> put_flash(
              :error,
              "Your organization requires MFA. Enrol a factor first " <>
                "(POST /v1/auth/mfa/enroll or `bp auth mfa enroll`), then sign in again."
            )
            |> render(:new, return_to: return_to, page_title: "Sign in")

          true ->
            mint_user_session(conn, user, return_to, mfa_verified: false)
        end
    end
  end

  def account(conn, params) do
    conn
    |> put_flash(:error, "Email and password are required.")
    |> render(:new,
      return_to: sanitize_return_to(params["return_to"]),
      page_title: "Sign in"
    )
  end

  @doc """
  Second step of account sign-in: TOTP code or a recovery code against the
  pending user (5-minute window). Mirrors the API's `login_with_mfa` —
  `verify_totp` consumes the code (one-time per window), `consume_recovery_code`
  burns the recovery code.
  """
  def mfa(conn, params) do
    return_to = sanitize_return_to(params["return_to"])
    user_id = get_session(conn, "studio_mfa_user")
    at = get_session(conn, "studio_mfa_at")

    fresh? =
      is_integer(at) and System.system_time(:second) - at <= 300

    with true <- is_binary(user_id) and fresh?,
         %Barkpark.Accounts.User{} = user <- Barkpark.Accounts.get_user(user_id),
         true <- mfa_factor_ok?(user, params["code"], params["recovery_code"]) do
      conn
      |> delete_session("studio_mfa_user")
      |> delete_session("studio_mfa_at")
      |> mint_user_session(user, return_to, mfa_verified: true)
    else
      _ ->
        if is_binary(user_id) and fresh? do
          conn
          |> put_flash(:error, "That code didn't work — try again.")
          |> render(:mfa, return_to: return_to, page_title: "Two-factor code")
        else
          conn
          |> configure_session(renew: true)
          |> put_flash(:error, "Sign-in expired — start again.")
          |> redirect(to: "/login")
        end
    end
  end

  defp mfa_factor_ok?(user, code, recovery) do
    (is_binary(code) and match?({:ok, _}, Barkpark.Accounts.verify_totp(user, code))) or
      (is_binary(recovery) and
         match?({:ok, _}, Barkpark.Accounts.consume_recovery_code(user, recovery)))
  end

  # Mint the browser user session — same token machinery as the API login
  # (`SessionIssuer` parity: ip/ua stamped, `mfa_verified` marks step-up
  # freshness), delivered as the `user_session` cookie + a redirect instead of
  # the API's JSON body.
  defp mint_user_session(conn, user, return_to, opts) do
    {:ok, token} =
      Barkpark.Accounts.create_user_session_token(
        user,
        [ip_address: client_ip(conn), user_agent: user_agent(conn)] ++ opts
      )

    conn
    |> configure_session(renew: true)
    |> put_session("user_session", token)
    |> put_flash(:info, "Signed in.")
    |> redirect(to: return_to)
  end

  defp client_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  defp user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      _ -> nil
    end
  end

  def delete(conn, _params) do
    # Revoke the account session server-side (not just the cookie) — parity
    # with DELETE /v1/auth/logout; the API-token session key needs no
    # revocation (dropping the cookie is the whole grant).
    case get_session(conn, "user_session") do
      token when is_binary(token) and token != "" ->
        Barkpark.Accounts.revoke_user_session_token(token)

      _ ->
        :ok
    end

    conn
    |> configure_session(drop: true)
    |> put_flash(:info, "Signed out.")
    |> redirect(to: "/studio")
  end

  # Harden the one-time-link response: never cached/stored, and the ticket URL
  # is never leaked onward as a Referer.
  defp no_store(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  defp sanitize_return_to(nil), do: @default_return_to
  defp sanitize_return_to(""), do: @default_return_to

  defp sanitize_return_to(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") do
      path
    else
      @default_return_to
    end
  end

  defp sanitize_return_to(_), do: @default_return_to
end
