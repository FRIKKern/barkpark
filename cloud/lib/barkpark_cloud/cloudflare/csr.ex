defmodule BarkparkCloud.Cloudflare.CSR do
  @moduledoc """
  A PKCS#10 Certification Request generator, hand-rolled on Erlang's
  `:public_key` — NO new dependency, NO shelling out to `openssl`.

  Cloudflare's Origin CA endpoint (`POST /certificates`) does not mint a key
  pair for you: it signs a CSR you supply. Nothing anywhere in `cloud/` or
  `api/` could produce one before this module (`grep -rn CertificationRequest`
  found only prose), which is why the Origin CA callback was an unreachable
  stub.

  ## What it builds

  `generate/2` creates a fresh RSA key pair (Cloudflare Origin CA is
  `origin-rsa`) and DER-encodes a `CertificationRequest`:

      CertificationRequest ::= SEQUENCE {
        certificationRequestInfo  CertificationRequestInfo,
        signatureAlgorithm        sha256WithRSAEncryption,
        signature                 BIT STRING   -- over the DER of the info
      }

  The info carries version `v1`, a subject of one RDN (`CN=<primary hostname>`),
  the RSA `SubjectPublicKeyInfo`, and ONE attribute — `extensionRequest`
  (`1.2.840.113549.1.9.14`) holding a `subjectAltName` with every hostname as a
  `dNSName`. The SAN is what makes a multi-hostname cert (`example.com` +
  `*.example.com`) a correct request rather than a CN-only one Cloudflare has to
  reinterpret from the JSON body.

  ## The open-type trap (why `{:asn1_OPENTYPE, der}` and not raw DER)

  Two of the fields here are ASN.1 open types driven by an information object
  set — the algorithm `parameters` and each attribute's `values`. OTP's
  generated `PKCS-10` encoder accepts EXACTLY `{:asn1_OPENTYPE, binary}` for
  them and `case_clause`-crashes on a bare `<<5, 0>>` or an atom like `:NULL`.
  That shape is stable across OTP versions.

  ## The subject attribute value FLIPPED shape between OTP 27 and OTP 28

  The `AttributeTypeAndValue` value inside the subject `rdnSequence` did NOT
  stay stable, and it is the one field this module cannot spell as a literal:

    * **OTP 27** — the value is an ASN.1 OPEN TYPE. `enc_AttributeTypeAndValue`
      hands it straight to `encode_open_type/2`, which calls `byte_size/1` on
      it, so it must be ALREADY-DER-ENCODED bytes. A `{:utf8String, name}`
      tuple raises `{:asn1, {:badarg, [{:erlang, :byte_size, [utf8String: …]}`.
    * **OTP 28** — the modern `PKIX1Explicit-2009` encoder took over and wants
      the TYPED tuple `{:utf8String, name}`, DER-encoding it itself. Handing it
      the pre-encoded binary now crashes instead.

  Both shapes produce BYTE-IDENTICAL output on the OTP that accepts them, so
  there is nothing to choose between them on the wire — only on which encoder
  is loaded. `request_info_der/2` therefore PROBES rather than branching on
  `:erlang.system_info(:otp_release)`: it tries the typed tuple, and falls back
  to `:public_key.der_encode(:X520CommonName, …)` when the encoder refuses it.
  A version check would have to be re-guessed at every OTP release; a probe
  asks the encoder that is actually loaded.

  The decode side flipped with it — OTP 27 reads the value back as raw DER,
  OTP 28 as the typed tuple — so `common_name/1` normalises BOTH, or `verify/1`
  would report the CN as `<<12, 13, "a.example.com">>` on OTP 27.

  ## The self-check

  `verify/1` is the parse-back proof this module is held to: DER-decode the
  request, re-encode its `certificationRequestInfo`, and check the signature
  against the public key CARRIED INSIDE the request. A CSR whose signature does
  not cover its own body is exactly what a CA rejects, so the round trip is the
  offline stand-in for the mint the human gate performs.
  """

  require Record

  @hrl "public_key/include/public_key.hrl"

  Record.defrecordp(
    :certification_request,
    :CertificationRequest,
    Record.extract(:CertificationRequest, from_lib: @hrl)
  )

  Record.defrecordp(
    :request_info,
    :CertificationRequestInfo,
    Record.extract(:CertificationRequestInfo, from_lib: @hrl)
  )

  Record.defrecordp(
    :subject_pk_info,
    :CertificationRequestInfo_subjectPKInfo,
    Record.extract(:CertificationRequestInfo_subjectPKInfo, from_lib: @hrl)
  )

  Record.defrecordp(
    :pk_algorithm,
    :CertificationRequestInfo_subjectPKInfo_algorithm,
    Record.extract(:CertificationRequestInfo_subjectPKInfo_algorithm, from_lib: @hrl)
  )

  Record.defrecordp(
    :signature_algorithm,
    :CertificationRequest_signatureAlgorithm,
    Record.extract(:CertificationRequest_signatureAlgorithm, from_lib: @hrl)
  )

  Record.defrecordp(
    :attribute,
    :CertificationRequestInfo_attributes_SETOF,
    Record.extract(:CertificationRequestInfo_attributes_SETOF, from_lib: @hrl)
  )

  Record.defrecordp(
    :rsa_private_key,
    :RSAPrivateKey,
    Record.extract(:RSAPrivateKey, from_lib: @hrl)
  )

  Record.defrecordp(
    :rsa_public_key,
    :RSAPublicKey,
    Record.extract(:RSAPublicKey, from_lib: @hrl)
  )

  # OIDs. Spelled out rather than pulled from a constants module because these
  # three are the whole vocabulary of a PKCS#10 request and a wrong one here is
  # a silent mis-encode, not a compile error.
  @oid_common_name {2, 5, 4, 3}
  @oid_rsa_encryption {1, 2, 840, 113_549, 1, 1, 1}
  @oid_sha256_with_rsa {1, 2, 840, 113_549, 1, 1, 11}
  @oid_extension_request {1, 2, 840, 113_549, 1, 9, 14}
  @oid_subject_alt_name {2, 5, 29, 17}

  # DER of ASN.1 NULL — the `parameters` every RSA AlgorithmIdentifier carries.
  @der_null <<5, 0>>

  @default_key_size 2048
  @public_exponent 65_537

  @typedoc """
  A generated request: the PEM `csr` to POST to Cloudflare, the PEM
  `private_key` that must land on the origin box beside the signed cert, and
  the `hostnames` the request covers.
  """
  @type t :: %{
          csr: String.t(),
          private_key: String.t(),
          hostnames: [String.t()]
        }

  @doc """
  Generate an RSA key pair and a PKCS#10 CSR covering `hostnames`.

  The FIRST hostname becomes the subject `CN`; every hostname (that one
  included) becomes a `dNSName` in the `subjectAltName` extension request.
  Returns `{:ok, t()}`, or `{:error, :no_hostnames}` / `{:error,
  {:invalid_hostname, term}}` — a blank or non-binary hostname is refused
  BEFORE any key is generated, since a CSR with an empty CN is a request no CA
  will sign and generating 2048 bits to discover that is pure waste.

  `opts`:

    * `:key_size` — RSA modulus bits (default `#{@default_key_size}`).
  """
  @spec generate([String.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def generate(hostnames, opts \\ [])

  def generate([], _opts), do: {:error, :no_hostnames}

  def generate(hostnames, opts) when is_list(hostnames) do
    # find_INDEX, not find: a `nil` hostname is itself an invalid value, and
    # `Enum.find/2` would hand it back as its own "nothing found" answer.
    case Enum.find_index(hostnames, &(not valid_hostname?(&1))) do
      nil ->
        key_size = Keyword.get(opts, :key_size, @default_key_size)
        private_key = :public_key.generate_key({:rsa, key_size, @public_exponent})

        {:ok,
         %{
           csr: build_csr(hostnames, private_key),
           private_key: encode_private_key(private_key),
           hostnames: hostnames
         }}

      index ->
        {:error, {:invalid_hostname, Enum.at(hostnames, index)}}
    end
  end

  @doc """
  Parse-back self-check: does `pem` decode as a PKCS#10 request whose signature
  covers its own `certificationRequestInfo`, verified with the public key the
  request itself carries?

  Returns `{:ok, %{common_name: cn, hostnames: [...]}}` — the subject CN and the
  `subjectAltName` dNSNames read back OUT of the DER, so a caller asserts what
  the bytes actually say rather than what it passed in — or `{:error, reason}`
  (`:not_a_csr` for anything that is not a single CERTIFICATE REQUEST PEM entry,
  `:bad_signature` when the signature does not verify, `:malformed` when the DER
  will not decode).
  """
  @spec verify(String.t()) ::
          {:ok, %{common_name: String.t() | nil, hostnames: [String.t()]}} | {:error, term()}
  def verify(pem) when is_binary(pem) do
    with {:ok, der} <- csr_der(pem),
         {:ok, request} <- decode_request(der) do
      info = certification_request(request, :certificationRequestInfo)
      signature = certification_request(request, :signature)
      info_der = :public_key.der_encode(:CertificationRequestInfo, info)
      public_key = public_key_from_info(info)

      if :public_key.verify(info_der, :sha256, signature, public_key) do
        {:ok, %{common_name: common_name(info), hostnames: san_hostnames(info)}}
      else
        {:error, :bad_signature}
      end
    end
  end

  ## Internals ───────────────────────────────────────────────────────────────

  defp build_csr(hostnames, private_key) do
    {info, info_der} = request_info_der(hostnames, private_key)

    request =
      certification_request(
        certificationRequestInfo: info,
        signatureAlgorithm:
          signature_algorithm(
            algorithm: @oid_sha256_with_rsa,
            parameters: {:asn1_OPENTYPE, @der_null}
          ),
        signature: :public_key.sign(info_der, :sha256, private_key)
      )

    der = :public_key.der_encode(:CertificationRequest, request)
    :public_key.pem_encode([{:CertificationRequest, der, :not_encrypted}])
  end

  # Builds the CertificationRequestInfo AND its DER together, because which
  # subject-value shape the loaded OTP accepts is only discoverable by encoding
  # (see the moduledoc). Returns the record in the shape that actually encoded,
  # so the outer CertificationRequest re-encodes the SAME bytes the signature
  # was taken over.
  defp request_info_der([common_name | _] = hostnames, private_key) do
    build = fn subject_value ->
      request_info(
        version: :v1,
        subject: {:rdnSequence, [[{:AttributeTypeAndValue, @oid_common_name, subject_value}]]},
        subjectPKInfo:
          subject_pk_info(
            algorithm:
              pk_algorithm(
                algorithm: @oid_rsa_encryption,
                parameters: {:asn1_OPENTYPE, @der_null}
              ),
            subjectPublicKey: :public_key.der_encode(:RSAPublicKey, public_key(private_key))
          ),
        attributes: [san_attribute(hostnames)]
      )
    end

    typed = build.({:utf8String, common_name})

    try do
      {typed, :public_key.der_encode(:CertificationRequestInfo, typed)}
    rescue
      # OTP 27: the value is an open type, so it wants the DER, not the tuple.
      # A second failure is a REAL fault and is left to propagate.
      _ ->
        pre_encoded =
          build.(:public_key.der_encode(:X520CommonName, {:utf8String, common_name}))

        {pre_encoded, :public_key.der_encode(:CertificationRequestInfo, pre_encoded)}
    end
  end

  # The extensionRequest attribute carrying a subjectAltName over every
  # hostname. `values` is an open type, so the DER'd Extensions must be wrapped
  # in {:asn1_OPENTYPE, _} — see the moduledoc's open-type trap.
  defp san_attribute(hostnames) do
    san =
      :public_key.der_encode(
        :SubjectAltName,
        Enum.map(hostnames, &{:dNSName, String.to_charlist(&1)})
      )

    extensions =
      :public_key.der_encode(:Extensions, [{:Extension, @oid_subject_alt_name, false, san}])

    attribute(type: @oid_extension_request, values: [{:asn1_OPENTYPE, extensions}])
  end

  defp public_key(private_key) do
    rsa_public_key(
      modulus: rsa_private_key(private_key, :modulus),
      publicExponent: rsa_private_key(private_key, :publicExponent)
    )
  end

  defp encode_private_key(private_key) do
    der = :public_key.der_encode(:RSAPrivateKey, private_key)
    :public_key.pem_encode([{:RSAPrivateKey, der, :not_encrypted}])
  end

  defp csr_der(pem) do
    case :public_key.pem_decode(pem) do
      [{:CertificationRequest, der, :not_encrypted}] -> {:ok, der}
      _ -> {:error, :not_a_csr}
    end
  rescue
    _ -> {:error, :not_a_csr}
  end

  defp decode_request(der) do
    {:ok, :public_key.der_decode(:CertificationRequest, der)}
  rescue
    _ -> {:error, :malformed}
  end

  defp public_key_from_info(info) do
    info
    |> request_info(:subjectPKInfo)
    |> subject_pk_info(:subjectPublicKey)
    |> then(&:public_key.der_decode(:RSAPublicKey, &1))
  end

  defp common_name(info) do
    case request_info(info, :subject) do
      {:rdnSequence, rdns} ->
        rdns
        |> List.flatten()
        |> Enum.find_value(fn
          {:AttributeTypeAndValue, @oid_common_name, value} -> directory_string(value)
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp directory_string({_type, value}) when is_binary(value), do: value
  defp directory_string({_type, value}) when is_list(value), do: List.to_string(value)

  # OTP 27 hands the attribute value back as the RAW DER of the DirectoryString
  # (it is an open type there). Returning it verbatim would make verify/1 report
  # a CN of <<12, 13, "a.example.com">>, so decode one level and re-normalise.
  defp directory_string(der) when is_binary(der) do
    :X520CommonName
    |> :public_key.der_decode(der)
    |> directory_string()
  rescue
    _ -> nil
  end

  defp directory_string(_), do: nil

  defp san_hostnames(info) do
    info
    |> request_info(:attributes)
    |> Kernel.||([])
    |> Enum.flat_map(fn
      # OTP DECODES the attribute as `:Attribute` even though the .hrl record it
      # is ENCODED from is `CertificationRequestInfo_attributes_SETOF` — match
      # both rather than guessing which side of the round trip we are on.
      {tag, @oid_extension_request, values}
      when tag in [:Attribute, :CertificationRequestInfo_attributes_SETOF] ->
        Enum.flat_map(values, &extension_hostnames/1)

      _ ->
        []
    end)
  end

  defp extension_hostnames({:asn1_OPENTYPE, der}), do: extension_hostnames(der)

  defp extension_hostnames(der) when is_binary(der) do
    :Extensions
    |> :public_key.der_decode(der)
    |> Enum.flat_map(fn
      {:Extension, @oid_subject_alt_name, _critical, san} ->
        san
        |> general_names()
        |> Enum.flat_map(fn
          {:dNSName, name} -> [to_string(name)]
          _ -> []
        end)

      _ ->
        []
    end)
  rescue
    _ -> []
  end

  defp extension_hostnames(_), do: []

  # The extension value is a binary when OTP left it opaque and an already
  # decoded GeneralNames list when it recognised the OID — both shapes reach
  # here depending on the decoder path, so normalise instead of assuming one.
  defp general_names(san) when is_binary(san), do: :public_key.der_decode(:SubjectAltName, san)
  defp general_names(san) when is_list(san), do: san
  defp general_names(_), do: []

  defp valid_hostname?(host), do: is_binary(host) and String.trim(host) != ""
end
