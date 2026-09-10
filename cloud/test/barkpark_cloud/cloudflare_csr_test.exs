defmodule BarkparkCloud.Cloudflare.CSRTest do
  @moduledoc """
  The hand-rolled PKCS#10 generator (cf-origin-ca-wire-and-provision). PURE — no
  DB, no network, no `openssl` binary. The load-bearing test is the PARSE-BACK:
  a CSR is only useful if a CA can decode it and check that its signature covers
  its own body, so every assertion here reads values BACK OUT of the DER rather
  than trusting the inputs that went in.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Cloudflare.CSR

  # 1024 keeps the suite fast; the shape under test (encoding, signature
  # coverage, SAN) is identical at 2048, which is the module default.
  @key_size 1024

  describe "generate/2" do
    test "produces a PEM CERTIFICATE REQUEST that parses back and self-verifies" do
      assert {:ok, %{csr: csr, private_key: key, hostnames: hosts}} =
               CSR.generate(["example.com", "*.example.com"], key_size: @key_size)

      assert csr =~ "-----BEGIN CERTIFICATE REQUEST-----"
      assert csr =~ "-----END CERTIFICATE REQUEST-----"
      assert key =~ "-----BEGIN RSA PRIVATE KEY-----"
      assert hosts == ["example.com", "*.example.com"]

      # THE self-check: decode, re-encode the info, verify the signature with the
      # public key carried inside the request.
      assert {:ok, %{common_name: "example.com", hostnames: san}} = CSR.verify(csr)
      assert san == ["example.com", "*.example.com"]
    end

    test "the emitted private key is a usable RSA key (not a truncated blob)" do
      assert {:ok, %{private_key: pem}} = CSR.generate(["a.example.com"], key_size: @key_size)
      assert [{:RSAPrivateKey, der, :not_encrypted}] = :public_key.pem_decode(pem)

      assert {:RSAPrivateKey, _, _modulus, _e, _d, _p, _q, _, _, _, _} =
               :public_key.der_decode(:RSAPrivateKey, der)
    end

    test "the FIRST hostname is the subject CN, every hostname is a SAN dNSName" do
      assert {:ok, %{csr: csr}} =
               CSR.generate(["one.example.com", "two.example.com", "three.example.com"],
                 key_size: @key_size
               )

      assert {:ok, %{common_name: "one.example.com", hostnames: hosts}} = CSR.verify(csr)
      assert hosts == ["one.example.com", "two.example.com", "three.example.com"]
    end

    test "the CN lands as a UTF8String TLV in the RAW DER on whichever OTP built it" do
      cn = "a.example.com"
      assert {:ok, %{csr: csr}} = CSR.generate([cn], key_size: @key_size)
      [{:CertificationRequest, der, :not_encrypted}] = :public_key.pem_decode(csr)

      # 0x0C is the UTF8String tag, then the length, then the bytes. This is the
      # ONE assertion here that does not route through OTP's decoder, which is
      # exactly why it is worth writing: the subject AttributeTypeAndValue value
      # is an open type on OTP 27 (wants pre-encoded DER) and a typed tuple on
      # OTP 28 (wants {:utf8String, cn}), and request_info_der/2 probes for the
      # shape the loaded encoder accepts. If the two shapes ever stop producing
      # byte-identical output, or the probe falls through to a CN-less request,
      # this reds while every decoder-mediated assertion below stays green.
      assert :binary.match(der, <<12, byte_size(cn)>> <> cn) != :nomatch

      # …and the decode side normalises it back to a plain hostname rather than
      # handing the caller the raw DER bytes, which is what OTP 27 returns.
      assert {:ok, %{common_name: ^cn}} = CSR.verify(csr)
    end

    test "each generate/2 call mints a FRESH key pair (no reuse across sites)" do
      {:ok, a} = CSR.generate(["a.example.com"], key_size: @key_size)
      {:ok, b} = CSR.generate(["a.example.com"], key_size: @key_size)
      refute a.private_key == b.private_key
      refute a.csr == b.csr
    end

    test "an empty hostname list is refused before any key is generated" do
      assert {:error, :no_hostnames} = CSR.generate([])
    end

    test "a blank or non-binary hostname is refused (an empty CN is unsignable)" do
      assert {:error, {:invalid_hostname, "  "}} = CSR.generate(["ok.example.com", "  "])
      assert {:error, {:invalid_hostname, nil}} = CSR.generate([nil])
    end
  end

  describe "verify/1 — the mutation the parse-back exists to catch" do
    test "a CORRUPTED signature is rejected as :bad_signature" do
      {:ok, %{csr: csr}} = CSR.generate(["example.com"], key_size: @key_size)
      assert {:ok, _} = CSR.verify(csr)

      [{:CertificationRequest, der, :not_encrypted}] = :public_key.pem_decode(csr)
      request = :public_key.der_decode(:CertificationRequest, der)

      # Flip one bit of the signature and RE-ENCODE: the DER is still perfectly
      # well-formed PKCS#10, so ONLY the signature check can catch this. If
      # verify/1 ever stops verifying, this test is the one that reds.
      signature = elem(request, 3)
      <<first, rest::binary>> = signature
      tampered = put_elem(request, 3, <<Bitwise.bxor(first, 0xFF), rest::binary>>)

      tampered_pem =
        :public_key.pem_encode([
          {:CertificationRequest, :public_key.der_encode(:CertificationRequest, tampered),
           :not_encrypted}
        ])

      assert {:error, :bad_signature} = CSR.verify(tampered_pem)
    end

    test "a signature over a DIFFERENT body is rejected (bodies are not swappable)" do
      {:ok, %{csr: a}} = CSR.generate(["a.example.com"], key_size: @key_size)
      {:ok, %{csr: b}} = CSR.generate(["b.example.com"], key_size: @key_size)

      [{:CertificationRequest, a_der, _}] = :public_key.pem_decode(a)
      [{:CertificationRequest, b_der, _}] = :public_key.pem_decode(b)

      a_req = :public_key.der_decode(:CertificationRequest, a_der)
      b_req = :public_key.der_decode(:CertificationRequest, b_der)

      # b's body under a's signature.
      frankenstein = put_elem(b_req, 3, elem(a_req, 3))

      pem =
        :public_key.pem_encode([
          {:CertificationRequest, :public_key.der_encode(:CertificationRequest, frankenstein),
           :not_encrypted}
        ])

      assert {:error, :bad_signature} = CSR.verify(pem)
    end

    test "a non-CSR PEM (and plain garbage) is :not_a_csr, never a crash" do
      assert {:error, :not_a_csr} = CSR.verify("not a pem at all")
      assert {:error, :not_a_csr} = CSR.verify("")

      {:ok, %{private_key: key_pem}} = CSR.generate(["a.example.com"], key_size: @key_size)
      assert {:error, :not_a_csr} = CSR.verify(key_pem)
    end
  end
end
