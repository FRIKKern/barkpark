defmodule Barkpark.EncryptedBinary do
  @moduledoc """
  An Ecto type that transparently encrypts a single `binary`/`string` column at
  rest with `Barkpark.Vault` (Cloak AES-GCM). Stored as ciphertext in Postgres,
  surfaced as a plaintext string on the struct. The single-value sibling of
  `Barkpark.EncryptedMap` — used for one-string secrets
  (`Barkpark.Secrets.SecretRecord`).
  """
  use Cloak.Ecto.Binary, vault: Barkpark.Vault
end
