defmodule Barkpark.EncryptedBinary do
  @moduledoc """
  An Ecto type that transparently encrypts a `binary` column at rest with
  `Barkpark.Vault` (Cloak AES-GCM). Stored as ciphertext in Postgres, surfaced
  as a plaintext binary on the struct. Used for TOTP secrets
  (`Barkpark.Accounts.User.totp_secret`) — the same cipher seam as
  `Barkpark.EncryptedMap`, for a scalar binary instead of a map.
  """
  use Cloak.Ecto.Binary, vault: Barkpark.Vault
end
