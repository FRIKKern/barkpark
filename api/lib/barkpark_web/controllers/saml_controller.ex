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
  alias BarkparkWeb.ErrorResponse
  alias BarkparkWeb.SessionIssuer

  def start(conn, %{"org_slug" => slug}) do
    case Saml.connection_for_org_slug(slug) do
      nil ->
        ErrorResponse.emit_custom(
          conn,
          404,
          "not_found",
          "no SAML connection for this organization"
        )

      c ->
        redirect(conn, external: Saml.authn_redirect_url(c, slug))
    end
  end

  # `when is_binary(encoded)` belongs on the ACTION HEAD, not on the callee:
  # the :sso_browser pipeline carries no auth plug, so an unauthenticated
  # caller posting `SAMLResponse[]=abc` used to raise FunctionClauseError
  # inside Base.decode64/2 — below the action frame, where Phoenix's
  # ActionClauseError→400 conversion no longer applies (500). Guarded here, a
  # wrong-typed body falls through to the fallback clause below for a clean 400.
  def acs(conn, %{"org_slug" => slug, "SAMLResponse" => encoded}) when is_binary(encoded) do
    c = Saml.connection_for_org_slug(slug)

    with %Barkpark.Sso.SamlConnection{} <- c || :no_conn,
         {:ok, xml} <- Base.decode64(encoded),
         {:ok, %{email: email} = subject} <- Saml.consume(c, xml, slug) do
      user = Sso.find_or_create_user(email)
      Sso.jit_provision(c.organization_id, user)

      # era-w8-sso-mfa-binding: org-require-MFA binds at session-mint time —
      # a governed factor-less user is refused HERE (audited), never landed
      # in Studio. The password door already blocks this user; without this
      # check the IdP redirect was a clean bypass. Checked AFTER JIT so a
      # first-ever login into a require_mfa org is governed too.
      if SessionIssuer.org_mfa_enrolment_blocked?(user) do
        SessionIssuer.deny_org_mfa_enrolment(conn, user, "saml", c.organization_id)
      else
        Sso.record_login(user, "saml", c.organization_id)

        {:ok, token} =
          Accounts.create_user_session_token(
            user,
            SessionIssuer.actor_opts(conn) ++
              [
                saml_name_id: subject.name_id,
                saml_session_index: subject.session_index,
                saml_org_slug: slug
              ]
          )

        conn = conn |> configure_session(renew: true) |> put_session("user_session", token)

        # studio-user-login: a BROWSER posting the IdP's auto-submit form
        # (Accept: text/html) lands IN Studio — the cookie above is its
        # credential. Non-HTML callers (interop suite, SDKs) keep the JSON
        # contract byte-identical.
        if browser?(conn) do
          conn |> Phoenix.Controller.redirect(to: "/studio")
        else
          conn
          |> put_status(:created)
          |> json(%{ok: true, token: token, user: %{id: user.id, email: user.email}})
        end
      end
    else
      # Every failed callback lands on the audit trail (era-w8) — a forged or
      # expired assertion used to leave no trace; only successes audited.
      :no_conn ->
        Sso.record_login_failure("saml", slug, :no_connection)

        ErrorResponse.emit_custom(
          conn,
          404,
          "not_found",
          "no SAML connection for this organization"
        )

      :error ->
        Sso.record_login_failure("saml", slug, :invalid_base64)
        ErrorResponse.emit_custom(conn, 400, "malformed", "SAMLResponse is not valid base64")

      {:error, reason} ->
        Sso.record_login_failure("saml", slug, reason)

        ErrorResponse.emit_custom(conn, 401, "unauthorized", "SAML assertion rejected", %{
          reason: inspect(reason)
        })
    end
  end

  def acs(conn, %{"org_slug" => _}), do: refuse_missing(conn, "SAMLResponse is required")

  @doc """
  IdP-initiated Single Logout (POST binding). The LogoutRequest's XML-dsig is
  verified against the org's pinned IdP cert — an unsigned or foreign-signed
  request revokes nothing. On success the named sessions are revoked and the
  auto-submit LogoutResponse form is returned (the browser posts it back to the
  IdP, completing the front channel).
  """
  # @sobelow_skip — XSS.SendResp (send_resp/3) is a false-positive: the body is
  # `Saml.logout_response_html/2`, an auto-submit SAML POST form emitted by the
  # esaml library (`:esaml_binding.encode_http_post/3`) from the server-signed
  # LogoutResponse and the IdP URL stored on the DB SamlConnection. No request
  # parameter is interpolated into the HTML — `slug` only builds server-side
  # entity/ACS URIs inside `sp_for/2`, never the response body.
  # sobelow_skip ["XSS.SendResp"]
  # `when is_binary(encoded)` on the ACTION HEAD — same reason as acs/2 above:
  # a list-valued `SAMLRequest` raised inside Base.decode64/2, below the action
  # frame, so it surfaced as a 500 instead of a 400.
  def slo(conn, %{"org_slug" => slug, "SAMLRequest" => encoded}) when is_binary(encoded) do
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

      # The :sso_browser pipeline bypasses root.html.heex, so the SLO form's
      # CSP + nonce are plumbed by hand here: a per-request nonce lets esaml's
      # auto-submit <script> run under a strict script-src while any injected
      # inline script is blocked (task-0fc9d55c).
      nonce = BarkparkWeb.CSP.nonce()

      conn
      |> put_resp_content_type("text/html")
      |> put_resp_header("content-security-policy", BarkparkWeb.CSP.sso_policy(nonce))
      |> send_resp(200, Saml.logout_response_html(c, slug, nonce))
    else
      :no_conn ->
        ErrorResponse.emit_custom(
          conn,
          404,
          "not_found",
          "no SAML connection for this organization"
        )

      :error ->
        ErrorResponse.emit_custom(conn, 400, "malformed", "SAMLRequest is not valid base64")

      {:error, reason} ->
        ErrorResponse.emit_custom(conn, 401, "unauthorized", "SAML LogoutRequest rejected", %{
          reason: inspect(reason)
        })
    end
  end

  def slo(conn, %{"org_slug" => _}), do: refuse_missing(conn, "SAMLRequest is required")

  # Deliberately NOT `ErrorResponse.emit_custom/5` inline in the clause above.
  # The FIRST `slo/2` clause carries an `XSS.SendResp` waiver (the esaml
  # LogoutResponse form it send_resp's), and
  # api/scripts/sobelow-inline-overlap-check.sh rule 4a reds when a sibling
  # clause of an annotated def group calls the same module the annotated clause
  # calls without carrying its own annotation — Sobelow binds a waiver to ONE
  # def. Stamping this clause with an `XSS.SendResp` waiver would be a lie: it
  # cannot produce that finding, it never calls send_resp. Routing through a
  # single-clause private helper keeps the waiver honest and the gate green.
  defp refuse_missing(conn, message),
    do: ErrorResponse.emit_custom(conn, 400, "malformed", message)

  # A browser's form POST / redirect chain advertises text/html; API clients
  # (interop suite, SDKs) don't. Drives the redirect-vs-JSON fork above.
  defp browser?(conn) do
    conn
    |> Plug.Conn.get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/html"))
  end
end
