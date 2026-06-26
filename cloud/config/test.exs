import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :barkpark_cloud, BarkparkCloud.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "barkpark_cloud_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Speed up the test suite: the default 12 bcrypt log_rounds (~250ms/hash) is
# overkill for tests. 1 round keeps register/verify cycles fast while still
# exercising the real Bcrypt code path.
config :bcrypt_elixir, log_rounds: 1

# Print only warnings and errors during test
config :logger, level: :warning

# Web (cloud-12a): do NOT boot the Bandit HTTP listener in test — the router is
# exercised directly via Plug.Test (`conn(...) |> Router.call(@opts)`), so no
# live socket is needed and the suite stays hermetic / port-conflict-free.
config :barkpark_cloud, BarkparkCloud.Web.Endpoint, server: false

# Billing (cloud-5): tests run the whole pay-once go-live path through the
# in-memory StubGateway — €0, deterministic ids, no network. (config.exs already
# defaults to StubGateway; this is the explicit, env-local statement of intent.)
config :barkpark_cloud, BarkparkCloud.Billing, gateway: BarkparkCloud.Billing.StubGateway

# A FAKE Stripe secret key so the StripeGateway request-builder test can assert
# the exact Authorization header without reaching the wire. There is no
# http_client configured, so even if a callback tried to send, it would fail
# closed (:http_client_not_configured) rather than spend. The LIVE key is HUMAN
# task cloud-17.
config :barkpark_cloud, BarkparkCloud.Billing.StripeGateway,
  secret_key: "sk_test_FAKE_cloud5",
  webhook_secret: "whsec_test_FAKE_cloud5"
