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
config :barkpark_cloud, BarkparkCloud.Billing,
  gateway: BarkparkCloud.Billing.StubGateway,
  # Plan → gateway-side price id (cloud-17). PLACEHOLDERS in dev/test — a human
  # wires the REAL Stripe price ids at Gate 4; runtime.exs overrides each from
  # STRIPE_PRICE_<PLAN> in prod. "free" has NO price → it never opens a checkout.
  prices: %{
    "supporter" => "price_PLACEHOLDER_supporter",
    "support_plus" => "price_PLACEHOLDER_support_plus"
  },
  # Plan → the max number of managed Barkpark instances a team on that plan may
  # hold (usage-limits-quotas). This is the QUOTA half of go-live — Coolify's
  # `Team::serverLimit` — distinct from the ENTITLEMENT half (active-or-not,
  # the 402 gate), which already gates launch. These are PLACEHOLDER ceilings;
  # the real commercial numbers are HUMAN task cloud-17, the same gate as
  # `prices`. runtime.exs makes the self-serve tiers env-overridable in prod.
  # Every plan that can be an ACTIVE subscription needs a key: `trial` is the
  # signup grant (BILL-1) and `forever` is the admin comp (effectively
  # unlimited). `none` is the fallback for a team with NO active subscription
  # (already 402-blocked at go-live; 0 keeps the internal register path honest).
  limits: %{
    "free" => 1,
    "trial" => 1,
    "supporter" => 3,
    "support_plus" => 10,
    "forever" => 1_000_000,
    "none" => 0
  }

# OAuth/SSO (oauth-sso): "Continue with GitHub / Google". Dev/test DEFAULT —
# empty client creds ⇒ both providers DISABLED (no buttons, the routes 404), so
# the app boots with social login simply off until creds are supplied. prod
# wires real creds + the verified-TLS http_client from env in runtime.exs;
# test.exs sets a fixed state_secret + a stub http_client (hermetic, €0). The
# state_secret here is a DEV-ONLY placeholder (same discipline as the
# Registry.Vault dev key above) — it is the HMAC key for the single-use CSRF
# state token, NOT a provider secret. See BarkparkCloud.OAuth.
config :barkpark_cloud, BarkparkCloud.OAuth,
  base_url: "http://localhost:4100",
  state_secret: "dev-only-oauth-state-secret-change-me",
  http_client: nil,
  providers: %{
    "github" => %{
      module: BarkparkCloud.OAuth.Github,
      client_id: nil,
      client_secret: nil
    },
    "google" => %{
      module: BarkparkCloud.OAuth.Google,
      client_id: nil,
      client_secret: nil
    }
  }

# Web (cloud-12a): the minimal JSON HTTP API (Plug.Router + Bandit) that exposes
# the Accounts/Registry/Billing contexts to the agent (cloud-10) and the Go CLI
# client (cloud-12b). `server` controls whether the Bandit listener joins the
# supervision tree; `port` is the listen port. Defaults here; test.exs sets
# `server: false` (the router is driven directly via Plug.Test), runtime.exs
# reads PORT in prod. NOT Phoenix — there is no dashboard yet (a later task).
config :barkpark_cloud, BarkparkCloud.Web.Endpoint, server: true, port: 4100

# oban-substrate: the cloud control plane's job + cron engine. Postgres-backed
# on BarkparkCloud.Repo (no Redis). A near-verbatim port of the proven api/ Oban
# setup (api/config/config.exs:81-118), trimmed to what the control plane needs
# today. Queues are sized small — the cloud plane is a low-volume control plane,
# not a content firehose:
#
#   * maintenance — recurring housekeeping (the stale-provision-job reaper today;
#     health-staleness sweeps, usage downgrade, billing reconcile later). Low
#     concurrency: these are cheap scans that must not stampede.
#   * default     — ad-hoc / fan-out work enqueued by request handlers
#     (notification dispatch, backup kickoff) once those slugs land.
#
# Adding a queue here is the ONLY place a new recurring subsystem needs to touch
# this file — workers name their queue via `use Oban.Worker, queue: :…`. Unlike
# api/, cloud/ has NO plugin system, so the crontab is fully static (no boot-time
# plugin-crontab merge seam — YAGNI until a plugin layer exists).
config :barkpark_cloud, Oban,
  repo: BarkparkCloud.Repo,
  queues: [
    default: 10,
    maintenance: 2
  ],
  plugins: [
    # Reap finished/discarded job rows after 7 days so oban_jobs never grows
    # unbounded (same retention api/ uses — control-plane volume is far lower, so
    # 7 days is harmless and keeps a useful audit window).
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Recurring schedule. One entry today: the stale-provision-job reaper every
    # minute, mirroring api/'s per-minute TtlSweeper cadence. Sibling slugs add
    # their own entries here (e.g. {"0 4 * * *", BackupWorker}).
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", BarkparkCloud.Workers.StaleProvisionJobReaper}
     ]}
  ]

# notifications-email: the PLATFORM mailer transport. Dev = in-memory Local
# mailbox (no network). test.exs swaps in Swoosh.Adapters.Test; runtime.exs swaps
# in Swoosh.Adapters.SMTP (gen_smtp) from env in prod. Per-team SMTP rides a
# per-call config override carried in the Notifications context — one mailer
# module serves both. Same config-selected-adapter seam as Billing.Gateway.
config :barkpark_cloud, BarkparkCloud.Mailer, adapter: Swoosh.Adapters.Local

# Platform From + identity. from_address / from_name are read by Mailer.from/0;
# runtime.exs overrides each from MAIL_FROM_* in prod. No secret here.
config :barkpark_cloud, BarkparkCloud.Notifications,
  from_address: "noreply@barkpark.cloud",
  from_name: "Barkpark Cloud"

# No HTTP-client dep for the SMTP/Local/Test adapters — only a hosted-API adapter
# (Resend/SendGrid, deferred) would need one. Keeps the "no new HTTP dep" posture
# the Billing layer already took (:httpc via Billing.HttpClient).
config :swoosh, :api_client, false

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
