defmodule Barkpark.ChatHosts.Security do
  @moduledoc false

  @secret_bytes 32

  def mint_secret do
    @secret_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  def hash_secret(secret) when is_binary(secret), do: :crypto.hash(:sha256, secret)

  def secret_matches?(secret, expected_hash)
      when is_binary(secret) and is_binary(expected_hash) and byte_size(expected_hash) == 32 do
    Plug.Crypto.secure_compare(hash_secret(secret), expected_hash)
  end

  def secret_matches?(_, _), do: false
end
