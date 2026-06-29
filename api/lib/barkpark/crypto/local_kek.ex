defmodule Barkpark.Crypto.LocalKek do
  @moduledoc """
  The default `Barkpark.Crypto.KeyProvider`: a master KEK loaded from config,
  wrapping DEKs with AES-256-GCM.

  Mirrors the proven `cloud/`-side `BarkparkCloud.Registry.Vault` GCM pattern and
  the core `Barkpark.Vault` key-loading discipline (key resolved at call time so
  `runtime.exs` overrides are honoured; prod **raises** when unset, dev/test fall
  back to a non-secret placeholder).

  ## Config

      config :barkpark, #{inspect(__MODULE__)},
        key: <base64 32-byte key>,   # from BARKPARK_KEK in runtime.exs
        version: 1                    # KEK generation; bump on rotation

  ## Wire format — `wrap/1` returns `Base64(iv ‖ tag ‖ ciphertext)`

      ┌──────────┬───────────┬──────────────┐
      │ IV (12B) │ tag (16B) │ wrapped DEK  │
      └──────────┴───────────┴──────────────┘

  GCM is authenticated: any tamper makes `unwrap/1` fail closed. A fresh IV per
  wrap means the same DEK wraps to different bytes each time (no equality leak).

  ## Rotation

  Bumping `:version` (with a fresh `:key`) and re-wrapping every DEK via
  `Barkpark.Crypto.DataKeys.rewrap_all/0` rotates the KEK without re-encrypting a
  single byte of content. Provided as the seam; the operational tooling lands in
  the hardening phase.
  """
  @behaviour Barkpark.Crypto.KeyProvider

  @aad "barkpark-kek-wrap-v1"
  @iv_bytes 12
  @tag_bytes 16

  @impl true
  def wrap(dek) when is_binary(dek) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, dek, @aad, true)
    Base.encode64(iv <> tag <> ct)
  end

  @impl true
  def unwrap(encoded) when is_binary(encoded) do
    with {:ok, <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ct::binary>>} <-
           Base.decode64(encoded),
         dek when is_binary(dek) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ct, @aad, tag, false) do
      {:ok, dek}
    else
      _ -> :error
    end
  end

  @impl true
  def kek_version do
    Application.get_env(:barkpark, __MODULE__, [])
    |> Keyword.get(:version, 1)
  end

  # 32-byte AES-256 master key, decoded from the Base64 config value. Resolved at
  # call time so prod's runtime.exs override is honoured.
  defp key do
    config = Application.get_env(:barkpark, __MODULE__, [])

    encoded =
      config[:key] ||
        raise """
        #{inspect(__MODULE__)} is not configured. Set:
          config :barkpark, #{inspect(__MODULE__)}, key: <base64 32-byte key>
        (wired from BARKPARK_KEK in config/runtime.exs).
        """

    case Base.decode64(encoded) do
      {:ok, <<k::binary-size(32)>>} ->
        k

      _ ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} :key must be a Base64-encoded 32-byte (AES-256) key"
    end
  end
end
