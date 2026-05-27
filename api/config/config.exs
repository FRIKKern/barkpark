# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :barkpark,
  ecto_repos: [Barkpark.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  media_upload_dir: Path.expand("../uploads", __DIR__)

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

config :barkpark, :media_signing_secret, "dev-media-signing-secret-change-in-prod"

config :barkpark, :media_cdn,
  base_url: nil,
  invalidation: [adapter: :noop]

config :barkpark, :media_webhooks, endpoints: []

config :barkpark, :media_processing_callback_token, "dev-media-processing-callback-token"

# Fallback CORS allowlist for API routes without a dataset path segment
# (e.g. /v1/meta, /media without ?dataset=, legacy /api/*).
config :barkpark, :default_cors_origins, []

# Shared secret for the paperflow → Barkpark paper-ingest endpoint
# (convergence MVP, masterplan Figure 6). Matches BARKPARK_INGEST_TOKEN
# from ~/.paperflow/barkpark.env. Overridden per-env: runtime.exs reads
# PAPERFLOW_INGEST_TOKEN in prod; dev.exs/test.exs set a local default.
config :barkpark, :paperflow_ingest_token, nil

config :barkpark, :search_query_exclude_patterns, [
  ~r/^(test|asdf|qwerty|foo|bar)$/i
]

# W7-05: the `tasks_ttl` queue is concurrency=1 per node — only one TTL
# sweep runs at a time on a given node, defense in depth against double-
# sweeping the same expired claim (the per-task advisory lock inside the
# worker is the authoritative serializer; queue=1 keeps the noise floor
# low on small clusters and avoids ten redundant SELECT scans every
# `task_lease_sweep_interval_seconds`).
config :barkpark, Oban,
  repo: Barkpark.Repo,
  queues: [default: 10, bokbasen: 4, plugins: 6, tasks_ttl: 1, tasks_compact: 1],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"30 3 * * *", Barkpark.Search.Workers.Crystallize},
       {"0 4 * * *", Barkpark.Search.Workers.Prune},
       # W7-05 TTL sweep — runs every minute (the finest Oban.Cron
       # granularity). Sub-minute cadence is intentionally NOT
       # supported; see :task_lease_ttl_seconds comment below.
       {"* * * * *", Barkpark.Tasks.TtlSweeper},
       # W7-06 task-document compaction — every 6 hours. Coarser than
       # TTL sweep because compaction is batch storage maintenance, not
       # real-time crash recovery. The per-task advisory lock (same key
       # as TtlSweeper / Tasks.close) serializes with claim/close/sweep.
       {"0 */6 * * *", Barkpark.Tasks.Compactor}
     ]}
  ]

# W7-05 — TTL sweep tuning. Tests override `:task_lease_ttl_seconds`
# (e.g. to 0 / 1) to make sweep-or-not deterministic. The default
# 5-minute lease is the contract: any worker that hasn't refreshed
# its claim.ts_iso in 300 s is considered crashed. Sweep cadence is
# fixed by the Oban.Cron entry above — once per minute. Sub-minute
# cadence is intentionally NOT supported: paperflow's recovery SLO
# is "minutes, not seconds," and the per-minute cron + per-task
# advisory lock + fencing epoch already cover the crash path
# without driving Oban poll pressure higher than the rest of the
# fleet (Search.Crystallize / Prune are daily).
config :barkpark, :task_lease_ttl_seconds, 300

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
