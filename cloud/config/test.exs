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
