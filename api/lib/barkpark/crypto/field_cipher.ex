defmodule Barkpark.Crypto.FieldCipher do
  @moduledoc """
  Encrypt/decrypt a single content-field value at rest, using the per-scope DEK
  from `Barkpark.Crypto.DataKeys`.

  A plaintext value becomes a self-describing **envelope map** stored in place of
  the field inside `documents.content`:

      %{"_bpenc" => 1, "k" => <dek_version>, "v" => Base64(iv ‖ tag ‖ ct)}

  AES-256-GCM with a fresh 12-byte IV per call; the **scope is the AAD**, so a
  ciphertext can't be lifted from one dataset/tenant and replayed under another.
  GCM authentication means any tamper → `:error` (fails closed). The `"k"`
  (DEK version) lets `decrypt/2` find the right key after rotation.

  Values are JSON-encoded before encryption so non-string fields (numbers, maps,
  lists) round-trip exactly.

  @canonical capability:field-encryption aka:encrypt-field,field-cipher,encrypted-field,secrets-at-rest
  """
  alias Barkpark.Crypto.DataKeys

  @marker "_bpenc"
  @version 1
  @iv_bytes 12
  @tag_bytes 16

  @doc "True when `value` is an encryption envelope produced by `encrypt/2`."
  @spec encrypted?(term()) :: boolean()
  def encrypted?(%{@marker => _}), do: true
  def encrypted?(_), do: false

  @doc """
  Encrypt `value` under the active DEK for `scope`. Returns the envelope map.
  Already-encrypted values pass through untouched (idempotent — re-saving a doc
  whose secret field is already ciphertext does not double-encrypt).
  """
  @spec encrypt(term(), String.t()) :: map()
  def encrypt(value, _scope) when is_map(value) and is_map_key(value, @marker), do: value

  def encrypt(value, scope) when is_binary(scope) do
    {version, dek} = DataKeys.active_dek(scope)
    iv = :crypto.strong_rand_bytes(@iv_bytes)
    plaintext = Jason.encode!(value)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, dek, iv, plaintext, scope, true)

    %{@marker => @version, "k" => version, "v" => Base.encode64(iv <> tag <> ct)}
  end

  @doc """
  Decrypt an envelope produced by `encrypt/2` back to the original value.
  `{:ok, value}` or `:error` (unknown key version, bad payload, or tamper).
  A non-envelope value returns `{:ok, value}` unchanged (so callers can decrypt
  blindly over a content map).
  """
  @spec decrypt(term(), String.t()) :: {:ok, term()} | :error
  def decrypt(%{@marker => @version, "k" => version, "v" => encoded}, scope)
      when is_binary(scope) do
    with {:ok, dek} <- DataKeys.dek_for_version(scope, version),
         {:ok, <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ct::binary>>} <-
           Base.decode64(encoded),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, dek, iv, ct, scope, tag, false),
         {:ok, value} <- Jason.decode(plaintext) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  def decrypt(%{@marker => _}, _scope), do: :error
  def decrypt(value, _scope), do: {:ok, value}
end
