defmodule BarkparkCloud.Push.JWTTest do
  @moduledoc """
  The two provider signatures the push relay mints, and the ONE trap in them.

  ES256's trap is not the crypto, it is the ENCODING: `:public_key.sign/3`
  returns a DER `ECDSA-Sig-Value` SEQUENCE (70–72 bytes, variable), while JWS
  requires the raw fixed-width `R || S` (exactly 64). Handing Apple the DER
  bytes produces a 403 `InvalidProviderToken` that reads identically to a wrong
  Key ID — hours of debugging the wrong thing. The `der_to_raw/1` legs below
  pin all three width cases, and the `es256/3` leg pins the 64-byte outcome, so
  a regression fails here instead of at Apple.

  RS256 is verified END TO END (sign here, verify with the matching public key)
  because it can be: PKCS#1 v1.5 output is deterministic and the public half is
  recoverable from the private record.
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Push.JWT

  defp ec_pem do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])
  end

  defp rsa_key, do: :public_key.generate_key({:rsa, 2048, 65_537})

  defp rsa_pem(key),
    do: :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

  # {:RSAPrivateKey, version, modulus, publicExponent, ...} — the public half is
  # elements 2 and 3 of the record.
  defp rsa_public(key), do: {:RSAPublicKey, elem(key, 2), elem(key, 3)}

  defp decode_segment(seg), do: seg |> Base.url_decode64!(padding: false) |> Jason.decode!()

  describe "der_to_raw/1 — the ES256 encoding trap" do
    test "a full-width {r, s} passes through as exactly 64 bytes" do
      r = :binary.decode_unsigned(:binary.copy(<<0x7F>>, 32))
      s = :binary.decode_unsigned(:binary.copy(<<0x11>>, 32))
      der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})

      raw = JWT.der_to_raw(der)

      assert byte_size(raw) == 64
      assert binary_part(raw, 0, 32) == :binary.copy(<<0x7F>>, 32)
      assert binary_part(raw, 32, 32) == :binary.copy(<<0x11>>, 32)
    end

    test "a SHORT r is left-padded to 32 bytes (DER drops leading zero bytes)" do
      der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", 1, 2})

      raw = JWT.der_to_raw(der)

      assert byte_size(raw) == 64
      assert binary_part(raw, 0, 32) == <<0::248, 1>>
      assert binary_part(raw, 32, 32) == <<0::248, 2>>
    end

    test "a HIGH-BIT r loses DER's 0x00 sign byte instead of overflowing to 33" do
      # An ASN.1 INTEGER whose top bit is set gains a leading 0x00 so it is not
      # read as negative — 33 bytes on the wire for a 32-byte value. Naively
      # concatenating those gives a 65/66-byte signature Apple rejects.
      high = :binary.copy(<<0xFF>>, 32)
      r = :binary.decode_unsigned(high)
      der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, r})

      raw = JWT.der_to_raw(der)

      assert byte_size(raw) == 64
      assert binary_part(raw, 0, 32) == high
      assert binary_part(raw, 32, 32) == high
    end
  end

  describe "es256/3" do
    test "produces a 3-segment JWT with the APNs header and a 64-byte signature" do
      {:ok, jwt} =
        JWT.es256(%{"iss" => "TEAM123456", "iat" => 1_700_000_000}, ec_pem(), "KEYID12345")

      assert [header_seg, claims_seg, sig_seg] = String.split(jwt, ".")

      assert decode_segment(header_seg) == %{
               "alg" => "ES256",
               "kid" => "KEYID12345",
               "typ" => "JWT"
             }

      assert decode_segment(claims_seg) == %{"iss" => "TEAM123456", "iat" => 1_700_000_000}

      # THE regression tripwire: DER signatures are 70–72 bytes, JWS ES256 is
      # exactly 64. If this ever reads 70, der_to_raw/1 stopped being applied.
      assert byte_size(Base.url_decode64!(sig_seg, padding: false)) == 64
    end

    test "an unparseable key is an error tuple, never a raise" do
      assert {:error, _} = JWT.es256(%{"iss" => "T"}, "not a pem at all", "KID")
    end
  end

  describe "rs256/2" do
    test "signs a verifiable RS256 assertion with the Google claim set" do
      key = rsa_key()
      claims = %{"iss" => "svc@project.iam.gserviceaccount.com", "iat" => 1, "exp" => 3601}

      {:ok, jwt} = JWT.rs256(claims, rsa_pem(key))

      assert [header_seg, claims_seg, sig_seg] = String.split(jwt, ".")
      assert decode_segment(header_seg) == %{"alg" => "RS256", "typ" => "JWT"}
      assert decode_segment(claims_seg) == claims

      signing_input = header_seg <> "." <> claims_seg
      signature = Base.url_decode64!(sig_seg, padding: false)
      assert :public_key.verify(signing_input, :sha256, signature, rsa_public(key))
    end

    test "a tampered payload fails verification (the signature is over both segments)" do
      key = rsa_key()
      {:ok, jwt} = JWT.rs256(%{"iss" => "a"}, rsa_pem(key))
      [header_seg, _claims_seg, sig_seg] = String.split(jwt, ".")

      forged = Base.url_encode64(Jason.encode!(%{"iss" => "attacker"}), padding: false)
      signature = Base.url_decode64!(sig_seg, padding: false)

      refute :public_key.verify(header_seg <> "." <> forged, :sha256, signature, rsa_public(key))
    end
  end
end
