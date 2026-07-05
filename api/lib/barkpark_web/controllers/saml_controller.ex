defmodule BarkparkWeb.SamlController do
  @moduledoc """
  SAML 2.0 Service-Provider endpoints (era-w3-saml).

  - `GET /v1/auth/saml/:org_slug/start` — SP-initiated: redirect to the org's IdP.
  - `POST /v1/auth/saml/:org_slug/acs` — Assertion Consumer Service: validate the
    signed SAML assertion, then find-or-create the User, JIT-provision, and mint
    a session.
  """
  use BarkparkWeb, :controller

  alias Barkpark.{Accounts, Sso}
  alias Barkpark.Sso.Saml

  def start(conn, %{"org_slug" => slug}) do
    case Saml.connection_for_org_slug(slug) do
      nil -> conn |> put_status(404) |> json(%{error: "no SAML connection for this organization"})
      c -> redirect(conn, external: Saml.authn_redirect_url(c, slug))
    end
  end

  def acs(conn, %{"org_slug" => slug, "SAMLResponse" => encoded}) do
    c = Saml.connection_for_org_slug(slug)

    with %Barkpark.Sso.SamlConnection{} <- c || :no_conn,
         {:ok, xml} <- Base.decode64(encoded),
         {:ok, email} <- Saml.consume(c, xml, slug) do
      user = Sso.find_or_create_user(email)
      Sso.jit_provision(c.organization_id, user)
      Sso.record_login(user, "saml", c.organization_id)

      {:ok, token} =
        Accounts.create_user_session_token(user,
          ip_address: client_ip(conn),
          user_agent: user_agent(conn)
        )

      conn
      |> configure_session(renew: true)
      |> put_session("user_session", token)
      |> put_status(:created)
      |> json(%{ok: true, token: token, user: %{id: user.id, email: user.email}})
    else
      :no_conn ->
        conn |> put_status(404) |> json(%{error: "no SAML connection for this organization"})

      :error ->
        conn |> put_status(400) |> json(%{error: "SAMLResponse is not valid base64"})

      {:error, reason} ->
        conn |> put_status(401) |> json(%{error: "saml_failed", detail: inspect(reason)})
    end
  end

  def acs(conn, %{"org_slug" => _}),
    do: conn |> put_status(400) |> json(%{error: "SAMLResponse is required"})

  defp client_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  defp user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      _ -> nil
    end
  end
end
