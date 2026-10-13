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

  alias BarkparkWeb.Plugs.RequirePlatformOperator

  # POST /v1/auth/login-tickets → 201 {ticket, expires_in}. Reads the RAW bearer
  # straight off the header (RequireToken assigns only the verified struct, but
  # the session needs the raw value later). RequireToken guarantees a valid
  # Bearer reached here; the fallback clause is pure defense-in-depth.
  def create(conn, params) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> raw_token] ->
        mint(conn, raw_token, params)

      _ ->
        unauthorized(conn)
    end
  end

  # OWNER RULING 2026-10-03 #6 (task-6a1e6031438a3bcd): the EMAIL form signs
  # its consumer in as any account (no password, two-factor or SSO) and seats
  # it as Default owner, so it is an instance-level power and rides the
  # platform-operator tier like the other instance-global doors. Allowlist
  # UNSET (single-tenant) -> `permits?/1` is true and the admin bit in
  # `Auth.mint_login_ticket/2` alone decides, as before; ARMED -> an admin
  # bearer the allowlist does not name gets 403 `required: platform_operator`.
  # A non-admin bearer keeps the generic 401 from `mint_login_ticket/2`.
  defp mint(conn, raw_token, %{"email" => email} = params) when is_binary(email) do
    token = conn.assigns[:api_token]

    if String.trim(email) != "" and match?(%Barkpark.Auth.ApiToken{}, token) and
         Barkpark.Auth.has_permission?(token, "admin") and
         not RequirePlatformOperator.permits?(token) do
      operator_required(conn)
    else
      do_mint(conn, raw_token, params)
    end
  end

  defp mint(conn, raw_token, params), do: do_mint(conn, raw_token, params)

  # Optional `email` makes this a USER-shaped ticket (cloud-identity handoff):
  # consuming it JIT-provisions that account and mints a user_session.
  # Auth.mint_login_ticket gates it on the bearer holding `admin` — a lesser
  # token gets the same generic unauthorized.
  defp do_mint(conn, raw_token, params) do
    case Barkpark.Auth.mint_login_ticket(raw_token,
           user_email: params["email"],
           user_role: params["role"]
         ) do
      {:ok, ticket} ->
        conn
        |> put_status(:created)
        |> json(%{ticket: ticket, expires_in: Barkpark.Auth.login_ticket_ttl_seconds()})

      {:error, :unauthorized} ->
        unauthorized(conn)
    end
  end

  defp operator_required(conn) do
    env = Barkpark.Content.Errors.to_envelope({:error, :forbidden}, conn)
    body = env |> Map.delete(:status) |> Map.put(:required, "platform_operator")

    conn
    |> put_status(env.status)
    |> json(%{error: body})
  end

  defp unauthorized(conn) do
    BarkparkWeb.ErrorResponse.emit(conn, {:error, :unauthorized})
  end
end
