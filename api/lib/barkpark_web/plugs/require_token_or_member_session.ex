defmodule BarkparkWeb.Plugs.RequireTokenOrMemberSession do
  @moduledoc """
  The credential gate for the scoped editor streams — `GET /v1/data/listen`,
  `GET /v1/data/presence` and presence's `focus` / `leave` — on
  `/w/:ws/p/:proj` (task-cc6ad07a8aa36338): an API token, OR a login session
  presented as `Authorization: Bearer` by a member of the URL's workspace.

  #22764 made a login-session bearer a credential on the scoped data API
  (`OptionalSessionToken` resolves it), but these routes sat behind
  `:require_token`, which only knows API tokens, so a signed-in editor's
  presence and listen streams answered 401 while their reads and writes
  worked.

  No new resolver and no new membership check: the session was verified by
  `OptionalSessionToken` upstream (`:current_user`, `:current_user_via`) and
  admitted by `ResolveWorkspace`, which sets `:member_user` only when a
  token-less user is a member of this workspace (never on a grant, share or
  anonymous admit). This plug only reads those assigns.

  Bearer only: a session that arrived as the COOKIE (`:current_user_via ==
  :cookie`) does not pass, so the streams gain no ambient credential.

  Anything else — an API token included — takes the unchanged
  `:require_token` chain (`RequireToken`, `PublicRead`,
  `RequireWriteForMutation`), so every API-token answer, refusal and clamp is
  byte-identical.
  """

  alias BarkparkWeb.Plugs.{PublicRead, RequireToken, RequireWriteForMutation}

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: assigns} = conn, _opts) do
    if member_session?(assigns) do
      conn
    else
      [
        {RequireToken, RequireToken.init([])},
        {PublicRead, PublicRead.init([])},
        {RequireWriteForMutation, RequireWriteForMutation.init([])}
      ]
      |> Enum.reduce_while(conn, fn {plug, opts}, conn ->
        case plug.call(conn, opts) do
          %Plug.Conn{halted: true} = halted -> {:halt, halted}
          conn -> {:cont, conn}
        end
      end)
    end
  end

  defp member_session?(assigns) do
    is_nil(assigns[:api_token]) and assigns[:member_user] == true and
      match?(%Barkpark.Accounts.User{}, assigns[:current_user]) and
      assigns[:current_user_via] == :bearer
  end
end
