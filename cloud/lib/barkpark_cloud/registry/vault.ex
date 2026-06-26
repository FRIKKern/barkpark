defmodule BarkparkCloud.Registry.Vault do
  @moduledoc """
  The encrypt-at-rest SEAM for connected-provider secrets (the API token a Team
  links for, e.g., its Hetzner cloud account). A `Provider`'s `encrypted_token`
  column NEVER holds plaintext — it holds the Base64 of `encrypt/1`'s output.

  ## What this is — and what it deliberately is NOT

  This is AES-256-GCM with a SINGLE key loaded from config
  (`config :barkpark_cloud, #{inspect(__MODULE__)}, key: <base64-32-bytes>`).
  GCM gives us authenticated encryption: tamper with the ciphertext and
  `decrypt/1` fails closed rather than returning garbage. A fresh 12-byte IV is
  drawn per encryption, so encrypting the same token twice yields different
  ciphertext (no equality leak).

  **Real key management is a later / human concern.** There is no rotation, no
  KMS/HSM, no per-tenant key derivation, no key versioning here. Those land when
  a human wires the control plane to a real secrets backend. What ships now is
  the *seam*: every provider token goes through `encrypt/1` on the way in and
  `decrypt/1` on the way out, so the storage format is already encrypted and the
  call sites already exist. Swapping the key source later is a one-module change.

  ## Wire format

  `encrypt/1` returns `Base.encode64(iv <> tag <> ciphertext)`:

      ┌──────────┬───────────┬──────────────┐
      │ IV (12B) │ tag (16B) │ ciphertext   │
      └──────────┴───────────┴──────────────┘

  `decrypt/1` reverses it and verifies the tag.
  """

  @aad "barkpark-cloud-registry-provider-token"
  @iv_bytes 12
  @tag_bytes 16

  @doc """
  Encrypt `plaintext` (a binary) under the configured key. Returns a Base64
  string safe to store in a text/varchar column. Raises if no key is configured.
  """
  @spec encrypt(binary()) :: String.t()
  def encrypt(plaintext) when is_binary(plaintext) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, @aad, true)

    Base.encode64(iv <> tag <> ciphertext)
  end

  @doc """
  Decrypt a value produced by `encrypt/1`. Returns `{:ok, plaintext}` or
  `:error` (bad Base64, truncated payload, or a failed authentication tag —
  GCM fails closed on any tampering).
  """
  @spec decrypt(String.t()) :: {:ok, binary()} | :error
  def decrypt(encoded) when is_binary(encoded) do
    with {:ok, <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>>} <-
           Base.decode64(encoded),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, @aad, tag, false) do
      {:ok, plaintext}
    else
      _ -> :error
    end
  end

  # 32-byte AES-256 key, decoded from the Base64 value in config. Resolved at
  # call time (not compile time) so prod's runtime.exs override is honoured.
  defp key do
    config = Application.get_env(:barkpark_cloud, __MODULE__, [])

    encoded =
      config[:key] ||
        raise """
        #{inspect(__MODULE__)} is not configured. Set:
          config :barkpark_cloud, #{inspect(__MODULE__)}, key: <base64 32-byte key>
        """

    case Base.decode64(encoded) do
      {:ok, <<key::binary-size(32)>>} ->
        key

      _ ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} :key must be a Base64-encoded 32-byte (AES-256) key"
    end
  end
end
