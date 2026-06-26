defmodule BarkparkCloud.Web.Auth do
  @moduledoc """
  Bearer-token authentication for the control-plane HTTP API (cloud-12a).

  Two principals share one `Authorization: Bearer <token>` header but resolve
  through different stores:

    * a USER session token (`Accounts.verify_user_session_token/1`) → the human
      behind "one login for all your Barkparks". Assigned as
      `conn.assigns.current_user` + `conn.assigns.current_team` (the user's
      primary team — a logged-in user acts within one team at a time).
    * an AGENT token (`Registry.verify_agent_token/1`) → an on-box agent
      reporting for one Barkpark. Assigned as `conn.assigns.current_barkpark`.

  The token namespaces do not overlap (random 32-byte tokens, separate hashed
  tables), so a token is at most one principal. Two pipeline plugs gate routes:

    * `require_user/2`  — 401 unless a valid USER session token resolved.
    * `require_agent/2` — 401 unless a valid AGENT token resolved.

  Each pipeline does its OWN lookup against only the store it cares about, so an
  agent token can never satisfy a user route (or vice-versa) even by accident.
  """
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Registry

  @doc """
  Require a valid USER session token. On success assigns `:current_user` and
  `:current_team`; otherwise halts the conn with a 401 JSON body.
  """
  def require_user(conn, _opts) do
    with token when is_binary(token) <- bearer_token(conn),
         %{} = user <- Accounts.verify_user_session_token(token) do
      conn
      |> assign(:current_user, user)
      |> assign(:current_team, Accounts.primary_team(user))
    else
      _ -> unauthorized(conn)
    end
  end

  @doc """
  Require a valid AGENT token. On success assigns `:current_barkpark`; otherwise
  halts the conn with a 401 JSON body.
  """
  def require_agent(conn, _opts) do
    with token when is_binary(token) <- bearer_token(conn),
         %{} = barkpark <- Registry.verify_agent_token(token) do
      assign(conn, :current_barkpark, barkpark)
    else
      _ -> unauthorized(conn)
    end
  end

  @doc """
  Extract the bearer token from the `Authorization` header, or `nil` when it is
  absent or not a `Bearer <token>` form. Public so the router can reuse it.
  """
  @spec bearer_token(Plug.Conn.t()) :: binary() | nil
  def bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> String.trim(token)
      ["bearer " <> token | _] -> String.trim(token)
      _ -> nil
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    |> halt()
  end
end
