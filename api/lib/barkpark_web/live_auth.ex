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

  def on_mount(:ops, _params, session, socket) do
    authorize(socket, session, ["ops", "admin"], "Operator access required")
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
         |> redirect(to: denial_target(socket, session))}
    end
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
