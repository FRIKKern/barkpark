defmodule BarkparkWeb.SamlController do
  @moduledoc """
  SAML 2.0 Service-Provider endpoints (era-w3-saml + era-w7 SLO).

  - `GET /v1/auth/saml/:org_slug/start` — SP-initiated: redirect to the org's IdP.
  - `POST /v1/auth/saml/:org_slug/acs` — Assertion Consumer Service: validate the
    signed SAML assertion (SP-initiated AND IdP-initiated/unsolicited — same
    rigor), then find-or-create the User, JIT-provision, and mint a session
    carrying the SAML birth context (NameID + SessionIndex) for later SLO.
  - `POST /v1/auth/saml/:org_slug/slo` — IdP-initiated Single Logout: validate
    the IdP's signed LogoutRequest, revoke the sessions it names, and
    front-channel a LogoutResponse back (POST binding).
  """
  use BarkparkWeb, :controller

  alias Barkpark.{Accounts, Audit, Sso}
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
         {:ok, %{email: email} = subject} <- Saml.consume(c, xml, slug) do
      user = Sso.find_or_create_user(email)
      Sso.jit_provision(c.organization_id, user)
      Sso.record_login(user, "saml", c.organization_id)

      {:ok, token} =
        Accounts.create_user_session_token(user,
          ip_address: client_ip(conn),
          user_agent: user_agent(conn),
          saml_name_id: subject.name_id,
          saml_session_index: subject.session_index,
          saml_org_slug: slug
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

  @doc """
  IdP-initiated Single Logout (POST binding). The LogoutRequest's XML-dsig is
  verified against the org's pinned IdP cert — an unsigned or foreign-signed
  request revokes nothing. On success the named sessions are revoked and the
  auto-submit LogoutResponse form is returned (the browser posts it back to the
  IdP, completing the front channel).
  """
  def slo(conn, %{"org_slug" => slug, "SAMLRequest" => encoded}) do
    c = Saml.connection_for_org_slug(slug)

    with %Barkpark.Sso.SamlConnection{} <- c || :no_conn,
         {:ok, xml} <- Base.decode64(encoded),
         {:ok, %{name_id: name_id, session_index: idx}} <-
           Saml.consume_logout_request(c, xml, slug) do
      revoked = Accounts.revoke_saml_sessions(slug, name_id, idx)

      Audit.emit(%{
        category: "auth",
        action: "saml_slo",
        subject: name_id,
        actor_type: "idp",
        metadata: %{
          "organization_id" => c.organization_id,
          "revoked" => revoked,
          "session_index" => idx
        }
      })

      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, Saml.logout_response_html(c, slug))
    else
      :no_conn ->
        conn |> put_status(404) |> json(%{error: "no SAML connection for this organization"})

      :error ->
        conn |> put_status(400) |> json(%{error: "SAMLRequest is not valid base64"})

      {:error, reason} ->
        conn |> put_status(401) |> json(%{error: "slo_failed", detail: inspect(reason)})
    end
  end

  def slo(conn, %{"org_slug" => _}),
    do: conn |> put_status(400) |> json(%{error: "SAMLRequest is required"})

  defp client_ip(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  defp user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      _ -> nil
    end
  end
end
