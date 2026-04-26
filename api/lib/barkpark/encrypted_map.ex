defmodule Barkpark.EncryptedMap do
  use Cloak.Ecto.Map, vault: Barkpark.Vault
end
