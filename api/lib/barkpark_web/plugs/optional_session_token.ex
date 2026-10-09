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
      INVALID  | absent         | anonymous — no `:api_token` assign (or 401, strict — see below)
      absent   | valid          | the SESSION's token
      absent   | absent         | anonymous — no `:api_token` assign

  A malformed `Authorization` header that does not match `"Bearer " <> raw`
  (wrong scheme, wrong case, repeated header) is indistinguishable from an
  absent one here and falls through identically. Pinned case-by-case in
  `test/barkpark_web/plugs/optional_session_token_precedence_test.exs`.

  Default (`strict_on_presented: false`): never halts — like
  `BarkparkWeb.Plugs.OptionalToken`, it passes an anonymous conn through
  untouched and lets the downstream membership gate
  (`BarkparkWeb.Plugs.ResolveWorkspace`) reject closed.

  ## `strict_on_presented: true` (task-2366a212d58a1700)

  Mirrors `OptionalToken`'s own opt of the same name: a request that
  PRESENTS `Authorization: Bearer <x>` where `<x>` does not verify (revoked,
  expired, or never existed) halts with the same indistinguishable 401
  `RequireToken` emits — UNLESS the row above's own session fallback would
  have recovered it anyway (a valid session token, OR a valid
  `:current_user` account session). Only the ONE row that previously fell
  through to pure anonymous (`INVALID` bearer, nothing else resolves it
  either) changes shape; every other row in the table is untouched,
  including "INVALID bearer, valid session → the SESSION's token", which
  still wins exactly as before. Why: this plug serves routes a browser
  Studio session legitimately reaches with a stale cached bearer header
  alongside a live session cookie, and that caller must keep working.

  Exists because `ResolveWorkspace`'s membership gate cannot tell "no
  credential was presented" from "a credential was presented and it was
  garbage" once a bad bearer has already been silently dropped here — both
  read as anonymous and get the SAME 403 `not_a_member`, which misleads a
  caller holding a genuinely revoked token into thinking they lack
  permission rather than realizing their credential is dead.

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
  alias BarkparkWeb.Plugs.RequireToken

  # Ruling #16 rework half (task-57f23825b18ab55d): "`session["api_token"]`"
  # above is the LEGACY shape — a cookie minted before a revocable session row
  # existed. `token_from_session/1` now tries `session["api_token_session"]`
  # (the current shape) first, via `Barkpark.Auth.resolve_session_credential/2`.

  def init(opts), do: opts

  def call(conn, opts) do
    strict? = strict_on_presented?(opts)
    bearer_token = token_from_bearer(conn)

    conn =
      case bearer_token || token_from_session(conn) || token_from_dev_config() do
        {:ok, token} -> assign(conn, :api_token, token)
        _ -> conn
      end

    # studio-user-login: an account session (`user_session`, minted by the
    # /login/account flow or an SSO callback) resolves to :current_user — the
    # User principal the downstream gates (ResolveWorkspace, LiveScope) accept
    # via Tenancy.Auth.authorize/3. Soft like the token arm: invalid/absent
    # passes through anonymous. A token, when present, keeps precedence.
    conn =
      case user_from_session(conn) do
        %Barkpark.Accounts.User{} = user -> assign(conn, :current_user, user)
        _ -> conn
      end

    # task-2366a212d58a1700 — the ONE row of the precedence table this
    # changes: a bearer was PRESENTED (`bearer_presented?/1`), it did NOT
    # verify (`bearer_token` is nil, so it is not a plain absent header), and
    # NOTHING else recovered it either (no session token, no session user).
    # Every other row -- a valid session recovering an invalid bearer chief
    # among them -- is untouched: this check runs LAST, after both
    # assigns above already ran, so it only ever fires when they both failed.
    if strict? and is_nil(bearer_token) and bearer_presented?(conn) and
         not Map.has_key?(conn.assigns, :api_token) and
         not Map.has_key?(conn.assigns, :current_user) do
      RequireToken.deny(conn, {:error, :unauthorized})
    else
      conn
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

  # Same predicate `OptionalToken` strict-mode uses: did the REQUEST carry a
  # Bearer scheme at all, regardless of whether it verified. `token_from_bearer/1`
  # alone cannot answer this -- it returns nil for both "absent" and
  # "presented but invalid", which is exactly the ambiguity strict mode exists
  # to resolve.
  defp bearer_presented?(conn),
    do: match?(["Bearer " <> _], get_req_header(conn, "authorization"))

  defp strict_on_presented?(opts) when is_list(opts),
    do: Keyword.get(opts, :strict_on_presented, false)

  defp strict_on_presented?(%{} = opts), do: Map.get(opts, :strict_on_presented, false)
  defp strict_on_presented?(_), do: false

  defp token_from_session(conn) do
    case Auth.resolve_session_credential(
           get_session(conn, "api_token_session"),
           get_session(conn, "api_token")
         ) do
      {:ok, token, _raw} -> {:ok, token}
      :error -> nil
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
