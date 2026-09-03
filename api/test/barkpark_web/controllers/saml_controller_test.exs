defmodule BarkparkWeb.SamlControllerTest do
  @moduledoc "SAML SP HTTP surface — start redirect + ACS session mint + JIT."
  use BarkparkWeb.ConnCase, async: true

  # TOTP codes come from the window-stable helper ONLY — a code minted inline
  # can expire in the gap before the server validates it (honest-gates S1).
  import Barkpark.TotpTestHelper

  alias Barkpark.{Accounts, Repo, Sso.Saml, Tenancy}
  alias Barkpark.Tenancy.Membership
  import Ecto.Query

  @slug "samlctrl"

  defp idp do
    key = X509.PrivateKey.new_rsa(2048)
    cert = X509.Certificate.self_signed(key, "/CN=Test IdP")
    %{key: key, cert_pem: X509.Certificate.to_pem(cert), cert_der: X509.Certificate.to_der(cert)}
  end

  defp signed_response(email, key, cert_der, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    death = now |> DateTime.add(300) |> DateTime.to_iso8601()
    nbf = now |> DateTime.add(-60) |> DateTime.to_iso8601()

    authn =
      case Keyword.get(opts, :session_index) do
        nil ->
          ""

        idx ->
          ~s(<saml:AuthnStatement AuthnInstant="#{DateTime.to_iso8601(now)}" SessionIndex="#{idx}"/>)
      end

    xml = """
    <saml:Assertion xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" Version="2.0" ID="_a1" IssueInstant="#{DateTime.to_iso8601(now)}">
      <saml:Issuer>https://idp.example.com/entity</saml:Issuer>
      <saml:Subject>
        <saml:NameID>#{email}</saml:NameID>
        <saml:SubjectConfirmation Method="urn:oasis:names:tc:SAML:2.0:cm:bearer">
          <saml:SubjectConfirmationData Recipient="#{Saml.acs_uri(@slug)}" NotOnOrAfter="#{death}"/>
        </saml:SubjectConfirmation>
      </saml:Subject>
      <saml:Conditions NotBefore="#{nbf}" NotOnOrAfter="#{death}">
        <saml:AudienceRestriction><saml:Audience>#{Saml.entity_id(@slug)}</saml:Audience></saml:AudienceRestriction>
      </saml:Conditions>
      #{authn}
    </saml:Assertion>
    """

    {elem, _} = :xmerl_scan.string(to_charlist(xml), namespace_conformant: true)
    signed = :xmerl_dsig.sign(elem, key, cert_der)

    assertion =
      :xmerl.export([signed], :xmerl_xml)
      |> to_string()
      |> String.replace(~r/^<\?xml[^>]*\?>/, "")

    resp = """
    <samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol">
      <samlp:Status><samlp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></samlp:Status>
      #{assertion}
    </samlp:Response>
    """

    Base.encode64(resp)
  end

  defp setup_conn(cert_pem, extra \\ %{}) do
    {:ok, org} = Tenancy.create_organization(%{slug: @slug, name: "SAML Ctrl"})
    {:ok, ws} = Tenancy.create_workspace(%{slug: @slug <> "-ws", name: "WS"})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)

    {:ok, _} =
      Saml.create_connection(
        Map.merge(
          %{
            organization_id: org.id,
            idp_entity_id: "https://idp.example.com/entity",
            idp_sso_url: "https://idp.example.com/sso",
            idp_cert_pem: cert_pem
          },
          extra
        )
      )

    {org, ws}
  end

  # Build + sign an IdP LogoutRequest for the SLO endpoint.
  defp signed_logout_request(name_id, key, cert_der, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    idx =
      case Keyword.get(opts, :session_index) do
        nil -> ""
        i -> "<samlp:SessionIndex>#{i}</samlp:SessionIndex>"
      end

    xml = """
    <samlp:LogoutRequest xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" Version="2.0" ID="_lr1" IssueInstant="#{now}">
      <saml:Issuer>https://idp.example.com/entity</saml:Issuer>
      <saml:NameID>#{name_id}</saml:NameID>
      #{idx}
    </samlp:LogoutRequest>
    """

    {elem, _} = :xmerl_scan.string(to_charlist(xml), namespace_conformant: true)
    signed = :xmerl_dsig.sign(elem, key, cert_der)

    :xmerl.export([signed], :xmerl_xml)
    |> to_string()
    |> String.replace(~r/^<\?xml[^>]*\?>/, "")
    |> Base.encode64()
  end

  test "POST ACS consumes a signed response, mints a session, and JIT-provisions", %{conn: conn} do
    i = idp()
    {_org, ws} = setup_conn(i.cert_pem)
    saml_response = signed_response("newhire@samlctrl.com", i.key, i.cert_der)

    body =
      conn
      |> post("/v1/auth/saml/#{@slug}/acs", %{"SAMLResponse" => saml_response})
      |> json_response(201)

    assert body["user"]["email"] == "newhire@samlctrl.com"
    assert body["token"]
    assert Accounts.verify_user_session_token(body["token"])

    user = Accounts.get_user_by_email("newhire@samlctrl.com")
    # JIT membership in the org's workspace
    assert Repo.exists?(
             from m in Membership,
               where:
                 m.principal_type == "user" and m.principal_id == ^user.id and
                   m.workspace_id == ^ws.id
           )
  end

  describe "org-require-MFA at the ACS mint (era-w8-sso-mfa-binding)" do
    test "a governed factor-less user is refused a session (JSON caller)", %{conn: conn} do
      i = idp()
      {org, _ws} = setup_conn(i.cert_pem)
      {:ok, _} = Tenancy.set_organization_require_mfa(org.id, true)

      resp =
        post(conn, "/v1/auth/saml/#{@slug}/acs", %{
          "SAMLResponse" => signed_response("governed@samlctrl.com", i.key, i.cert_der)
        })

      body = json_response(resp, 403)
      assert body["error"]["code"] == "mfa_enrolment_required"
      refute body["token"]

      # Fail closed: the account was JIT-provisioned but NO session exists.
      user = Accounts.get_user_by_email("governed@samlctrl.com")
      assert user

      refute Repo.exists?(from s in Barkpark.Accounts.UserSession, where: s.user_id == ^user.id)

      # The block is on the audit trail.
      assert Repo.exists?(
               from e in Barkpark.Audit.Event,
                 where: e.action == "mfa_enrolment_required" and e.subject == ^user.id
             )
    end

    test "a governed factor-less BROWSER is routed to /login, never Studio", %{conn: conn} do
      i = idp()
      {org, _ws} = setup_conn(i.cert_pem)
      {:ok, _} = Tenancy.set_organization_require_mfa(org.id, true)

      conn =
        conn
        |> put_req_header("accept", "text/html")
        |> post("/v1/auth/saml/#{@slug}/acs", %{
          "SAMLResponse" => signed_response("browser-gov@samlctrl.com", i.key, i.cert_der)
        })

      assert redirected_to(conn) == "/login"
      refute get_session(conn, "user_session")
    end

    test "a governed user WITH a factor mints unchanged (zero-tax)", %{conn: conn} do
      i = idp()
      {org, _ws} = setup_conn(i.cert_pem)
      {:ok, _} = Tenancy.set_organization_require_mfa(org.id, true)

      {:ok, user} =
        Accounts.register_user(%{email: "armed@samlctrl.com", password: "correct-horse-battery"})

      secret = NimbleTOTP.secret()

      {:ok, _user, _codes} =
        Accounts.enable_totp(user, secret, totp_code_stable!(secret))

      body =
        conn
        |> post("/v1/auth/saml/#{@slug}/acs", %{
          "SAMLResponse" => signed_response("armed@samlctrl.com", i.key, i.cert_der)
        })
        |> json_response(201)

      assert body["token"]
      assert Accounts.verify_user_session_token(body["token"])
    end
  end

  test "failed ACS callbacks land on the audit trail (era-w8)", %{conn: conn} do
    # No connection for the org → 404, audited.
    assert conn
           |> post("/v1/auth/saml/no-such-org/acs", %{"SAMLResponse" => Base.encode64("<x/>")})
           |> json_response(404)

    i = idp()
    setup_conn(i.cert_pem)

    # Bad base64 → 400, audited.
    assert build_conn()
           |> post("/v1/auth/saml/#{@slug}/acs", %{"SAMLResponse" => "!!!not-base64!!!"})
           |> json_response(400)

    # Forged signature (attacker key, victim connection) → 401, audited.
    attacker = idp()

    assert build_conn()
           |> post("/v1/auth/saml/#{@slug}/acs", %{
             "SAMLResponse" =>
               signed_response("victim@samlctrl.com", attacker.key, attacker.cert_der)
           })
           |> json_response(401)

    failures = Repo.all(from e in Barkpark.Audit.Event, where: e.action == "sso_login_failed")
    reasons = Enum.map(failures, & &1.metadata["reason"])

    assert length(failures) == 3
    assert Enum.all?(failures, &(&1.metadata["provider"] == "saml"))
    assert "no_connection" in reasons
    assert "invalid_base64" in reasons
  end

  test "POST ACS with a bad base64 body is 400", %{conn: conn} do
    i = idp()
    setup_conn(i.cert_pem)

    assert conn
           |> post("/v1/auth/saml/#{@slug}/acs", %{"SAMLResponse" => "!!!not-base64!!!"})
           |> json_response(400)
  end

  test "start for an org without a SAML connection is 404", %{conn: conn} do
    assert conn |> get("/v1/auth/saml/no-such-org/start") |> json_response(404)
  end

  # acpc-w1-sso-list-param-guard: the :sso_browser pipeline carries NO auth
  # plug, so both of these are reachable by an unauthenticated caller who only
  # knows an org slug with a configured SamlConnection. Before the
  # `when is_binary(encoded)` head guards, a list-valued param slipped past the
  # action head and raised FunctionClauseError inside Base.decode64/2 — below
  # the action frame, so Phoenix's ActionClauseError→400 conversion never
  # applied and the caller got a 500.
  test "POST ACS with a LIST-valued SAMLResponse is 400, not a 500", %{conn: conn} do
    i = idp()
    setup_conn(i.cert_pem)

    assert conn
           |> post("/v1/auth/saml/#{@slug}/acs", %{"SAMLResponse" => ["abc"]})
           |> json_response(400)
  end

  test "POST SLO with a LIST-valued SAMLRequest is 400, not a 500", %{conn: conn} do
    i = idp()
    setup_conn(i.cert_pem, %{idp_slo_url: "https://idp.example.com/slo"})

    assert conn
           |> post("/v1/auth/saml/#{@slug}/slo", %{"SAMLRequest" => ["abc"]})
           |> json_response(400)
  end

  # The missing-param fallback clauses (saml_controller.ex acs/2 and slo/2
  # second heads) are what the guarded heads fall through to — pin them so the
  # guard can never be "fixed" by deleting the fallback.
  test "POST ACS with no SAMLResponse at all is still 400", %{conn: conn} do
    i = idp()
    setup_conn(i.cert_pem)

    body = conn |> post("/v1/auth/saml/#{@slug}/acs", %{}) |> json_response(400)
    # §9 envelope, not the bare string this used to answer: a client branches on
    # `code`, and `request_id` is what correlates the refusal to the log line.
    assert body["error"]["code"] == "malformed"
    assert body["error"]["message"] == "SAMLResponse is required"
    assert is_binary(body["error"]["request_id"])
  end

  test "POST SLO with no SAMLRequest at all is still 400", %{conn: conn} do
    i = idp()
    setup_conn(i.cert_pem, %{idp_slo_url: "https://idp.example.com/slo"})

    body = conn |> post("/v1/auth/saml/#{@slug}/slo", %{}) |> json_response(400)
    assert body["error"]["code"] == "malformed"
    assert body["error"]["message"] == "SAMLRequest is required"
    assert is_binary(body["error"]["request_id"])
  end

  describe "Single Logout" do
    test "IdP LogoutRequest revokes the named session, replies with a LogoutResponse form, and audits",
         %{conn: conn} do
      i = idp()
      setup_conn(i.cert_pem, %{idp_slo_url: "https://idp.example.com/slo"})

      # SAML login carrying a SessionIndex — birth context lands on the session.
      token =
        conn
        |> post("/v1/auth/saml/#{@slug}/acs", %{
          "SAMLResponse" =>
            signed_response("slo@samlctrl.com", i.key, i.cert_der, session_index: "idx-1")
        })
        |> json_response(201)
        |> Map.fetch!("token")

      assert Accounts.verify_user_session_token(token)

      # The IdP front-channels its signed LogoutRequest to our SLO endpoint.
      resp =
        build_conn()
        |> post("/v1/auth/saml/#{@slug}/slo", %{
          "SAMLRequest" =>
            signed_logout_request("slo@samlctrl.com", i.key, i.cert_der, session_index: "idx-1")
        })

      html = response(resp, 200)
      # The auto-submit LogoutResponse form pointing back at the IdP.
      assert html =~ "SAMLResponse"
      assert html =~ "https://idp.example.com/slo"

      # CSP survival (task-0fc9d55c): the :sso_browser pipeline bypasses
      # root.html.heex, so slo/2 sets a strict script-src 'nonce-…' by hand and
      # esaml stamps the SAME nonce onto its auto-submit <script>. Prove the
      # policy is present, has no 'unsafe-inline' (a real backstop, not vacuous
      # green), the script carries the exact header nonce, and the form still
      # auto-submits — so the logout completes under the tightened policy.
      [policy] = get_resp_header(resp, "content-security-policy")
      assert [_, nonce] = Regex.run(~r/script-src 'self' 'nonce-([^']+)'/, policy)
      refute policy =~ "'unsafe-inline'"
      assert html =~ ~s|<script nonce="#{nonce}">|
      assert html =~ "saml-req-form"
      assert html =~ ".submit()"

      # Sobelow Config.Headers fix (task-f76e9b7b): the SLO auto-submit HTML form
      # rides the :sso_browser pipeline, which now sets secure browser headers.
      # Regression fence — this HTML page must never ship without them again.
      # (Phoenix 1.8's put_secure_browser_headers sets nosniff/referrer-policy/
      # permitted-cross-domain-policies; it no longer emits x-frame-options.)
      assert get_resp_header(resp, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(resp, "referrer-policy") == ["strict-origin-when-cross-origin"]

      # The named session is dead; the SLO is on the audit chain.
      refute Accounts.verify_user_session_token(token)
      assert Repo.one(from e in Barkpark.Audit.Event, where: e.action == "saml_slo")
    end

    test "a LogoutRequest signed by an UNTRUSTED key revokes nothing (401)", %{conn: conn} do
      i = idp()
      setup_conn(i.cert_pem, %{idp_slo_url: "https://idp.example.com/slo"})

      token =
        conn
        |> post("/v1/auth/saml/#{@slug}/acs", %{
          "SAMLResponse" =>
            signed_response("victim@samlctrl.com", i.key, i.cert_der, session_index: "idx-2")
        })
        |> json_response(201)
        |> Map.fetch!("token")

      attacker = idp()

      assert build_conn()
             |> post("/v1/auth/saml/#{@slug}/slo", %{
               "SAMLRequest" =>
                 signed_logout_request("victim@samlctrl.com", attacker.key, attacker.cert_der,
                   session_index: "idx-2"
                 )
             })
             |> json_response(401)

      # The session survives the forged logout.
      assert Accounts.verify_user_session_token(token)
    end

    test "logout of a SAML-born session returns the SP-initiated slo_url", %{conn: conn} do
      i = idp()
      setup_conn(i.cert_pem, %{idp_slo_url: "https://idp.example.com/slo"})

      token =
        conn
        |> post("/v1/auth/saml/#{@slug}/acs", %{
          "SAMLResponse" =>
            signed_response("bye@samlctrl.com", i.key, i.cert_der, session_index: "idx-3")
        })
        |> json_response(201)
        |> Map.fetch!("token")

      body =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> delete("/v1/auth/logout")
        |> json_response(200)

      assert body["ok"] == true
      assert body["slo_url"] =~ "https://idp.example.com/slo?"
      assert body["slo_url"] =~ "SAMLRequest="
      refute Accounts.verify_user_session_token(token)
    end

    test "logout of a SAML session on an SLO-less connection stays local (no slo_url)", %{
      conn: conn
    } do
      i = idp()
      setup_conn(i.cert_pem)

      token =
        conn
        |> post("/v1/auth/saml/#{@slug}/acs", %{
          "SAMLResponse" => signed_response("local@samlctrl.com", i.key, i.cert_der)
        })
        |> json_response(201)
        |> Map.fetch!("token")

      body =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> delete("/v1/auth/logout")
        |> json_response(200)

      assert body["ok"] == true
      refute Map.has_key?(body, "slo_url")
      refute Accounts.verify_user_session_token(token)
    end
  end
end
