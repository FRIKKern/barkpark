defmodule BarkparkWeb.SessionIssuer do
  @moduledoc """
  The single place a user login turns into a session response. Mints a session
  token, sets the signed `user_session` cookie (browser) alongside the bearer in
  the body (API/JS), and 201s. Shared by password login (`AuthController`) and
  passkey login (`WebauthnController`) so both mint identically — including the
  `mfa_verified: true` freshness stamp when a strong factor was presented.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Barkpark.Accounts

  @doc """
  Issue a session for `user` and render the standard login response. `opts` are
  forwarded to `Accounts.create_user_session_token/2` (e.g. `mfa_verified: true`).
  """
  @spec issue(Plug.Conn.t(), Accounts.User.t(), keyword()) :: Plug.Conn.t()
  def issue(conn, user, opts \\ []) do
    {:ok, token} =
      Accounts.create_user_session_token(
        user,
        [ip_address: client_ip(conn), user_agent: user_agent(conn)] ++ opts
      )

    conn
    |> configure_session(renew: true)
    |> put_session("user_session", token)
    |> put_status(:created)
    |> json(%{token: token, user: %{id: user.id, email: user.email}})
  end

  defp client_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  defp user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      _ -> nil
    end
  end
end
