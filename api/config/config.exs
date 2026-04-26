# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :barkpark,
  ecto_repos: [Barkpark.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configure the endpoint
config :barkpark, BarkparkWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BarkparkWeb.ErrorHTML, json: BarkparkWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Barkpark.PubSub,
  live_view: [signing_salt: "MXGKAyTI"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :barkpark, :idempotency, ttl_seconds: 86_400

config :barkpark, :rate_limits,
  read_per_minute: 300,
  write_per_minute: 60,
  datasets: %{}

config :barkpark, :preview,
  secret: "dev-preview-secret-change-in-prod-please-32-chars",
  ttl_seconds: 600,
  issuer: "barkpark"

# Fallback CORS allowlist for API routes without a dataset path segment
# (e.g. /v1/meta, /media without ?dataset=, legacy /api/*).
config :barkpark, :default_cors_origins, []

config :barkpark, Oban,
  repo: Barkpark.Repo,
  queues: [default: 10, bokbasen: 4, plugins: 6],
  plugins: [{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
