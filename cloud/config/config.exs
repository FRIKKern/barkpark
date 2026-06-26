# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.
import Config

config :barkpark_cloud,
  ecto_repos: [BarkparkCloud.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing
config :ecto, json_library: Jason

# Registry (cloud-9): the at-rest encryption key for connected-provider tokens
# (e.g. the Hetzner API token a Team links). This is a 32-byte AES-256-GCM key,
# Base64-encoded. The value here is a DEV/TEST default ONLY — prod overrides it
# from the REGISTRY_ENCRYPTION_KEY env var in runtime.exs. Real key management
# (rotation, a KMS/HSM, per-tenant keys) is a later/human concern; this is the
# encrypt-at-rest SEAM, deliberately simple. See BarkparkCloud.Registry.Vault.
config :barkpark_cloud, BarkparkCloud.Registry.Vault,
  key: "kvm81OuQQi9o5bZpN2Lb2yKkNH+Mi5LjaJtKc9nAMi0="

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
