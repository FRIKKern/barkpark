defmodule BarkparkWeb.Plugs.OptionalToken do
  @moduledoc """
  Soft-auth plug. Assigns `:api_token` when a valid `Authorization: Bearer …`
  header is present; otherwise passes the conn through untouched.

  Never halts on a missing or invalid credential. ONE exception (wave-2 seal,
  foreign-scope-share-token-flat-read): a scope-bound SHARE token
  (`share_scope` set) presented on a FLAT route is refused 403 — soft-passing
  it through as authed is exactly the escape that let a foreign-scoped
  share-edit token read Default-scoped drafts on `GET /v1/data/doc/...`
  (authed? true → the anonymous drafts clamp was skipped, while the flat
  route's scope came from `AssignDefaultScope`, not the token's binding).
  Predicate + rationale live in
  `BarkparkWeb.Plugs.RequireToken.share_token_off_surface?/2` — the share
  token keeps working on its own scoped share routes.

  For endpoints that must reject anonymous callers, use
  `BarkparkWeb.Plugs.RequireToken` instead.
  """

  import Plug.Conn
  alias Barkpark.Auth
  alias BarkparkWeb.Plugs.RequireToken

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw_token] ->
        case Auth.verify_token(raw_token) do
          {:ok, token} ->
            if RequireToken.share_token_off_surface?(conn, token) do
              RequireToken.deny(conn, {:error, :forbidden})
            else
              assign(conn, :api_token, token)
            end

          _ ->
            conn
        end

      _ ->
        conn
    end
  end
end
