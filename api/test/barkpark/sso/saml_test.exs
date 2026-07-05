defmodule Barkpark.Sso.SamlTest do
  @moduledoc "SAML SP assertion consumption + SLO — we play the IdP with a test cert (era-w3-saml, era-w7 SLO)."
  use Barkpark.DataCase, async: false

  alias Barkpark.{Sso.Saml, Tenancy}

  @slug "samlorg"

  # A self-signed test IdP: key + cert (x509, test-only dep).
  defp idp do
    key = X509.PrivateKey.new_rsa(2048)
    cert = X509.Certificate.self_signed(key, "/CN=Test IdP")
    %{key: key, cert_pem: X509.Certificate.to_pem(cert), cert_der: X509.Certificate.to_der(cert)}
  end

  defp connection(cert_pem, extra \\ %{}) do
    {:ok, org} = Tenancy.create_organization(%{slug: @slug, name: "SAML Org"})

    {:ok, c} =
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

    {org, c}
  end

  # Build a SAML Assertion XML, then sign it (enveloped XML-dsig) with the IdP key.
  defp signed_assertion(email, key, cert_der, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    recipient = Keyword.get(opts, :recipient, Saml.acs_uri(@slug))
    audience = Keyword.get(opts, :audience, Saml.entity_id(@slug))
    session_index = Keyword.get(opts, :session_index)
    death = now |> DateTime.add(300) |> DateTime.to_iso8601()
    nbf = now |> DateTime.add(-60) |> DateTime.to_iso8601()
    issued = DateTime.to_iso8601(now)

    authn =
      if session_index do
        ~s(<saml:AuthnStatement AuthnInstant="#{issued}" SessionIndex="#{session_index}"/>)
      else
        ""
      end

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
      #{authn}
    </saml:Assertion>
    """

    {elem, _} = :xmerl_scan.string(to_charlist(xml), namespace_conformant: true)
    signed = :xmerl_dsig.sign(elem, key, cert_der)

    signed_assertion =
      :xmerl.export([signed], :xmerl_xml)
      |> to_string()
      |> String.replace(~r/^<\?xml[^>]*\?>/, "")

    # Wrap the signed Assertion in a samlp:Response with a Success status —
    # the envelope esaml_sp:validate_assertion expects. NOTE: deliberately no
    # InResponseTo — this is the UNSOLICITED (IdP-initiated) shape, and the
    # same rigor must apply to it.
    """
    <samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol">
      <samlp:Status><samlp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></samlp:Status>
      #{signed_assertion}
    </samlp:Response>
    """
  end

  # Build + sign an IdP LogoutRequest (the SLO front channel), enveloped-dsig.
  defp signed_logout_request(name_id, key, cert_der, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    session_index = Keyword.get(opts, :session_index)

    idx_xml =
      if session_index, do: "<samlp:SessionIndex>#{session_index}</samlp:SessionIndex>", else: ""

    xml = """
    <samlp:LogoutRequest xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" Version="2.0" ID="_lr1" IssueInstant="#{now}">
      <saml:Issuer>https://idp.example.com/entity</saml:Issuer>
      <saml:NameID>#{name_id}</saml:NameID>
      #{idx_xml}
    </samlp:LogoutRequest>
    """

    {elem, _} = :xmerl_scan.string(to_charlist(xml), namespace_conformant: true)
    signed = :xmerl_dsig.sign(elem, key, cert_der)
    :xmerl.export([signed], :xmerl_xml) |> to_string() |> String.replace(~r/^<\?xml[^>]*\?>/, "")
  end

  test "consumes a validly-signed assertion and extracts email + SAML session context" do
    i = idp()
    {_org, c} = connection(i.cert_pem)

    xml = signed_assertion("alice@samlorg.com", i.key, i.cert_der, session_index: "idx-42")

    assert {:ok, %{email: "alice@samlorg.com", name_id: "alice@samlorg.com", session_index: "idx-42"}} =
             Saml.consume(c, xml, @slug)
  end

  test "an UNSOLICITED (IdP-initiated) response validates with the same rigor — no session_index degrades to nil" do
    i = idp()
    {_org, c} = connection(i.cert_pem)

    # The fixture is inherently unsolicited (no InResponseTo) — this pins that
    # the IdP-initiated shape is accepted, with the session index optional.
    xml = signed_assertion("bob@samlorg.com", i.key, i.cert_der)
    assert {:ok, %{email: "bob@samlorg.com", session_index: nil}} = Saml.consume(c, xml, @slug)
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

  describe "Single Logout" do
    test "a validly-signed IdP LogoutRequest yields its name_id + session_index" do
      i = idp()
      {_org, c} = connection(i.cert_pem, %{idp_slo_url: "https://idp.example.com/slo"})

      xml = signed_logout_request("alice@samlorg.com", i.key, i.cert_der, session_index: "idx-9")

      assert {:ok, %{name_id: "alice@samlorg.com", session_index: "idx-9"}} =
               Saml.consume_logout_request(c, xml, @slug)
    end

    test "an UNSIGNED or foreign-signed LogoutRequest is rejected (no unauthenticated session kill)" do
      trusted = idp()
      {_org, c} = connection(trusted.cert_pem, %{idp_slo_url: "https://idp.example.com/slo"})

      attacker = idp()
      forged = signed_logout_request("victim@samlorg.com", attacker.key, attacker.cert_der)
      assert {:error, _} = Saml.consume_logout_request(c, forged, @slug)

      unsigned = """
      <samlp:LogoutRequest xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" Version="2.0" ID="_lr2" IssueInstant="2026-01-01T00:00:00Z">
        <saml:Issuer>https://idp.example.com/entity</saml:Issuer>
        <saml:NameID>victim@samlorg.com</saml:NameID>
      </samlp:LogoutRequest>
      """

      assert {:error, _} = Saml.consume_logout_request(c, unsigned, @slug)
    end

    test "sp_logout_redirect_url carries a SAMLRequest to the IdP SLO endpoint" do
      i = idp()
      {_org, c} = connection(i.cert_pem, %{idp_slo_url: "https://idp.example.com/slo"})

      url = Saml.sp_logout_redirect_url(c, @slug, "alice@samlorg.com", "idx-9")
      assert url =~ "https://idp.example.com/slo?"
      assert url =~ "SAMLRequest="
    end

    test "slo_available? requires a configured idp_slo_url" do
      i = idp()
      {_org, c} = connection(i.cert_pem)
      refute Saml.slo_available?(c)
      refute Saml.slo_available?(nil)
      assert Saml.slo_available?(%{c | idp_slo_url: "https://idp.example.com/slo"})
    end
  end
end
