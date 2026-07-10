defmodule BarkparkWeb.LiveAuth do
  @moduledoc """
  `on_mount` hooks for LiveView auth.

  ## Hooks

    * `:admin` — requires the `"admin"` permission. Used by `/studio/settings`
      and any LiveView that exposes plugin-secret reveal/audit, schema CRUD,
      or other privileged surfaces.

    * `:ops` — requires the `"ops"` *or* `"admin"` permission (Phase 8 WI5).
      Used by the `/admin/bokbasen` operations console. Admin tokens
      retain ops capabilities; this is purely an *additive* role so a
      future operator persona can be granted publish-ops access without
      exposing the full admin surface (settings reveal, schema CRUD).

    * `:require_org_mfa` — org-require-MFA on the LiveView surface
      (era-w8-sso-mfa-binding), defence-in-depth behind the session-mint
      chokepoints: a `user_session` cookie resolving to a user who is
      governed by a `require_mfa` org and has NO factor enrolled is halted
      to `/login` with enrolment guidance. Covers cookie reuse — a session
      minted before the org flipped `require_mfa` on, or the deliberately
      flagged `POST /v1/auth/login` enrolment session (which the API
      surface gates via `RequireOrgMfaEnrolment`, but LiveViews never ran
      a plug). Anonymous and api_token-only sessions pass untouched — the
      other hooks own those gates — and an undecidable `user_session` is
      already treated as logged out by `user_from_session/1` (fail
      closed). Runs in the scoped + admin + plugin Studio live_sessions
      (router.ex).

  Both hooks read `session["api_token"]` (the raw bearer token), verify it
  via `Barkpark.Auth`, and halt with a redirect to `/studio` on failure.

  Tests inject the session token with `Plug.Test.init_test_session/2`.

  Browser sessions are bootstrapped at `GET /login` (see
  `BarkparkWeb.SessionController`), where a human pastes their raw API
  token. The controller stores it under `session["api_token"]` after
  verifying via `Barkpark.Auth.verify_token/1`. `POST /logout` clears
  the session.

  A failed `on_mount` redirects to `/studio` with an error flash. To
  recover, the user navigates to `/login` and pastes a valid token.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  alias Barkpark.Auth

  def on_mount(:admin, _params, session, socket) do
    authorize(socket, session, ["admin"], "Admin access required")
  end

  def on_mount(:ops, _params, session, socket) do
    authorize(socket, session, ["ops", "admin"], "Operator access required")
  end

  def on_mount(:require_org_mfa, _params, session, socket) do
    case user_from_session(session) do
      %Barkpark.Accounts.User{} = user ->
        if BarkparkWeb.SessionIssuer.org_mfa_enrolment_blocked?(user) do
          {:halt,
           socket
           |> put_flash(:error, BarkparkWeb.SessionIssuer.org_mfa_enrolment_message())
           |> redirect(to: "/login")}
        else
          {:cont, socket}
        end

      _ ->
        {:cont, socket}
    end
  end

  def on_mount(:fetch_api_token, _params, session, socket) do
    raw =
      case session["api_token"] do
        token when is_binary(token) and token != "" -> token
        _ -> dev_browser_token_fallback()
      end

    socket = assign(socket, :current_user, user_from_session(session))

    case raw do
      nil ->
        {:cont,
         socket
         |> assign(:api_token, nil)
         |> assign(:api_token_raw, "")}

      token ->
        case Auth.verify_token(token) do
          {:ok, api_token} ->
            {:cont,
             socket
             |> assign(:api_token, api_token)
             |> assign(:api_token_raw, token)}

          _ ->
            {:cont,
             socket
             |> assign(:api_token, nil)
             |> assign(:api_token_raw, "")}
        end
    end
  end

  # studio-user-login: resolve the account session (`user_session` cookie,
  # minted by /login/account or an SSO callback) to its User — the principal
  # LiveScope's membership gate accepts. nil when absent/invalid.
  defp user_from_session(session) do
    case session["user_session"] do
      raw when is_binary(raw) and raw != "" ->
        case Barkpark.Accounts.verify_user_session(String.trim(raw)) do
          {%Barkpark.Accounts.User{} = user, _} -> user
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # In dev, Studio gets the seeded token automatically — media upload and the
  # :admin/:ops gates all fall back to it — so the host never needs a separate
  # /login step. Production always requires POST /login.
  defp dev_browser_token_fallback do
    if Mix.env() == :dev do
      Application.get_env(:barkpark, :dev_browser_token)
    end
  end

  # Dev token first: the host running Barkpark locally always gets
  # admin+ops, even if the browser is carrying a stale/insufficient
  # `session["api_token"]` from earlier manual testing. In non-dev envs
  # `dev_browser_token_fallback/0` is nil, so this is a no-op there and
  # the real session token (or the user_session path) decides.
  defp authorize(socket, session, allowed_perms, denial_flash) do
    candidates = Enum.filter([dev_browser_token_fallback(), session["api_token"]], &is_binary/1)

    granted =
      Enum.find_value(candidates, fn token ->
        with {:ok, api_token} <- Auth.verify_token(token),
             true <- Enum.any?(allowed_perms, &Auth.has_permission?(api_token, &1)) do
          api_token
        else
          _ -> nil
        end
      end)

    case granted do
      nil -> authorize_user(socket, session, denial_flash)
      api_token -> {:cont, assign(socket, :api_token, api_token)}
    end
  end

  # studio-user-login: the account-session arm of the admin/ops gates. Users
  # carry no permissions[] — the grant is the membership ROLE, and the flat
  # admin surfaces (/studio/settings, /studio/org-admin, /admin/*) operate in
  # the DEFAULT-workspace context (the tenancy contract's flat posture), so
  # the bar is an owner/admin-grade role THERE, checked through the same
  # Tenancy.Auth.authorize/3 chokepoint (:admin action). An org-scoped
  # self-serve admin surface is the separate follow-up.
  defp authorize_user(socket, session, denial_flash) do
    with %Barkpark.Accounts.User{} = user <- user_from_session(session),
         %{id: ws_id} <- Barkpark.Tenancy.get_default_workspace(),
         :ok <- Barkpark.Tenancy.Auth.authorize(user, ws_id, :admin) do
      {:cont, assign(socket, :current_user, user)}
    else
      _ ->
        {:halt,
         socket
         |> put_flash(:error, denial_flash)
         |> redirect(to: "/studio")}
    end
  end
end
