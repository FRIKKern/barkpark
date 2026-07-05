defmodule Barkpark.Sso.SamlTest do
  @moduledoc "SAML SP assertion consumption — we play the IdP with a test cert (era-w3-saml)."
  use Barkpark.DataCase, async: false

  alias Barkpark.{Sso.Saml, Tenancy}

  @slug "samlorg"

  # A self-signed test IdP: key + cert (x509, test-only dep).
  defp idp do
    key = X509.PrivateKey.new_rsa(2048)
    cert = X509.Certificate.self_signed(key, "/CN=Test IdP")
    %{key: key, cert_pem: X509.Certificate.to_pem(cert), cert_der: X509.Certificate.to_der(cert)}
  end

  defp connection(cert_pem) do
    {:ok, org} = Tenancy.create_organization(%{slug: @slug, name: "SAML Org"})

    {:ok, c} =
      Saml.create_connection(%{
        organization_id: org.id,
        idp_entity_id: "https://idp.example.com/entity",
        idp_sso_url: "https://idp.example.com/sso",
        idp_cert_pem: cert_pem
      })

    {org, c}
  end

  # Build a SAML Assertion XML, then sign it (enveloped XML-dsig) with the IdP key.
  defp signed_assertion(email, key, cert_der, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    recipient = Keyword.get(opts, :recipient, Saml.acs_uri(@slug))
    audience = Keyword.get(opts, :audience, Saml.entity_id(@slug))
    death = now |> DateTime.add(300) |> DateTime.to_iso8601()
    nbf = now |> DateTime.add(-60) |> DateTime.to_iso8601()
    issued = DateTime.to_iso8601(now)

    xml = """
    <saml:Assertion xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" Version="2.0" ID="_a1" IssueInstant="#{issued}">
      <saml:Issuer>https://idp.example.com/entity</saml:Issuer>
      <saml:Subject>
        <saml:NameID>#{email}</saml:NameID>
        <saml:SubjectConfirmation Method="urn:oasis:names:tc:SAML:2.0:cm:bearer">
          <saml:SubjectConfirmationData Recipient="#{recipient}" NotOnOrAfter="#{death}"/>
        </saml:SubjectConfirmation>
      </saml:Subject>
      <saml:Conditions NotBefore="#{nbf}" NotOnOrAfter="#{death}">
        <saml:AudienceRestriction><saml:Audience>#{audience}</saml:Audience></saml:AudienceRestriction>
      </saml:Conditions>
    </saml:Assertion>
    """

    {elem, _} = :xmerl_scan.string(to_charlist(xml), namespace_conformant: true)
    signed = :xmerl_dsig.sign(elem, key, cert_der)

    signed_assertion =
      :xmerl.export([signed], :xmerl_xml)
      |> to_string()
      |> String.replace(~r/^<\?xml[^>]*\?>/, "")

    # Wrap the signed Assertion in a samlp:Response with a Success status —
    # the envelope esaml_sp:validate_assertion expects.
    """
    <samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol">
      <samlp:Status><samlp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></samlp:Status>
      #{signed_assertion}
    </samlp:Response>
    """
  end

  test "consumes a validly-signed assertion and extracts the subject email" do
    i = idp()
    {_org, c} = connection(i.cert_pem)

    xml = signed_assertion("alice@samlorg.com", i.key, i.cert_der)
    assert {:ok, "alice@samlorg.com"} = Saml.consume(c, xml, @slug)
  end

  test "rejects an assertion signed by a DIFFERENT (untrusted) key" do
    trusted = idp()
    {_org, c} = connection(trusted.cert_pem)

    # sign with a different key than the one the connection trusts
    attacker = idp()
    xml = signed_assertion("mallory@samlorg.com", attacker.key, attacker.cert_der)

    assert {:error, _} = Saml.consume(c, xml, @slug)
  end

  test "rejects a wrong audience (assertion meant for another SP)" do
    i = idp()
    {_org, c} = connection(i.cert_pem)

    xml =
      signed_assertion("eve@samlorg.com", i.key, i.cert_der, audience: "https://evil.example.com")

    assert {:error, _} = Saml.consume(c, xml, @slug)
  end

  test "cert_fingerprint is the sha256 of the DER cert" do
    i = idp()
    fp = Saml.cert_fingerprint(i.cert_pem)
    assert fp == "sha256:" <> Base.encode64(:crypto.hash(:sha256, i.cert_der))
  end
end
