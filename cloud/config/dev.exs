import Config

# Configure your database — mirrors api/'s local Postgres creds
# (postgres/postgres on localhost:5432), separate database.
config :barkpark_cloud, BarkparkCloud.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "barkpark_cloud_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :elixir, :ansi_enabled, true

# azure-transport-wiring (task-2772b2cdd5001bfc) — THE DEV DECISION, RECORDED.
# `BarkparkCloud.Azure`'s moduledoc has always claimed "dev/test swaps in
# Azure.FakeClient"; that was true of test.exs only, so a dev box resolved
# Azure.RealClient and every azure read died :http_client_not_configured. The
# decision is to make the documented behaviour the real one: dev selects the
# in-memory FakeClient, exactly as test.exs does. Dev has no Azure tenant and no
# service principal, so RealClient in dev can only ever fail — and now that prod
# wires a real transport, leaving dev on RealClient would mean a dev box one
# stray credential away from live ARM calls. prod is untouched by this line: it
# has no dev.exs and keeps the RealClient default from `Azure.client/0`.
config :barkpark_cloud,
  azure_http_client: BarkparkCloud.Azure.FakeClient
