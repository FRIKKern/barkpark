defmodule BarkparkWeb.Plugs.ResolveTokenOwner do
  @moduledoc """
  NON-halting plug: resolve an OWNED api_token to its owner `%User{}` and assign
  `:current_user` — the seam that gives a `bp` api_token a user identity on the
  grantee surface (`POST /v1/access/claim`, `GET /v1/access/mine`).

  Runs AFTER `OptionalSessionToken` (which may already have assigned
  `:current_user` from a `user_session` cookie) and reads `conn.assigns[:api_token]`:

    * a token with a non-nil `owner_user_id` → load that user and
      `assign(:current_user, user)`;
    * NULL `owner_user_id`, no token, or a dangling FK → assign NOTHING.

  ## Precedence + fail-closed

  A direct login session ALWAYS wins: when `:current_user` is already assigned
  (OptionalSessionToken resolved a `user_session`), this plug is a no-op — a
  token's owner never overrides a live account session. When neither an owned
  token nor a session yields a user, `:current_user` stays nil and the
  downstream `RequirePrincipalUser` 401s. Every non-owned path fails closed.

  Wired ONLY on the claim/mine pipeline — NEVER on the grantor routes
  (`POST/GET/DELETE /v1/access`), whose api_token principal must stay a token,
  not silently gain a user identity.
  """
  import Plug.Conn

  alias Barkpark.Accounts
  alias Barkpark.Accounts.User
  alias Barkpark.Auth.ApiToken

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: %User{}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    case conn.assigns[:api_token] do
      %ApiToken{owner_user_id: owner_id} when is_binary(owner_id) ->
        case Accounts.get_user(owner_id) do
          %User{} = user -> assign(conn, :current_user, user)
          _ -> conn
        end

      _ ->
        conn
    end
  end
end
