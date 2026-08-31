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
    render(conn, :new, new_assigns(return_to))
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
        |> render(:new, new_assigns(return_to))
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Token is required.")
    |> render(:new, new_assigns(@default_return_to))
  end

  # Every render of :new carries the same assign set — error re-renders must
  # not lose the cloud button or the host line.
  defp new_assigns(return_to) do
    [
      return_to: return_to,
      page_title: "Sign in",
      instance_host: instance_host(),
      cloud_login_href: cloud_login_href()
    ]
  end

  defp instance_host, do: URI.parse(BarkparkWeb.Endpoint.url()).host

  # "Log in with Barkpark Cloud": on a cloud-managed instance (runtime env
  # BARKPARK_CLOUD_URL → :cloud_login_url), deep-link to the control plane's
  # SPA carrying THIS instance's public origin. The SPA matches the origin
  # against the signed-in user's own fleet and round-trips a login ticket to
  # /login/ticket/:t — authorization stays entirely on the cloud's
  # studio-link route, so the href carries no secret. nil → no button.
  defp cloud_login_href do
    case Application.get_env(:barkpark, :cloud_login_url) do
      url when is_binary(url) and url != "" ->
        String.trim_trailing(url, "/") <>
          "/#/instance-login?url=" <> URI.encode_www_form(BarkparkWeb.Endpoint.url())

      _ ->
        nil
    end
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
      # USER-shaped ticket (cloud-identity-studio-handoff): the Barkpark Cloud
      # owner lands signed in AS their cloud account. JIT-provision mirrors
      # SSO (find-or-create by email); the Default-workspace OWNER grant is
      # legitimate because minting required the instance ADMIN token, and the
      # control plane only mints for the instance's own team.
      {:ok, {:user, email, _admin_token}} ->
        user = Barkpark.Sso.find_or_create_user(email)
        ensure_default_owner_membership(user)

        {:ok, token} =
          Barkpark.Accounts.create_user_session_token(
            user,
            BarkparkWeb.SessionIssuer.actor_opts(conn)
          )

        conn
        |> configure_session(renew: true)
        |> put_session("user_session", token)
        |> put_flash(:info, "Signed in.")
        |> redirect(to: @default_return_to)

      {:ok, api_token} when is_binary(api_token) ->
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

  # Idempotent: an existing membership (any role) is left untouched — the
  # handoff never DOWNGRADES; absence gets the owner grant the admin-token
  # mint vouches for.
  defp ensure_default_owner_membership(user) do
    with %{id: ws_id} <- Barkpark.Tenancy.get_default_workspace(),
         nil <- Barkpark.Tenancy.Auth.membership(user, ws_id) do
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws_id, user.id, "owner", "user")
      :ok
    else
      _ -> :ok
    end
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
        |> render(:new, new_assigns(return_to))

      user ->
        complete_sign_in(conn, user, return_to)
    end
  end

  def account(conn, params) do
    conn
    |> put_flash(:error, "Email and password are required.")
    |> render(:new, new_assigns(sanitize_return_to(params["return_to"])))
  end

  # The shared post-authentication decision, reused by password (`account/2`)
  # AND magic-link (`magic/2`) sign-in so both surfaces enforce the SAME second
  # factor — a magic link must never be a 2FA / org-MFA bypass. A TOTP-armed
  # user is routed to the second step (`mfa/2`); a governed factor-less user is
  # blocked with enrolment guidance (era-w2-org-require-mfa); otherwise the
  # session is minted directly.
  defp complete_sign_in(conn, user, return_to) do
    cond do
      user.totp_enabled ->
        conn
        |> put_session("studio_mfa_user", user.id)
        |> put_session("studio_mfa_at", System.system_time(:second))
        |> render(:mfa, return_to: return_to, page_title: "Two-step verification")

      Barkpark.Tenancy.org_requires_mfa_for_user?(user.id) ->
        conn
        |> put_flash(
          :error,
          "Your organization requires MFA. Enrol a factor first " <>
            "(POST /v1/auth/mfa/enroll or `bp auth mfa enroll`), then sign in again."
        )
        |> render(:new, new_assigns(return_to))

      true ->
        mint_user_session(conn, user, return_to, mfa_verified: false)
    end
  end

  @doc """
  Magic-link sign-in — request it (`GET|POST /login/magic`). Browser twin of
  `POST /v1/auth/request-magic-link` (AuthController): the SAME anti-enumeration
  contract — whether or not the address has an account, the page shows the same
  confirmation. The emailed link is the same `/auth/magic/<token>` URL the JSON
  flow already sends (which `magic/2` below makes land in a browser).
  """
  def magic_request_form(conn, _params) do
    render(conn, :magic_request, page_title: "Sign-in link", sent: false)
  end

  def magic_request(conn, %{"email" => email}) when is_binary(email) do
    case Barkpark.Accounts.build_login_token(String.trim(email)) do
      {:ok, token, user} ->
        Barkpark.Accounts.UserNotifier.deliver_magic_link(
          user.email,
          BarkparkWeb.Endpoint.url() <> "/auth/magic/" <> token
        )

      _ ->
        :ok
    end

    render(conn, :magic_request, page_title: "Sign-in link", sent: true)
  end

  def magic_request(conn, _params), do: redirect(conn, to: "/login/magic")

  @doc """
  Magic-link sign-in — complete it (`GET /auth/magic/:token`). Consumes the
  single-use login token (email possession = a factor), then rides the shared
  `complete_sign_in/3` decision so a TOTP-armed or org-governed user still meets
  the second factor. Before this route the emailed link 404'd in a browser (only
  the JSON `POST /magic-login` existed). Same GET-consume magic-link tradeoff as
  the ticket flow: single-use + short TTL + `no-store` + `no-referrer`; every
  failure kind yields ONE generic flash (no oracle).
  """
  def magic(conn, %{"token" => token}) when is_binary(token) do
    conn = no_store(conn)

    case Barkpark.Accounts.consume_login_token(token) do
      {:ok, user} ->
        complete_sign_in(conn, user, @default_return_to)

      :error ->
        conn
        |> put_flash(:error, "This sign-in link is invalid or has expired — request a fresh one.")
        |> redirect(to: "/login/magic")
    end
  end

  def magic(conn, _params), do: redirect(conn, to: "/login/magic")

  @doc """
  "Forgot password?" — browser twin of `POST /v1/auth/request-reset`
  (AuthController). Same anti-enumeration contract: whether or not the address
  has an account, the page shows the SAME confirmation. The emailed link is the
  same `/auth/reset/<token>` URL the API flow sends; `reset_form/2` below is
  what makes that link actually land somewhere in a browser.
  """
  def reset_request_form(conn, _params) do
    render(conn, :reset_request, page_title: "Reset password", sent: false)
  end

  def reset_request(conn, %{"email" => email}) when is_binary(email) do
    if user = Barkpark.Accounts.get_user_by_email(String.trim(email)) do
      {:ok, token} = Barkpark.Accounts.build_email_token(user, "reset")

      Barkpark.Accounts.UserNotifier.deliver_reset(
        user.email,
        BarkparkWeb.Endpoint.url() <> "/auth/reset/" <> token
      )
    end

    render(conn, :reset_request, page_title: "Reset password", sent: true)
  end

  def reset_request(conn, _params), do: redirect(conn, to: "/login/reset")

  @doc """
  Landing page for the emailed reset link (`GET /auth/reset/:token`). The
  token is only VERIFIED on submit — rendering the form never consumes or
  oracles it (`reset_submit/2` gives every bad token the same generic error).
  """
  def reset_form(conn, %{"token" => token}) when is_binary(token) do
    conn
    |> no_store()
    |> render(:reset, page_title: "Set a new password", token: token)
  end

  def reset_submit(conn, %{"token" => token, "password" => password})
      when is_binary(token) and is_binary(password) do
    case Barkpark.Accounts.reset_user_password(token, %{password: password}) do
      {:ok, _user} ->
        conn
        |> configure_session(renew: true)
        |> put_flash(:info, "Password updated — sign in with your new password.")
        |> redirect(to: "/login")

      {:error, %Ecto.Changeset{} = changeset} ->
        # Policy failure (too short, breached, …): the token survives — the
        # same link can be retried with a stronger password.
        conn
        |> put_flash(:error, password_error(changeset))
        |> no_store()
        |> render(:reset, page_title: "Set a new password", token: token)

      :error ->
        conn
        |> put_flash(:error, "That reset link is invalid or has expired — request a fresh one.")
        |> redirect(to: "/login/reset")
    end
  end

  def reset_submit(conn, _params), do: redirect(conn, to: "/login/reset")

  defp password_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
    |> case do
      %{password: [msg | _]} -> "Password " <> msg <> "."
      _ -> "That password can't be used — pick a different one."
    end
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

    # RECENCY predicate (class A — `at` is a server-written instant stamped by
    # `complete_sign_in/3` on an earlier request and transmitted back through the
    # SIGNED session cookie, so the wall clock is the CORRECT source and must
    # stay). What was wrong is the SIDEDNESS: with only an upper bound, an
    # anchor LATER than now — what a backward wall-clock step on this node
    # produces — kept the 5-minute pending window open indefinitely. The floor
    # (`at <= now`) rejects a nonsensical anchor. Deliberately NOT `abs/1`:
    # every two-sided gate in this repo guards a REMOTE-supplied signature
    # timestamp, where two-sidedness is mandatory; `at` is ours.
    now = System.system_time(:second)

    fresh? =
      is_integer(at) and at <= now and now - at <= 300

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
          |> render(:mfa, return_to: return_to, page_title: "Two-step verification")
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
        BarkparkWeb.SessionIssuer.actor_opts(conn) ++ opts
      )

    conn
    |> configure_session(renew: true)
    |> put_session("user_session", token)
    |> put_flash(:info, "Signed in.")
    |> redirect(to: return_to)
  end

  def delete(conn, _params) do
    # Revoke the account session server-side (not just the cookie) — parity
    # with DELETE /v1/auth/logout; the API-token session key needs no
    # revocation (dropping the cookie is the whole grant).
    revoked =
      case get_session(conn, "user_session") do
        token when is_binary(token) and token != "" ->
          {:ok, n} = Barkpark.Accounts.revoke_user_session_token(token)
          n

        _ ->
          0
      end

    conn
    |> configure_session(drop: true)
    |> put_flash(:info, sign_out_flash(revoked))
    |> redirect(to: "/studio")
  end

  # The receipt names what actually happened instead of asserting it. Both are
  # successes — the cookie is dropped either way, so a benign double sign-out is
  # never an error — but "a live session was revoked" and "there was nothing
  # left to revoke" no longer arrive at the user as the same sentence over a
  # count nobody read (PDS-D523).
  defp sign_out_flash(0), do: "You were already signed out."
  defp sign_out_flash(_revoked), do: "Signed out."

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
