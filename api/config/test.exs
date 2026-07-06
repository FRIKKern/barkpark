import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :barkpark, Barkpark.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "barkpark_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  # Per-hold watchdog. At the 15s default, a legitimately long single hold
  # under saturated-suite CPU (the EDItEUR/Thema codelist seed's big JSONB
  # register) gets force-disconnected mid-query — killing a pool connection
  # and starving concurrent tests' setups (same poisoning as the orphan-task
  # leak drained by DataCase.setup_sandbox). 45s stays under ExUnit's 60s
  # test timeout so a truly hung test still fails as a test, not a disconnect.
  timeout: 45_000

# Mount the test-only /__error_test__/boom route (router.ex) so the RenderErrors
# integration tests can exercise ErrorJSON/ErrorHTML through the real endpoint.
config :barkpark, error_test_routes: true

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :barkpark, BarkparkWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "/WlOyDI2/9z2XIW0syrE1JBZpUAiuyRHm9KLShzBXqB35t3S1Y0gP1WIrI2azToL",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Drive Oban manually in tests so we can drain queues from assertions.
#
# This block sets ONLY `testing: :manual` — it does NOT override `:queues`, so
# the queue list from `config/config.exs` (which now includes `edge_projector: 2`
# alongside `indx: 2`) is INHERITED here verbatim. Config import order is
# config.exs then test.exs, and Oban merges on the keys each file sets, so the
# `:edge_projector` queue flows into the test env. The EdgeProjector tests still
# drive the worker via `Oban.Testing.with_testing_mode(:inline, fn -> ... end)`
# or `perform_job/2` — `testing: :manual` means enqueued jobs do NOT auto-run.
# If a future edit adds a `:queues` key here, `edge_projector` MUST be added too.
config :barkpark, Oban, testing: :manual

# Search analytics inserts run synchronously in tests (no Task race).
config :barkpark, :search_analytics_async, false

# Self-update stays OFF (no Checker in the tree) and the upstream client is
# the scripted Fake — tests prime it per-call via Application env.
config :barkpark, Barkpark.SelfUpdate,
  enabled: false,
  client: Barkpark.SelfUpdate.Client.Fake

# Core-auth mailer captured in-process during tests (assert_email).
config :barkpark, Barkpark.Mailer, adapter: Swoosh.Adapters.Test

# Fixed paper-ingest secret for tests.
config :barkpark, :ingest_token, "barkpark-test-ingest-token"
config :barkpark, :media_signing_secret, "test-media-signing-secret"
config :barkpark, :media_processing_callback_token, "test-media-processing-callback-token"

# SSRF guard escape hatch (Barkpark.Net.SafeOutbound). Tests dispatch webhooks
# at Bypass on 127.0.0.1, which the guard would otherwise refuse. Prod/runtime
# leaves this false so tenant webhook URLs cannot reach internal hosts.
config :barkpark, :allow_private_outbound, true

# The boot-time codelist seeders do DB writes from the SchemaBootstrap process
# before any test owns an Ecto sandbox connection ("cannot find ownership
# process"), which intermittently cascades into unrelated test setups. Tests that
# need codelist data seed it explicitly, so skip the boot pass here.
config :barkpark, run_boot_codelist_seeders: false

# Pulse (Shared Storm): one channel fixture so the public-surface tests can
# exercise ingest/feed/caps end-to-end. Prod channels come from
# BARKPARK_PULSE_CHANNELS (runtime.exs); default everywhere is %{} = closed.
config :barkpark, :pulse_channels, %{
  "test-storm" => %{
    "fields" => %{
      "hue" => ["int", 0, 359],
      "x" => ["float", 0, 1],
      "y" => ["float", 0, 1],
      "mega" => ["bool"],
      "chg" => ["float", 0, 1, 0]
    },
    "rate_per_min" => 600,
    "daily_cap" => 100_000
  }
}
