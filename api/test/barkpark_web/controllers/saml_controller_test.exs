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

  defp signed_response(email, key, cert_der) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    death = now |> DateTime.add(300) |> DateTime.to_iso8601()
    nbf = now |> DateTime.add(-60) |> DateTime.to_iso8601()

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

  defp setup_conn(cert_pem) do
    {:ok, org} = Tenancy.create_organization(%{slug: @slug, name: "SAML Ctrl"})
    {:ok, ws} = Tenancy.create_workspace(%{slug: @slug <> "-ws", name: "WS"})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)

    {:ok, _} =
      Saml.create_connection(%{
        organization_id: org.id,
        idp_entity_id: "https://idp.example.com/entity",
        idp_sso_url: "https://idp.example.com/sso",
        idp_cert_pem: cert_pem
      })

    {org, ws}
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
end
