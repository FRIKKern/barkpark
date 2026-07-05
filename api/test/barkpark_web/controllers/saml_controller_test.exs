defmodule BarkparkWeb.SamlControllerTest do
  @moduledoc "SAML SP HTTP surface — start redirect + ACS session mint + JIT."
  use BarkparkWeb.ConnCase, async: false

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
        nil -> ""
        idx -> ~s(<saml:AuthnStatement AuthnInstant="#{DateTime.to_iso8601(now)}" SessionIndex="#{idx}"/>)
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

  describe "Single Logout" do
    test "IdP LogoutRequest revokes the named session, replies with a LogoutResponse form, and audits",
         %{conn: conn} do
      i = idp()
      setup_conn(i.cert_pem, %{idp_slo_url: "https://idp.example.com/slo"})

      # SAML login carrying a SessionIndex — birth context lands on the session.
      token =
        conn
        |> post("/v1/auth/saml/#{@slug}/acs", %{
          "SAMLResponse" => signed_response("slo@samlctrl.com", i.key, i.cert_der, session_index: "idx-1")
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
          "SAMLResponse" => signed_response("victim@samlctrl.com", i.key, i.cert_der, session_index: "idx-2")
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
          "SAMLResponse" => signed_response("bye@samlctrl.com", i.key, i.cert_der, session_index: "idx-3")
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

    test "logout of a SAML session on an SLO-less connection stays local (no slo_url)", %{conn: conn} do
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
