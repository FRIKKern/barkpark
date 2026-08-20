defmodule BarkparkCloud.Push.JWT do
  @moduledoc """
  The two JWS signatures the push relay needs, on OTP's `:public_key` alone —
  no `joken`/`jose` dependency.

    * **ES256** — the APNs provider authentication token (`.p8` auth key,
      ECDSA P-256 + SHA-256).
    * **RS256** — the Google service-account assertion FCM HTTP v1 exchanges
      for an OAuth2 access token (RSA PKCS#1 v1.5 + SHA-256).

  ## The ES256 trap this module exists to contain

  `:public_key.sign/3` returns a **DER-encoded `ECDSA-Sig-Value` SEQUENCE**
  (`{r, s}` as ASN.1 INTEGERs, variable length, sign-padded). JWS ES256 requires
  the **raw `R || S` fixed-width concatenation**, 32 bytes each, 64 total
  (RFC 7518 §3.4). Handing Apple the DER bytes yields a signature Apple rejects
  with `InvalidProviderToken` — a 403 that looks exactly like "wrong key id" and
  costs a day. `der_to_raw/1` below does the conversion (and is directly
  unit-tested, verify-side, in `push/jwt_test.exs`).
  """

  @doc """
  Sign `claims` as an ES256 JWT with the PEM contents of an APNs `.p8` auth key.
  `kid` is the APNs Key ID; it rides in the JOSE header, where Apple looks for
  it. Returns `{:ok, compact_jwt}` or `{:error, reason}`.
  """
  @spec es256(map(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def es256(claims, pem, kid) when is_map(claims) and is_binary(pem) and is_binary(kid) do
    with {:ok, key} <- decode_pem(pem) do
      header = %{"alg" => "ES256", "kid" => kid, "typ" => "JWT"}
      input = signing_input(header, claims)

      try do
        signature = :public_key.sign(input, :sha256, key)
        {:ok, input <> "." <> b64(der_to_raw(signature))}
      rescue
        e -> {:error, {:sign_failed, Exception.message(e)}}
      end
    end
  end

  @doc """
  Sign `claims` as an RS256 JWT with a PKCS#8 RSA private key PEM (the
  `private_key` field of a Google service-account JSON).
  """
  @spec rs256(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def rs256(claims, pem) when is_map(claims) and is_binary(pem) do
    with {:ok, key} <- decode_pem(pem) do
      header = %{"alg" => "RS256", "typ" => "JWT"}
      input = signing_input(header, claims)

      try do
        signature = :public_key.sign(input, :sha256, key)
        {:ok, input <> "." <> b64(signature)}
      rescue
        e -> {:error, {:sign_failed, Exception.message(e)}}
      end
    end
  end

  @doc """
  Convert a DER `ECDSA-Sig-Value` into the raw fixed-width `R || S` JWS form.
  Public because it is the single trap in ES256 and deserves a direct test.
  """
  @spec der_to_raw(binary()) :: binary()
  def der_to_raw(der) do
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    pad32(r) <> pad32(s)
  end

  # An ASN.1 INTEGER carries no fixed width: a small r encodes short, and a
  # high-bit-set r gains a leading 0x00 sign byte. JWS wants exactly 32 bytes
  # per half — left-pad the short case, drop the sign byte in the long case.
  defp pad32(int) when is_integer(int) do
    bin = :binary.encode_unsigned(int)

    case byte_size(bin) do
      32 -> bin
      n when n < 32 -> :binary.copy(<<0>>, 32 - n) <> bin
      n -> binary_part(bin, n - 32, 32)
    end
  end

  defp signing_input(header, claims) do
    b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(claims))
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  # A `.p8` / service-account PEM is PKCS#8 (`BEGIN PRIVATE KEY`).
  # `pem_entry_decode/1` unwraps PrivateKeyInfo to the concrete
  # `#'ECPrivateKey'{}` / `#'RSAPrivateKey'{}` record `sign/3` needs. A
  # `BEGIN EC PRIVATE KEY` / `BEGIN RSA PRIVATE KEY` (PKCS#1/SEC1) PEM decodes
  # directly and is accepted too — operators paste what their console gave them.
  defp decode_pem(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] ->
        try do
          {:ok, :public_key.pem_entry_decode(entry)}
        rescue
          e -> {:error, {:bad_key, Exception.message(e)}}
        end

      [] ->
        {:error, :no_pem_entry}
    end
  end
end
