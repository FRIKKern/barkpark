defmodule Barkpark.EncryptedMap do
  @moduledoc """
  An Ecto type that transparently encrypts a `map` column at rest with
  `Barkpark.Vault` (Cloak AES-GCM). Stored as ciphertext in Postgres, surfaced
  as a plaintext map on the struct. Used for sensitive plugin settings
  (`Barkpark.Plugins.SettingsRecord`).
  """
  use Cloak.Ecto.Map, vault: Barkpark.Vault
end
