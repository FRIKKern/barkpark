defmodule BarkparkWeb.LiveAuth do
  @moduledoc """
  `on_mount` hooks for LiveView auth.

  ## Hooks

    * `:admin` — requires the `"admin"` permission. Used by `/studio/settings`
      and any LiveView that exposes plugin-secret reveal/audit, schema CRUD,
      or other privileged surfaces.

    * `:scoped_admin` — the TARGET-workspace admin gate for the scoped admin
      live_sessions (`/w/:workspace_slug/...` — connectors W26, D219-D222).
      `:admin` above answers a GLOBAL question (token permissions[] / the
      Default-workspace role), which is the wrong question on a scoped URL:
      a flat-global-admin principal that is only a MEMBER of workspace B
      could mount B's scoped admin LiveViews (the W24-proven escalation).
      This hook resolves the workspace FROM THE URL PARAMS — the same
      workspace the page writes to — and requires an owner/admin membership
      role THERE (`Tenancy.Auth.workspace_admin?/2`), for token and user
      principals alike. Fail-closed on a missing/unknown slug or a
      non-admin role. The dev browser token stays instance-root (nil
      outside `:dev`), so the local self-hosted host is unaffected.

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
  alias BarkparkWeb.Studio.ReturnTo

  # A chat-session deep link (`/studio/chat/:id`) — the shape the notifier emails
  # point at (charter D69). ONLY these earn a `return_to` round-trip; the bare
  # `/studio/chat` new-chat landing (no resource to return to) and every other
  # admin surface keep the `/studio` funnel, so the gate suite stays byte-stable.
  @chat_deep_link ~r{^/studio/chat/[^/?#]+$}

  def on_mount(:admin, _params, session, socket) do
    authorize(socket, session, ["admin"], "Admin access required")
  end

  # W26 (charter D219-D222) — authorize against the workspace IN THE URL, not a
  # flat/Default-pinned one. The membership ROLE in the target workspace is the
  # grant for BOTH principal arms (`workspace_admin?/2`, role-only — NOT
  # `authorize/3(:admin)`, whose token arm folds global permissions back in and
  # would reopen the hole). Fronts the `:scoped_plugin_admin` and
  # `:scoped_admin_studio` live_sessions (router.ex); the flat sessions and the
  # global-registry `:scoped_admin_studio_dataset` stay on `:admin`.
  def on_mount(:scoped_admin, params, session, socket) do
    case scoped_target_workspace(params) do
      %{id: _} = ws -> scoped_admin_authorize(socket, session, ws)
      nil -> scoped_admin_deny(socket)
    end
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
  #
  # THE CONFIG KEY IS THE SWITCH, NOT `Mix.env()`. `:dev_browser_token` is set
  # in exactly one place, `config/dev.exs` — never in config.exs, prod.exs,
  # test.exs or runtime.exs. So test stays fail-closed (the anonymous-403
  # contract tests depend on that) and a release never carries the key at all,
  # because dev.exs is not loaded into one. This is the idiom the sibling
  # conn-pipeline arm has always used:
  # `BarkparkWeb.Plugs.OptionalSessionToken.token_from_dev_config/0` reads the
  # key bare, with no env guard, and its moduledoc states the same reasoning.
  #
  # gh-8461 — DO NOT REINTRODUCE A RUNTIME `Mix.` CALL HERE. The previous
  # `if Mix.env() == :dev` raised, in an OTP release:
  #
  #     ** (UndefinedFunctionError) function Mix.env/0 is undefined
  #        (module Mix is not available)
  #
  # Mix is a build-time tool; `mix release` does not ship it (see
  # `cloud/lib/barkpark_cloud/release.ex`, whose moduledoc says so outright).
  # `authorize/4` and `scoped_admin_candidates/1` call this UNCONDITIONALLY, so
  # every `:admin`/`:ops`/`:scoped_admin` Studio mount 500'd in the Docker image
  # while both `mix phx.server` paths — local dev AND the Hetzner systemd prod
  # box, which runs `mix phx.server`, not a release — never saw it. That split
  # is why it survived nine months. `BarkparkWeb.ReleaseSafetyTripwireTest`
  # now fails on any runtime `Mix.*` call from a release-reachable module.
  defp dev_browser_token_fallback do
    case Application.get_env(:barkpark, :dev_browser_token) do
      raw when is_binary(raw) and raw != "" -> raw
      _ -> nil
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
         |> redirect(to: denial_target(socket, session))}
    end
  end

  # ── :scoped_admin (W26) ────────────────────────────────────────────────────

  # The SAME resolver LiveScope calls (live_scope.ex) — one slug→workspace
  # truth, never a second resolver. nil (unknown slug / missing param) is a
  # deny: an unresolvable target workspace can never be authorized against.
  defp scoped_target_workspace(%{"workspace_slug" => slug}) when is_binary(slug) and slug != "",
    do: Barkpark.Tenancy.get_workspace_by_slug(slug)

  defp scoped_target_workspace(_params), do: nil

  # Token arm first (mirrors `authorize/4`): the first candidate that verifies
  # AND holds the grant wins and rides the socket as `:api_token` (LiveScope's
  # read gate + the LVs' per-write re-gates read it). No token grant → the
  # user-session arm decides. The dev fallback is the local host's
  # instance-root credential — exempt from the membership check by design
  # ([[local-dev-host-is-admin]]); `dev_browser_token_fallback/0` is nil
  # outside :dev, so the exemption is inert in test/prod.
  defp scoped_admin_authorize(socket, session, ws) do
    granted =
      Enum.find_value(scoped_admin_candidates(session), fn {kind, raw} ->
        with {:ok, api_token} <- Auth.verify_token(raw),
             true <- scoped_admin_grant?(kind, api_token, ws) do
          api_token
        else
          _ -> nil
        end
      end)

    case granted do
      nil -> scoped_admin_authorize_user(socket, session, ws)
      api_token -> {:cont, assign(socket, :api_token, api_token)}
    end
  end

  defp scoped_admin_candidates(session) do
    Enum.filter(
      [dev_root: dev_browser_token_fallback(), session: session["api_token"]],
      fn {_kind, raw} -> is_binary(raw) end
    )
  end

  defp scoped_admin_grant?(:dev_root, api_token, _ws),
    do: Auth.has_permission?(api_token, "admin")

  # A session token's grant is its membership ROLE in the target workspace —
  # never its global permissions[]. A flat-global-admin token that is only a
  # member (or non-member) of the URL workspace is denied here.
  defp scoped_admin_grant?(:session, api_token, ws),
    do: Barkpark.Tenancy.Auth.workspace_admin?(api_token, ws.id)

  # User-session arm: same role-only bar, against the TARGET workspace — a
  # Default-workspace admin who is only a member of the URL workspace is
  # denied, and a legit target-workspace admin needs NO Default role at all
  # (the D207 over-tight lockout this clause also fixes).
  defp scoped_admin_authorize_user(socket, session, ws) do
    with %Barkpark.Accounts.User{} = user <- user_from_session(session),
         true <- Barkpark.Tenancy.Auth.workspace_admin?(user, ws.id) do
      {:cont, assign(socket, :current_user, user)}
    else
      _ -> scoped_admin_deny(socket)
    end
  end

  defp scoped_admin_deny(socket) do
    {:halt,
     socket
     |> put_flash(:error, "Admin access required")
     |> redirect(to: "/studio")}
  end

  # D69 — the email-notification promise. An ANONYMOUS visitor bounced off a chat
  # deep link (`/studio/chat/:id`, the notifier's link) is sent to `/login` with
  # a validated `return_to`, so signing in lands them back on that exact session.
  # Everyone else keeps the `/studio` funnel: an authenticated-but-insufficient
  # token would only loop through login (it already has a session), and a bare
  # section landing has no resource to return to. Falls back to `/studio` when
  # the request path is unavailable (a connected patch has no request URI).
  defp denial_target(socket, session) do
    with true <- anonymous?(session),
         %URI{path: path} = uri when is_binary(path) <- requested_uri(socket),
         true <- Regex.match?(@chat_deep_link, path),
         dest when is_binary(dest) <- ReturnTo.sanitize_dest(path <> query_suffix(uri.query)) do
      ReturnTo.with_return_to("/login", dest)
    else
      _ -> "/studio"
    end
  end

  defp anonymous?(session) do
    blank?(session["api_token"]) and blank?(session["user_session"])
  end

  defp blank?(value), do: not (is_binary(value) and value != "")

  # The path the browser asked for — exposed by `get_connect_info/2` ONLY on the
  # dead (HTTP) render, which is exactly the cold email-click that must round-trip.
  # A connected socket's connect_info is the endpoint's session-only map (no
  # `:uri`), so this returns nil there and the caller funnels to `/studio`.
  defp requested_uri(socket) do
    get_connect_info(socket, :uri)
  rescue
    _ -> nil
  end

  defp query_suffix(query) when is_binary(query) and query != "", do: "?" <> query
  defp query_suffix(_query), do: ""
end
