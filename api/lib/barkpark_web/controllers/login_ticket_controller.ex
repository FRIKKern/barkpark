defmodule BarkparkWeb.LoginTicketController do
  @moduledoc """
  Mints single-use, 60s login handoff tickets (dwb-7 "Studio one-click entry").

  `POST /v1/auth/login-tickets` — bearer-authed (the `:require_token` pipeline
  already verified the token and assigned `:api_token`). The caller proves
  possession of an api_token (typically the control plane using the stored
  per-instance admin token); we mint a ticket BOUND to that exact raw bearer.

  The control plane then hands the browser `<fqdn>/login/ticket/<ticket>` — one
  click sets the session, no token paste. The consume half lives in
  `BarkparkWeb.SessionController.ticket/2`.

  The api_token itself NEVER appears in the response or a URL — only the opaque
  ticket does.
  """
  use BarkparkWeb, :controller

  # POST /v1/auth/login-tickets → 201 {ticket, expires_in}. Reads the RAW bearer
  # straight off the header (RequireToken assigns only the verified struct, but
  # the session needs the raw value later). RequireToken guarantees a valid
  # Bearer reached here; the fallback clause is pure defense-in-depth.
  def create(conn, _params) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw_token] ->
        case Barkpark.Auth.mint_login_ticket(raw_token) do
          {:ok, ticket} ->
            conn
            |> put_status(:created)
            |> json(%{ticket: ticket, expires_in: Barkpark.Auth.login_ticket_ttl_seconds()})

          {:error, :unauthorized} ->
            unauthorized(conn)
        end

      _ ->
        unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    env = Barkpark.Content.Errors.to_envelope({:error, :unauthorized}, conn)

    conn
    |> put_status(env.status)
    |> json(%{error: Map.delete(env, :status)})
  end
end
