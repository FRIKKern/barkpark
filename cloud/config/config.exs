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

# Billing (cloud-5): which BarkparkCloud.Billing.Gateway runs. Default to the
# in-memory StubGateway — no network, deterministic ids, €0 spend — so the whole
# pay-once go-live path is buildable and testable without any payment provider.
# runtime.exs swaps in BarkparkCloud.Billing.StripeGateway in prod when
# STRIPE_SECRET_KEY is set. Live keys + the per-plan price ids are HUMAN task
# cloud-17. See BarkparkCloud.Billing.Gateway.
config :barkpark_cloud, BarkparkCloud.Billing, gateway: BarkparkCloud.Billing.StubGateway

# Web (cloud-12a): the minimal JSON HTTP API (Plug.Router + Bandit) that exposes
# the Accounts/Registry/Billing contexts to the agent (cloud-10) and the Go CLI
# client (cloud-12b). `server` controls whether the Bandit listener joins the
# supervision tree; `port` is the listen port. Defaults here; test.exs sets
# `server: false` (the router is driven directly via Plug.Test), runtime.exs
# reads PORT in prod. NOT Phoenix — there is no dashboard yet (a later task).
config :barkpark_cloud, BarkparkCloud.Web.Endpoint, server: true, port: 4100

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
