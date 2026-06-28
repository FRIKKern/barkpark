defmodule Barkpark.Vault do
  @moduledoc """
  The Cloak encryption vault — the single cipher source for every
  encrypted-at-rest field in Barkpark (e.g. plugin settings via
  `Barkpark.EncryptedMap`).

  Configured in `config/runtime.exs`: `Cloak.Ciphers.AES.GCM` keyed by
  `:crypto.hash(:sha256, BARKPARK_CLOAK_KEY)`. Production **raises** when
  `BARKPARK_CLOAK_KEY` is unset; dev/test fall back to a non-secret
  placeholder key (never use it in prod).
  """
  use Cloak.Vault, otp_app: :barkpark
end
