defmodule Barkpark.Sso.SamlXmlNames do
  @moduledoc """
  Name check for an inbound SAML protocol message, run before xmerl parses it.

  xmerl stores every element name, attribute name, namespace prefix, namespace
  name, processing-instruction target, entity name and declared encoding as an
  atom. `check/1` reads the raw binary with Saxy, which keeps names as
  binaries, and refuses the message unless each of those names is in a fixed
  vocabulary: SAML 2.0 assertion, protocol and metadata, XML-dsig 1.0 and 1.1,
  XML-enc 1.0 and 1.1, exclusive C14N, XML Schema and the `xml` namespace.

  The vocabulary is fixed at compile time, so xmerl only ever sees names from
  that set. An IdP that sends a name outside it is refused with
  `{:error, {:xml_name_not_permitted, name}}`; add the name here if a real IdP
  needs it.
  """
  @behaviour Saxy.Handler

  # The prefixes IdPs use in practice: Entra and ADFS use samlp plus default
  # namespaces, Okta, Google and Shibboleth use saml2p/saml2, Keycloak uses dsig.
  @prefixes MapSet.new(~w(
    saml saml2 samlp saml2p md ds dsig dsig11 xenc xenc11 ec exc14n xs xsd xsi xml
  ))

  @namespaces MapSet.new([
                "",
                "urn:oasis:names:tc:SAML:2.0:assertion",
                "urn:oasis:names:tc:SAML:2.0:protocol",
                "urn:oasis:names:tc:SAML:2.0:metadata",
                "http://www.w3.org/2000/09/xmldsig#",
                "http://www.w3.org/2009/xmldsig11#",
                "http://www.w3.org/2001/04/xmlenc#",
                "http://www.w3.org/2009/xmlenc11#",
                "http://www.w3.org/2001/10/xml-exc-c14n#",
                "http://www.w3.org/2001/XMLSchema",
                "http://www.w3.org/2001/XMLSchema-instance",
                "http://www.w3.org/XML/1998/namespace"
              ])

  # Local names of elements and attributes, from the SAML 2.0 core schemas
  # (assertion and protocol), XML-dsig, XML-enc, exclusive C14N and XML Schema
  # instance. One set for both, so the allowed set is prefixes x local names.
  @local_names MapSet.new(~w(
    Assertion AssertionIDRef AssertionURIRef EncryptedAssertion Issuer BaseID
    NameID EncryptedID Subject SubjectConfirmation SubjectConfirmationData
    Conditions Condition AudienceRestriction Audience OneTimeUse ProxyRestriction
    Advice Statement AuthnStatement SubjectLocality AuthnContext
    AuthnContextClassRef AuthnContextDecl AuthnContextDeclRef
    AuthenticatingAuthority AttributeStatement Attribute AttributeValue
    EncryptedAttribute AuthzDecisionStatement Action Evidence

    Response Status StatusCode StatusMessage StatusDetail Extensions
    LogoutRequest LogoutResponse SessionIndex AuthnRequest RequestedAuthnContext
    NameIDPolicy Scoping IDPList IDPEntry GetComplete RequesterID
    ArtifactResolve ArtifactResponse Artifact ManageNameIDRequest
    ManageNameIDResponse NewID NewEncryptedID Terminate AttributeQuery AuthnQuery
    AuthzDecisionQuery AssertionIDRequest SubjectQuery NameIDMappingRequest
    NameIDMappingResponse

    Signature SignedInfo CanonicalizationMethod SignatureMethod Reference
    Transforms Transform DigestMethod DigestValue SignatureValue KeyInfo KeyName
    KeyValue RSAKeyValue Modulus Exponent DSAKeyValue P Q G Y J Seed PgenCounter
    RetrievalMethod X509Data X509IssuerSerial X509IssuerName X509SerialNumber
    X509SKI X509SubjectName X509Certificate X509CRL X509Digest PGPData
    PGPKeyID PGPKeyPacket SPKIData SPKISexp MgmtData Object Manifest
    SignatureProperties SignatureProperty HMACOutputLength XPath ECKeyValue
    NamedCurve PublicKey ECParameters

    EncryptedData EncryptedKey EncryptionMethod CipherData CipherValue
    CipherReference ReferenceList DataReference KeyReference CarriedKeyName
    EncryptionProperties EncryptionProperty KeySize OAEPparams AgreementMethod
    KeyDerivationMethod MGF

    InclusiveNamespaces PrefixList

    ID Version IssueInstant Destination Consent InResponseTo Format
    NameQualifier SPNameQualifier SPProvidedID Method NotBefore NotOnOrAfter
    Recipient Address DNSName AuthnInstant SessionNotOnOrAfter Name NameFormat
    FriendlyName Value Count Resource Decision Namespace Algorithm URI Type Id
    MimeType Encoding Target AllowCreate ForceAuthn IsPassive ProtocolBinding
    AssertionConsumerServiceIndex AssertionConsumerServiceURL
    AttributeConsumingServiceIndex ProviderName Comparison ProxyCount Reason
    ProviderID Loc

    type nil schemaLocation noNamespaceSchemaLocation lang space
  ))

  # The XML declaration may name UTF-8 only, in any letter case.
  @encoding "utf-8"

  # Only an XML declaration at the very start may use `<?`.
  @xml_decl_re ~r/\A(?:\xEF\xBB\xBF)?<\?xml[\x20\x09\x0D\x0A][^?]*\?>/

  @doc """
  `:ok` when every name in `xml` is in the SAML vocabulary, else an error tuple.
  Never creates an atom from the document.
  """
  @spec check(binary()) :: :ok | {:error, term()}
  def check(xml) when is_binary(xml) do
    with :ok <- check_processing_instructions(xml) do
      case Saxy.parse_string(xml, __MODULE__, :ok,
             expand_entity: {__MODULE__, :refuse_entity, []},
             cdata_as_characters: true
           ) do
        {:ok, :ok} -> :ok
        {:ok, {:error, _} = error} -> error
        {:error, error} -> {:error, {:malformed_xml, Exception.message(error)}}
      end
    end
  catch
    :throw, {__MODULE__, reason} -> {:error, reason}
  end

  defp check_processing_instructions(xml) do
    rest =
      case Regex.run(@xml_decl_re, xml, return: :index) do
        [{0, len}] -> binary_part(xml, len, byte_size(xml) - len)
        _ -> xml
      end

    case :binary.match(rest, "<?") do
      :nomatch -> :ok
      _ -> {:error, :processing_instruction_not_permitted}
    end
  end

  @doc false
  # Saxy calls this for an entity reference other than the five predefined
  # ones. With no DTD there is no other valid entity, so refuse it.
  def refuse_entity(name), do: throw({__MODULE__, {:entity_not_permitted, clip(name)}})

  @impl Saxy.Handler
  def handle_event(:start_document, prolog, state) do
    case Keyword.get(prolog, :encoding) do
      nil ->
        {:ok, state}

      enc when is_binary(enc) ->
        if String.downcase(enc) == @encoding,
          do: {:ok, state},
          else: refuse(:encoding_not_permitted, enc)
    end
  end

  def handle_event(:start_element, {name, attributes}, state) do
    cond do
      not qualified_name?(name) ->
        refuse(:xml_name_not_permitted, name)

      bad = Enum.find(attributes, &(not attribute?(&1))) ->
        refuse(:xml_name_not_permitted, elem(bad, 0))

      true ->
        {:ok, state}
    end
  end

  def handle_event(_event, _data, state), do: {:ok, state}

  defp refuse(kind, value), do: {:stop, {:error, {kind, clip(value)}}}

  defp attribute?({"xmlns", uri}), do: MapSet.member?(@namespaces, uri)

  defp attribute?({"xmlns:" <> prefix, uri}),
    do: MapSet.member?(@prefixes, prefix) and MapSet.member?(@namespaces, uri)

  defp attribute?({name, _value}), do: qualified_name?(name)

  defp qualified_name?(name) do
    case :binary.split(name, ":") do
      [local] -> MapSet.member?(@local_names, local)
      [prefix, local] -> MapSet.member?(@prefixes, prefix) and MapSet.member?(@local_names, local)
    end
  end

  # Keep the refused name short in the audit log and server log.
  defp clip(value) when byte_size(value) > 64, do: binary_part(value, 0, 64)
  defp clip(value), do: value
end
