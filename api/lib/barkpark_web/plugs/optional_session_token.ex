defmodule BarkparkWeb.Plugs.OptionalSessionToken do
  @moduledoc """
  Soft-auth plug for browser-facing scoped routes. Assigns `:api_token`
  when a valid token is present in EITHER:

    * `Authorization: Bearer …` — API clients and Web Components that
      receive `data-token` from LiveView, or
    * `session["api_token"]` — a browser user who signed in at
      `GET /login` (see `BarkparkWeb.SessionController`).

  PRECEDENCE, stated for all six cases — "the Bearer header wins when both are
  present" was the previous wording and it is true of a VALID bearer ONLY.
  Resolution is `token_from_bearer/1 || token_from_session/1 ||
  token_from_dev_config/0`, and each arm yields `nil` unless its credential
  actually VERIFIES. So a presented-but-unverifiable bearer does not win the
  conn — it falls through to the cookie:

      bearer   | session cookie | resolved principal
      ---------|----------------|--------------------------------
      valid    | valid          | the BEARER's token
      valid    | absent         | the BEARER's token
      INVALID  | valid          | the SESSION's token (bearer does NOT win)
      INVALID  | absent         | anonymous — no `:api_token` assign
      absent   | valid          | the SESSION's token
      absent   | absent         | anonymous — no `:api_token` assign

  A malformed `Authorization` header that does not match `"Bearer " <> raw`
  (wrong scheme, wrong case, repeated header) is indistinguishable from an
  absent one here and falls through identically. Pinned case-by-case in
  `test/barkpark_web/plugs/optional_session_token_precedence_test.exs`.

  Never halts — like
  `BarkparkWeb.Plugs.OptionalToken`, it passes an anonymous conn through
  untouched and lets the downstream membership gate
  (`BarkparkWeb.Plugs.ResolveWorkspace`) reject closed.

  This is the cookie-aware sibling of `OptionalToken`. It exists for the
  `:scoped_browser` pipeline: a logged-in browser user carries only the
  session cookie (no Bearer header), so plain `OptionalToken` left
  `conn.assigns[:api_token]` nil and `ResolveWorkspace.authorize/3`
  403'd a real member before the LiveView could mount. Reading the
  session token here lets that member resolve their token → membership
  gate passes → the scoped plugin LV mounts.

  Requires `:fetch_session` upstream (the `:scoped_browser` pipeline runs
  `:fetch_session` before this plug).

  ## Dev fallback (Scoped-by-URL follow-through)

  In dev, the flat Studio works without `/login` because
  `LiveAuth.:fetch_api_token` falls back to the seeded
  `:dev_browser_token` — but that hook runs at LiveView mount, AFTER the
  conn pipeline. On the scoped surface `ResolveWorkspace` authorizes at
  the DEAD render, so an un-logged-in dev browser 403'd every `/w/...`
  URL the moment the scoped Studio shipped. The same fallback therefore
  lives here too: an anonymous conn picks up the dev token when (and
  only when) `:dev_browser_token` is configured — set exclusively in
  `config/dev.exs`, so test stays fail-closed (the anonymous-403
  contract tests depend on it) and prod never carries it.
  """

  import Plug.Conn
  alias Barkpark.Auth

  def init(opts), do: opts

  def call(conn, _opts) do
    conn =
      case token_from_bearer(conn) || token_from_session(conn) || token_from_dev_config() do
        {:ok, token} -> assign(conn, :api_token, token)
        _ -> conn
      end

    # studio-user-login: an account session (`user_session`, minted by the
    # /login/account flow or an SSO callback) resolves to :current_user — the
    # User principal the downstream gates (ResolveWorkspace, LiveScope) accept
    # via Tenancy.Auth.authorize/3. Soft like the token arm: invalid/absent
    # passes through anonymous. A token, when present, keeps precedence.
    case user_from_session(conn) do
      %Barkpark.Accounts.User{} = user -> assign(conn, :current_user, user)
      _ -> conn
    end
  end

  defp user_from_session(conn) do
    case get_session(conn, "user_session") do
      raw when is_binary(raw) and raw != "" ->
        case Barkpark.Accounts.verify_user_session(String.trim(raw)) do
          {%Barkpark.Accounts.User{} = user, _session} -> user
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp token_from_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw] -> verify(raw)
      _ -> nil
    end
  end

  defp token_from_session(conn) do
    case get_session(conn, "api_token") do
      raw when is_binary(raw) and raw != "" -> verify(raw)
      _ -> nil
    end
  end

  defp verify(raw) do
    case Auth.verify_token(String.trim(raw)) do
      {:ok, token} -> {:ok, token}
      _ -> nil
    end
  end

  defp token_from_dev_config do
    case Application.get_env(:barkpark, :dev_browser_token) do
      raw when is_binary(raw) and raw != "" -> verify(raw)
      _ -> nil
    end
  end
end
