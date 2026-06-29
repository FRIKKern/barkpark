defmodule Barkpark.Crypto.KeyProvider do
  @moduledoc """
  The pluggable key-management SEAM for envelope encryption.

  Barkpark encrypts content fields with per-scope **Data Encryption Keys**
  (DEKs). The DEKs themselves are never stored in the clear — each is *wrapped*
  (encrypted) by a master **Key Encryption Key** (KEK) that a `KeyProvider`
  owns. This indirection is what makes the system rotatable and portable:

    * **KEK rotation** re-wraps every DEK (cheap — no content is touched).
    * **Swapping the backend** (env-KEK → HashiCorp Vault → cloud KMS) is a
      one-module change behind this behaviour; nothing in `Content` knows or
      cares which provider is configured.

  The default implementation is `Barkpark.Crypto.LocalKek` (master key from the
  `BARKPARK_KEK` env). To move to a managed backend, implement this behaviour
  and point `config :barkpark, :key_provider, MyProvider` at it.

  ## Contract

    * `wrap/1`   — encrypt a raw DEK; returns an opaque, storable string.
    * `unwrap/1` — reverse `wrap/1`; `{:ok, dek}` or `:error` (fails closed).
    * `kek_version/0` — the current KEK generation, recorded alongside each
      wrapped DEK so a rotation can tell which KEK sealed it.

  Implementations MUST fail closed (`:error`, never garbage) on any tampering.
  """

  @doc "Encrypt a raw DEK binary under the current KEK. Returns a storable string."
  @callback wrap(dek :: binary()) :: String.t()

  @doc "Decrypt a value produced by `wrap/1`. Fails closed."
  @callback unwrap(wrapped :: String.t()) :: {:ok, binary()} | :error

  @doc "The current KEK generation (a monotonically increasing integer)."
  @callback kek_version() :: non_neg_integer()

  @doc "The configured provider module (defaults to `Barkpark.Crypto.LocalKek`)."
  @spec impl() :: module()
  def impl, do: Application.get_env(:barkpark, :key_provider, Barkpark.Crypto.LocalKek)

  @doc "Wrap a DEK with the configured provider."
  @spec wrap(binary()) :: String.t()
  def wrap(dek) when is_binary(dek), do: impl().wrap(dek)

  @doc "Unwrap a DEK with the configured provider."
  @spec unwrap(String.t()) :: {:ok, binary()} | :error
  def unwrap(wrapped) when is_binary(wrapped), do: impl().unwrap(wrapped)

  @doc "Current KEK generation from the configured provider."
  @spec kek_version() :: non_neg_integer()
  def kek_version, do: impl().kek_version()
end
