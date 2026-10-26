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

  alias Barkpark.Auth.CloudSeat
  alias BarkparkWeb.Plugs.RequirePlatformOperator
  alias BarkparkWeb.SessionIssuer

  # BARKPARK_CLOUD_HANDOFF=off: the Cloud handoff doors answer 404.
  plug(:require_cloud_handoff when action == :exchange)

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

    cond do
      String.trim(email) != "" and not CloudSeat.handoff_enabled?() ->
        BarkparkWeb.ErrorResponse.emit(conn, {:error, :not_found})

      String.trim(email) != "" and match?(%Barkpark.Auth.ApiToken{}, token) and
        Barkpark.Auth.has_permission?(token, "admin") and
          not RequirePlatformOperator.permits?(token) ->
        operator_required(conn)

      true ->
        do_mint(conn, raw_token, params)
    end
  end

  defp mint(conn, raw_token, params), do: do_mint(conn, raw_token, params)

  # Optional `email` makes this a USER-shaped ticket (cloud-identity handoff):
  # consuming it JIT-provisions that account and mints a user_session.
  # Auth.mint_login_ticket gates it on the bearer holding `admin` — a lesser
  # token gets the same generic unauthorized.
  #
  # `purpose: "exchange"` (+ `audience`, `code_challenge`) mints a ticket for the
  # server-to-server `exchange/2` below instead of the browser door. The answer
  # echoes `purpose`, so a control plane can tell a box that honoured it from an
  # older one that ignored the field and minted a browser ticket.
  defp do_mint(conn, raw_token, params) do
    case Barkpark.Auth.mint_login_ticket(raw_token,
           user_email: params["email"],
           user_role: params["role"],
           purpose: params["purpose"],
           audience: params["audience"],
           code_challenge: params["code_challenge"]
         ) do
      {:ok, ticket} ->
        purpose = if params["purpose"] == "exchange", do: "exchange", else: "browser"

        conn
        |> put_status(:created)
        |> json(%{
          ticket: ticket,
          expires_in: Barkpark.Auth.login_ticket_ttl_seconds(),
          purpose: purpose
        })

      {:error, :invalid_exchange} ->
        BarkparkWeb.ErrorResponse.emit_custom(
          conn,
          422,
          "invalid_exchange",
          "an exchange ticket needs email, audience (the Studio origin) and a PKCE S256 code_challenge"
        )

      {:error, :unauthorized} ->
        unauthorized(conn)
    end
  end

  @doc """
  `POST /v1/auth/login-tickets/exchange` — "Sign in with Barkpark Cloud" for an
  external Studio, the server-to-server half.

  Body `{ticket, audience, code_verifier}`. No bearer: the single-use 60 s
  ticket is the credential, and it only redeems for the Studio origin it was
  minted for (`audience`) and for the server that holds the PKCE verifier. The
  answer is the same login session `POST /v1/auth/login` mints — `201 {token,
  user: {id, email}}` — for the Barkpark Cloud account the control plane named.

  Seating is the browser handoff's, nothing more: the Default workspace only
  (`Barkpark.Auth.CloudSeat`). Any other workspace must already seat the user.

  Every failure (unknown, used, expired, browser-purpose, wrong audience, wrong
  verifier, missing field) is the same `401 invalid_ticket`.
  """
  def exchange(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with ticket when is_binary(ticket) <- params["ticket"],
         audience when is_binary(audience) <- params["audience"],
         verifier when is_binary(verifier) <- params["code_verifier"],
         {:ok, {email, role}} <- Barkpark.Auth.consume_exchange_ticket(ticket, audience, verifier) do
      user = Barkpark.Sso.find_or_create_user(email)
      CloudSeat.ensure_default_membership(user, role)

      if refused = SessionIssuer.policy_refusal(conn, user, "cloud") do
        refused
      else
        {:ok, token} =
          Barkpark.Accounts.create_user_session_token(user, SessionIssuer.actor_opts(conn))

        conn
        |> put_status(:created)
        |> json(%{token: token, user: %{id: user.id, email: user.email}})
      end
    else
      _ ->
        BarkparkWeb.ErrorResponse.emit_custom(
          conn,
          401,
          "invalid_ticket",
          "this sign-in ticket is invalid, already used or expired"
        )
    end
  end

  defp operator_required(conn) do
    env = Barkpark.Content.Errors.to_envelope({:error, :forbidden}, conn)
    body = env |> Map.delete(:status) |> Map.put(:required, "platform_operator")

    conn
    |> put_status(env.status)
    |> json(%{error: body})
  end

  defp require_cloud_handoff(conn, _opts) do
    if CloudSeat.handoff_enabled?(),
      do: conn,
      else: conn |> BarkparkWeb.ErrorResponse.emit({:error, :not_found}) |> halt()
  end

  defp unauthorized(conn) do
    BarkparkWeb.ErrorResponse.emit(conn, {:error, :unauthorized})
  end
end
