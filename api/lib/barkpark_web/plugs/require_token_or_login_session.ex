defmodule BarkparkWeb.Plugs.RequireTokenOrLoginSession do
  @moduledoc """
  The credential door for `GET /v1/auth/token` (task-a89ef18ee88ba6a0): an API
  token OR a login session, presented as `Authorization: Bearer`.

  `/v1/auth/login` answers `token` = a user-session token. #22764 made that
  token a bearer on the scoped data API, but `/v1/auth/token` sat behind
  `:require_token` (API tokens only) and answered it 401 — so a client that
  reads its permissions there treated a live session as dead.

  A bearer that verifies as a login session assigns `:current_user` and
  `:current_user_session` and passes. Anything else takes the unchanged
  `:require_token` path — `RequireToken` then `PublicRead` — so every API-token
  answer, refusal and clamp is byte-identical. Bearer only: the session COOKIE
  is not read here (the `:api` pipeline fetches no session), so this route
  gains no ambient credential.
  """

  import Plug.Conn

  alias Barkpark.Accounts
  alias BarkparkWeb.Plugs.{PublicRead, RequireToken}

  def init(opts), do: opts

  def call(conn, _opts) do
    case login_session(conn) do
      {user, session} ->
        conn
        |> assign(:current_user, user)
        |> assign(:current_user_session, session)

      nil ->
        conn
        |> RequireToken.call(RequireToken.init([]))
        |> then(fn
          %Plug.Conn{halted: true} = halted -> halted
          conn -> PublicRead.call(conn, PublicRead.init([]))
        end)
    end
  end

  defp login_session(conn) do
    with ["Bearer " <> raw] <- get_req_header(conn, "authorization"),
         {%Accounts.User{} = user, session} <- Accounts.verify_user_session(String.trim(raw)) do
      {user, session}
    else
      _ -> nil
    end
  end
end
