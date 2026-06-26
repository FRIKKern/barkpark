import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
#
# In prod the control plane's database is wired entirely from the
# environment. DATABASE_URL points at the control plane's own Postgres —
# the store of metadata about many Barkpark instances, never customer
# content.
if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  config :barkpark_cloud, BarkparkCloud.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # Registry (cloud-9): the at-rest key for connected-provider tokens. In prod
  # the dev/test default in config.exs is REQUIRED to be overridden — a Base64
  # 32-byte AES-256-GCM key from REGISTRY_ENCRYPTION_KEY. Generate one with:
  #     mix run -e 'IO.puts(:crypto.strong_rand_bytes(32) |> Base.encode64())'
  # Real key management (rotation, KMS) is a later/human concern.
  registry_key =
    System.get_env("REGISTRY_ENCRYPTION_KEY") ||
      raise """
      environment variable REGISTRY_ENCRYPTION_KEY is missing.
      Generate a Base64 32-byte key:
        mix run -e 'IO.puts(:crypto.strong_rand_bytes(32) |> Base.encode64())'
      """

  config :barkpark_cloud, BarkparkCloud.Registry.Vault, key: registry_key
end
