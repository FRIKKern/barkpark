defmodule Barkpark.Sso.SamlXmlNamesTest do
  @moduledoc """
  task-f5fa1c456a7e9877: `Saml.parse_untrusted_xml/1` refuses names outside
  the SAML vocabulary before xmerl runs. Not async, so the atom counts are not
  disturbed by other test modules loading code.
  """
  use ExUnit.Case, async: false

  alias Barkpark.Sso.{Saml, SamlXmlNames}

  defp unique, do: "z" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp atom_growth(fun) do
    # Warm-up with a fresh value, so code loading is not counted.
    fun.()
    before = :erlang.system_info(:atom_count)
    result = fun.()
    {result, :erlang.system_info(:atom_count) - before}
  end

  @samlp ~s(xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol")

  # The shape Entra ID sends: samlp prefix on the envelope, default namespaces
  # on the assertion and signature, an XML declaration.
  @entra """
  <?xml version="1.0" encoding="UTF-8"?>
  <samlp:Response ID="_r1" Version="2.0" IssueInstant="2026-10-30T10:00:00Z" Destination="https://bp.example/acs" InResponseTo="_q1" xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol">
    <Issuer xmlns="urn:oasis:names:tc:SAML:2.0:assertion">https://sts.windows.net/t/</Issuer>
    <samlp:Status><samlp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></samlp:Status>
    <Assertion ID="_a1" IssueInstant="2026-10-30T10:00:00Z" Version="2.0" xmlns="urn:oasis:names:tc:SAML:2.0:assertion">
      <Issuer>https://sts.windows.net/t/</Issuer>
      <Signature xmlns="http://www.w3.org/2000/09/xmldsig#">
        <SignedInfo>
          <CanonicalizationMethod Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/>
          <SignatureMethod Algorithm="http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"/>
          <Reference URI="#_a1">
            <Transforms>
              <Transform Algorithm="http://www.w3.org/2000/09/xmldsig#enveloped-signature"/>
              <Transform Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/>
            </Transforms>
            <DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/>
            <DigestValue>AAAA</DigestValue>
          </Reference>
        </SignedInfo>
        <SignatureValue>AAAA</SignatureValue>
        <KeyInfo><X509Data><X509Certificate>AAAA</X509Certificate></X509Data></KeyInfo>
      </Signature>
      <Subject>
        <NameID Format="urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress">a@b.example</NameID>
        <SubjectConfirmation Method="urn:oasis:names:tc:SAML:2.0:cm:bearer">
          <SubjectConfirmationData InResponseTo="_q1" NotOnOrAfter="2026-10-30T11:00:00Z" Recipient="https://bp.example/acs"/>
        </SubjectConfirmation>
      </Subject>
      <Conditions NotBefore="2026-10-30T09:55:00Z" NotOnOrAfter="2026-10-30T11:00:00Z">
        <AudienceRestriction><Audience>https://bp.example/md</Audience></AudienceRestriction>
      </Conditions>
      <AttributeStatement>
        <Attribute Name="http://schemas.microsoft.com/identity/claims/tenantid"><AttributeValue>t</AttributeValue></Attribute>
        <Attribute Name="http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress"><AttributeValue>a@b.example</AttributeValue></Attribute>
      </AttributeStatement>
      <AuthnStatement AuthnInstant="2026-10-30T09:59:00Z" SessionIndex="_s1">
        <AuthnContext><AuthnContextClassRef>urn:oasis:names:tc:SAML:2.0:ac:classes:Password</AuthnContextClassRef></AuthnContext>
      </AuthnStatement>
    </Assertion>
  </samlp:Response>
  """

  # The shape Okta sends: saml2p/saml2/ds prefixes, exclusive C14N with an
  # InclusiveNamespaces prefix list, xsi:type on attribute values.
  @okta """
  <?xml version="1.0" encoding="UTF-8"?><saml2p:Response xmlns:saml2p="urn:oasis:names:tc:SAML:2.0:protocol" Destination="https://bp.example/acs" ID="id1" IssueInstant="2026-10-30T10:00:00.000Z" Version="2.0"><saml2:Issuer xmlns:saml2="urn:oasis:names:tc:SAML:2.0:assertion" Format="urn:oasis:names:tc:SAML:2.0:nameid-format:entity">http://www.okta.com/x</saml2:Issuer><saml2p:Status><saml2p:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></saml2p:Status><saml2:Assertion xmlns:saml2="urn:oasis:names:tc:SAML:2.0:assertion" ID="id2" IssueInstant="2026-10-30T10:00:00.000Z" Version="2.0"><saml2:Issuer Format="urn:oasis:names:tc:SAML:2.0:nameid-format:entity">http://www.okta.com/x</saml2:Issuer><ds:Signature xmlns:ds="http://www.w3.org/2000/09/xmldsig#"><ds:SignedInfo><ds:CanonicalizationMethod Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/><ds:SignatureMethod Algorithm="http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"/><ds:Reference URI="#id2"><ds:Transforms><ds:Transform Algorithm="http://www.w3.org/2000/09/xmldsig#enveloped-signature"/><ds:Transform Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"><ec:InclusiveNamespaces xmlns:ec="http://www.w3.org/2001/10/xml-exc-c14n#" PrefixList="xs"/></ds:Transform></ds:Transforms><ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/><ds:DigestValue>AAAA</ds:DigestValue></ds:Reference></ds:SignedInfo><ds:SignatureValue>AAAA</ds:SignatureValue><ds:KeyInfo><ds:X509Data><ds:X509Certificate>AAAA</ds:X509Certificate></ds:X509Data></ds:KeyInfo></ds:Signature><saml2:Subject><saml2:NameID Format="urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress">a@b.example</saml2:NameID><saml2:SubjectConfirmation Method="urn:oasis:names:tc:SAML:2.0:cm:bearer"><saml2:SubjectConfirmationData NotOnOrAfter="2026-10-30T10:05:00.000Z" Recipient="https://bp.example/acs"/></saml2:SubjectConfirmation></saml2:Subject><saml2:Conditions NotBefore="2026-10-30T09:55:00.000Z" NotOnOrAfter="2026-10-30T10:05:00.000Z"><saml2:AudienceRestriction><saml2:Audience>https://bp.example/md</saml2:Audience></saml2:AudienceRestriction></saml2:Conditions><saml2:AuthnStatement AuthnInstant="2026-10-30T10:00:00.000Z" SessionIndex="id3"><saml2:AuthnContext><saml2:AuthnContextClassRef>urn:oasis:names:tc:SAML:2.0:ac:classes:PasswordProtectedTransport</saml2:AuthnContextClassRef></saml2:AuthnContext></saml2:AuthnStatement><saml2:AttributeStatement><saml2:Attribute Name="email" NameFormat="urn:oasis:names:tc:SAML:2.0:attrname-format:unspecified"><saml2:AttributeValue xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="xs:string">a@b.example</saml2:AttributeValue></saml2:Attribute></saml2:AttributeStatement></saml2:Assertion></saml2p:Response>
  """

  describe "IdP response shapes inside the vocabulary" do
    test "an Entra-shaped response passes and parses" do
      assert :ok = SamlXmlNames.check(@entra)
      assert {:ok, _doc} = Saml.parse_untrusted_xml(@entra)
    end

    test "an Okta-shaped response passes and parses" do
      assert :ok = SamlXmlNames.check(@okta)
      assert {:ok, _doc} = Saml.parse_untrusted_xml(@okta)
    end

    test "predefined and character entity references pass" do
      assert :ok =
               SamlXmlNames.check(
                 ~s(<samlp:Response #{@samlp}>a &amp; b &#38; &#x26;</samlp:Response>)
               )
    end
  end

  describe "names outside the vocabulary are refused with no new atoms" do
    test "5000 unique element and attribute names" do
      {result, growth} =
        atom_growth(fn ->
          body = for _ <- 1..5000, into: "", do: ~s(<#{unique()} #{unique()}="1"/>)
          Saml.parse_untrusted_xml(~s(<samlp:Response #{@samlp}>#{body}</samlp:Response>))
        end)

      IO.puts("parse_untrusted_xml: 10000 unknown names, atom_count grew by #{growth}")
      assert {:error, {:xml_name_not_permitted, _}} = result
      assert growth < 10
    end

    test "unknown prefixes, namespace names, PI targets, entities and encodings" do
      cases = [
        prefix: fn -> ~s(<#{unique()}:Response xmlns:#{unique()}="urn:x"/>) end,
        xmlns_prefix: fn ->
          ~s(<samlp:Response #{@samlp} xmlns:#{unique()}="urn:oasis:names:tc:SAML:2.0:assertion"/>)
        end,
        namespace: fn -> ~s(<Response xmlns="urn:#{unique()}"/>) end,
        processing_instruction: fn ->
          ~s(<samlp:Response #{@samlp}><?#{unique()} x?></samlp:Response>)
        end,
        entity: fn -> ~s(<samlp:Response #{@samlp}>&#{unique()};</samlp:Response>) end,
        entity_in_attribute: fn -> ~s(<samlp:Response #{@samlp} ID="&#{unique()};"/>) end,
        encoding: fn ->
          ~s(<?xml version="1.0" encoding="#{unique()}"?><samlp:Response #{@samlp}/>)
        end
      ]

      for {kind, gen} <- cases do
        {result, growth} =
          atom_growth(fn -> for(_ <- 1..200, do: Saml.parse_untrusted_xml(gen.())) |> hd() end)

        IO.puts("#{kind}: 200 unknown values, atom_count grew by #{growth}")
        assert match?({:error, _}, result), "#{kind} was not refused"
        assert growth < 10, "#{kind} grew the atom table by #{growth}"
      end
    end

    test "a message over the size cap is refused before any parse" do
      big =
        ~s(<samlp:Response #{@samlp}>) <> String.duplicate("a", 300_000) <> "</samlp:Response>"

      assert {:error, :xml_too_large} = Saml.parse_untrusted_xml(big)
    end

    test "malformed XML is refused by the name check" do
      assert {:error, {:malformed_xml, _}} =
               SamlXmlNames.check("<samlp:Response #{@samlp}><samlp:Status></samlp:Response>")
    end
  end
end
