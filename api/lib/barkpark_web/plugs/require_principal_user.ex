defmodule BarkparkWeb.Plugs.RequirePrincipalUser do
  @moduledoc """
  Terminal gate for the grantee surface: 401 unless a `%User{}` principal was
  resolved upstream into `:current_user` — by EITHER path:

    * a direct login session (`OptionalSessionToken` reading a `user_session`
      cookie or a login-session bearer), OR
    * an OWNED api_token (`ResolveTokenOwner` loading the token's owner user).

  This is the soft-pipeline's fail-closed floor: an anonymous caller, a
  bad/absent token, or an UN-OWNED api_token (NULL `owner_user_id`) all leave
  `:current_user` nil and are rejected here with the same 401. It replaces
  `RequireUserSession` on the claim/mine routes ONLY — those routes now accept
  an owned token as a user identity, where a plain login gate could not.
  """
  import Plug.Conn

  alias Barkpark.Accounts.User

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_user: %User{}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn
    |> put_status(401)
    |> Phoenix.Controller.json(%{
      error: %{code: "unauthorized", message: "a user identity is required (a login session or an owned token)"}
    })
    |> halt()
  end
end
